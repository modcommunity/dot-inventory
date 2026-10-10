# dot-inventory

An inventory as a document a server validates, mutated only by ops it can refuse one at a time: grids and slot lists, stacks, weight, nesting, client prediction with rollback, and a drag-and-drop panel with no art.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to inventories.

**The distributable is `addons/dot_inventory/`.** It requires [dot-core](../dot-core) and nothing else. dot-loadout is linked only so the self-test can run `DotInvLoadoutLink` against the real document; the addon never names it.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
ln -s ../../dot-loadout/addons/dot_loadout addons/dot_loadout   # the self-test only
```

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: why not dot-loadout, ops, snapshots, prediction, identity, what is never stored, nesting, the panel, what is not here |
| [docs/history.md](docs/history.md) | the bugs a real wire found, and the suite's own false alarms |

## Layout

| Path | What |
| --- | --- |
| `core/dot_inv_item.gd` | `DotInvItem`: what a thing is. A document with a translation key, not a name |
| `core/dot_inv_catalogue.gd` | `DotInvCatalogue`: items and container shapes. Validates with no icons and no meshes |
| `core/dot_inv_container.gd` | `DotInvContainer`: a grid or a list of slots (only the geometry differs) |
| `core/dot_inv_doc.gd` | `DotInvDoc`: several containers, the parent links, the depth bound and the cycle test |
| `core/dot_inv_op.gd` | `DotInvOp`: one mutation. The wire format, the undo record and the refusal unit |
| `core/dot_inv_query.gd` | `DotInvQuery`: filtering and sorting, locally |
| `core/dot_inv_loadout_link.gd` | `DotInvLoadoutLink`: the only file that knows dot-loadout exists |
| `runtime/dot_inv_manager.gd` | `DotInvManager`: validates, applies, snapshots, predicts, rolls back, lands a server's op underneath the predictions |
| `runtime/dot_inv_panel.gd` | `DotInvPanel`: a grid with native drag-and-drop; asks `validate` before a cell lights up |
| `examples/inventory_selftest.tscn` | the suite; the dot-loadout section needs dot-loadout linked |

Paths under `core/` and `runtime/` are in `addons/dot_inventory/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 180 godot --headless --path . res://examples/inventory_selftest.tscn`. The checks that matter are the refusals (a move that does not fit, a bag inside itself, a split that is really a move, a weight cap, a rollback that does not duplicate): each is a real exploit in some shipped game, and none is visible in a screenshot.

## Rules that bite

- Every mutation is a `DotInvOp`; never "set the inventory to this". A predicting client keeps its ops in `_pending`. [design](docs/design.md#every-mutation-is-an-op)
- Rollback restores a snapshot, never an inverse; history is capped at `MAX_HISTORY` (64), and a rewind past it WARNs and needs the server's whole document. [design](docs/design.md#rollback-restores-a-snapshot-not-an-inverse)
- `rollback(A)` re-applies what came after A; what no longer applies comes back through `dropped`. Rewinds use `_reapply`, never `apply`. [design](docs/design.md#rollback-restores-a-snapshot-not-an-inverse)
- A server's op on a predicting manager goes through `apply_authoritative`, never `apply` (which sends it back up). [design](docs/design.md#a-servers-op-lands-underneath-the-predictions)
- Search history by identity (`_history_index`), never by content; a MOVE keeps its uid. [design](docs/design.md#identity-survives-the-wire)
- Occupancy is computed, never stored; a container's shape comes from the catalogue on `adopt`, never from the save. [design](docs/design.md#two-derived-things-that-must-never-be-stored)
- `validate` must ask what `_do_add` will do (`_room_for_add`); a full bag is `CODE_QUOTA`. [design](docs/design.md#validation-asks-what-applying-will-do)
- Moving within a container passes `ignore_uid`; never remove-then-place. [design](docs/design.md#ignore_uid-is-not-an-optimisation)
- `can_nest()` runs before every move, walking up; `_remove_subtree` collects before erasing. [design](docs/design.md#nesting-bounded-and-cycles-refused-before-they-exist)
- `actor` comes from the receiver, never the wire; `to_dictionary()` leaves it out. The rate limit is per actor, with `unlimited_actors` for the server's own. [design](docs/design.md#smaller-decisions)
- Items carry a `name_key` and an icon path, never a name or a `Texture2D`. Sorts break ties on the id. [design](docs/design.md#smaller-decisions)
- `DotInvPanel._can_drop_data` asks `manager.validate(op)`; never give the panel its own idea of what fits. [design](docs/design.md#the-panel)
- `DotInvLoadoutLink` takes one player's `DotLoadout` (from `active_for`), not the manager, and only removes. [design](docs/design.md#the-link-takes-one-players-dotloadout-not-the-dotloadoutmanager)

Deliberately not here: a themed panel, crafting, equipment stats, a transport. [design](docs/design.md#deliberately-not-here)
