extends Node

## Exercises dot-inventory with no interface and no transport.
##
## The checks worth having are the ones about what a server must refuse: a move that does
## not fit, a bag put inside itself, a split that is really a move, a weight cap, and a
## rollback that does not duplicate. Every one of those is a real exploit in some shipped
## game, and none of them is visible in a screenshot.
##
## [codeblock]
## godot --headless --path . res://examples/inventory_selftest.tscn
## [/codeblock]

const SECTIONS := 9
const CHECKS := 104

var _passed := 0
var _failed := 0
var _section_count := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	# Awaited: the panel section waits a frame for a Control to lay itself out, and an
	# un-awaited coroutine returns at its first `await` with the caller carrying on.
	await _run()


func _run() -> void:
	_line("dot-inventory self-test")
	_line("")

	_test_items()
	_test_grid_placement()
	_test_stacking()
	_test_moving()
	_test_weight()
	_test_nesting()
	_test_rollback()
	_test_query_and_loadout()
	await _test_the_panel_asks_the_same_question()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


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


# --- 1 ----------------------------------------------------------------------

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


# --- 2 ----------------------------------------------------------------------

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
	# dot-props used one list for ownership and undo, and trimming it for one purpose
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


# --- 3 ----------------------------------------------------------------------

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

	# A partial merge: dragging a full stack onto one with room for five should move five
	# and leave the rest. Built explicitly rather than searched for -- a test that looks
	# for "the stack of thirty" is a test that breaks when the top-up rule changes, and
	# then reports a bug in the merge.
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


# --- 4 ----------------------------------------------------------------------

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


# --- 5 ----------------------------------------------------------------------

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


# --- 6 ----------------------------------------------------------------------

func _test_nesting() -> void:
	_section("A bag inside a bag, and never inside itself")

	var m := _manager()
	m.apply(DotInvOp.add(&"pouch", 1, &"backpack"))
	var bag := m.doc.get_container(&"backpack")
	var pouch_uid: int = bag.entries.keys()[0]
	var child := StringName(str(bag.entries[pouch_uid].get("child", "")))
	_check(child != &"", "a container item opens into a container")
	_check(m.doc.has_container(child), "which the document knows about")
	_check(m.doc.depth_of(child) == 1, "one level down")

	m.apply(DotInvOp.add(&"ammo", 10, child))
	_check(m.doc.get_container(child).count_of(&"ammo") == 10, "and things go into it")
	_check(
		m.doc.weight_of(&"backpack") > 0.5,
		"whose weight counts towards the bag holding it, which is the exploit otherwise"
	)

	# The one that hangs rather than being wrong: a cycle makes every traversal infinite.
	_check(
		not m.doc.can_nest(child, child).ok,
		"a container cannot be put inside itself"
	)

	# A 2x2 pouch needs all four cells of a 2x2 pouch, so the ammo has to come out first.
	# That is the space rule doing its job, not a nesting failure -- and the two look
	# identical from outside, which is why the ammo is dropped explicitly here.
	var ammo_in_pouch: int = m.doc.get_container(child).entries.keys()[0]
	m.apply(DotInvOp.drop(child, ammo_in_pouch))
	var nested := m.apply(DotInvOp.add(&"pouch", 1, child))
	_check(nested.ok, "a pouch goes inside an empty pouch")
	var inner_uid: int = m.doc.get_container(child).entries.keys()[0]
	var grandchild := StringName(str(m.doc.get_container(child).entries[inner_uid].get("child", "")))
	_check(grandchild != &"", "and opens into a container of its own")
	_check(m.doc.depth_of(grandchild) == 2, "two levels down")
	_check(
		not m.doc.can_nest(child, grandchild).ok,
		"and the outer one may not then be put inside the inner one, which would close the loop"
	)

	# And the depth bound, because unbounded nesting is a save file whose size is the
	# player's patience.
	m.doc.max_depth = 2
	_check(
		not m.doc.can_nest(&"backpack", grandchild).ok,
		"nesting stops at the declared depth"
	)

	# Dropping a container takes what is inside it with it.
	var before := m.doc.containers.size()
	m.apply(DotInvOp.drop(&"backpack", pouch_uid))
	_check(m.doc.containers.size() == before - 2, "dropping a bag removes it and everything under it")
	_check(not m.doc.has_container(grandchild), "including the one two levels down")

	m.queue_free()


# --- 7 ----------------------------------------------------------------------

func _test_rollback() -> void:
	_section("A client predicts, and a refusal does not duplicate anything")

	var sent := []
	var m := _manager()
	m.authoritative = false
	m.send_fn = func(op: Dictionary) -> void: sent.append(op)

	var res := m.apply(DotInvOp.add(&"rifle", 1, &"backpack"))
	_check(res.ok, "a client applies an op locally")
	_check(sent.size() == 1, "and sends it")
	_check(m.pending_count() == 1, "keeping it, which is what makes a rollback possible")
	_check(m.doc.get_container(&"backpack").entries.size() == 1, "the item is there")

	m.rollback(sent[0])
	_check(m.pending_count() == 0, "a refusal clears the pending op")
	_check(
		m.doc.get_container(&"backpack").entries.size() == 0,
		"and the item is gone, restored from the snapshot rather than from an inverse"
	)

	var again := m.apply(DotInvOp.add(&"ammo", 5, &"backpack"))
	_check(again.ok, "another op applies")
	m.confirm(sent[1])
	_check(m.pending_count() == 0, "a confirmation clears it without touching the document")
	_check(m.doc.get_container(&"backpack").count_of(&"ammo") == 5, "and the ammo is still there")

	# The rate limit, because an inventory is the cheapest denial of service a client has.
	var limited := _manager()
	limited.ops_per_second = 2
	limited.setup([&"backpack", &"belt"])
	var accepted := 0
	for _i in range(20):
		if limited.apply(DotInvOp.add(&"ammo", 1, &"backpack"), &"spammer").ok:
			accepted += 1
	_check(accepted <= 4, "a flood of operations is refused after a few (%d got through)" % accepted)
	_check(
		limited.apply(DotInvOp.add(&"ammo", 1, &"backpack"), &"somebody_else").ok,
		"and somebody else is not throttled by it, because the bucket is per actor"
	)

	# The round trip, because the two ends of a serialisation are exactly as capable of
	# never meeting as the two ends of a wire.
	var saved := m.to_dictionary()
	var loaded := _manager()
	_check(loaded.adopt(saved).ok, "a document round-trips")
	_check(
		loaded.doc.get_container(&"backpack").count_of(&"ammo") == 5,
		"with its contents"
	)
	var op_dict := DotInvOp.move(&"backpack", 3, &"belt", Vector2i(1, 0), true).to_dictionary()
	var back := DotInvOp.from_dictionary(op_dict)
	_check(back.to_cell == Vector2i(1, 0), "and so does an op, including its cell")
	_check(back.to_rotated, "and its rotation")

	m.queue_free()
	limited.queue_free()
	loaded.queue_free()


# --- 8 ----------------------------------------------------------------------

func _test_query_and_loadout() -> void:
	_section("Filtering is the client's, and dot-loadout is one file away")

	var m := _manager()
	m.apply(DotInvOp.add(&"rifle", 1, &"backpack"))
	m.apply(DotInvOp.add(&"ammo", 20, &"backpack"))
	m.apply(DotInvOp.add(&"brick", 1, &"backpack"))

	var q := DotInvQuery.new()
	_check(q.run(m.doc, m.catalogue).size() == 3, "an empty query finds everything")

	q.tags = [&"weapon"]
	_check(q.run(m.doc, m.catalogue).size() == 1, "a tag filter narrows it")

	q.tags = []
	q.text = "AMM"
	_check(q.run(m.doc, m.catalogue).size() == 1, "and a text search is case-insensitive")

	q.text = ""
	q.sort_by = DotInvQuery.Sort.WEIGHT
	var by_weight := q.run(m.doc, m.catalogue)
	_check(
		(by_weight[0]["item"] as DotInvItem).id == &"ammo",
		"sorting by weight puts the lightest first"
	)
	q.descending = true
	var heavy := q.run(m.doc, m.catalogue)
	_check(
		(heavy[0]["item"] as DotInvItem).id == &"brick",
		"and reversing puts the heaviest first"
	)

	# Ties are broken by id, always. sort_custom is not stable in Godot, so a sorted list
	# that reshuffles its ties on every redraw looks like a bug in the inventory.
	m.apply(DotInvOp.add(&"brick", 1, &"belt"))
	q.descending = false
	var first := q.run(m.doc, m.catalogue)
	var second := q.run(m.doc, m.catalogue)
	var stable := true
	for i in range(first.size()):
		if first[i]["uid"] != second[i]["uid"]:
			stable = false
	_check(stable, "and two runs of one query come out in the same order")

	var link := DotInvLoadoutLink.of(null)
	_check(not link.usable(), "a link with nothing behind it says so rather than failing later")
	_check(
		link.fill_from_loadout(m, &"backpack").is_empty(),
		"and does nothing at all when it is asked to"
	)

	var fake := FakeLoadout.new()
	var real := DotInvLoadoutLink.of(fake)
	_check(real.usable(), "a link to something that can answer is usable")
	var fresh := _manager()
	var missed := real.fill_from_loadout(fresh, &"backpack")
	_check(fresh.doc.get_container(&"backpack").count_of(&"rifle") == 1, "a loadout fills a bag")
	_check(
		missed.size() == 1 and missed[0] == "not_in_this_catalogue",
		"and reports what it could not place, rather than dropping it silently"
	)

	m.queue_free()
	fresh.queue_free()


class FakeLoadout:
	extends RefCounted

	## A stand-in for dot-loadout's manager: `slots()` and `item_in()` and nothing else,
	## which is exactly the surface DotInvLoadoutLink duck-types against.

	var published: PackedStringArray = PackedStringArray()

	func slots() -> PackedStringArray:
		return PackedStringArray(["primary", "secondary"])

	func item_in(slot: String) -> String:
		return "rifle" if slot == "primary" else "not_in_this_catalogue"

	func set_items(ids: PackedStringArray) -> void:
		published = ids


# --- 9 ----------------------------------------------------------------------

func _test_the_panel_asks_the_same_question() -> void:
	_section("A cell lights up because the manager said so")

	var m := _manager()
	m.apply(DotInvOp.add(&"rifle", 1, &"backpack"))
	var bag := m.doc.get_container(&"backpack")
	var uid: int = bag.entries.keys()[0]

	var panel := DotInvPanel.new()
	panel.name = "Panel"
	panel.manager = m
	panel.container_id = &"backpack"
	add_child(panel)
	await get_tree().process_frame
	await get_tree().process_frame

	# The one thing an assertion can reach about a Control, and the reason it is asserted:
	# `set_anchors_preset` does not set offsets, and this family has shipped 0 x 0
	# Controls twice with every property reading correctly both times.
	_check(panel.size.x > 0.0 and panel.size.y > 0.0, "the panel has a size")
	_check(
		panel.custom_minimum_size.x >= 6.0 * float(panel.cell_size),
		"as wide as the container it is drawing (%d cells)" % 6
	)

	var payload := {"uid": uid, "from": "backpack", "item": "rifle", "rotated": false}

	# The decision this class exists for: the highlight comes from the same call the
	# server will make. A panel with its own idea of what fits eventually disagrees, and
	# the player sees a move accepted on screen and undone a round trip later.
	_check(panel.may_drop(payload, Vector2i(1, 2)), "an empty cell accepts the drop")
	_check(
		not panel.may_drop(payload, Vector2i(5, 3)),
		"and one where it would hang over the edge does not"
	)
	_check(
		panel.may_drop(payload, Vector2i(0, 0)),
		"including the cell it is already in, because an item may not collide with itself"
	)

	# The drop first, while the bag is otherwise empty. Adding the brick before this
	# would make (1,1) a legitimate refusal -- a 4x2 rifle there reaches the cell the
	# brick is in -- and the failure would read as the drop being broken.
	var moves := []
	panel.moved.connect(func(_op: DotInvOp, r: DotResult) -> void: moves.append(r))
	var res := panel.do_drop(payload, Vector2i(1, 2))
	_check(res.ok, "a drop applies")
	_check(moves.size() == 1, "and announces itself once")
	var moved_uid: int = bag.occupied_cells(m.catalogue).get(Vector2i(1, 2), 0)
	_check(moved_uid != 0, "with the item where it was dropped")

	# Placed explicitly rather than left to first_fit. A 2x2 into whatever is left after a
	# 4x2 has moved is a placement that depends on the earlier drop, and a brick that did
	# not fit would leave the next three lines indexing a dictionary by zero -- which is
	# an aborted section rather than a failed check.
	var brick_op := DotInvOp.add(&"brick", 1, &"backpack")
	brick_op.to_cell = Vector2i(0, 0)
	_check(m.apply(brick_op).ok, "and something else goes in beside it")
	var brick_cell := Vector2i(0, 0)
	var moved_payload := {
		"uid": moved_uid, "from": "backpack", "item": "rifle", "rotated": false
	}
	_check(
		not panel.may_drop(moved_payload, brick_cell),
		"a cell something else is standing in is refused"
	)

	var refused := panel.do_drop(
		{"uid": 99999, "from": "backpack", "item": "rifle", "rotated": false},
		Vector2i(3, 3)
	)
	_check(not refused.ok, "and a drop of something that is not there is refused")

	# `note_pickup` / `dragging_uid` are the pair a game greys out the containers it will
	# not fit in with, and `dragging_uid` had no caller. The signal is asserted beside the
	# accessor because a value produced correctly and consumed by nothing looks exactly
	# like a value produced wrongly -- this family's second-most repeated shape.
	var picked := []
	panel.picked_up.connect(func(cid: StringName, u: int) -> void: picked.append([cid, u]))
	_check(panel.dragging_uid() == 0, "nothing is being dragged to begin with")
	panel.note_pickup(moved_uid)
	_check(panel.dragging_uid() == moved_uid, "picking something up records what it is")
	_check(
		picked.size() == 1 and picked[0][0] == &"backpack" and picked[0][1] == moved_uid,
		"and announces the container as well as the item, which is what a second panel needs"
	)

	panel.queue_free()
	m.queue_free()
	_done_panel()


func _done_panel() -> void:
	pass


# --- Harness ---------------------------------------------------------------

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
