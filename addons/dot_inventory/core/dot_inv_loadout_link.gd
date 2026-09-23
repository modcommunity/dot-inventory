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
## What crosses between them is a list of ids, in one direction at a time:
##
## - [method fill_from_loadout] — a match starts, and what a player brought becomes what is
##   in their hands.
## - [method publish_to_loadout] — a match ends, and what survived becomes what they own.
##
## Neither is automatic. A game decides when a round's inventory is worth keeping, because
## that is a design decision (an extraction game says yes, a round-based shooter says no)
## and not something an addon should assume.

const CHANNEL := "inventory"

## Anything with [code]slots()[/code] and [code]item_in(slot)[/code].
var loadout: Object = null

## Whether the "cannot use this loadout" warning has been written, so it is written once.
var _warned_unusable: bool = false


static func of(loadout_manager: Object) -> DotInvLoadoutLink:
	var l := DotInvLoadoutLink.new()
	l.loadout = loadout_manager
	return l


## Whether the object handed over can actually answer.
##
## Checked once, here, rather than at every call site. A link that reports it is not usable
## is a game that can say "this deployment has no loadouts" and carry on; a link that finds
## out at the first call is one that fails in the middle of a match start.
func usable() -> bool:
	if loadout == null or not is_instance_valid(loadout):
		return false
	return loadout.has_method("slots") and loadout.has_method("item_in")


## Puts everything from a player's loadout into [param container].
##
## Returns the ids it could not place. A loadout that does not fit in the bag it is being
## poured into is a configuration mistake, and the honest answer is to say which items
## were left rather than to silently drop them or to refuse the whole match start.
func fill_from_loadout(
	manager: DotInvManager, container_id: StringName, actor: StringName = &"local"
) -> PackedStringArray:
	var missed := PackedStringArray()
	if not usable():
		_warn_unusable("fill")
		return missed

	var slot_names: Variant = loadout.call("slots")
	if not (slot_names is Array or slot_names is PackedStringArray):
		return missed

	for slot in slot_names:
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
		var res := manager.apply(DotInvOp.add(id, 1, container_id), actor)
		if not res.ok:
			missed.append(String(id))
	return missed


## Reports what is in [param container] back to the loadout, id by id.
##
## Only ids. The count, the position, the rotation and the durability are the inventory's
## business and mean nothing to a loadout — which is exactly why this is a link and not a
## shared document.
func publish_to_loadout(manager: DotInvManager, container_id: StringName) -> PackedStringArray:
	var ids := PackedStringArray()
	if not usable() or manager.doc == null:
		return ids
	var c := manager.doc.get_container(container_id)
	if c == null:
		return ids
	for uid in c.entries.keys():
		ids.append(str((c.entries[uid] as Dictionary).get("item", "")))
	if loadout.has_method("set_items"):
		loadout.call("set_items", ids)
	else:
		_warn_unusable("publish")
	return ids


## Once per link, and only when something WAS wired: a null loadout is a game with no
## dot-loadout, which is the ordinary case and not worth a line. Anything else that fails
## the duck-typed check means a round starts with empty hands, or ends without keeping
## what survived, and nothing else in the process would say why. WARN, because it is
## wiring somebody has to fix.
func _warn_unusable(what: String) -> void:
	if _warned_unusable or loadout == null or not is_instance_valid(loadout):
		return
	_warned_unusable = true
	DotLog.warn(CHANNEL, "the loadout link cannot use what it was given; nothing crosses", {
		"during": what,
		"given": loadout.get_class() if loadout.get_script() == null
			else String(loadout.get_script().get_global_name()),
		"needs": "slots(), item_in(slot), set_items(ids)",
	})
