@tool
extends EditorPlugin

## Editor entry point for dot-inventory. Registers inspector types only.
##
## No autoloads: a server holding every player's inventory and a client predicting its own
## are two managers in one process, and one of them is authoritative and the other is not.

const _ICON := "res://addons/dot_inventory/icon_placeholder.svg"

const _TYPES := [
	[
		"DotInvManager",
		"Node",
		"res://addons/dot_inventory/runtime/dot_inv_manager.gd",
	],
	[
		"DotInvPanel",
		"Control",
		"res://addons/dot_inventory/runtime/dot_inv_panel.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
