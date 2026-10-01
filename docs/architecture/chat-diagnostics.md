# Chat freeze diagnostics

## Captured incident: September 28, 2026

The installed app froze after opening a card discussion, receiving an analysis,
and sending “do you think it’s worth the effort”. The process used one CPU core
(~100%) and its sampled physical footprint was 1.4 GB. Two live process samples
showed the main thread continuously inside SwiftUI graph transactions and layout,
including `LazyStack.measureEstimates` for the chat transcript. They did not show
an executor, provider, file-writing, or database CPU loop.

The implicated view was `BubbleView.transcript`: a bottom-anchored `LazyVStack`
with animated scrolling and note heights that change when a new turn begins.
The diagnostic build reproduced the freeze in the installed application using
that two-turn sequence. The previous reply was only 1,667 bytes. Breadcrumbs ended
at `chatScrollRequested` after appending the follow-up, before `contextReady` or
`executionStarted`. The automatic sample again showed the lazy layout loop.
Synthetic hosted probes, including a replay of the prior rendered text, remained
responsive; the live replay is the failing end-to-end case.

The targeted change replaces the transcript's `LazyVStack` with `VStack`, so the
bottom-anchored scroll measures actual note heights. The note content, reveal,
actions and scroll behavior otherwise remain unchanged. The installed release then completed the same card discussion and exact follow-up
without a stall. The live check changed from failing to passing; the full suite
passed 427 tests across 62 suites. The watchdog remains enabled because one
successful replay cannot establish that every layout edge case is gone.

## Automatic capture

`AppDelegate` explicitly starts `MainThreadDiagnostics` after setup. A background
queue posts one main-thread heartbeat at a time and checks it every 500 ms. A
three-second delay records an event and invokes `/usr/bin/sample` on this process.
There is one report per stall episode, one sampler at a time, and a bounded sampler
timeout. Process suspension gaps restart the detector rather than reporting sleep
as a UI freeze. Recovery is recorded when the heartbeat completes.

Files live under `~/.noteling/diagnostics/main-thread/` (respecting `NOTELING_HOME`, or the older `FAMILIAR_HOME`):

- `events.jsonl`: typed phases, counts, stall/recovery events, and report names.
- `events.previous.jsonl`: one rotated 256 KB metadata log.
- `stall-<readable UTC timestamp>-<id>.sample.txt`: up to five reports, 2 MB each.

New breadcrumbs never contain prompts, replies, URLs, or screenshots. The regular
app log adds correlation IDs, phase names, message/byte/line/note counts, card-focus
state, and panel dimensions. Existing unrelated context logs can still contain
private page titles and URLs; redact those before sharing a diagnostic bundle.

## Verification

`MainThreadDiagnosticsTests` tests healthy heartbeats, single-episode reporting,
recovery, stale acknowledgments, and suspension. `ChatLayoutRegressionTests` hosts
the real view in a child process, so an actual UI spin can be sampled and terminated
by its parent. Its passing result is not proof that the live freeze is fixed.

After a debug build, `--probe-main-thread-diagnostics` deliberately blocks an
isolated main thread, then verifies a stall, recovery, and real saved process sample.
Run it with a temporary `NOTELING_HOME`, never the user's live home. The debug
`--probe-chat-layout` also accepts `FAMILIAR_BUBBLE_LAYOUT_FIXTURE` and optionally
`FAMILIAR_LAYOUT_ONSCREEN=1` for a normal-level, non-activating on-screen window.

The opt-in `scripts/check-chat-replay.py --since <UTC timestamp>` validates the
interactive replay from diagnostic events. It requires two completed turns and
zero stalls, without reading prompt/reply contents. Against the failing replay
beginning `2026-09-28T23:51:40Z`, it fails at `chatScrollRequested` as expected.

Successful live verification: `--since 2026-09-28T23:57:29Z` reported two completed
chat turns and no main-thread stalls. The watchdog's isolated four-second freeze
probe also verified automatic capture, recovery and a readable process sample.
The signed release was rebuilt, installed and relaunched locally; card/workspace
and work-item data were compared with the pre-restart backup and remained unchanged.
