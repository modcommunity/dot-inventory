class_name DotInvManager
extends Node

## The node a game holds. Ops in, a yes or a no out.
##
## [codeblock]
## var inv := DotInvManager.new()
## inv.catalogue = my_catalogue
## add_child(inv)
## inv.setup([&"backpack", &"belt"])
##
## inv.apply(DotInvOp.add(&"rifle_ammo", 60, &"backpack"))
## inv.apply(DotInvOp.move(&"backpack", uid, &"belt", Vector2i(0, 0)))
## [/codeblock]
##
## [b]It is server-authoritative by construction, because there is nothing else it could
## be.[/b] `authoritative` decides whether an op is applied or merely predicted, and a
## client that predicts keeps the op so it can be rolled back. The server never receives
## state — only ops — because a diff between two documents cannot tell "this rifle moved"
## from "this rifle was destroyed and an identical one appeared", and one of those is a
## duplication exploit.

const SERVICE := &"dot_inventory"
const CHANNEL := "inventory"

## An op was applied. The only signal a view needs.
signal applied(op: DotInvOp, res: DotResult)

## An op was refused, with the reason.
signal refused(op: DotInvOp, res: DotResult)

## The whole document was replaced — loaded, or corrected by a server.
signal reloaded()

@export var catalogue: DotInvCatalogue = null

## Whether this instance decides, or predicts and waits.
##
## A client sets it false, applies locally, sends the op, and rolls back on a refusal.
## [b]A client that applies an op and does NOT keep it cannot roll back[/b], which is the
## shape of the reconciliation bug this family has hit three times — the correction is
## measured against a state that has already been corrected.
@export var authoritative: bool = true

## How deep containers may nest.
@export_range(1, 16, 1) var max_depth: int = 3

## The most ops one actor may apply per second. Zero is unlimited.
##
## An inventory is the cheapest denial of service a client has: a move is a validation, a
## weight sum and a redraw, and a client can send them as fast as it likes.
@export_range(0, 1000, 1) var ops_per_second: int = 30

@export var register_as_service: bool = true

## Where an op goes when this instance is not the authority.
## [code](op: Dictionary) -> void[/code]
var send_fn: Callable = Callable()

## Asked before any op is applied. [code](op, doc) -> bool[/code]. Optional.
##
## The game's own rule — a quest item that cannot be dropped, a container that is locked
## while a fight is on. Separate from the schema because it is about the situation rather
## than about the shape.
var may_apply: Callable = Callable()

var doc: DotInvDoc = null

var _limiter: DotRateLimiter = null
var _history: Array[Dictionary] = []
var _pending: Array[DotInvOp] = []


func setup(root_containers: Array = []) -> DotResult:
	if catalogue == null:
		return DotResult.fail(DotError.CODE_INVALID, "an inventory with no catalogue")
	var res := catalogue.validate()
	if not res.ok:
		return res.wrap("inventory catalogue")

	doc = DotInvDoc.new()
	doc.max_depth = max_depth
	doc._catalogue = catalogue

	for id in root_containers:
		var key := StringName(str(id))
		var def := catalogue.container(key)
		if def.is_empty():
			return DotResult.fail(
				DotError.CODE_INVALID, "container '%s' is not declared" % key
			)
		doc.add_container(DotInvContainer.from_definition(key, def))

	if ops_per_second > 0:
		_limiter = DotRateLimiter.new(float(ops_per_second), float(ops_per_second))

	if register_as_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(
		CHANNEL,
		"inventory ready",
		{
			"containers": doc.containers.size(),
			"items": catalogue.items.size(),
			"authoritative": authoritative,
			"rate": ops_per_second,
		}
	)
	return DotResult.success(null)


func _exit_tree() -> void:
	if register_as_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Applying ---------------------------------------------------------------

## Validates and applies an op. The only way anything changes.
func apply(op: DotInvOp, actor: StringName = &"local") -> DotResult:
	# Set here, from the caller's own knowledge, never read off the wire. An op that
	# carries its own actor is an op that can claim to be somebody else.
	op.actor = actor

	# Keyed by the actor: one player flooding must not throttle everybody else's
	# inventory, which is what a single shared bucket does.
	if _limiter != null and not _limiter.allow(actor):
		var limited := DotResult.fail(
			DotError.CODE_RATE_LIMITED, "too many inventory operations"
		)
		_note_refusal(op, limited)
		refused.emit(op, limited)
		return limited

	if may_apply.is_valid() and not bool(may_apply.call(op, doc)):
		var vetoed := DotResult.fail(DotError.CODE_FORBIDDEN, "the game refused that")
		_note_refusal(op, vetoed)
		refused.emit(op, vetoed)
		return vetoed

	var check := validate(op)
	if not check.ok:
		_note_refusal(op, check)
		refused.emit(op, check)
		return check

	var before := doc.to_dictionary()
	var res := _perform(op)
	if not res.ok:
		# Restored from the snapshot rather than undone step by step. An op that failed
		# part-way through is exactly the case an inverse cannot describe, and this family
		# has the matching lesson from dot-props: one list used for two purposes meant
		# trimming it for one purpose silently changed the other.
		doc.adopt(before, catalogue)
		# ERROR rather than the DEBUG the refusals get: a validated op that then failed
		# half way through is this addon having got something wrong, not a player having
		# asked for something silly.
		DotLog.error(
			CHANNEL,
			"an inventory operation failed after it had been validated",
			{"actor": op.actor, "op": op.kind, "why": res.error.message}
		)
		refused.emit(op, res)
		return res

	_history.append({"op": op, "before": before})
	while _history.size() > 64:
		_history.remove_at(0)

	if not authoritative:
		# Kept so it can be rolled back. A client that applies an op and does not keep it
		# cannot reconcile, and "resend the whole inventory" is the answer that makes an
		# inventory feel broken even when it is correct.
		_pending.append(op)
		if send_fn.is_valid():
			send_fn.call(op.to_dictionary())

	applied.emit(op, res)
	return res


## Records a refused operation.
##
## [b]DEBUG, not WARN.[/b] On an authoritative server a refusal is the system working:
## a client asked for something it was not allowed and was told no, which happens
## constantly and legitimately — a stack that will not fit, a slot already taken, a
## predicted move that lost the race. Logging each at WARN would fill an operator's log
## with the sound of the rules being enforced.
##
## It is still logged, because the question it answers is asked often and cannot be
## answered any other way: "where did my item go". Turn the channel up for one server —
## [code]log channel inventory debug[/code] — rather than leaving it up everywhere.
func _note_refusal(op: DotInvOp, res: DotResult) -> void:
	if not DotLog.enabled(DotLog.Level.DEBUG, CHANNEL):
		return
	DotLog.debug(
		CHANNEL,
		"inventory operation refused",
		{
			"actor": op.actor,
			"op": op.kind,
			"code": res.code(),
			"why": res.error.message if res.error != null else "",
		}
	)


## Checks an op without applying it. What a view greys a slot out with.
func validate(op: DotInvOp) -> DotResult:
	match op.kind:
		DotInvOp.Kind.ADD:
			return _validate_add(op)
		DotInvOp.Kind.MOVE:
			return _validate_move(op)
		DotInvOp.Kind.SPLIT:
			return _validate_split(op)
		DotInvOp.Kind.MERGE:
			return _validate_merge(op)
		DotInvOp.Kind.DROP, DotInvOp.Kind.USE:
			return _validate_take(op)
		_:
			return DotResult.fail(DotError.CODE_UNSUPPORTED, "that operation is not implemented")


func _container(id: StringName) -> DotInvContainer:
	return doc.get_container(id)


func _entry(container_id: StringName, uid: int) -> Dictionary:
	var c := _container(container_id)
	return {} if c == null else c.entries.get(uid, {})


func _validate_add(op: DotInvOp) -> DotResult:
	var item := catalogue.find(op.item)
	if item == null:
		return DotResult.fail(DotError.CODE_INVALID, "no such item '%s'" % op.item)
	var c := _container(op.to_container)
	if c == null:
		return DotResult.fail(DotError.CODE_INVALID, "no such container '%s'" % op.to_container)
	if op.count < 1:
		return DotResult.fail(DotError.CODE_INVALID, "adding %d of something" % op.count)
	if not c.within_weight(item.weight * float(op.count), catalogue, doc):
		return DotResult.fail(DotError.CODE_QUOTA, "'%s' is too heavy for that" % op.item)
	return DotResult.success(null)


func _validate_move(op: DotInvOp) -> DotResult:
	var from := _container(op.from_container)
	var to := _container(op.to_container)
	if from == null or to == null:
		return DotResult.fail(DotError.CODE_INVALID, "no such container")
	var entry := _entry(op.from_container, op.from_uid)
	if entry.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "there is nothing there to move")

	var item := catalogue.find(StringName(str(entry.get("item", ""))))
	if item == null:
		return DotResult.fail(DotError.CODE_INVALID, "that item is not in the catalogue")

	# The nesting test comes before the fit test, because a cycle that has been created
	# cannot be detected by anything that has to walk the structure to find it.
	if item.kind == DotInvItem.Kind.CONTAINER:
		var child := StringName(str(entry.get("child", "")))
		if child != &"":
			var nest := doc.can_nest(child, op.to_container)
			if not nest.ok:
				return nest

	# ignore_uid is what makes moving something one cell to the left work. Without it the
	# item collides with itself, and the obvious workaround -- remove, then place -- is
	# the one that loses the item when the place half fails.
	var ignore := op.from_uid if op.from_container == op.to_container else 0
	var fit := to.fits(item, op.to_cell, op.to_rotated, catalogue, ignore)
	if not fit.ok:
		return fit

	if op.from_container != op.to_container:
		var w := item.weight * float(entry.get("count", 1))
		if item.kind == DotInvItem.Kind.CONTAINER:
			w += doc.weight_of(StringName(str(entry.get("child", ""))))
		if not to.within_weight(w, catalogue, doc):
			return DotResult.fail(DotError.CODE_QUOTA, "that is too heavy for '%s'" % to.id)
	return DotResult.success(null)


func _validate_split(op: DotInvOp) -> DotResult:
	var entry := _entry(op.from_container, op.from_uid)
	if entry.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "there is nothing there to split")
	var have := int(entry.get("count", 1))
	if op.count < 1 or op.count >= have:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"splitting %d off a stack of %d" % [op.count, have],
			"a split that takes the whole stack is a move, and the two are not the same op"
		)
	var item := catalogue.find(StringName(str(entry.get("item", ""))))
	if item == null or item.stack_max <= 1:
		return DotResult.fail(DotError.CODE_INVALID, "that does not stack")
	var to := _container(op.to_container)
	if to == null:
		return DotResult.fail(DotError.CODE_INVALID, "no such container")
	return to.fits(item, op.to_cell, op.to_rotated, catalogue)


func _validate_merge(op: DotInvOp) -> DotResult:
	var a := _entry(op.from_container, op.from_uid)
	var b := _entry(op.to_container, op.to_uid)
	if a.is_empty() or b.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "one of those is not there")
	if op.from_container == op.to_container and op.from_uid == op.to_uid:
		return DotResult.fail(DotError.CODE_INVALID, "merging a stack with itself")
	if str(a.get("item", "")) != str(b.get("item", "")):
		return DotResult.fail(DotError.CODE_INVALID, "those are different items")
	var item := catalogue.find(StringName(str(a.get("item", ""))))
	if item == null or item.stack_max <= 1:
		return DotResult.fail(DotError.CODE_INVALID, "that does not stack")
	if int(b.get("count", 1)) >= item.stack_max:
		return DotResult.fail(DotError.CODE_QUOTA, "that stack is already full")
	return DotResult.success(null)


func _validate_take(op: DotInvOp) -> DotResult:
	var entry := _entry(op.from_container, op.from_uid)
	if entry.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "there is nothing there")
	var have := int(entry.get("count", 1))
	if op.count > have:
		return DotResult.fail(
			DotError.CODE_INVALID, "there are only %d of those" % have
		)
	return DotResult.success(null)


func _perform(op: DotInvOp) -> DotResult:
	match op.kind:
		DotInvOp.Kind.ADD:
			return _do_add(op)
		DotInvOp.Kind.MOVE:
			return _do_move(op)
		DotInvOp.Kind.SPLIT:
			return _do_split(op)
		DotInvOp.Kind.MERGE:
			return _do_merge(op)
		DotInvOp.Kind.DROP, DotInvOp.Kind.USE:
			return _do_take(op)
		_:
			return DotResult.fail(DotError.CODE_UNSUPPORTED, "not implemented")


func _do_add(op: DotInvOp) -> DotResult:
	var item := catalogue.find(op.item)
	var c := _container(op.to_container)
	var remaining := op.count
	var made: Array[int] = []

	# Topped up into existing stacks first. A pickup that makes a second stack of five
	# beside a stack of five, in a game whose stack limit is twenty, is the single most
	# reported inventory complaint there is.
	if item.stack_max > 1:
		for uid in c.entries.keys():
			if remaining <= 0:
				break
			var e: Dictionary = c.entries[uid]
			if str(e.get("item", "")) != String(item.id):
				continue
			var room := item.stack_max - int(e.get("count", 1))
			if room <= 0:
				continue
			var take := mini(room, remaining)
			e["count"] = int(e.get("count", 1)) + take
			remaining -= take

	while remaining > 0:
		var take := mini(item.stack_max, remaining)
		var cell: Vector2i = op.to_cell
		var rotated := op.to_rotated
		if cell.x < 0 or cell.y < 0:
			var spot := c.first_fit(item, catalogue)
			if not bool(spot.get("ok", false)):
				if made.is_empty() and remaining == op.count:
					return DotResult.fail(DotError.CODE_QUOTA, "there is no room for that")
				# A partial add is reported as a success carrying what did not fit, not
				# as a failure -- a pickup that half worked has half worked, and rolling
				# it back to take the other half away is worse for everybody.
				return DotResult.success({"added": op.count - remaining, "left": remaining})
			cell = spot["cell"]
			rotated = bool(spot["rotated"])
		var fit := c.fits(item, cell, rotated, catalogue)
		if not fit.ok:
			return fit
		made.append(c.add_entry({
			"item": String(item.id),
			"count": take,
			"cell": cell,
			"rotated": rotated,
			"state": op.state.duplicate(true),
		}))
		remaining -= take
		# Only the first explicit placement is honoured; the rest find their own spot.
		op.to_cell = Vector2i(-1, -1)

	_open_containers_for(c, made)
	return DotResult.success({"added": op.count, "left": 0})


func _open_containers_for(c: DotInvContainer, uids: Array[int]) -> void:
	for uid in uids:
		var e: Dictionary = c.entries.get(uid, {})
		var item := catalogue.find(StringName(str(e.get("item", ""))))
		if item == null or item.kind != DotInvItem.Kind.CONTAINER:
			continue
		var def := catalogue.container(item.container_id)
		if def.is_empty():
			continue
		var res := doc.open_container(c.id, uid, def, catalogue)
		if res.ok:
			e["child"] = String(res.value)


func _do_move(op: DotInvOp) -> DotResult:
	var from := _container(op.from_container)
	var to := _container(op.to_container)
	var entry := from.entries.get(op.from_uid, {})
	var moved: Dictionary = (entry as Dictionary).duplicate(true)
	moved["cell"] = op.to_cell
	moved["rotated"] = op.to_rotated

	from.remove_entry(op.from_uid)
	var uid := to.add_entry(moved)

	# The child container's parent record has to move with it, or the depth and cycle
	# tests are answering about where the bag used to be.
	var child := StringName(str(moved.get("child", "")))
	if child != &"" and doc.parents.has(child):
		doc.parents[child] = {"parent": op.to_container, "uid": uid}
	return DotResult.success(uid)


func _do_split(op: DotInvOp) -> DotResult:
	var from := _container(op.from_container)
	var to := _container(op.to_container)
	var entry: Dictionary = from.entries[op.from_uid]
	entry["count"] = int(entry.get("count", 1)) - op.count
	var uid := to.add_entry({
		"item": entry.get("item", ""),
		"count": op.count,
		"cell": op.to_cell,
		"rotated": op.to_rotated,
		"state": (entry.get("state", {}) as Dictionary).duplicate(true),
	})
	return DotResult.success(uid)


func _do_merge(op: DotInvOp) -> DotResult:
	var from := _container(op.from_container)
	var to := _container(op.to_container)
	var a: Dictionary = from.entries[op.from_uid]
	var b: Dictionary = to.entries[op.to_uid]
	var item := catalogue.find(StringName(str(a.get("item", ""))))

	var room := item.stack_max - int(b.get("count", 1))
	var take := mini(room, int(a.get("count", 1)))
	b["count"] = int(b.get("count", 1)) + take
	var left := int(a.get("count", 1)) - take
	if left <= 0:
		from.remove_entry(op.from_uid)
	else:
		# A partial merge leaves the remainder where it was rather than refusing. Dragging
		# a stack of twenty onto one with room for five should move five, which is what
		# every player expects and what a whole-or-nothing merge refuses to do.
		a["count"] = left
	return DotResult.success({"merged": take, "left": left})


func _do_take(op: DotInvOp) -> DotResult:
	var from := _container(op.from_container)
	var entry: Dictionary = from.entries[op.from_uid]
	var have := int(entry.get("count", 1))
	var take := have if op.count <= 0 else op.count
	if take >= have:
		var child := StringName(str(entry.get("child", "")))
		if child != &"":
			_remove_subtree(child)
		from.remove_entry(op.from_uid)
	else:
		entry["count"] = have - take
	return DotResult.success(take)


## Removes a container and everything inside it.
##
## Depth-first, and the child list is collected before anything is erased: removing while
## iterating the dictionary that is being walked is a crash on some sizes and a silent
## partial removal on others.
func _remove_subtree(id: StringName) -> void:
	var children: Array[StringName] = []
	for key in doc.parents.keys():
		if StringName(str(doc.parents[key].get("parent", ""))) == id:
			children.append(key)
	for child in children:
		_remove_subtree(child)
	doc.containers.erase(id)
	doc.parents.erase(id)


# --- Prediction -------------------------------------------------------------

## A server refused an op this client already applied. Roll it back.
func rollback(op_dict: Dictionary) -> void:
	for i in range(_pending.size()):
		if DotValue.same_dictionary(_pending[i].to_dictionary(), op_dict):
			_pending.remove_at(i)
			break
	# The whole document, from the snapshot taken before the op. Not an inverse: an op
	# that was refused after a partial application is exactly the case an inverse cannot
	# describe, and inventing one is how a rollback becomes a duplication.
	for j in range(_history.size() - 1, -1, -1):
		if DotValue.same_dictionary(_history[j]["op"].to_dictionary(), op_dict):
			doc.adopt(_history[j]["before"], catalogue)
			_history.resize(j)
			reloaded.emit()
			return


func confirm(op_dict: Dictionary) -> void:
	for i in range(_pending.size()):
		if DotValue.same_dictionary(_pending[i].to_dictionary(), op_dict):
			_pending.remove_at(i)
			return


func pending_count() -> int:
	return _pending.size()


# --- Saving -----------------------------------------------------------------

func to_dictionary() -> Dictionary:
	return doc.to_dictionary()


func adopt(d: Dictionary) -> DotResult:
	var res := doc.adopt(d, catalogue)
	if res.ok:
		_pending.clear()
		_history.clear()
		reloaded.emit()
	return res


func describe() -> Dictionary:
	return {
		"containers": doc.containers.size() if doc != null else 0,
		"authoritative": authoritative,
		"pending": _pending.size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("dot-inventory %s" % ("authoritative" if authoritative else "predicting"))
	if not _pending.is_empty():
		out.append("  %d ops awaiting an answer" % _pending.size())
	if doc != null:
		out.append_array(doc.describe_lines(catalogue))
	return out
