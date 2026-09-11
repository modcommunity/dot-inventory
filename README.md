This is the **inventory** asset for TMC's **Dot** collection. It adds a full inventory as a document a server can check: grids, stacks, weight, equipment slots and nested containers, mutated only by operations a server can refuse one at a time.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

## Every mutation is an op, and four things fall out of that

```gdscript
inv.apply(DotInvOp.move(&"backpack", uid, &"belt", Vector2i(0, 0)))
```

- **The network shape.** A client sends an op; a server answers yes or no. Sending *state* instead makes the server diff two documents to work out what a player claims to have done — and a diff is ambiguous: "this rifle moved" and "this rifle was destroyed and an identical one appeared" are the same diff, and only one of them is a duplication exploit.
- **Undo.** An op names what it did rather than what the result looked like.
- **A partial refusal.** One move out of ten can be refused without the other nine snapping back, which is what makes an inventory feel broken even when it is correct.
- **Prediction.** A client applies locally, sends, and rolls back on a no.

## The occupancy map is derived, never stored

A grid that keeps both a cell map and an item list can have them disagree. That is this family's most expensive bug shape in its own words: the props asset once used one list for ownership *and* undo, so trimming it for one purpose silently changed the other and a player could hold any number of props for free.

`cells_of()` and `occupied_cells()` are computed from the entries every time they are asked.

## `ignore_uid`, and why moving something one cell to the left is hard

An item moved within its own container collides with **itself**. The obvious workaround — remove it, then place it — is the one that loses the item when the place half fails. `fits(..., ignore_uid)` asks the question that was actually meant.

## Nesting is bounded, and cycles are refused before they exist

A bag inside itself is an infinite loop in every traversal — weight, save, draw, search — so the symptom is a hang, not a wrong number. And a bag in a bag in a bag with no limit is a save file whose size is the player's patience.

`can_nest()` walks **up** from the destination before the move. A cycle that already exists cannot be found by anything that has to traverse the structure to look for it: that traversal *is* the hang.

## The complaints this addresses on purpose

| | |
| --- | --- |
| "It made a second stack of five next to my stack of five" | A pickup tops up existing stacks first. |
| "I dragged twenty onto a stack with room for five and nothing happened" | A partial merge moves five and leaves fifteen. |
| "My rifle won't fit and there's clearly space" | Rotation is tried at each cell, not after a whole failed pass. |
| "The sort order changes every time I open it" | `sort_custom` is not stable in Godot, so every comparison breaks ties on the id. |

## Filtering and sorting are the client's

The server owns what is in the inventory; the client owns how it is shown. Sending a filter to a server makes it responsible for a preference, costs a round trip per keystroke, and gives the player a list that lags behind their own typing. Same rule as the server-browser asset's.

## It meets dot-loadout in exactly one file

`DotInvLoadoutLink`, by duck typing, so this asset parses in a project that does not have dot-loadout. The division is real:

- **dot-loadout** answers *what do you own and what did you bring in* — a permanent, bounded document validated against entitlements before a match.
- **dot-inventory** answers *what is in your bag right now* — it changes every few seconds, it has a shape, and a server must be able to refuse one move.

Neither direction is automatic. Whether a round's inventory is worth keeping is a design decision (an extraction game says yes, a round-based shooter says no), not something an asset should assume.

## Installing

Copy `addons/dot_inventory/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable dot-inventory in **Project → Project Settings → Plugins**.

## Dependencies

[dot-core](https://github.com/modcommunity/dot-core). Nothing else — dot-loadout and dot-ui are both optional and both reached without being named.

## License

MIT.
