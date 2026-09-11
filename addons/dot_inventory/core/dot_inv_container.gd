class_name DotInvContainer
extends RefCounted

## One place things go: a grid of cells, or a list of slots.
##
## Both shapes in one class rather than two, because everything that is interesting —
## weight, capacity, stacking, what a slot accepts, the placement test — is the same for
## both, and only the geometry differs. Two classes would be two copies of the
## interesting half.
##
## [b]The occupancy map is derived, never stored.[/b] Two representations of one fact is
## the bug this family has shipped most often in its own shape: dot-props used one list
## for ownership and undo, so trimming the undo depth removed props from their owner's
## account, and a player could hold any number of props for free. A grid whose cell map
## and whose item list can disagree is the same bug with a nicer interface.

enum Shape { GRID, SLOTS }

## What is in it. uid -> [code]{item, count, cell, rotated, state}[/code].
##
## Keyed by a per-entry uid rather than by a position, because a move is then a change of
## one field instead of a delete and an insert — which matters when a server is refusing
## one move out of a batch.
var entries: Dictionary = {}

var id: StringName = &""
var shape: Shape = Shape.GRID
var width: int = 1
var height: int = 1
var slots: int = 1

## Kilograms, or whatever the game counts. Zero is no limit.
var weight_cap: float = 0.0

## Tags this container accepts. Empty accepts anything.
var accepts: Array[StringName] = []

var _next_uid: int = 1


static func from_definition(p_id: StringName, d: Dictionary) -> DotInvContainer:
	var c := DotInvContainer.new()
	c.id = p_id
	if str(d.get("kind", "grid")) == "slots":
		c.shape = Shape.SLOTS
		c.slots = maxi(1, int(d.get("slots", 1)))
	else:
		c.shape = Shape.GRID
		c.width = maxi(1, int(d.get("width", 1)))
		c.height = maxi(1, int(d.get("height", 1)))
	c.weight_cap = float(d.get("weight_cap", 0.0))
	var raw: Array = d.get("accepts", [])
	for t in raw:
		c.accepts.append(StringName(str(t)))
	return c


func capacity() -> int:
	return slots if shape == Shape.SLOTS else width * height


# --- Occupancy --------------------------------------------------------------

## The cells an entry covers. Derived from the entry, never stored beside it.
func cells_of(entry: Dictionary, catalogue: DotInvCatalogue) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if shape == Shape.SLOTS:
		out.append(entry.get("cell", Vector2i.ZERO))
		return out
	var item := catalogue.find(StringName(str(entry.get("item", ""))))
	if item == null:
		return out
	var fp := item.footprint(bool(entry.get("rotated", false)))
	var at: Vector2i = entry.get("cell", Vector2i.ZERO)
	for y in range(fp.y):
		for x in range(fp.x):
			out.append(at + Vector2i(x, y))
	return out


## Whether [param item] fits at [param cell], ignoring [param ignore_uid].
##
## [param ignore_uid] is what makes "move this item one cell to the left" work at all: the
## item would otherwise collide with itself, and the obvious fix — remove then place — is
## the one that loses the item when the place half fails.
func fits(
	item: DotInvItem,
	cell: Vector2i,
	rotated: bool,
	catalogue: DotInvCatalogue,
	ignore_uid: int = 0
) -> DotResult:
	if not accepts.is_empty():
		var allowed := false
		for t in accepts:
			if item.has_tag(t) or item.fits_slot_tag(t):
				allowed = true
				break
		if not allowed:
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "'%s' does not belong in '%s'" % [item.id, id]
			)

	if shape == Shape.SLOTS:
		if cell.x < 0 or cell.x >= slots:
			return DotResult.fail(DotError.CODE_INVALID, "slot %d is outside '%s'" % [cell.x, id])
		for uid in entries.keys():
			if uid == ignore_uid:
				continue
			if Vector2i(entries[uid].get("cell", Vector2i.ZERO)).x == cell.x:
				return DotResult.fail(DotError.CODE_STATE, "slot %d is taken" % cell.x)
		return DotResult.success(null)

	var fp := item.footprint(rotated)
	if cell.x < 0 or cell.y < 0 or cell.x + fp.x > width or cell.y + fp.y > height:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' does not fit inside '%s' at %d,%d" % [item.id, id, cell.x, cell.y]
		)

	var taken := occupied_cells(catalogue, ignore_uid)
	for y in range(fp.y):
		for x in range(fp.x):
			if taken.has(cell + Vector2i(x, y)):
				return DotResult.fail(
					DotError.CODE_STATE,
					"something is already at %d,%d" % [cell.x + x, cell.y + y]
				)
	return DotResult.success(null)


## Every occupied cell, derived from the entries.
func occupied_cells(catalogue: DotInvCatalogue, ignore_uid: int = 0) -> Dictionary:
	var out := {}
	for uid in entries.keys():
		if uid == ignore_uid:
			continue
		for c in cells_of(entries[uid], catalogue):
			out[c] = uid
	return out


## The first place [param item] fits, trying rotation when it is allowed.
##
## Row-major, left to right, top to bottom, and rotation tried second at each cell rather
## than after a whole failed pass. Both are deliberate: it is what a player expects
## ("it went to the first empty space"), and it is deterministic, which means a server and
## a client that both auto-place agree without exchanging anything.
func first_fit(item: DotInvItem, catalogue: DotInvCatalogue) -> Dictionary:
	if shape == Shape.SLOTS:
		for s in range(slots):
			if fits(item, Vector2i(s, 0), false, catalogue).ok:
				return {"ok": true, "cell": Vector2i(s, 0), "rotated": false}
		return {"ok": false}

	for y in range(height):
		for x in range(width):
			var at := Vector2i(x, y)
			if fits(item, at, false, catalogue).ok:
				return {"ok": true, "cell": at, "rotated": false}
			if item.rotatable and item.size.x != item.size.y:
				if fits(item, at, true, catalogue).ok:
					return {"ok": true, "cell": at, "rotated": true}
	return {"ok": false}


# --- Weight -----------------------------------------------------------------

## Total weight, including everything nested inside.
##
## Recursive on purpose and bounded by the schema's depth, because the alternative — a
## bag whose weight does not count what is in it — is the exploit every game with nested
## containers has shipped at least once.
func total_weight(catalogue: DotInvCatalogue, doc: Object = null) -> float:
	var sum := 0.0
	for uid in entries.keys():
		var e: Dictionary = entries[uid]
		var item := catalogue.find(StringName(str(e.get("item", ""))))
		if item == null:
			continue
		sum += item.weight * float(e.get("count", 1))
		if item.kind == DotInvItem.Kind.CONTAINER and doc != null and doc.has_method("weight_of"):
			sum += float(doc.call("weight_of", e.get("child", &"")))
	return sum


func within_weight(added: float, catalogue: DotInvCatalogue, doc: Object = null) -> bool:
	if weight_cap <= 0.0:
		return true
	return total_weight(catalogue, doc) + added <= weight_cap + 0.0001


# --- Entries ----------------------------------------------------------------

func add_entry(entry: Dictionary) -> int:
	var uid := _next_uid
	_next_uid += 1
	entries[uid] = entry
	return uid


func remove_entry(uid: int) -> Dictionary:
	var e: Dictionary = entries.get(uid, {})
	entries.erase(uid)
	return e


func entry_at(cell: Vector2i, catalogue: DotInvCatalogue) -> int:
	var taken := occupied_cells(catalogue)
	return int(taken.get(cell, 0))


func count_of(item_id: StringName) -> int:
	var n := 0
	for uid in entries.keys():
		if str(entries[uid].get("item", "")) == String(item_id):
			n += int(entries[uid].get("count", 1))
	return n


func is_empty() -> bool:
	return entries.is_empty()


func to_dictionary() -> Dictionary:
	var out_entries := {}
	for uid in entries.keys():
		var e: Dictionary = (entries[uid] as Dictionary).duplicate(true)
		var cell: Vector2i = e.get("cell", Vector2i.ZERO)
		# A Vector2i does not survive JSON. Written as two numbers here rather than
		# stringified, because the two ends of a serialisation are exactly as capable of
		# never meeting as the two ends of a wire -- a stored voice mute in this family
		# came back as a warning for precisely that reason.
		e["cell"] = [cell.x, cell.y]
		out_entries[str(uid)] = e
	return {
		"id": String(id),
		"shape": "slots" if shape == Shape.SLOTS else "grid",
		"entries": out_entries,
		"next_uid": _next_uid,
	}


func adopt(d: Dictionary) -> void:
	entries.clear()
	var raw: Dictionary = d.get("entries", {})
	for key in raw.keys():
		var e: Dictionary = (raw[key] as Dictionary).duplicate(true)
		var cell: Variant = e.get("cell", [0, 0])
		if cell is Array and (cell as Array).size() >= 2:
			e["cell"] = Vector2i(int(cell[0]), int(cell[1]))
		entries[int(str(key))] = e
	_next_uid = maxi(1, int(d.get("next_uid", 1)))


func describe_lines(catalogue: DotInvCatalogue) -> PackedStringArray:
	var out := PackedStringArray()
	var where := "%dx%d" % [width, height] if shape == Shape.GRID else "%d slots" % slots
	out.append("%s (%s) %d entries, %.2f kg%s" % [
		id,
		where,
		entries.size(),
		total_weight(catalogue),
		" of %.2f" % weight_cap if weight_cap > 0.0 else "",
	])
	for uid in entries.keys():
		var e: Dictionary = entries[uid]
		var cell: Vector2i = e.get("cell", Vector2i.ZERO)
		out.append("  #%-4d %-20s x%-4d @%d,%d%s" % [
			uid,
			str(e.get("item", "")),
			int(e.get("count", 1)),
			cell.x,
			cell.y,
			" rotated" if bool(e.get("rotated", false)) else "",
		])
	return out
