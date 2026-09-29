# Morning files — first implementation

## Product boundary

Morning Files is an independent entry point for reviewing and handing over work.
A small folder starts at the upper-left of a physical display. Opening it reveals
categories, then freely selectable paper files. Reading or closing a file does not
make a decision. Who's Who supplies editable relationships and working context.
Its management entry stays inside the options menu. The launcher can be dragged,
and morning windows and the task list move by their headers. Their preferred
positions persist in native window preferences, independently of card storage;
layout changes keep them within a connected physical display.

This version provides local authoring, persistent cards generated from saved source
observations, and execution of explicitly chosen actions. Generated cards retain
identity and human decisions across runs; see [persistent cards](persistent-cards.md). Calendar sources learned through Watch Me can also collect a
chosen day's schedule and produce a factual briefing. **Run all sources**
reads registered calendars, inboxes and web views sequentially and reports each outcome.
**Manage sources** edits reusable setup and rules. Completed rows and **Run history**
open a separate view of the actual findings, with collection evidence expandable
after the results. Each collection run has a durable timestamped folder; see
[calendar ingestion](calendar-ingestion.md). It does not have direct Outlook or
Jira API connections, scheduled refreshes, or inferred relationships. Sample files
are fictional, labeled, and loaded only on request. They use preparation-only actions.

## Boundaries in code

- `Features/Morning/MorningModels.swift`: folders, people, source evidence, cards,
  chosen actions, and durable work items. These are distinct from screen-anchored
  `StickyNote` annotations and chat messages.
- `Features/Morning/MorningStore.swift`: local transactions and validation. Card
  decisions and accepted work are committed together.
- `Features/Morning/MorningSamples.swift`: optional illustrative content using the
  same product models and storage as manually authored files.
- `Presentation/Morning/` and the morning views/editors: native folder launcher,
  reading and editing, and the temporary handoff animation.
- `App/MorningTaskRunner.swift`: serial dispatch of accepted work through
  `TaskRequest`, `TaskPlan`, and the shared `TaskExecutor`. The runner retains work
  validation, queue ordering, and durable outcomes.
- `App/TaskExecutor.swift`: execution handles shared with source ingestion and
  chat, wrapping the existing conversation coordinator and desktop execution
  service. See [task execution](task-execution.md).
- `BackgroundTaskStore` and `BackgroundTaskPanel`: compact queue admission,
  progress, native approvals, and results in the existing top-right task surface.
- `AppDelegate`: composition only. Card requests do not pass through chat.

## Local state and decisions

The workspace is stored through `MorningRepository` in the local SQLite database
`Config.dir/morning/morning.sqlite` (`~/.noteling/morning/morning.sqlite` normally).
Existing `workspace.json` data is validated and migrated, keeping the original JSON
unchanged. `FAMILIAR_HOME` redirects storage for tests and isolated runs. Transactions
commit card decisions, accepted work and generation receipts atomically; files use
owner-only permissions. An unreadable or unsupported workspace is reported and
blocked from replacement; it is not treated as an empty workspace.

Each card keeps a stable identity and category, original excerpts and capture
times, linked people, an explanation of relevance, proposed action, unresolved
questions, and its disposition. Category and progress are independent.

- Ignore files away the local card. It does not modify its source system.
- I'll do it keeps the card in a personal collection.
- Delegation commits a work item with snapshots of the card, linked people and your own profile,
  and selected action. A duplicate pending handoff is rejected.
- A context request is separate work and leaves the original decision open.
- Successful action work attaches its result. Manually authored/sample cards retain
  their result-ready disposition; generated cards return to review/personal ownership
  until explicit source evidence or the person resolves the underlying matter.
  Failed, stopped, or interrupted work remains inspectable and the card can be
  reviewed again. A local filing reversal does not undo an external action.

Local cards and people can be edited without an LLM connection. Only delegating
or requesting preparation calls the configured model with that work item's
context. It does not send the entire people directory.

## Execution and recovery

Preparation actions use a fresh conversation and an empty tool router. They can
draft or reason over the supplied evidence, but cannot inspect other apps or
claim to have fetched new information. Claude Code also has its built-in tools,
hooks, and other MCP servers disabled by the existing adapter.

Desktop actions require the existing control setting and reuse existing native
target selection, input borrowing, and action approvals. Queued desktop work
does not inherit whatever app the person happens to be using when it starts.

The runner saves `running` before invoking work, constructs a `TaskPlan` with the
chosen capabilities, and saves the result before calling `TaskExecution.finish`.
The shared executor owns cancellation, native cleanup and task presentation; the
runner owns the durable work outcome. It waits while shared desktop resources are busy. Each work item gets an
independent conversation; unrelated card tasks do not inherit chat history.
One card job executes at a time. A native approval keeps that job occupied;
resumable jobs that let other work pass an approval wait are outside this phase.

Queued items survive restart. Running or approval-waiting items recovered after
restart become interrupted, so an uncertain external action is not replayed
automatically. Their prior evidence, chosen action, and results remain available.
If saving a final result fails, further dispatch stays paused until restart can
safely recover that interrupted item. A session-only result remains visible in
the task panel and is explicitly labeled as unsaved.

The handoff animation follows successful local admission. Its overlay ignores
mouse events and respects Reduce Motion. It is a receipt for accepting work,
not proof that the work has finished.

## Validation

Run `FAMILIAR_HOME=<temporary-directory> bash scripts/test.sh` for deterministic
storage and queue tests alongside the existing regression suite. Do not point
tests at the user's normal Noteling data directory. Build with
`bash scripts/build.sh release` and inspect the native folder, editing, filing,
and task-result surfaces. Live execution checks should use local sample
preparation or an explicitly authorized target.

Initial verification: 274 deterministic tests passed, including storage/queue
coverage and existing desktop-control regressions. Native render fixtures cover
the empty state, folders, file spread/details, people/editors, and queue. Live
checks created and filed a local note, undid that filing, edited a sample person,
and completed two fictional preparation actions through the configured provider.
A quit/relaunch retained the local note, people data, and readable task results.
No real message was sent and no external desktop action was exercised by those
sample runs.
