class_name DotInvPanel
extends Control

## A grid you can drag things around in, built in code and themed by nothing.
##
## [b]It does not depend on dot-ui, and that is not an oversight.[/b] Godot's own
## [method Control._get_drag_data], [method Control._can_drop_data] and
## [method Control._drop_data] are the drag-and-drop mechanism — they are the engine, not
## dot-ui — so a panel built on them works in a project that has dot-ui and in one that does
## not, and drops onto a `DotScreen` without knowing what one is.
##
## [b]What it draws is not the point. What it refuses is.[/b] Every drop asks
## [method DotInvManager.validate] before it is allowed to start, so a cell that cannot take
## what is being dragged never lights up — and the same call the server will make is the one
## the highlight came from. A panel that decided for itself which drops look legal is a
## panel that will eventually disagree with the server, and the player sees a move accepted
## on screen and undone a round trip later.
##
## [codeblock]
## var panel := DotInvPanel.new()
## panel.manager = inventory
## panel.container_id = &"backpack"
## add_child(panel)
## [/codeblock]
##
## Ships no art and no [Theme], for dot-ui's reason. A game that wants icons sets
## [member icon_resolver]; without one, a cell draws the item's id.

## A drag ended on this panel and the op was applied.
signal moved(op: DotInvOp, res: DotResult)

## Something was picked up, so a game can grey out what it will not fit in.
signal picked_up(container_id: StringName, uid: int)

@export var manager: DotInvManager = null

@export var container_id: StringName = &""

## Pixels per grid cell.
@export_range(8, 256, 1) var cell_size: int = 48

## Who this panel acts as. Passed to every op, never read off anything.
@export var actor: StringName = &"local"

## [code](item: DotInvItem) -> Texture2D[/code]. Optional; without one, cells draw the id.
var icon_resolver: Callable = Callable()

var _grid: Control = null
var _cells: Dictionary = {}
var _dragging_uid := 0


func _ready() -> void:
	# set_anchors_AND_OFFSETS_preset. `set_anchors_preset` does NOT set offsets, so a
	# Control built in code keeps the zero size it was created with -- and every child then
	# lays out inside nothing, invisibly, while being by every property correctly
	# configured. This family has shipped that twice, most recently five times in one addon.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_grid = Control.new()
	_grid.name = "Grid"
	_grid.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_grid)
	refresh()


## Rebuilds the cells from the document.
##
## Called on every change rather than diffed. A grid of sixty cells is nothing to rebuild,
## and a diff is a second model of what is on screen — which is the "two copies of one
## fact" this family has paid for more than any other mistake.
func refresh() -> void:
	if manager == null or manager.doc == null or _grid == null:
		return
	var container := manager.doc.get_container(container_id)
	if container == null:
		return

	for child in _grid.get_children():
		child.queue_free()
	_cells.clear()

	var w := container.width if container.shape == DotInvContainer.Shape.GRID else container.slots
	var h := container.height if container.shape == DotInvContainer.Shape.GRID else 1
	custom_minimum_size = Vector2(w * cell_size, h * cell_size)

	for y in range(h):
		for x in range(w):
			_add_cell(Vector2i(x, y))

	for uid in container.entries.keys():
		_add_item(uid, container.entries[uid], container)


func _add_cell(at: Vector2i) -> void:
	var cell := DotInvCell.new()
	cell.panel = self
	cell.cell = at
	cell.position = Vector2(at.x * cell_size, at.y * cell_size)
	cell.size = Vector2(cell_size, cell_size)
	cell.mouse_filter = Control.MOUSE_FILTER_PASS
	_grid.add_child(cell)
	_cells[at] = cell


func _add_item(uid: int, entry: Dictionary, container: DotInvContainer) -> void:
	var item := manager.catalogue.find(StringName(str(entry.get("item", ""))))
	if item == null:
		return
	var fp := item.footprint(bool(entry.get("rotated", false)))
	var at: Vector2i = entry.get("cell", Vector2i.ZERO)

	var button := DotInvItemView.new()
	button.panel = self
	button.uid = uid
	button.item = item
	button.count = int(entry.get("count", 1))
	button.position = Vector2(at.x * cell_size, at.y * cell_size)
	button.size = Vector2(fp.x * cell_size, fp.y * cell_size)
	if icon_resolver.is_valid():
		button.icon = icon_resolver.call(item)
	elif item.icon_path != "":
		# The fallback that makes `DotInvItem.icon_path` mean something. Without it the
		# field was a documented declaration nothing anywhere read, and a catalogue that
		# named an icon for every item drew the ids regardless.
		#
		# Loaded by PATH at draw time rather than preloaded, which is the whole reason the
		# field is a String: a mounted content pack's `class_name` globals are not
		# registered in the host, so a catalogue that preloads cannot describe delivered
		# content. `exists` first, because a missing icon is a missing picture and must not
		# be a red line per cell per redraw.
		if ResourceLoader.exists(item.icon_path):
			var tex: Variant = load(item.icon_path)
			if tex is Texture2D:
				button.icon = tex
	_grid.add_child(button)


## Whether a drop of [param payload] onto [param at] would be accepted.
##
## [b]The same question the server will be asked, asked here.[/b] A panel with its own idea
## of what fits is one that will eventually disagree, and the player sees a move accepted on
## screen and undone a round trip later.
func may_drop(payload: Dictionary, at: Vector2i) -> bool:
	if manager == null or not payload.has("uid"):
		return false
	var op := DotInvOp.move(
		StringName(str(payload.get("from", ""))),
		int(payload["uid"]),
		container_id,
		at,
		bool(payload.get("rotated", false))
	)
	return manager.validate(op).ok


## Applies a drop. Returns what the manager said.
func do_drop(payload: Dictionary, at: Vector2i) -> DotResult:
	var op := DotInvOp.move(
		StringName(str(payload.get("from", ""))),
		int(payload["uid"]),
		container_id,
		at,
		bool(payload.get("rotated", false))
	)
	var res := manager.apply(op, actor)
	moved.emit(op, res)
	refresh()
	return res


func note_pickup(uid: int) -> void:
	_dragging_uid = uid
	picked_up.emit(container_id, uid)


func dragging_uid() -> int:
	return _dragging_uid


## One cell. Takes the drop, because a cell is what a position means.
class DotInvCell:
	extends Control

	var panel: DotInvPanel = null
	var cell: Vector2i = Vector2i.ZERO

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		# Asked on every frame of a drag, so it has to be cheap -- which it is, because
		# `validate` is arithmetic over a document and touches no content at all.
		return data is Dictionary and panel != null and panel.may_drop(data, cell)

	func _drop_data(_at: Vector2, data: Variant) -> void:
		if data is Dictionary and panel != null:
			panel.do_drop(data, cell)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.04), true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.10), false, 1.0)


## One item. Starts the drag, because an item is what is being moved.
class DotInvItemView:
	extends Button

	var panel: DotInvPanel = null
	var uid: int = 0
	var item: DotInvItem = null
	var count: int = 1

	func _ready() -> void:
		# The id rather than the name key: a panel has no translation table, and a raw key
		# on screen is at least honest about what is missing. A game sets `icon_resolver`.
		if icon == null and item != null:
			text = String(item.id) if count <= 1 else "%s x%d" % [item.id, count]
		clip_text = true
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _get_drag_data(_at: Vector2) -> Variant:
		if panel == null or item == null:
			return null
		panel.note_pickup(uid)

		# A preview, because a drag with nothing under the cursor is a drag a player cannot
		# aim. Godot frees it; this does not hold a reference.
		var preview := Button.new()
		preview.text = text
		preview.icon = icon
		preview.size = size
		preview.modulate = Color(1, 1, 1, 0.7)
		set_drag_preview(preview)

		return {
			"uid": uid,
			"from": String(panel.container_id),
			"item": String(item.id),
			"rotated": false,
		}
