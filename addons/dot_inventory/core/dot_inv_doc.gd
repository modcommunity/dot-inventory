class_name DotInvDoc
extends RefCounted

## A whole inventory: several containers, some of them inside items in the others.
##
## [b]Nesting is bounded and cycles are refused, and both are load-bearing.[/b] A bag put
## inside itself is an infinite loop in every traversal — weight, save, draw, search — and
## the symptom is a hang rather than a wrong number. A bag inside a bag inside a bag with
## no limit is a save file whose size is a player's patience, and a server that has to walk
## it on every validation.
##
## [method can_nest] answers both questions in one pass, and it is called before the move
## rather than after: a cycle that has been created cannot be detected by anything that has
## to traverse the structure to look for it.

const CHANNEL := "inventory"

## container id -> [DotInvContainer].
var containers: Dictionary = {}

## The container id a child container hangs off, and which entry holds it.
## child id -> [code]{parent: StringName, uid: int}[/code].
var parents: Dictionary = {}

## How deep a container may be. Depth 0 is the root.
var max_depth: int = 3

var _next_child := 1


func add_container(c: DotInvContainer) -> void:
	containers[c.id] = c


func get_container(id: StringName) -> DotInvContainer:
	return containers.get(id)


func has_container(id: StringName) -> bool:
	return containers.has(id)


## Creates a container for an item that is one, and records who holds it.
func open_container(
	parent_id: StringName, uid: int, definition: Dictionary, catalogue: DotInvCatalogue
) -> DotResult:
	var depth := depth_of(parent_id) + 1
	if depth > max_depth:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"a container %d deep, and %d is the limit" % [depth, max_depth],
			"unbounded nesting is a save file whose size is the player's patience"
		)
	var child_id := StringName("%s#%d" % [parent_id, _next_child])
	_next_child += 1
	var c := DotInvContainer.from_definition(child_id, definition)
	add_container(c)
	parents[child_id] = {"parent": parent_id, "uid": uid}
	var entry: Dictionary = (containers[parent_id] as DotInvContainer).entries.get(uid, {})
	entry["child"] = String(child_id)
	if catalogue != null:
		pass
	return DotResult.success(child_id)


func depth_of(id: StringName) -> int:
	var depth := 0
	var at := id
	var guard := 0
	while parents.has(at) and guard < 64:
		at = StringName(str((parents[at] as Dictionary).get("parent", "")))
		depth += 1
		guard += 1
	return depth


## Whether [param child] may be put inside [param into]. The cycle and depth test.
##
## Called before the move. A cycle that has already been created cannot be found by
## anything that traverses the structure looking for one — that traversal is the hang.
func can_nest(child: StringName, into: StringName) -> DotResult:
	if child == into:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "a container cannot be put inside itself"
		)
	# Walk up from the destination. If the child is anywhere above it, putting the child
	# in would close the loop.
	var at := into
	var guard := 0
	while parents.has(at) and guard < 64:
		if at == child:
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				"'%s' is already inside '%s'" % [into, child],
				"putting it in would make a loop, and every traversal of a loop is a hang"
			)
		at = StringName(str((parents[at] as Dictionary).get("parent", "")))
		guard += 1
	if depth_of(into) + 1 > max_depth:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "that would be %d containers deep" % (depth_of(into) + 1)
		)
	return DotResult.success(null)


## The weight of a container and everything under it.
func weight_of(id: StringName) -> float:
	var c: DotInvContainer = containers.get(id)
	return 0.0 if c == null else c.total_weight(_catalogue, self)


## Set by the manager so [method weight_of] can be called recursively from a container.
var _catalogue: DotInvCatalogue = null


## Every container, root first, then the ones inside it.
func ordered_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in containers.keys():
		if not parents.has(id):
			out.append(id)
	var i := 0
	while i < out.size():
		var here: StringName = out[i]
		for id in containers.keys():
			if parents.has(id) and StringName(str(parents[id].get("parent", ""))) == here:
				if not out.has(id):
					out.append(id)
		i += 1
	return out


## How many of [param item_id] the whole document holds.
func count_of(item_id: StringName) -> int:
	var n := 0
	for id in containers.keys():
		n += (containers[id] as DotInvContainer).count_of(item_id)
	return n


func to_dictionary() -> Dictionary:
	var out := {}
	for id in containers.keys():
		out[String(id)] = (containers[id] as DotInvContainer).to_dictionary()
	var parent_map := {}
	for id in parents.keys():
		parent_map[String(id)] = {
			"parent": str(parents[id].get("parent", "")),
			"uid": int(parents[id].get("uid", 0)),
		}
	return {
		"containers": out,
		"parents": parent_map,
		"max_depth": max_depth,
		"next_child": _next_child,
	}


func adopt(d: Dictionary, catalogue: DotInvCatalogue) -> DotResult:
	containers.clear()
	parents.clear()
	_catalogue = catalogue
	max_depth = int(d.get("max_depth", 3))
	_next_child = int(d.get("next_child", 1))

	var raw: Dictionary = d.get("containers", {})
	for key in raw.keys():
		var cd: Dictionary = raw[key]
		var c := DotInvContainer.new()
		c.id = StringName(str(key))
		c.shape = (
			DotInvContainer.Shape.SLOTS
			if str(cd.get("shape", "grid")) == "slots"
			else DotInvContainer.Shape.GRID
		)
		# The shape's numbers come back from the catalogue rather than from the document.
		# A stored width is a stored copy of a declaration, and the two go out of step the
		# first time somebody makes a backpack bigger -- with every old save silently
		# keeping the old size and nothing saying so.
		var def := catalogue.container(_definition_id_of(StringName(str(key))))
		if not def.is_empty():
			var fresh := DotInvContainer.from_definition(StringName(str(key)), def)
			c.width = fresh.width
			c.height = fresh.height
			c.slots = fresh.slots
			c.weight_cap = fresh.weight_cap
			c.accepts = fresh.accepts
			c.shape = fresh.shape
		c.adopt(cd)
		containers[c.id] = c

	var pm: Dictionary = d.get("parents", {})
	for key in pm.keys():
		parents[StringName(str(key))] = {
			"parent": StringName(str(pm[key].get("parent", ""))),
			"uid": int(pm[key].get("uid", 0)),
		}
	return DotResult.success(null)


## A nested container's id is `<parent>#<n>`; the definition it came from is the item's.
func _definition_id_of(id: StringName) -> StringName:
	var s := String(id)
	var cut := s.find("#")
	return StringName(s if cut < 0 else s.substr(0, cut))


func describe_lines(catalogue: DotInvCatalogue) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("inventory: %d containers, depth limit %d" % [containers.size(), max_depth])
	for id in ordered_ids():
		var prefix := "  " + "  ".repeat(depth_of(id))
		for line in (containers[id] as DotInvContainer).describe_lines(catalogue):
			out.append(prefix + line)
	return out
