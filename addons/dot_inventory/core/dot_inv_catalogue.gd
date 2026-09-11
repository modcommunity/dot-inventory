@tool
class_name DotInvCatalogue
extends Resource

## Every item and every container shape a game has, as a document.
##
## Validated at boot, on a server, with no icons, no meshes and no scenes — the same rule
## as dot-loadout's schema and dot-user-avatar's. What that buys is that a typo in an item
## id fails a start-up rather than producing an empty slot in a firefight.

@export var items: Array[DotInvItem] = []

## Container shapes, by id: [code]{width, height, slots, weight_cap, accepts}[/code].
##
## A dictionary rather than a resource per container because a container shape is four
## numbers and a list of tags, and this family has already found that nineteen of
## twenty-one status effects were the same six fields with different numbers.
@export var containers: Dictionary = {}

var _by_id: Dictionary = {}


func add(item: DotInvItem) -> DotInvCatalogue:
	items.append(item)
	_by_id.clear()
	return self


## Declares a grid container: w by h cells.
func add_grid(id: StringName, w: int, h: int, weight_cap: float = 0.0) -> DotInvCatalogue:
	containers[id] = {
		"kind": "grid", "width": w, "height": h, "weight_cap": weight_cap, "accepts": []
	}
	return self


## Declares a slot container: [param count] slots, each accepting [param accepts].
func add_slots(
	id: StringName, count: int, accepts: Array = [], weight_cap: float = 0.0
) -> DotInvCatalogue:
	containers[id] = {
		"kind": "slots", "slots": count, "weight_cap": weight_cap, "accepts": accepts
	}
	return self


func find(id: StringName) -> DotInvItem:
	_ensure_index()
	return _by_id.get(id)


func has(id: StringName) -> bool:
	_ensure_index()
	return _by_id.has(id)


func container(id: StringName) -> Dictionary:
	# Duplicated on the way out. A Dictionary is a reference in GDScript and this family
	# has shipped that aliasing four times -- a scoped leaderboard sharing its template's
	# dictionary being the first, and every board on the server ending up with the last
	# scope anybody asked for.
	var d: Dictionary = containers.get(id, {})
	return d.duplicate(true)


func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for i in items:
		out.append(i.id)
	return out


func _ensure_index() -> void:
	if _by_id.size() == items.size():
		return
	_by_id.clear()
	for i in items:
		if i != null:
			_by_id[i.id] = i


func validate() -> DotResult:
	var seen := {}
	for i in items:
		if i == null:
			return DotResult.fail(DotError.CODE_INVALID, "a null item in the catalogue")
		var res := i.validate()
		if not res.ok:
			return res
		if seen.has(i.id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"item id '%s' appears twice" % i.id,
				"the second one is unreachable and nothing would ever say so"
			)
		seen[i.id] = true

	for i in items:
		if i.kind == DotInvItem.Kind.CONTAINER and not containers.has(i.container_id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"'%s' opens into container '%s', which is not declared" % [i.id, i.container_id]
			)

	for key in containers.keys():
		var c: Dictionary = containers[key]
		var kind := str(c.get("kind", ""))
		if kind == "grid":
			if int(c.get("width", 0)) < 1 or int(c.get("height", 0)) < 1:
				return DotResult.fail(
					DotError.CODE_INVALID, "container '%s' has no cells" % key
				)
		elif kind == "slots":
			if int(c.get("slots", 0)) < 1:
				return DotResult.fail(
					DotError.CODE_INVALID, "container '%s' has no slots" % key
				)
		else:
			return DotResult.fail(
				DotError.CODE_INVALID, "container '%s' is neither a grid nor slots" % key
			)
	return DotResult.success(null)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("catalogue: %d items, %d container shapes" % [items.size(), containers.size()])
	for i in items:
		out.append("  %s" % i.describe_line())
	return out
