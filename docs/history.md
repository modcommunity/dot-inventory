# History

Bugs worth recognising if they come back. The lessons that still apply are rules in [CLAUDE.md](../CLAUDE.md) and [design.md](design.md).

## The link spoke to a fake

`DotInvLoadoutLink` once duck-typed against `slots()` and `set_items()`, which nothing in dot-loadout has: it worked only against the self-test's own fake. It now uses the document's real methods, and the self-test runs it against the real dot-loadout ([design](design.md#the-link-takes-one-players-dotloadout-not-the-dotloadoutmanager)). A duck-typed seam tested only against a fake of itself proves nothing.

## What building it found

All three were in the suite rather than in the addon, and each read as a bug in the code:

- **A test that searched for "the stack of thirty".** The top-up rule changed what the stacks looked like, the search found nothing, and the failure pointed at the merge. Built explicitly now: two stacks at two known cells.
- **A test whose arithmetic was wrong.** 20 kg plus 20 kg in a 30 kg bag is refused, and the check expected it to fit. The section now asserts there *was* room for it, so the refusal is provably the weight cap and not the space.
- **A 2×2 pouch will not go into a 2×2 pouch that has one round of ammunition in it.** Correct, and it looked exactly like the nesting being broken. The ammunition is dropped explicitly now, with the reason written beside it: the space rule and the nesting rule produce identical symptoms from outside.

## What a real wire found

Six, all in the addon, found when game-playground carried a bag over dot-net: the first time any of `send_fn`, `confirm` and `rollback` had been called by anything but this suite. Each was reproduced in the suite's last section against this addon alone before it was fixed, and each check there was armed (fix removed, check failing, fix restored).

- **`validate` passed an ADD into a full container.** `_validate_add` asked the item, the container and the weight, never room; `_do_add` found out by running out of it, and the manager logged ERROR "failed after it had been validated" for an ordinary full bag. A shop asking `validate` before charging charged for a purchase that then failed. Fixed with `_room_for_add`.
- **`rollback(A)` undid B as well.** It restored the snapshot from before A and cut the history there, which discarded every op predicted after A while leaving them in the pending list: a move the server was about to accept vanished from the client's bag. And on a predicting manager a rollback of an op that was not pending fell back to the newest content match in the history, which for "drop one of these", sent twice, is the one the server ACCEPTED.
- **Nothing applied a server's op to a predicting manager.** `apply` kept it as the client's own and sent it, so a purchase sent down went straight back up and was refused. `apply_authoritative` was added.
- **The rate limit could not exempt the authority.** Keyed per actor, so a server applying its own gives as the player spent the player's budget, and as its own actor capped itself at thirty a second. `unlimited_actors` was added.
- **A MOVE re-allocated the uid**, even within one container (remove, then re-add). A client chaining a second op onto the uid its first predicted named whatever the server had allocated that number to: a crate the server added in between, moved validly and in silence.
- **Applying an ADD rewrote the caller's op.** `_do_add` set `op.to_cell` to `(-1, -1)` after the first placement, so the dictionary sent was not the op the caller made, and an ADD replayed after a rollback lost its named cell. A local now.

The shape under the last four: **identity matters once there is a wire** ([design](design.md#identity-survives-the-wire)).
