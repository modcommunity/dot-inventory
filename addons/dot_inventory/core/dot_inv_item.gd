@tool
class_name DotInvItem
extends Resource

## What an item is: a document of ids and numbers, with no content in it.
##
## Named [code]DotInvItem[/code] rather than [code]DotItem[/code] because dot-loadout
## already has that name and [code]class_name[/code] is global in Godot — these install
## side by side. The collision is a symptom of something real, though, and it is worth
## being explicit about the division:
##
## [b]dot-loadout answers "what do you own and what did you bring in".[/b] It is a
## permanent, bounded document a server validates against entitlements before a match.
## [b]dot-inventory answers "what is in your bag right now".[/b] It changes every few
## seconds, it has a shape, things stack in it, and the server has to be able to refuse
## one move without refusing the document.
##
## They meet in exactly one file, [DotInvLoadoutLink], which is the same arrangement
## dot-npc-ai has with dot-npc: only one file in it names the other.

enum Kind {
	## Stacks, has no state of its own. Ammunition, materials, currency.
	STACKABLE,
	## One per stack, carries its own state. A weapon with durability.
	UNIQUE,
	## Holds other items. See [member container_id] and the depth bound.
	CONTAINER,
}

## The id a game asks for. Unique in a catalogue.
@export var id: StringName = &""

## A translation key, not a name.
##
## [b]An item document must not carry English.[/b] It is stored, it is sent to a server,
## and it is read back by a client whose language nobody knew when it was written — so it
## carries a key and the client looks it up. A stored display name is also a stored
## typo: fixing one means rewriting every save file that has it.
@export var name_key: StringName = &""

@export var kind: Kind = Kind.STACKABLE

## How many fit in one stack. One means it does not stack.
@export_range(1, 1000000, 1) var stack_max: int = 1

## Grams, or whatever the game counts. Per unit, not per stack.
@export_range(0.0, 1000000.0, 0.01, "or_greater") var weight: float = 0.0

## Cells occupied in a grid container. Ignored by a slot container.
@export var size: Vector2i = Vector2i(1, 1)

## Whether it may be turned ninety degrees to fit.
##
## Off for anything whose shape is meaningful in the interface — an interface where some
## things rotate and some do not is one a player has to experiment with, so this is set
## per item deliberately rather than globally.
@export var rotatable: bool = true

## Which slots this fits. An equipment slot lists the tags it accepts.
##
## Tags rather than a slot name, so an item works in a game that calls the slot something
## else — and so one item can fit two slots without listing both.
@export var slot_tags: Array[StringName] = []

## Free tags for filtering and for a game's own rules.
@export var tags: Array[StringName] = []

## The container definition this opens into, for [constant Kind.CONTAINER].
@export var container_id: StringName = &""

## An icon's PATH, not a [Texture2D].
##
## The rule dot-props, dot-audio and dot-fx all follow: a **mounted pack's `class_name`
## globals are not registered in the host**, so a catalogue that preloads cannot describe
## delivered content — and a server validating an inventory must not need an icon.
@export var icon_path: String = ""

## Anything the game wants. Copied on the way in and out; never shared.
@export var meta: Dictionary = {}


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "an item with no id")
	if size.x < 1 or size.y < 1:
		return DotResult.fail(DotError.CODE_INVALID, "'%s' occupies no cells" % id)
	if kind == Kind.UNIQUE and stack_max != 1:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' is unique and stacks to %d" % [id, stack_max],
			"an item that carries its own state cannot be merged with another one"
		)
	if kind == Kind.CONTAINER:
		if container_id == &"":
			return DotResult.fail(
				DotError.CODE_INVALID, "'%s' is a container that opens into nothing" % id
			)
		if stack_max != 1:
			return DotResult.fail(
				DotError.CODE_INVALID, "'%s' is a container that stacks" % id
			)
	return DotResult.success(null)


## The footprint, honouring a rotation.
func footprint(rotated: bool) -> Vector2i:
	return Vector2i(size.y, size.x) if rotated and rotatable else size


func has_tag(tag: StringName) -> bool:
	return tags.has(tag)


func fits_slot_tag(tag: StringName) -> bool:
	return slot_tags.has(tag)


func describe_line() -> String:
	return "%-22s %-10s %dx%d  stack %-5d %.2f kg%s" % [
		String(id),
		["stackable", "unique", "container"][kind],
		size.x,
		size.y,
		stack_max,
		weight,
		"  -> %s" % container_id if kind == Kind.CONTAINER else "",
	]
