@tool
class_name DotInvOp
extends RefCounted

## One mutation. Everything that changes an inventory is one of these.
##
## [b]This is the central decision of the addon, and four things fall out of it.[/b]
##
## [b]The network shape.[/b] A client sends an op and a server answers yes or no. Sending
## state instead means the server has to diff two documents to work out what a player
## claims to have done — and a diff is ambiguous: "this rifle moved" and "this rifle was
## destroyed and an identical one appeared" are the same diff, and only one of them is a
## duplication exploit.
##
## [b]Undo.[/b] An op that was applied can be inverted, because it names what it did
## rather than what the result looked like.
##
## [b]A partial refusal.[/b] A server can refuse one move out of ten without refusing the
## other nine, and without the client's whole inventory snapping back — which is the thing
## that makes an inventory feel broken even when it is correct.
##
## [b]Prediction.[/b] A client applies the op locally, sends it, and rolls it back if the
## answer is no. That is the same shape dot-net's predictor uses for movement, and it has
## the same trap: **do not reconcile on top of a reconciliation.** game-hungario's bridge
## replayed inputs against values that had already been rewound and its correction rate
## was 0.500; removing the extra pass took it to 0.032.

enum Kind {
	## Move a stack to another place, possibly in another container.
	MOVE,
	## Split [member count] off a stack into a new one.
	SPLIT,
	## Merge one stack into another of the same item.
	MERGE,
	## Put an item into an equipment slot.
	EQUIP,
	## Take it out again.
	UNEQUIP,
	## Remove it from the document entirely.
	DROP,
	## Consume one, or all of them.
	USE,
	## Add one from outside — a pickup, a reward, a purchase.
	ADD,
}

@export var kind: Kind = Kind.MOVE

## Where it is now.
@export var from_container: StringName = &""
@export var from_uid: int = 0

## Where it is going.
@export var to_container: StringName = &""
@export var to_cell: Vector2i = Vector2i.ZERO
@export var to_rotated: bool = false
@export var to_uid: int = 0

## For SPLIT, USE and ADD.
@export var count: int = 1

## For ADD.
@export var item: StringName = &""

## Whatever a game wants to carry with an ADD — durability, an enchantment, a serial.
@export var state: Dictionary = {}

## Who asked. Set by the manager, not by a client.
##
## [b]Never taken from the wire.[/b] An op that carries its own actor is an op that can
## claim to be somebody else, and this is the field a client would forge first.
var actor: StringName = &""


static func move(
	from_c: StringName, uid: int, to_c: StringName, cell: Vector2i, rotated: bool = false
) -> DotInvOp:
	var o := DotInvOp.new()
	o.kind = Kind.MOVE
	o.from_container = from_c
	o.from_uid = uid
	o.to_container = to_c
	o.to_cell = cell
	o.to_rotated = rotated
	return o


static func split(from_c: StringName, uid: int, n: int, cell: Vector2i) -> DotInvOp:
	var o := DotInvOp.new()
	o.kind = Kind.SPLIT
	o.from_container = from_c
	o.from_uid = uid
	o.to_container = from_c
	o.to_cell = cell
	o.count = n
	return o


static func merge(from_c: StringName, uid: int, to_c: StringName, target_uid: int) -> DotInvOp:
	var o := DotInvOp.new()
	o.kind = Kind.MERGE
	o.from_container = from_c
	o.from_uid = uid
	o.to_container = to_c
	o.to_uid = target_uid
	return o


static func add(item_id: StringName, n: int, to_c: StringName) -> DotInvOp:
	var o := DotInvOp.new()
	o.kind = Kind.ADD
	o.item = item_id
	o.count = n
	o.to_container = to_c
	o.to_cell = Vector2i(-1, -1)
	return o


static func drop(from_c: StringName, uid: int, n: int = 0) -> DotInvOp:
	var o := DotInvOp.new()
	o.kind = Kind.DROP
	o.from_container = from_c
	o.from_uid = uid
	o.count = n
	return o


static func use(from_c: StringName, uid: int, n: int = 1) -> DotInvOp:
	var o := DotInvOp.new()
	o.kind = Kind.USE
	o.from_container = from_c
	o.from_uid = uid
	o.count = n
	return o


## The op as plain data, for a wire or a log.
##
## The actor is deliberately not included. It is set by the receiver from the connection
## the op arrived on, which is the only source that cannot be forged.
func to_dictionary() -> Dictionary:
	return {
		"kind": kind,
		"from": String(from_container),
		"from_uid": from_uid,
		"to": String(to_container),
		"cell": [to_cell.x, to_cell.y],
		"rotated": to_rotated,
		"to_uid": to_uid,
		"count": count,
		"item": String(item),
		"state": state.duplicate(true),
	}


static func from_dictionary(d: Dictionary) -> DotInvOp:
	var o := DotInvOp.new()
	o.kind = int(d.get("kind", Kind.MOVE)) as Kind
	o.from_container = StringName(str(d.get("from", "")))
	o.from_uid = int(d.get("from_uid", 0))
	o.to_container = StringName(str(d.get("to", "")))
	var cell: Variant = d.get("cell", [0, 0])
	if cell is Array and (cell as Array).size() >= 2:
		o.to_cell = Vector2i(int(cell[0]), int(cell[1]))
	o.to_rotated = bool(d.get("rotated", false))
	o.to_uid = int(d.get("to_uid", 0))
	o.count = int(d.get("count", 1))
	o.item = StringName(str(d.get("item", "")))
	var raw_state: Variant = d.get("state", {})
	o.state = (raw_state as Dictionary).duplicate(true) if raw_state is Dictionary else {}
	return o


func describe_line() -> String:
	var names := ["move", "split", "merge", "equip", "unequip", "drop", "use", "add"]
	match kind:
		Kind.ADD:
			return "add %s x%d -> %s" % [item, count, to_container]
		Kind.MERGE:
			return "merge #%d (%s) into #%d (%s)" % [
				from_uid, from_container, to_uid, to_container
			]
		_:
			return "%s #%d %s -> %s @%d,%d" % [
				names[kind], from_uid, from_container, to_container, to_cell.x, to_cell.y
			]
