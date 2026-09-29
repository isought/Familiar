# Source ingestion through Watch Me

## Delivered scope

An employee demonstrates their calendar, explains what it represents, reviews the
learned source in chat, and keeps it. Morning Files exposes those sources and lets
the employee choose a date and briefing window for a fresh collection. A collected
snapshot supports a factual schedule briefing: observed events, meeting blocks,
overlapping accepted events, and open intervals within the chosen window.

The same teaching and batch path also registers mail and web reading sources.
Those profiles identify a location, account (when known), bounded reading scope,
navigation hints and completion checks. Mail/web collections retain up to 25
observations with visible evidence, account/location/scope evidence and explicit
coverage gaps. New-item inbox discovery inspects list rows and snippets. Existing
unresolved cards can request separately bounded, authorized rechecks that open a
matching tracked conversation; see [persistent cards](persistent-cards.md).

This is maintained functionality in the existing Watch Me and Morning Files paths.
It does not require a service API connection. The current route requires a signed-in
application and macOS access already used by Noteling. Calendar UI compatibility
depends on exposed Accessibility controls; a source description is not proof that
the current interface is completely readable.

## Learning meaning

`PackDraft.calendarSource` is optional, preserving ordinary Watch Me workflows.
`PackDraft.readingSource` handles mail and web views. Manage Sources uses generic
source-teaching intent, and Keep in this mode refuses a workflow-only draft rather
than claiming it is runnable. Only one source is registered per demonstration.
A calendar source captures the meaning, application, account, calendar, time zone,
navigation hints, completion checks, and unknowns. Its location is grounded in the
observed recording. Dates and events demonstrated during teaching are examples,
not collected schedule data for a future run.

After recording, Watch Me collects a short description and then optional context.
Submitting or skipping the description enters `awaitingContext` without contacting a
provider. Submitting context or choosing **Skip context** starts one generation from
the recording and both inputs. `WatchMeta.context` is optional for compatibility with
older recordings, stored separately from `purpose`, and retained through retries.
The source is reviewed in a compact Watch Me chat note with bounded description,
identity, reading rules and uncertainty notices. **Open full draft** builds the complete
review on demand in a separate native, read-only text window; workflow, screens,
glossary and every source field remain available without rendering a long chat note.
Only display text is shortened. Keep persists the complete source and workflow
before deleting the recording. A failed source save leaves the review available;
retry reuses successful workflow writes. Sources can be corrected in Morning Files,
including account, calendar and time zone before collection.

Every registered source has explicit **Edit** and **Remove** actions. Editing updates
the same source ID. Mail/web editors separate the source's meaning from its reading
rules (the saved scope). The optional context step also asks for these rules,
and teaching retains explicit restrictions separately from the source's meaning.
Relative date ranges remain relative to a future run. These rules guide collection; entering a filter does not add
unsupported UI capabilities such as typing a mailbox search query. Source management
is disabled during collection so edits do not race a visible run.

Mail/web locations come from observed URLs or native identifiers. A URL read from
a screenshot can become a candidate only when images were actually supplied and
the summary gives address evidence; the candidate requires review before running.
Existing kept workflows are listed separately as **Review & add** candidates.
They do not run until the employee reviews and saves a reading profile. Recovered
profiles retain the old notes as untrusted navigation references, not executable
steps. Source registration remembers its workflow file, avoiding duplicate import
suggestions after a fresh Keep.

Removal archives the source profile and excludes it from active source lists, future
batches and workflow recovery suggestions. Historical runs remain available in
**Run history**, and the original workflow document is preserved. **Removed sources →
Restore** returns the same reusable profile, including after a restart.
A stale editor cannot silently recreate an archived ID; restoration is explicit.
These operations affect Noteling's saved records, not the connected application's data.

## Fresh collection

`CalendarCollectionRunner` dispatches source-specific `SourceCollectionTask` plans
through the shared `TaskExecutor`, which wraps the conversation coordinator and
`DesktopExecutionService`. Chat and accepted morning actions use the same execution
entry point. The runner retains source validation, batch ordering and run-history
commits; a task is finished only after its domain outcome is established. See
[task execution](task-execution.md) for these contracts. The employee starts a
collection explicitly. A busy desktop or native activity returns an actionable
status rather than starting competing input.
The run has its own conversation, a snapshot of the taught source, a requested date,
and a selected time window. It explicitly selects a target window rather than
assuming the current foreground application is its source.

**Run all sources** in Morning Files captures the saved source
profiles and the current instant once, then reads each calendar sequentially. Each
calendar uses its own local date and a 09:00–17:00 briefing window; mail/web sources
read their saved scope at the captured request time. Incomplete source
details and individual collection failures are reported per source without blocking
other valid sources. Partial observations are saved and labeled partial. Stop cancels
the active collection and leaves remaining sources marked not run, preserving earlier
successful collections. A batch reserves the shared desktop before starting and
rejects duplicate starts. Progress, source outcomes and validated observations are
persisted in a run archive. A restart marks unfinished work interrupted without
replaying it. It runs registered source ingestion only, not arbitrary saved workflows.

Calendar collection has a separate tool policy. General scripts, file mutation,
message sending, arbitrary keys, text input and coordinate clicks are unavailable.
Supported calendar navigation uses guarded Accessibility controls. Unsupported or
ambiguous controls must yield a limitation instead of broader control permissions.
Control labels are checked against the current element when an action executes.
Mail/web discovery uses a separate constrained navigation policy. It allows
recognized mailbox tabs and page buttons, and refuses message rows/cells, content
links, account switching, selection, mutation controls, arbitrary typing, keys and
scripts. A mail source with explicit tracked follow-ups uses the bounded follow-up
policy, which additionally permits opening matching tracked conversations and
recognized All Mail/Sent navigation. It does not widen discovery to unrelated mail.

Fresh observation is required before structured submission. Changing targets or
navigating invalidates an earlier observation/submission. The local submission tool
validates source identity, requested day/time zone, event times and attendance,
evidence, and coverage. Account/calendar/date evidence is reported with the result;
the system cannot independently prove every semantic interpretation made from UI
text or images. Model prose alone never becomes a successful collection.

## Data and briefing

`CalendarStore` owns source rules and validation, and delegates storage through
`SourceRulesRepository`. The current `FileSourceRulesRepository` keeps the versioned
`Config.dir/calendar/workspace.json`; version 4 contains active and removed source
profiles. `SourceRunStore` owns run lifecycle and delegates archive I/O through
`SourceRunRepository`. Its current `FileSourceRunRepository` stores results under
`Config.dir/runs` (normally `~/.noteling/runs`). Both facades accept other repository
implementations without changing their consumers. Unsupported or corrupt state is
reported and protected from replacement. This boundary preserves the existing local
formats and synchronous storage behavior.

Every single-source or batch collection has one folder named with a readable local
timestamp. Name collisions create distinct folders. `run.json` is the authoritative
record: run identity, origin, exact times, time zone, each captured source profile,
status and validated snapshot. Per-source JSON files and `report.md` are generated
exports of that record. Reports lead with findings, without repeating saved rules.
Folders and files use owner-only permissions; writes publish only after the archive
commit succeeds. The archive retains partial, failed, stopped and skipped outcomes,
including which sources finished before a batch was stopped.

Version 1–3 workspace collections, including those attached to removed sources,
are migrated idempotently before the rules-only workspace is committed. Each is
identified as a recovered collection rather than a reconstructed historical batch.
Migration does not invent missing past runs. Existing snapshot/latest APIs are
compatibility projections of the archive, not a second persisted result store.
New runs retain prior observations, including repeat reads on the same day.

**Manage sources** displays definitions, reading rules, editing and removal.
Completed source rows open the exact run and source result. **Run history** remains
available after relaunch and after a source is removed. Result views lead with
collected items or calendar facts; collection evidence is expandable. Incomplete
coverage and failed attempts stay visible. The result never substitutes an older
successful collection for a failed run. **Show run folder** reveals the timestamped
run folder. Changing current source rules does not rewrite historical results or
the source identity captured when a run began.

`CalendarBriefing` computes facts from the saved observations. It distinguishes
adjacent meetings from overlaps, preserves unknown attendance, handles time zones
and day boundaries, and excludes declined/cancelled/free events from busy time.
Partial coverage and uncertain availability suppress confident open-time claims.
An empty *complete* observation is different from a failed or incomplete read.

Open time is described only within the collected calendar and selected window.
The briefing does not infer lunch preferences, relationship importance, remembered
priorities, preparation tasks, or which meeting should move. Calendar changes,
automatic morning scheduling, source APIs and cross-source reconciliation remain
future implementation phases using the same source/snapshot boundary.

## Verification

Use `FAMILIAR_HOME=<temporary-directory> bash scripts/test.sh` for model, storage,
briefing, teaching and execution regressions. Never point deterministic tests at
the normal data directory. `--render-morning <directory>` renders source and
briefing UI fixtures alongside the other native Morning Files surfaces.

Deterministic tests and fictional renders do not establish live Outlook/Teams/Slack
compatibility. Validate a taught calendar on two different dates and compare the
observations against the original calendar before claiming support for that client.
