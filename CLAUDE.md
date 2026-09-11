# dot-inventory

An inventory as a document a server validates, mutated only by ops it can refuse one at a time.

**The distributable is `addons/dot_inventory/`.** It requires [dot-core](../dot-core), a separate repository, and nothing else.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## Why this is not dot-loadout

`DotItem` was taken, which is a symptom rather than the reason. The reason is that the two answer different questions and want opposite properties:

| | dot-loadout | dot-inventory |
| --- | --- | --- |
| Question | What do you own, and what did you bring in? | What is in your bag right now? |
| Changes | Between matches | Every few seconds |
| Shape | A list of slots | A grid, with footprints and rotation |
| Validation | The whole document, against entitlements | One op, against the current state |
| On a refusal | The publish fails | That one move fails, and nothing else moves |

Building one on the other would mean either a loadout that has to be re-validated on every drag, or an inventory whose refusal throws away nine good moves. They meet in **one file** — `DotInvLoadoutLink`, duck-typed — which is the same arrangement dot-npc-ai has with dot-npc.

## The central decision: every mutation is an op

Not "set the inventory to this". A server that receives **state** has to diff two documents to work out what a player claims to have done, and a diff cannot tell *"this rifle moved"* from *"this rifle was destroyed and an identical one appeared"*. One of those is a duplication exploit and they are the same bytes.

An op names the change, so:

- the wire format is the op,
- undo is the op's snapshot,
- one refusal is one refusal,
- and a client can predict by applying locally and keeping the op.

**A client that applies an op and does not keep it cannot roll back**, and the fallback — resend the whole inventory — is what makes an inventory feel broken even when it is correct. `_pending` is that list.

## Rollback restores a snapshot, not an inverse

`apply()` snapshots the document before performing, and both the failure path and `rollback()` restore it. An inverse is tempting and wrong: an op that failed **part-way** is exactly the case an inverse cannot describe, and inventing one is how a rollback becomes a duplication.

The snapshots are bounded at 64, because an unbounded undo history is a memory leak with a plausible name — the same shape as dot-console's scrollback and dot-timer's `max_replay_seconds`.

## Two derived things that must never be stored

**Occupancy.** `occupied_cells()` is computed from the entries. A grid that stores both a cell map and an item list can have them disagree, which is this tree's most expensive bug shape: dot-props used one list for ownership *and* undo, so trimming it to the undo depth removed props from their owner's account and a player could hold any number for free.

**A container's shape.** `DotInvDoc.adopt` takes width, height, slots, weight cap and accepted tags from the **catalogue**, not from the saved document. A stored width is a stored copy of a declaration, and the two go out of step the first time somebody makes a backpack bigger — with every old save silently keeping the old size and nothing saying so.

## `ignore_uid` is not an optimisation

An item moved inside its own container collides with itself. Without `ignore_uid` the only way to move something one cell left is remove-then-place, and that is the version that **loses the item** when the place half fails. It is the argument that makes `fits()` ask the question that was actually meant.

## Nesting: bounded, and cycles refused before they exist

`can_nest()` walks **up** from the destination. A cycle that already exists cannot be detected by anything that traverses the structure looking for one — that traversal is the hang — so the test has to run before the move, every time.

`max_depth` exists because unbounded nesting is a save file whose size is the player's patience and a server that has to walk it on every validation. `_remove_subtree` collects children before erasing anything, because removing while iterating the dictionary being walked is a crash on some sizes and a silent partial removal on others.

## What building it found

All three were in the suite rather than in the addon, and all three are worth writing down because each one read as a bug in the code:

- **A test that searched for "the stack of thirty".** The top-up rule changed what the stacks looked like, the search found nothing, and the failure pointed at the merge. Built explicitly now: two stacks at two known cells.
- **A test whose arithmetic was wrong.** 20 kg plus 20 kg in a 30 kg bag is refused, and the check expected it to fit. The fix was worth more than the line: the section now asserts there *was* room for it, so the refusal is provably the weight cap and not the space.
- **A 2×2 pouch will not go into a 2×2 pouch that has one round of ammunition in it.** Correct, and it looked exactly like the nesting being broken. The ammunition is dropped explicitly now, with the reason written beside it — the space rule and the nesting rule produce identical symptoms from outside.

## The pieces

| | |
| --- | --- |
| `DotInvItem` | What a thing is. A document with a translation key, not a name. |
| `DotInvCatalogue` | Items and container shapes. Validates with no icons and no meshes. |
| `DotInvContainer` | A grid or a list of slots. Both, because only the geometry differs. |
| `DotInvDoc` | Several containers, the parent links, the depth bound and the cycle test. |
| `DotInvOp` | One mutation. The wire format, the undo record and the refusal unit. |
| `DotInvManager` | Validates, applies, snapshots, predicts, rolls back. |
| `DotInvQuery` | Filtering and sorting, locally. |
| `DotInvLoadoutLink` | The only file that knows dot-loadout exists. |
| `DotInvPanel` | A grid with native drag-and-drop. Asks `validate` before a cell lights up. |

## Decisions

### A name key, never a name

An item document is stored, sent to a server, and read back by a client whose language nobody knew when it was written. A stored display name is also a stored typo: fixing one means rewriting every save that has it.

### An icon PATH, never a `Texture2D`

The rule dot-props, dot-audio and dot-fx all follow: a **mounted pack's `class_name` globals are not registered in the host**, so a catalogue that preloads cannot describe delivered content — and a server validating an inventory must not need an icon.

### The rate limit is per actor

An inventory is the cheapest denial of service a client has: a move is a validation, a weight sum and a redraw, sent as fast as it likes. `DotRateLimiter` is keyed on the actor, because one shared bucket means one player flooding throttles everybody.

### `actor` is set by the receiver, never read off the wire

It is the field a client would forge first. `apply(op, actor)` takes it from the caller's own knowledge — the connection the op arrived on — and `to_dictionary()` deliberately leaves it out.

### Sorting breaks ties on the id

`Array.sort_custom` is not stable in Godot, so two items of equal weight come out in whatever order they happened to be in. A sorted list that reshuffles its ties on every redraw reads as a bug in the inventory. (And sorting by `name_key` sorts by translation keys rather than by what a player reads — sorting by the displayed name is the game's job, because only the game has the translation.)

## Things deliberately not here

- **A themed one.** `DotInvPanel` ships: a grid, native drag-and-drop through Godot's own `_get_drag_data` / `_can_drop_data` / `_drop_data` — which are the **engine**, not dot-ui, so it works in a project with either — and no art, no `Theme` and no icons. What it does not ship is a look. A game sets `icon_resolver` and a `Theme` and it is theirs.

  The one thing in it that is a decision rather than a widget: **`_can_drop_data` asks `manager.validate(op)`**, which is the same call the server will make. A panel with its own idea of what fits is one that will eventually disagree, and the player then sees a move accepted on screen and undone a round trip later.
- **Crafting.** A recipe is a rule over ids and a crafting table is a container with a rule; both are a layer above this and neither belongs in the thing that has to stay a document.
- **Equipment stats.** What a rifle *does* is dot-combat's. This holds the id.
- **A transport.** `send_fn` takes a dictionary. Same shape as dot-chat's router and dot-map's sync.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 180 godot --headless --path . res://examples/inventory_selftest.tscn
```

9 sections, 97 checks. The ones that matter are the refusals — a move that does not fit, a bag inside itself, a split that is really a move, a weight cap, a rollback that does not duplicate. Every one of those is a real exploit in some shipped game, and none of them is visible in a screenshot.
