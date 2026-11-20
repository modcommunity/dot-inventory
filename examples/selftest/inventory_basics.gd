extends Node

## The first half of inventory_selftest: the counters and helpers every section shares, the
## test catalogue and manager, and the checks on items, grid placement, stacking, moving and
## weight. The refusals, nesting, rollback, panel and wire checks live in the scene script.

var _passed := 0
var _failed := 0
var _section_count := 0


func _catalogue() -> DotInvCatalogue:
	var c := DotInvCatalogue.new()

	var ammo := DotInvItem.new()
	ammo.id = &"ammo"
	ammo.name_key = &"item.ammo"
	ammo.kind = DotInvItem.Kind.STACKABLE
	ammo.stack_max = 30
	ammo.weight = 0.01
	ammo.tags = [&"ammunition"]
	c.add(ammo)

	var rifle := DotInvItem.new()
	rifle.id = &"rifle"
	rifle.name_key = &"item.rifle"
	rifle.kind = DotInvItem.Kind.UNIQUE
	rifle.size = Vector2i(4, 2)
	rifle.weight = 3.5
	rifle.slot_tags = [&"primary"]
	rifle.tags = [&"weapon"]
	c.add(rifle)

	var brick := DotInvItem.new()
	brick.id = &"brick"
	brick.kind = DotInvItem.Kind.UNIQUE
	brick.size = Vector2i(2, 2)
	brick.weight = 20.0
	brick.rotatable = false
	c.add(brick)

	var pouch := DotInvItem.new()
	pouch.id = &"pouch"
	pouch.kind = DotInvItem.Kind.CONTAINER
	pouch.container_id = &"pouch_space"
	pouch.size = Vector2i(2, 2)
	pouch.weight = 0.5
	c.add(pouch)

	c.add_grid(&"backpack", 6, 4, 30.0)
	c.add_grid(&"pouch_space", 2, 2)
	c.add_slots(&"belt", 3, [&"ammunition"])
	c.add_slots(&"equipment", 2, [&"primary"])
	return c


func _manager(containers: Array = [&"backpack", &"belt"]) -> DotInvManager:
	var m := DotInvManager.new()
	m.catalogue = _catalogue()
	m.register_as_service = false
	m.ops_per_second = 0
	add_child(m)
	m.setup(containers)
	return m


func _test_items() -> void:
	_section("An item is a document with no content in it")

	var i := DotInvItem.new()
	_check(not i.validate().ok, "an item with no id is refused")
	i.id = &"x"
	_check(i.validate().ok, "and one with an id and a size is fine")

	i.kind = DotInvItem.Kind.UNIQUE
	i.stack_max = 4
	_check(
		not i.validate().ok,
		"a unique item that stacks is refused, because state cannot be merged"
	)
	i.stack_max = 1
	i.kind = DotInvItem.Kind.CONTAINER
	_check(not i.validate().ok, "and a container that opens into nothing")

	var rifle := _catalogue().find(&"rifle")
	_check(rifle.footprint(false) == Vector2i(4, 2), "a footprint is the size")
	_check(rifle.footprint(true) == Vector2i(2, 4), "and rotates")
	var brick := _catalogue().find(&"brick")
	_check(
		brick.footprint(true) == Vector2i(2, 2),
		"while something that may not rotate does not, even when asked"
	)

	var c := _catalogue()
	_check(c.validate().ok, "the catalogue validates")
	var orphan := DotInvCatalogue.new()
	var bag := DotInvItem.new()
	bag.id = &"bag"
	bag.kind = DotInvItem.Kind.CONTAINER
	bag.container_id = &"nowhere"
	orphan.add(bag)
	_check(
		not orphan.validate().ok,
		"and a container opening into a shape nothing declares is caught at boot"
	)

	var shape := c.container(&"backpack")
	shape["width"] = 99
	_check(
		int(c.container(&"backpack")["width"]) == 6,
		"a container shape is handed out as a copy, not as the catalogue's own dictionary"
	)

	# The same aliasing one level down, and the more dangerous one: a catalogue item is ONE
	# object shared by every stack of it in every container, so a game writing into
	# `item.meta` about one rifle has written it onto every rifle in the world.
	rifle.meta = {"ammo_type": &"762", "nested": {"n": 1}}
	var taken := rifle.meta_copy()
	taken["ammo_type"] = &"tampered"
	(taken["nested"] as Dictionary)["n"] = 99
	_check(
		rifle.meta["ammo_type"] == &"762",
		"meta is handed out as a copy, so one stack's notes are not every stack's"
	)
	_check(
		int((rifle.meta["nested"] as Dictionary)["n"]) == 1,
		"deeply, because a nested dictionary in a shallow copy is still the catalogue's"
	)
	var one: Variant = rifle.meta_value(&"nested")
	(one as Dictionary)["n"] = 77
	_check(
		int((rifle.meta["nested"] as Dictionary)["n"]) == 1,
		"and one value out of it is copied too"
	)
	_check(
		rifle.meta_value(&"absent", "fallback") == "fallback",
		"with a fallback for what is not there, rather than null"
	)


func _test_grid_placement() -> void:
	_section("A grid, and the occupancy that is never stored")

	var m := _manager()
	var res := m.apply(DotInvOp.add(&"rifle", 1, &"backpack"))
	_check(res.ok, "an item goes into the bag")
	var bag := m.doc.get_container(&"backpack")
	_check(bag.entries.size() == 1, "as one entry")

	var uid: int = bag.entries.keys()[0]
	var cells := bag.cells_of(bag.entries[uid], m.catalogue)
	_check(cells.size() == 8, "occupying its whole footprint")
	_check(
		bag.occupied_cells(m.catalogue).size() == 8,
		"and the occupancy map is derived from that, so the two cannot disagree"
	)

	# Two representations of one fact is this family's own most expensive bug shape:
	# GameSpice Props used one list for ownership and undo, and trimming it for one purpose
	# silently changed the other.
	_check(
		bag.entry_at(Vector2i(0, 0), m.catalogue) == uid,
		"a cell knows what is in it without anything having stored that"
	)
	_check(bag.entry_at(Vector2i(5, 3), m.catalogue) == 0, "and an empty cell knows it is empty")

	var overlap := DotInvOp.add(&"rifle", 1, &"backpack")
	overlap.to_cell = Vector2i(0, 0)
	_check(not m.apply(overlap).ok, "something cannot be placed on top of something else")

	var outside := DotInvOp.add(&"rifle", 1, &"backpack")
	outside.to_cell = Vector2i(4, 0)
	_check(not m.apply(outside).ok, "nor hanging over the edge")

	# Rotation is tried at each cell rather than after a whole failed pass, so a 4x2 rifle
	# goes into a 2x4 gap instead of being refused.
	var m2 := _manager()
	m2.apply(DotInvOp.add(&"rifle", 1, &"backpack"))
	m2.apply(DotInvOp.add(&"rifle", 1, &"backpack"))
	var third := m2.apply(DotInvOp.add(&"rifle", 1, &"backpack"))
	_check(third.ok, "three 4x2 rifles fit in a 6x4 bag, which needs one of them turned")
	var rotated := 0
	for e_uid in m2.doc.get_container(&"backpack").entries.keys():
		if bool(m2.doc.get_container(&"backpack").entries[e_uid].get("rotated", false)):
			rotated += 1
	_check(rotated >= 1, "and at least one of them was turned to do it")

	m.queue_free()
	m2.queue_free()


func _test_stacking() -> void:
	_section("Stacks, and the complaint every inventory gets")

	var m := _manager()
	m.apply(DotInvOp.add(&"ammo", 10, &"backpack"))
	m.apply(DotInvOp.add(&"ammo", 10, &"backpack"))
	var bag := m.doc.get_container(&"backpack")
	_check(
		bag.entries.size() == 1,
		"a second pickup tops up the first stack rather than making a second one beside it"
	)
	_check(bag.count_of(&"ammo") == 20, "with everything in it")

	m.apply(DotInvOp.add(&"ammo", 25, &"backpack"))
	_check(bag.entries.size() == 2, "and overflows into a new stack at the stack limit")
	_check(bag.count_of(&"ammo") == 45, "keeping the total right")

	var uid: int = bag.entries.keys()[0]
	var split := m.apply(DotInvOp.split(&"backpack", uid, 5, Vector2i(4, 3)))
	_check(split.ok, "a stack splits")
	_check(bag.count_of(&"ammo") == 45, "without changing the total")

	var whole := DotInvOp.split(&"backpack", uid, 30, Vector2i(5, 3))
	_check(
		not m.apply(whole).ok,
		"and splitting the whole stack is refused, because that is a move and they are not the same op"
	)

	# A partial merge: a full stack dropped on one with room for five moves five. Built
	# explicitly, not searched for: a test looking for "the stack of thirty" breaks when the
	# top-up rule changes, and then reports a bug in the merge.
	var fresh := _manager()
	var fbag := fresh.doc.get_container(&"backpack")
	var full_op := DotInvOp.add(&"ammo", 30, &"backpack")
	full_op.to_cell = Vector2i(0, 0)
	fresh.apply(full_op)
	var small_op := DotInvOp.add(&"ammo", 25, &"backpack")
	small_op.to_cell = Vector2i(2, 0)
	fresh.apply(small_op)
	var full := fbag.entry_at(Vector2i(0, 0), fresh.catalogue)
	var partial := fbag.entry_at(Vector2i(2, 0), fresh.catalogue)
	_check(full > 0 and partial > 0, "there is a full stack and a smaller one")
	_check(int(fbag.entries[partial]["count"]) == 25, "of twenty-five")

	var merged := fresh.apply(DotInvOp.merge(&"backpack", full, &"backpack", partial))
	_check(merged.ok, "a merge onto a stack with room works")
	_check(
		int(fbag.entries[partial]["count"]) == 30,
		"filling it to the limit rather than refusing the whole drag"
	)
	_check(
		fbag.entries.has(full) and int(fbag.entries[full]["count"]) == 25,
		"and leaving the remainder where it was, which is what every player expects"
	)

	_check(
		not fresh.apply(DotInvOp.merge(&"backpack", full, &"backpack", full)).ok,
		"merging a stack with itself is refused"
	)
	fresh.queue_free()

	m.queue_free()


func _test_moving() -> void:
	_section("Moving, including one cell to the left")

	var m := _manager()
	m.apply(DotInvOp.add(&"rifle", 1, &"backpack"))
	var bag := m.doc.get_container(&"backpack")
	var uid: int = bag.entries.keys()[0]

	# The bug ignore_uid exists for: an item collides with itself, and the obvious
	# workaround -- remove, then place -- loses the item when the place half fails.
	var nudge := m.apply(DotInvOp.move(&"backpack", uid, &"backpack", Vector2i(1, 0)))
	_check(nudge.ok, "an item can be moved one cell, past itself")
	var new_uid: int = bag.entries.keys()[0]
	_check(
		Vector2i(bag.entries[new_uid]["cell"]) == Vector2i(1, 0),
		"and lands where it was sent"
	)
	_check(bag.entries.size() == 1, "with exactly one of it afterwards")

	var slots := m.doc.get_container(&"belt")
	_check(
		not m.apply(DotInvOp.move(&"backpack", new_uid, &"belt", Vector2i(0, 0))).ok,
		"a container that only accepts ammunition refuses a rifle"
	)
	m.apply(DotInvOp.add(&"ammo", 5, &"backpack"))
	var ammo_uid := 0
	for u in bag.entries.keys():
		if str(bag.entries[u].get("item", "")) == "ammo":
			ammo_uid = u
	_check(
		m.apply(DotInvOp.move(&"backpack", ammo_uid, &"belt", Vector2i(0, 0))).ok,
		"and accepts what it is for"
	)
	_check(slots.entries.size() == 1, "which arrives in the slot")
	_check(bag.count_of(&"ammo") == 0, "and has left the bag, rather than being in both")

	_check(
		not m.apply(DotInvOp.move(&"backpack", 99999, &"belt", Vector2i(1, 0))).ok,
		"moving something that is not there is refused"
	)

	m.queue_free()


func _test_weight() -> void:
	_section("Weight, including what is inside what")

	var m := _manager()
	var bag := m.doc.get_container(&"backpack")
	_check(is_equal_approx(bag.total_weight(m.catalogue, m.doc), 0.0), "an empty bag weighs nothing")

	m.apply(DotInvOp.add(&"brick", 1, &"backpack"))
	_check(
		is_equal_approx(bag.total_weight(m.catalogue, m.doc), 20.0),
		"and one with a brick in it weighs the brick"
	)

	# 20 kg in, 30 kg cap: the second brick would be 40 and is refused. There is plenty of
	# room for it -- a 6x4 bag holds six 2x2 bricks -- which is exactly the point: a weight
	# cap and a space cap are two different limits and a refusal has to say which one it is.
	var second := m.apply(DotInvOp.add(&"brick", 1, &"backpack"))
	_check(not second.ok, "a second brick is refused: 40 kg in a 30 kg bag")
	_check(
		second.code() == DotError.CODE_QUOTA,
		"for being too heavy rather than for not fitting, which are different answers"
	)
	_check(
		bag.first_fit(m.catalogue.find(&"brick"), m.catalogue).get("ok", false),
		"and there was room for it, so the weight cap is what refused it"
	)

	var light := m.apply(DotInvOp.add(&"ammo", 30, &"backpack"))
	_check(light.ok, "while something light still goes in")

	m.queue_free()


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
