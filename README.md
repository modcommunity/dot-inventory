# dot-inventory

An inventory that a server can check: grids, stacks, weight, equipment slots and bags inside bags. Every change is an operation the server can accept or refuse one at a time.

Part of TMC's **Dot** collection: modular, MIT-licensed building blocks for games on the TMC platform (only the TMC website back end is closed). It was built with Claude Code and its headless suite passes, but little of it has met real players yet, so expect rough edges and please report what you find.

## Install

Copy `addons/dot_inventory/` and [dot-core](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable dot-inventory in **Project > Project Settings > Plugins**. dot-core is the only dependency. dot-loadout and dot-ui are optional and are reached by name at runtime.

## Use

```gdscript
inv.apply(DotInvOp.move(&"backpack", uid, &"belt", Vector2i(0, 0)))
```

A client sends an op and the server answers yes or no. Sending state instead would make the server guess what the player did by comparing two documents, and "the rifle moved" looks the same as "the rifle vanished and an identical one appeared". Ops also give you undo, refusing one move out of ten without the other nine snapping back, and prediction.

### Prediction on a client

A manager with `authoritative = false` remembers the ops it applied but has not heard back about.

```gdscript
inv.confirm(op_dict)                 # the server said yes
var lost := inv.rollback(op_dict)    # the server said no: undo that op, and only that op
inv.apply_authoritative(server_op)   # a change the server made: a purchase, a reward
```

- `rollback` rewinds to before that op and re-applies the later ones. Any that no longer fit are dropped and reported through `dropped`.
- `apply_authoritative` puts the server's own change underneath the pending predictions. It is never sent back and never rate limited.
- A move keeps its uid, so a client can chain a second op onto the first.
- `validate(op)` asks everything `apply` will, including room. A shop can ask before it charges.
- `unlimited_actors` exempts actors (such as the one the server grants purchases as) from `ops_per_second`.

## Settings and behaviour

| Topic | Behaviour |
| --- | --- |
| Occupancy | Derived from the entries each time (`cells_of()`, `occupied_cells()`), never stored, so it cannot disagree with the item list. |
| Moving inside a container | `fits(..., ignore_uid)` ignores the item itself, so a one-cell shift works without remove-then-place. |
| Nesting | `max_depth` (default 3, 0 = unlimited) limits bags in bags. `can_nest()` walks up from the destination, so cycles are refused before they exist. |
| Stacks | A pickup tops up existing stacks first. A partial merge moves what fits and leaves the rest. |
| Rotation | Tried at every cell, not after a full failed pass. |
| Sorting | Ties break on the id, because Godot's `sort_custom` is not stable. |
| Filtering and sorting | Done by the client. The server owns the contents. |

`DotInvPanel` is a code-built grid using Godot's own drag and drop. Its `_can_drop_data` calls `manager.validate(op)`, so the screen never accepts a move the server will refuse.

## With dot-loadout

`DotInvLoadoutLink` connects the two without either needing the other. `fill_from_loadout` pours a player's `DotLoadout` into a container at match start, and `publish_to_loadout` clears the slots whose items did not survive. Nothing is automatic, because whether a round's inventory is kept is a game design choice. dot-loadout holds what a player owns and brought in; dot-inventory holds what is in the bag right now.

## Test

```bash
godot --headless --path . --import
godot --headless --path . res://examples/inventory_selftest.tscn
```

## Licence

MIT. See [LICENSE](LICENSE).
