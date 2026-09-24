class_name DotInvLoadoutLink
extends RefCounted

## The one file in this addon that knows dot-loadout exists, and it does so by duck typing.
##
## [b]Deliberately one file.[/b] dot-npc-ai has the same arrangement with dot-npc — only
## one file in it names the other — and the reason is the family's hardest rule: apart from
## dot-core, nothing may be a hard dependency. Naming `DotLoadoutManager` anywhere in here
## would make this addon fail to parse in a project that does not have it, which is most
## projects.
##
## [b]The division between the two is real, not a naming accident.[/b]
##
## dot-loadout answers [i]what do you own and what did you bring in[/i]: a permanent,
## bounded document a server validates against a schema and entitlements before a match,
## with no content loaded. dot-inventory answers [i]what is in your bag right now[/i]: it
## changes every few seconds, it has a shape, things stack in it, and a server has to be
## able to refuse one move without refusing the whole document.
##
## What crosses between them is a list of ids, in one direction at a time, and what it
## crosses with is ONE PLAYER'S [code]DotLoadout[/code] -- the document, not the manager:
##
## [codeblock]
## var active: DotResult = await loadout_manager.active_for(user_key)
## var mine = active.value.duplicate_loadout()   # a copy: the manager caches the original
## var link := DotInvLoadoutLink.of(mine)
## link.fill_from_loadout(inventory, &"backpack")           # a match starts
## ...
## link.publish_to_loadout(inventory, &"backpack")          # a match ends
## await loadout_manager.publish(user_key, mine)            # validated and saved THERE
## [/codeblock]
##
## - [method fill_from_loadout] -- what a player brought becomes what is in their hands.
## - [method publish_to_loadout] -- what did not survive leaves the loadout.
##
## [b]The document, because that is the only thing in dot-loadout that answers per slot.[/b]
## This file used to duck-type against [code]slots()[/code], [code]item_in(slot)[/code] and
## [code]set_items(ids)[/code] on "the manager" -- and nothing in dot-loadout had the first
## or the last, so it only ever worked against the self-test's fake of itself. The manager
## is per-server and asynchronous ([code]active_for[/code] awaits a store); the document
## is per-player and synchronous, and what it has is [code]filled_slots()[/code],
## [code]item_in(slot)[/code], [code]count_in(slot, fallback)[/code], [code]set_item[/code]
## and [code]clear_slot(slot)[/code]. Those are what this reads and writes.
##
## [b]Saving is not this link's job.[/b] [code]DotLoadoutManager.publish[/code] is dot-loadout's
## trust boundary -- rate, cap, schema and entitlements -- and a link that wrote the store
## itself would be a way round it. The game hands the edited document to publish.
##
## Neither direction is automatic. A game decides when a round's inventory is worth keeping,
## because that is a design decision (an extraction game says yes, a round-based shooter says
## no) and not something an addon should assume.

const CHANNEL := "inventory"

## One player's loadout document: anything with [code]filled_slots()[/code] and
## [code]item_in(slot)[/code] -- dot-loadout's [code]DotLoadout[/code] in practice, which is
## not named here. [method publish_to_loadout] also needs [code]clear_slot(slot)[/code].
var loadout: Object = null

## Whether the "cannot use this loadout" warning has been written, so it is written once.
var _warned_unusable: bool = false


static func of(loadout_doc: Object) -> DotInvLoadoutLink:
	var l := DotInvLoadoutLink.new()
	l.loadout = loadout_doc
	return l


## Whether the object handed over can actually answer.
##
## Checked once, here, rather than at every call site. A link that reports it is not usable
## is a game that can say "this deployment has no loadouts" and carry on; a link that finds
## out at the first call is one that fails in the middle of a match start.
func usable() -> bool:
	if loadout == null or not is_instance_valid(loadout):
		return false
	return loadout.has_method("filled_slots") and loadout.has_method("item_in")


## Puts everything from a player's loadout into [param container].
##
## One op per slot, carrying the slot's count when the document has one
## ([code]count_in(slot, 1)[/code]; absent means one). Returns the ids it could not place. A
## loadout that does not fit in the bag it is being poured into is a configuration mistake,
## and the honest answer is to say which items were left rather than to silently drop them
## or to refuse the whole match start.
func fill_from_loadout(
	manager: DotInvManager, container_id: StringName, actor: StringName = &"local"
) -> PackedStringArray:
	var missed := PackedStringArray()
	if not usable():
		_warn_unusable("fill")
		return missed

	var has_counts := loadout.has_method("count_in")

	for slot in _slot_names():
		var item_id: Variant = loadout.call("item_in", slot)
		if item_id == null or DotValue.is_blank(item_id):
			continue
		var id := StringName(str(item_id))
		if not manager.catalogue.has(id):
			# An item a loadout names and this catalogue does not have is not an error
			# here. The two documents are validated against different schemas on purpose,
			# and a deployment that carries a cosmetic in one and not the other is
			# legitimate.
			missed.append(String(id))
			continue
		var n := maxi(1, int(loadout.call("count_in", slot, 1))) if has_counts else 1
		var res := manager.apply(DotInvOp.add(id, n, container_id), actor)
		if not res.ok:
			missed.append(String(id))
	return missed


## Clears every loadout slot whose item is no longer in [param container], and returns the
## slots it cleared.
##
## [b]Only removal crosses back.[/b] Which slot a newly found item belongs in is the loadout
## schema's question (kinds, tags, budgets, entitlements), and this file cannot ask it
## without naming dot-loadout. So an item picked up mid-match is left for the game to
## [code]set_item[/code] if it wants to keep it, and [code]DotLoadoutManager.publish[/code]
## then refuses whatever the schema would not have allowed. An id this inventory's catalogue
## does not carry is left alone. Two slots holding the same id
## need two of it to survive. Counts, positions, rotation and durability are the
## inventory's business and do not cross.
func publish_to_loadout(manager: DotInvManager, container_id: StringName) -> PackedStringArray:
	var cleared := PackedStringArray()
	if not usable() or not loadout.has_method("clear_slot"):
		_warn_unusable("publish")
		return cleared
	if manager.doc == null:
		return cleared
	var c := manager.doc.get_container(container_id)
	if c == null:
		return cleared

	var left := {}
	for slot in _slot_names():
		var item_id: Variant = loadout.call("item_in", slot)
		if item_id == null or DotValue.is_blank(item_id):
			continue
		var id := StringName(str(item_id))
		# An id this catalogue does not carry was never in the bag -- fill reported it as
		# missed -- so its absence says nothing about the match. Clearing it would strip a
		# cosmetic out of somebody's loadout at the end of every round.
		if not manager.catalogue.has(id):
			continue
		if not left.has(id):
			left[id] = c.count_of(id)
		if int(left[id]) > 0:
			left[id] = int(left[id]) - 1
			continue
		loadout.call("clear_slot", slot)
		cleared.append(str(slot))
	return cleared


## The filled slots, copied first: [method publish_to_loadout] clears slots while walking
## them, and the document's own list is built from the dictionary being changed.
func _slot_names() -> Array:
	var out: Array = []
	var names: Variant = loadout.call("filled_slots")
	if names is Array or names is PackedStringArray:
		for slot in names:
			out.append(slot)
	return out


## Once per link, and only when something WAS wired: a null loadout is a game with no
## dot-loadout, which is the ordinary case and not worth a line. Anything else that fails
## the duck-typed check means a round starts with empty hands, or ends without keeping
## what survived, and nothing else in the process would say why. WARN, because it is
## wiring somebody has to fix -- most likely the manager handed over where one player's
## document was meant.
func _warn_unusable(what: String) -> void:
	if _warned_unusable or loadout == null or not is_instance_valid(loadout):
		return
	_warned_unusable = true
	DotLog.warn(CHANNEL, "the loadout link cannot use what it was given; nothing crosses", {
		"during": what,
		"given": loadout.get_class() if loadout.get_script() == null
			else String(loadout.get_script().get_global_name()),
		"needs": "filled_slots(), item_in(slot), clear_slot(slot): one player's DotLoadout",
		"hint": "await loadout_manager.active_for(key) and link its value",
	})
