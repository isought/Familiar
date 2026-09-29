# Persistent morning cards

## Collection, generation and execution

Collected observations feed `CardGenerationService` after a saved source run
finishes. The manual generation action and startup recovery use the same service
and persisted generation receipts. The service selects the latest saved successful
or partial entry for each active source, or entries from an explicitly selected
run. It waits for the shared desktop task surface before running.

Generation is a separate producer for `TaskExecutor`. Its only tool is
`submit_card_proposals`: it proposes wording and an action against an exact supplied
observation key. It cannot collect new facts or execute the proposed action.
Unresolved observations are reviewed in batches of at most 80; all batches must
succeed before cards and the run receipts are committed together. An empty proposal
list is valid. Receipts make each source run idempotent across relaunch and repeated
generation requests.

The person decides whether to keep ownership, file a card away, discuss it, or hand
its action to Noteling. An accepted action becomes an immutable `MorningWorkItem`
snapshot and follows the existing `MorningTaskRunner` and shared executor path.
See [task execution](task-execution.md).

## Identity and continuing state

The continuing identity is the normalized pair of source ID and item key, with one
persistent card UUID per pair. Collection now records `identityKey` and
`identityEvidence` separately from mutable excerpts and observed state. A native
item ID or stable permalink is preferred; otherwise the model uses repeatable
visible facts and retains its matching evidence. Tracked rechecks reuse the saved
key. This is best-effort identity, not a guarantee of provider-level matching.
Older observations remain usable through their existing IDs; content-derived
legacy IDs can still change when the source text changes.

`MorningCardReconciliation` updates an existing card from strictly newer
observations. It retains the user's ownership/filing choice, personal context and
manual edits, while refreshing source facts and the latest observation reference.
Each card records its first/last observation, supporting run ID and change history.
The generator can update an unedited proposal; it cannot overwrite a human-edited
card or silently change already accepted work.

The underlying matter and execution have different lifecycles:

- An unresolved card carries forward even when a later scan omits the item.
- Explicit observed resolution requires supporting evidence. A newer explicit
  open observation can reopen an observed resolution.
- A human “handled” decision remains resolved until the human reopens it.
- Preparing or executing an action does not itself prove external resolution.
  Generated cards return to the accepted personal/review ownership after work
  completes; its result remains in work history.
- Resolving a card cancels queued work for that card and prevents new handoffs.
  Running work and its accepted snapshot are not silently rewritten.

Resolved observations update existing cards but do not create new resolved cards.
Ignored cards retain that decision through later observations. No missing item is
silently treated as answered, completed, or irrelevant.

## Reading tracked items

New-item discovery continues to obey the saved source scope, such as today's unread
mail. Separately, unresolved, non-ignored cards supply tracked follow-ups to the
collector. The user authorized checking these known conversations outside the
recent/unread boundary and opening a matching mail thread, which may mark it read.
The source/account and visible identity must match before reusing the tracked key.

The current read remains bounded: up to 25 new reading observations plus up to 10
tracked follow-ups per source. The collector is instructed to use at most ten extra
page/scroll navigation actions; this navigation limit is not enforced by a runtime
counter. Recognized mailbox controls may reach Inbox, All Mail and Sent. Matching
tracked rows can be opened through the constrained follow-up policy. Arbitrary
search typing, direct URL navigation, content-link following, sending and other
mutations are unavailable. Calendar follow-ups stay within the requested day.
Unsupported navigation or a tracked item that cannot be checked produces a coverage
limitation; its card stays unresolved. A recent unread-only scan alone cannot prove
that an older conversation was answered.

This does not establish broad live client compatibility. The native controls and
visible evidence still determine which conversations can actually be rechecked.

## Chat adjustments

`CardConversation` supplies the selected card and recent work as reference data to
a constrained chat conversation. Its tools are:

- `update_card_context`: save the person's context and optionally revise the next
  proposed action's instruction, without modifying previously accepted work.
- `queue_card_action`: accept the saved action only when the person asks to run it.
- `set_card_handled`: record the person's handled/reopen decision.

The discussion itself has no desktop or general file tools. Handoff enters the
normal queue; discussing or adjusting a proposal does not execute it.

## Local persistence

`MorningStore` owns validation and domain transactions through `MorningRepository`.
The current `SQLiteMorningRepository` stores mutable morning state at
`~/.noteling/morning/morning.sqlite` (under `FAMILIAR_HOME` when redirected). Workspace
metadata, card payloads and work-item payloads commit in one SQLite transaction.
A unique tracking-key column enforces one card per source item. Published state and
generation receipts change only after the transaction succeeds.

An existing `morning/workspace.json` is decoded and validated first. A complete
SQLite database is then created and installed; the original JSON remains unchanged
for recovery. Once the database exists, it is authoritative. Existing cards, people,
folders, decisions and work snapshots keep their identities. In-progress work is
recovered as interrupted using the existing recovery behavior.

Timestamped folders under `~/.noteling/runs` remain the collected evidence and
readable reports; they are not replaced by the card database. Reusable source rules
remain in `~/.noteling/calendar/workspace.json`. Files retain owner-only permissions.
The repository separation does not move synchronous database work off the main actor.

## Verification boundary

Deterministic tests cover carry-forward, stable IDs across repeated generations,
newer facts, explicit resolution/reopening, human edits and decisions, accepted
snapshots, queued cancellation, failed-save retry, generation receipts, SQLite
uniqueness and legacy migration. Generation tests use structured provider fixtures;
they do not prove the model's editorial choices or a live email client's controls.
Use isolated `FAMILIAR_HOME` directories for tests and fictional native renders.

The installed release was also checked against existing saved Gmail results: two
cards were generated, a repeated generation request made no duplicates, and the
native card-to-chat entry point worked. This verifies saved-result generation with
the configured provider; it does not establish fresh tracked-thread compatibility.
