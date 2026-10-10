# Design

Why dot-inventory is shaped the way it is, and why the obvious alternative is wrong in each case.

## Why this is not dot-loadout

`DotItem` was taken, which is a symptom rather than the reason. The reason is that the two answer different questions and want opposite properties:

| | dot-loadout | dot-inventory |
| --- | --- | --- |
| Question | What do you own, and what did you bring in? | What is in your bag right now? |
| Changes | Between matches | Every few seconds |
| Shape | A list of slots | A grid, with footprints and rotation |
| Validation | The whole document, against entitlements | One op, against the current state |
| On a refusal | The publish fails | That one move fails, and nothing else moves |

Building one on the other would mean either a loadout that has to be re-validated on every drag, or an inventory whose refusal throws away nine good moves. They meet in **one file**, `DotInvLoadoutLink`, duck-typed, which is the same arrangement dot-npc-ai has with dot-npc.

### The link takes one player's `DotLoadout`, not the `DotLoadoutManager`

It reads `filled_slots()` / `item_in()` / `count_in()` and writes `clear_slot()`, which are the document's real methods. The game gets the document from `await manager.active_for(key)` (a copy of it, since the manager caches the original) and hands the edited copy to `manager.publish`, which stays dot-loadout's trust boundary. Only removal crosses back: which slot a new item belongs in is the schema's question. The self-test's dot-loadout section runs against the real dot-loadout, linked for the test the way dot-team links dot-spectate, and reached by path so the addon still names nothing.

## Every mutation is an op

Not "set the inventory to this". A server that receives **state** has to diff two documents to work out what a player claims to have done, and a diff cannot tell *"this rifle moved"* from *"this rifle was destroyed and an identical one appeared"*. One of those is a duplication exploit and they are the same bytes.

An op names the change, so the wire format is the op, undo is the op's snapshot, one refusal is one refusal, and a client can predict by applying locally and keeping the op.

**A client that applies an op and does not keep it cannot roll back**, and the fallback (resend the whole inventory) is what makes an inventory feel broken even when it is correct. `_pending` is that list.

## Rollback restores a snapshot, not an inverse

`apply()` snapshots the document before performing, and both the failure path and `rollback()` restore it. An inverse is tempting and wrong: an op that failed **part-way** is exactly the case an inverse cannot describe, and inventing one is how a rollback becomes a duplication.

The snapshots are bounded at 64 (`MAX_HISTORY`), because an unbounded undo history is a memory leak with a plausible name, the same shape as dot-console's scrollback and dot-timer's `max_replay_seconds`. A rollback or an `apply_authoritative` that has to rewind past the oldest one cannot, and says so at WARN: the caller's copy then needs the server's whole document, which is why game-playground asks for one past 48 ops in flight.

`rollback(A)` rewinds to before A and re-applies what came after, without A; what no longer applies is taken out of the pending list, returned, and reported through `dropped`. On a predicting manager a rollback of an op that is not pending does nothing. Every rewind re-applies through `_reapply`, not `apply`: not limited, not vetoed and not sent a second time.

## A server's op lands underneath the predictions

`apply` on a predicting manager keeps the op as the client's own and calls `send_fn`. A server's op (a purchase, a give) goes through `apply_authoritative`, which applies without sending and lands it **underneath** the predictions: rewind to the oldest pending, re-apply what was decided in the order it arrived, then this, then the pending in the order predicted. An ordered channel means the server applied it before anything it has not answered yet.

## Identity survives the wire

In one process an op, an entry and an actor can be told apart by being the same object; across a wire each needs a name that survives. So the history is searched by identity (`_history_index`), never by content, whenever the object is to hand. A MOVE within a container edits the entry in place; across containers it keeps the uid unless the destination already uses it (`DotInvContainer.add_entry_keeping`), because uids are per container. A client chains its next op onto the uid its first one predicted, so a re-allocated uid silently names something else.

## Two derived things that must never be stored

**Occupancy.** `occupied_cells()` is computed from the entries. A grid that stores both a cell map and an item list can have them disagree, which is this tree's most expensive bug shape: dot-props used one list for ownership *and* undo, so trimming it to the undo depth removed props from their owner's account and a player could hold any number for free.

**A container's shape.** `DotInvDoc.adopt` takes width, height, slots, weight cap and accepted tags from the **catalogue**, not from the saved document. A stored width is a stored copy of a declaration, and the two go out of step the first time somebody makes a backpack bigger, with every old save silently keeping the old size and nothing saying so.

## Validation asks what applying will do

`_validate_add` checks room with `_room_for_add`, which asks exactly what `_do_add` will look for: top-ups first, a named cell, then first-fit. A full container is refused with `CODE_QUOTA`. An ADD that tops up or places anything is still allowed, because a pickup that half fits adds the half. Validation and application asking different questions is how a shop charges for a purchase that then fails.

## `ignore_uid` is not an optimisation

An item moved inside its own container collides with itself. Without `ignore_uid` the only way to move something one cell left is remove-then-place, and that is the version that **loses the item** when the place half fails. It is the argument that makes `fits()` ask the question that was actually meant.

## Nesting: bounded, and cycles refused before they exist

`can_nest()` walks **up** from the destination. A cycle that already exists cannot be detected by anything that traverses the structure looking for one (that traversal is the hang), so the test has to run before the move, every time.

`max_depth` exists because unbounded nesting is a save file whose size is the player's patience and a server that has to walk it on every validation. `_remove_subtree` collects children before erasing anything, because removing while iterating the dictionary being walked is a crash on some sizes and a silent partial removal on others.

## Smaller decisions

- **A name key, never a name.** An item document is stored, sent to a server, and read back by a client whose language nobody knew when it was written. A stored display name is also a stored typo: fixing one means rewriting every save that has it.
- **An icon PATH, never a `Texture2D`.** The rule dot-props, dot-audio and dot-fx all follow: a mounted pack's `class_name` globals are not registered in the host, so a catalogue that preloads cannot describe delivered content, and a server validating an inventory must not need an icon.
- **The rate limit is per actor.** An inventory is the cheapest denial of service a client has: a move is a validation, a weight sum and a redraw, sent as fast as it likes. `DotRateLimiter` is keyed on the actor, because one shared bucket means one player flooding throttles everybody. `unlimited_actors` (empty by default) names the ones it never applies to: the actor a server applies its own purchases and gives as, which cannot flood itself and otherwise spent whoever's bag it was changing.
- **`actor` is set by the receiver, never read off the wire.** It is the field a client would forge first. `apply(op, actor)` takes it from the caller's own knowledge (the connection the op arrived on) and `to_dictionary()` deliberately leaves it out.
- **Sorting breaks ties on the id.** `Array.sort_custom` is not stable in Godot, so a sorted list reshuffles its ties on every redraw and reads as a bug. Sorting by `name_key` sorts by translation keys rather than by what a player reads; sorting by the displayed name is the game's job, because only the game has the translation.

## The panel

`DotInvPanel` is a grid with native drag-and-drop through Godot's own `_get_drag_data` / `_can_drop_data` / `_drop_data` (the **engine**, not dot-ui, so it works in a project with either), and no art, no `Theme` and no icons. A game sets `icon_resolver` and a `Theme` and the look is theirs.

The one decision in it: **`_can_drop_data` asks `manager.validate(op)`**, the same call the server will make. A panel with its own idea of what fits will eventually disagree, and the player then sees a move accepted on screen and undone a round trip later.

## Deliberately not here

- **A themed panel.** See above.
- **Crafting.** A recipe is a rule over ids and a crafting table is a container with a rule; both are a layer above this and neither belongs in the thing that has to stay a document.
- **Equipment stats.** What a rifle *does* is dot-combat's. This holds the id.
- **A transport.** `send_fn` takes a dictionary. Same shape as dot-chat's router and dot-map's sync.
