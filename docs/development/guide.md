# Noteling developer guide

Build, configuration and implementation reference. For installation and everyday
use, start with the [user README](../../README.md).

A quiet macOS helper for non-technical people in companies full of internal tools. A familiar knows your world
and acts on your behalf: point the pen at anything on screen and it explains what you are looking at; ask it to
do something and it takes the mouse. It sits as a small floating sticky-note character whose eyes follow your
mouse, and it uses the company's own notes and scripts for the tool you are in.

## How it works
1. **Watcher** (Accessibility, no screenshots) polls the frontmost app, window title and browser URL.
2. **Tool packs** in `~/.noteling/tools/<pack>/` match the current app/URL and supply docs plus scripts.
3. **Pen**: hold the note until the ring fills, or press **⌃⌥Space**. The pointer becomes a quill, the screen dims with a
   shimmering border, the element under the quill is outlined, and a click sends a screenshot (ringed at the click) plus a
   zoomed crop to Claude. **Drag** to circle something instead: the ink stroke goes on the screenshot, the crop is the circled
   area, and the labelled controls inside it are named for the model.
   The reply names what you pointed at, explains its state, and offers tappable follow-ups.
4. **Notes**: while the pen is up, **right-click** (two-finger click, or ⌃-click) a control and a sticky note opens right on it.
   Type, ⏎ keeps it, ⇧⏎ makes a new line, Esc drops it; tick **Warning** for the orange kind. Right-drag circles a spot and
   sticks the note to that area. Right-click an existing sticker to edit or remove it. Picking up the pen shows every note
   already left on the current screen as a small sticker on its control (hover to read the whole thing); a pick puts the
   notes on that control onto the pad first, and Claude gets them too ("Notes left on this control"). Typed questions see the
   notes on the current screen as well. Notes live in `~/.noteling/notes/`, one JSON file each (notes kept in a pack's
   `notes.json` by earlier versions are moved there once, and the file renamed `notes.json.moved`). A note made in a
   browser is stuck to its page by its page key (so a record is the same page however it was reached, and a site that
   serves every page from one path keeps them apart), and to its control by the page's own id first, then its role and
   label, or a rectangle relative to the window for circled spots; in other apps, by app and window. Nothing is stuck
   to a password field. Nothing about notes stays on screen: arriving where there are notes, the bubble holds up a
   sticky with how many for a moment (hover it to read them). Press ⌥ Option twice (or click that sticky) to show them
   open on the page, in an overlay that lets clicks through; press it again, click, scroll, type or change page and
   they go. Where there are none, a one-line hint says so. A note whose control isn't on screen is left off rather
   than placed wrong; up to three show down the window's right edge instead, saying what they are for. The shortcut
   can be turned off in Settings. Pointing with the pen tells the notes on that control first (each as "PEOPLE SAY ·
   who · confirmed when", flagged when no one has confirmed it in 90 days), then the page's notes for controls not on
   screen, before the answer. A note can be linked to a script from the packs for its page ("Check with…" in the note
   editor, for scripts that take no arguments); pointing at it, or clicking its sticker, runs the script as you, stopped
   at 10 seconds, and shows its own answer as a CHECKED line under the note. A check runs only a script from a pack for
   that page, with only the arguments the script declares. Clicking a sticker with the pen asks about that note;
   right-clicking it edits it. The model is told notes are named people's claims with their age, to attribute and
   not to state as fact. How notes get used is counted in `~/.noteling/usage/notes.jsonl`: counts, kinds and note ids,
   never words or addresses.
5. **Chat**: double-click the note and type, for questions that have no single thing to point at. A single click just pokes it. The note reacts as it goes:
   curious when you hover, thinking while it works, happy or sad when the answer lands.
   The chat is a pad of sticky notes: each question is a note with the answer written on it (inked in line by line as it
   arrives), follow-ups are paper tabs under the note, and the character peeks over the newest one.
   For a little paper adventure, right-click the note → **Fold into a crane** (also in the pad's More menu and menu bar).
   It folds, flaps around the current screen once, lands at the same spot, and unfolds. The flight is click-through;
   **Esc** or menu bar → **Land Noteling** brings it back early. Starting work brings it back too. Available while idle;
   with macOS Reduce Motion enabled, the fold and gentle flap stay at home.
6. Claude can call the pack's scripts, `read_file` / `grep` over the docs, and `read_screen` (accessibility text).
   General chat also knows the saved sources (the jobs taught with Watch Me or created in chat).
   - **Context:** every turn carries a short "Your saved jobs" list: name, kind, address, reading rules, and when each was taught and last run.
   - **Tools** (`SourceConversation`): `get_source` shows one job with its latest findings, `update_source` edits it through the same store and checks as Manage sources, `remove_source` / `restore_source` take it out of future runs and bring it back, `create_source` starts a job that reads through a pack script, with no teaching, and `offer_run_source` adds a Run now tab.
   - **Rules:** only the person's tap runs a job. Edits wait while a read is running, and they never clear a source's "needs review" flag. Each change leaves a receipt on the pad and an Open Manage sources tab.
7. **Control** (off by default, Settings → "Allow Noteling to control the mouse and keyboard"): ask it to do something
   ("type the sum formula for me") and it does it through Claude's computer toolset. By default it works **in the
   background**: it drives the window you were in when you asked through Accessibility and events sent to that app, so
   your mouse and keyboard stay yours and you can carry on elsewhere. A purple ghost cursor shows what it presses.
   Once desktop execution begins, the instruction moves from chat to a compact **background task screen** in the top-right.
   Expand it for a live window preview, approvals and the result; **Stop** or ⌃⌥Space ends the work. Collapsing or hiding
   the task screen keeps execution running, and completion respects that choice. Reopen it through the menu bar's
   **Background Tasks…** entry or by clicking Noteling while a task runs. The task header can be dragged to another spot.
   Recent results and their last screenshots are kept for up to 20 tasks until Noteling quits. Ordinary conversational
   answers stay in chat. One desktop task runs at a time. Chat waits for its current request to finish; Morning Files can
   hand off several actions to a saved queue, which runs them one at a time.
   Background `read_screen` and `look_at_screen` read only the selected target window and fail if no target is available.
   When something needs the real mouse (a drag, a context menu, a ⌘ shortcut) it asks on the task screen first.
   Without the separate display, this explicitly asks to use your screen, mouse and keyboard, and **Go ahead** begins
   the desktop handoff with a shimmer border. Pause your own input during that step; typing (including ⌘Tab), clicking,
   scrolling or moving the cursor takes control back.
   The hand icon on the pad, next to the
   eye, turns background mode off; then it takes the mouse as before (the shimmer border, a caption per step, moving the
   mouse or pressing Esc stops it). Background Send / Submit / Delete / Pay button presses pause for a one-action approval
   on the task screen; a changed window or control invalidates that approval. A pack can list more
   controls to confirm under `irreversible:` in its SKILL.md. `find_on_screen` gives it labelled controls via Accessibility;
   in the background it presses them by id with `click_element`.
   Chat composers that send with Return can use `send_message`: the task screen shows the recipient, observed
   app/window/composer context and complete typed draft for one-action approval. Noteling rechecks the focused
   composer and exact draft, then presses Return once. Input permission is separate and must still be active for
   a separate-display send. Unreadable or changed drafts are not sent; uncertain delivery is inspected without
   automatically retrying. The offscreen input runner still rejects raw Return; send approval is handled by this dedicated tool.

   **Separate display (experimental, off by default):** Settings → "Use a separate display for background tasks"
   lets Noteling move the selected task window onto a temporary virtual monitor when the first action begins.
   The task card stays on your physical screen. If background input needs help, approving the mouse-and-keyboard
   request keeps the task window on its separate display. Noteling borrows input for each short action and returns
   it between steps, before the model thinks or inspects another screenshot. Typing or mouse input interrupts a
   borrowed action. Stop, completion and quitting return borrowed windows. Opening the live preview returns the window and stops
   the background task. Read-only questions never create a display or move a window.
   This uses private macOS display APIs. Input borrowing is in `Sources/Familiar/Native/Control/Background/OffscreenInputBorrow.swift`;
   see [its scope and verification status](../architecture/offscreen-input-borrow.md).
   It keeps existing app logins and uses native Accessibility/process-event controls, with temporary input borrowing
   when approved. It does not create a separate desktop session or guarantee every app's text input. Full-screen windows and mirrored-display
   arrangements are not supported by this first version; setup failures stop before task input.

8. **Watch me**: menu bar → **Watch Me** (or the eye on the pad). Do the task the way you normally do, then press ⌃⌥Space or
   **Stop Watching**. Noteling records clicks (with the real labels of what you clicked, via Accessibility), a crop around each
   click, a full frame whenever the screen changes, and text typed into named form fields, into
   `~/.noteling/recordings/<stamp>/` (folder 0700, files 0600). After stopping, enter a short name or description, then
   optionally add context such as reading rules, exceptions or where to stop. **Skip context** continues without it.
   Noteling waits for both steps before generating one draft from the recording and your inputs, then puts a compact
   review on the pad, including the source's reading rules and any uncertainty notice. Retry preserves both inputs. Typing while a draft is under review revises it: the text joins the recording's context as "Changes requested after reviewing the draft", and the draft is written again from the same recording. Earlier requests still apply, and a failed draft can be revised the same way.
   **Open full draft** shows the complete steps, screens, glossary, caveats and source details in a separate, read-only
   text window with search and copy. Long documents stay out of the chat layout. **Keep it** saves the complete draft as a tool pack (`SKILL.md`,
   `docs/screens.md`, `docs/workflows/<task>.md`, `docs/glossary.md`) into `~/.noteling/tools/<site>/` without touching
   existing files (new workflows get `-2`, `-3`; screens are added only when new); **Discard** throws the draft away. Either
   way the recording folder is deleted, as it is when you clear the pad or quit; anything left behind by a crash is swept
   after 7 days. The pen and control are off while it watches.
   What is never written down: anything typed in a password field or a field named like one (password, PIN, OTP, token, key…),
   anything typed in a terminal (Terminal, iTerm2, Warp, kitty, Alacritty, WezTerm, Ghostty…), anything typed outside a form
   field (editors, chat composers), and anything typed when Accessibility cannot say which field has focus — the log then
   says only that something was typed. A click never stores the value of a secure field, a text area or a terminal. Without
   Accessibility, keystrokes are not listened for at all. The write-up sends at most `watchMaxImages` images and 20 MB.
   Headless: `--record-synthetic <dir>` (a fake recording from the current screen) and
   `--summarize-recording <dir> ["purpose"] [--tools-root <dir>] [--keep] [--claude-cli]` (prints the draft JSON; keeps into a temp folder by default).

9. **Morning Files**: a small folder in the upper-left opens categorized folders and a spread of files. Choose any file
   to see its three parts: what it is, what it means for you, and one to three options, best first (hover an option for its
   exact instruction). **Show original** shows what Noteling read. **Ignore** files it away, **I'll do it**
   keeps it yours, and handing it to Noteling saves the action before the file flies to the background task screen.
   Drag the small folder itself or a window's header to move it; the morning windows and background task list remember
   their positions. Add your own folders and files, and configure roles, relationships and identities through
   **… → Who's Who**. The retrieval menu
   brings back filed items and completed results. Everything is stored privately under `~/.noteling/morning/`.
   **Try sample files** adds explicitly fictional examples; these can only prepare local drafts and analysis.
   Preparation uses your configured Claude connection with no tools. **Work in an app** uses existing desktop control
   and approvals. Queue entries survive restarts; interrupted work returns for review rather than replaying actions.
   **Manage sources → Teach a source with Watch Me** teaches a calendar, inbox, or web view from a demonstration.
   Show the location, account, and information to read; explain what they mean and review the learned description in chat.
   **Keep it** registers a reading source in Morning Files. If no reading source was established, Noteling keeps the review
   open and explains what is missing. Ordinary Watch Me action workflows remain separate from source collection.
   Previously saved demonstrations appear under **Saved reading workflows → Review & add** so you can confirm their
   source address and reading scope without recording again. For calendars, choose a day and **Read calendar**.
   Each saved source has **Edit** and **Remove** actions. Edit its description, location, account and reading rules;
   changes update the same source. Remove excludes it from future batches while keeping past run results.
   **Removed sources → Restore** brings the saved setup back, including after a restart.
   Noteling uses fresh observations to collect that date and compute meeting blocks, accepted conflicts, and open time
   within your selected briefing window. Partial reads show their limitations and do not assert free time.
   **Run all sources** reads registered sources one at a time: calendars for today (09:00–17:00 briefing window in each
   source’s time zone), and mail/web sources within their saved scope. It collects up to 25 visible mail/web observations,
   retaining evidence and coverage gaps. New-item inbox discovery uses visible rows and snippets. Separately,
   unresolved cards can request bounded rechecks of their tracked conversations, including opening a matching thread.
   A job can instead read through a pack script that its SKILL.md lists under `sources:`, with no window, model or
   computer control. The bundled `imap-mail` pack's `today` reads everything that arrived in the inbox over IMAP,
   read-only, back to the last read a card step sorted (24 hours the first time, at most 7 days, the newest 200
   messages). Chat creates such a job with `create_source`; the job's reading rules are applied by the card step.
   Results show which reads completed, were partial, or failed. Stop cancels the remaining reads
   and keeps collections already saved. **Run all sources** opens the **Latest run** screen, which follows the run and
   names any source that didn't finish at the top. The card controls (**Make cards from saved results**, **View cards**)
   are on the run screens; the main screen shows card work only while it runs or when it fails.
   Clicking a completed row opens that run’s findings; **Manage sources** is for saved setup and rules.
   **Run history** keeps earlier results available after a restart. Findings appear before expandable collection
   details, and partial or failed reads remain clearly labeled.
   Each run is stored under `~/.noteling/runs/<readable-timestamp>/`, with `run.json`, per-source JSON
   exports, and a readable `report.md`. **Show run folder** opens the run folder. Existing saved collections
   are preserved as recovered results; future runs retain every collection instead of replacing previous ones.
   This first calendar collection supports exposed Accessibility navigation controls; unsupported controls are reported.
   Calendar collection does not create or move meetings. Reads are started explicitly; scheduled collection, preference
   history and relationship-based recommendations are not connected yet. Apart from script jobs, sources are read from the screen.
   Saved observations generate continuing cards. Repeated scans match cards using the source and an extracted item key;
   newer evidence can update or resolve a card, while missing items remain open. Human edits and handled decisions persist.
   The card step judges each item once: only items that are new or changed since its last judgment go to the model.
   While a job reads mail through a script, the one-week attention test adds thumbs and **Let me explain…** to its
   cards, a daily line that opens the day's rest (with **Matters to me**), and **This week**. Its append-only
   ledger stays in `~/.noteling/attention/` and is never sent to a model. Thumbs, explanations and **Matters to me**
   (also offered on each run result that didn't become a card) become lessons in `morning/`, listed on **What you've
   taught**; the card step sends each job's 40 newest lessons beside its rules.
   **Discuss or adjust** opens a focused card conversation; an explicit handoff queues its action for the shared executor.
   Cards, decisions and accepted work live in a local SQLite database, separate from source rules and run evidence.
   See [persistent cards](../architecture/persistent-cards.md) for identity and recheck limitations.
   See [calendar collection](../architecture/calendar-ingestion.md) and [Morning Files](../architecture/morning-files.md).

Noteling appears in the Dock with its app icon. Click it to reopen chat, use **Quit Noteling** or ⌘Q to exit,
or use macOS **Force Quit** (⌥⌘Esc) if it becomes unresponsive. Closing a window keeps Noteling running.

## Try it on another Mac (5 minutes)
```bash
xcode-select --install                      # Command Line Tools, if `swift --version` fails
curl -LsSf https://astral.sh/uv/install.sh | sh   # uv, gets bundled into the app for pack scripts
git clone https://github.com/noteling/noteling.git && cd noteling
./scripts/make-dev-cert.sh                  # local signing identity so permission grants survive rebuilds
./scripts/run.sh                            # builds build/Noteling.app and launches it
```
Then, once:
1. macOS asks for **Accessibility** and **Screen Recording**. Grant both (System Settings → Privacy & Security), then quit and relaunch Noteling from the menu bar.
2. Right-click the note → **Settings…** → choose **API key** and paste an Anthropic API key, or choose **Local Claude CLI** to use your installed, signed-in Claude Code → **Save**.
3. Menu bar → **Watch Me**, do a short task in the app you want it to learn, then **Stop Watching** (or ⌃⌥Space). Add a short description, then add optional context or choose **Skip context**. Review the draft and choose **Keep it**. It becomes a tool pack under `~/.noteling/tools/`.

No packs are needed to start: watching creates them. Chat, recording write-ups, and delegated actions send their selected
context to your configured Claude connection. Creating and editing Morning Files or Who’s Who entries stays local.

## Requirements
- macOS 14+, Xcode Command Line Tools (Swift 5.9+). No Xcode needed.
- `uv` on the build machine (gets bundled into the app; scripts declare deps inline, PEP 723).
- An Anthropic API key (or a gateway that speaks the Messages API), or an installed Claude Code CLI with its own login.

## Build and run
```bash
./scripts/make-dev-cert.sh                # once: local signing identity so permission grants survive rebuilds
./scripts/run.sh                          # builds build/Noteling.app and launches it
./scripts/test.sh                         # deterministic tests; current Swift tools, no API/login needed
.build/release/Familiar --selftest tools  # loads the packs, runs three scripts, no UI, no API
.build/release/Familiar --render-mascot /tmp/mascot [--style innocent|innocentV1|innocentV3|innocentV4|sharp]   # renders every mood, the quill cursor and the app-icon source as PNGs
.build/release/Familiar --render-origami /tmp/origami [--style innocentV4]   # folding stages and crane wing poses as PNGs
.build/release/Familiar --render-card /tmp/card [--states]   # the pad with a pick, a note sticker and answers, as PNGs
.build/release/Familiar --render-background-task /tmp/tasks # task screen states, fabricated content, no model or desktop capture
.build/release/Familiar --render-morning /tmp/morning      # native folder, files, people and queue with fictional local data
.build/release/Familiar --render-pen /tmp/pen               # the pen overlay over a fake page: stickers and the note editor, as a PNG
build/Noteling.app/Contents/MacOS/Noteling --ask "question" [url] [--shot] [--control] [--claude-cli]   # headless Claude call, real tool loop
```
First launch creates `~/.noteling/` (or `$NOTELING_HOME`) with `config.json`, `tools/` (example packs copied in) and `noteling.log`. If you used the app before it was renamed, an existing `~/.familiar` is moved there on first launch, and `$FAMILIAR_HOME` still works.
Right-click the bubble → **Settings…** to choose the Claude connection, enter pack secrets, and set the hotkey, hold time and start-at-login.
Secrets never go into `config.json`: dev builds keep them owner-only in `~/.noteling/secrets.json` (a self-signed app is re-identified by macOS on every rebuild, so the Keychain would prompt each time); set `secretsStore` to `keychain` for Developer ID builds.

### Use your Claude Code login
The API connection remains the default, including for existing configurations. To use the local CLI:
1. Install Claude Code and sign in through its normal flow (`claude auth login` in Terminal).
2. In Noteling **Settings… → Connection**, choose **Local Claude CLI**. Leave the executable path blank to find it automatically, or enter its full path. Leave the model blank to use Claude Code's default.
3. Click **Check connection** to check installation and login status, then **Save**.

Noteling runs the unmodified Claude Code executable using its own login; no additional API key is needed for this mode. Requests share your Claude Code usage allowance, including your existing subscription allowance when signed in through a Claude plan. Switching connections preserves your API credentials and gateway settings.

For a single headless run, append `--claude-cli` to `--ask` or `--summarize-recording`; this override does not change your saved connection. Tool packs, screen access and optional mouse/keyboard control run through Noteling's tools. Claude Code's own filesystem and shell tools are disabled. Private temporary bridge data is removed after each turn, and CLI sessions are not persisted.

## Permissions
The menu bar menu shows permission status and opens the relevant System Settings pane.
- **Accessibility**: watcher context, element under the wand, `read_screen`.
- **Screen Recording**: the screenshot when you ask. Relaunch after granting.

## Tool packs
```
~/.noteling/tools/
  expenses/
    SKILL.md            manifest: name, description, match rules, short overview
    docs/               any files, any structure (md/txt are stuffed or indexed)
    scripts/
      report_status.py  def run(report_id: str) -> dict   -> tool "expenses__report_status"
  shared/               a pack with no match rules is always active
    scripts/open_url.py, copy_to_clipboard.py, fetch_page.py
```
`SKILL.md` front matter:
```yaml
---
name: Expenses (Concur)
description: Expense reports, receipts, cost centers, approvals.
match:
  urls: [expenses.internal.example.com, /concur.*reports/]   # substring, or /regex/
  bundles: [com.example.SomeApp]
  titles: [Concur]
---
Free-form overview that is always included when the pack is active.
```
Scripts: a top-level `run(...)` with type hints and a docstring becomes a tool; the docstring's `Args:` section
becomes parameter descriptions; the return value is JSON-serialised back to the model. Dependencies go in a
PEP 723 header and are installed by the bundled `uv` on first use:
```python
# /// script
# dependencies = ["requests>=2.31"]
# ///
```
Scripts receive `NOTELING_CONTEXT` (JSON of app/window/url) and `NOTELING_TOOL_DIR` in the environment (also as `FAMILIAR_CONTEXT` and `FAMILIAR_TOOL_DIR`, for packs written before the rename), plus the
config's `env` map and, for each name the pack lists under `requires:` in its front matter, the secret of that name from
the Keychain (entered in Settings). The menu bar shows which packs are missing a secret.
Docs under the stuff limit are pasted into the prompt; larger ones are listed and read on demand.

### The Waxwing pack (current target)
`tools/waxwing/` explains the Waxwing App (127.0.0.1:4310). Its scripts talk to the app's API, which needs a read
token: in Waxwing open **Account and access → Create agent token (Read)**, then paste it in Noteling Settings as
`WAXWING_API_TOKEN` (the pack declares `requires: [WAXWING_API_TOKEN]`). `whats_here` resolves the current browser URL to the real page,
collection, model revision, record or work report; `search`, `library` and `attention` cover the rest.
The docs were generated from the app's repo and use its real button labels.

### Watch lists (`watch:` scripts)
Say "watch these items for me: 1, 2, 3" in chat and Noteling checks each item on a schedule, sending a Mac notification
when one is not as it should be **right now**. A watch is about now, not history: there is no change timeline, and an
earlier check is never evidence of a cause. What the person was last told is kept only so the same alert isn't
repeated. The site-specific part is a pack script, named in SKILL.md with `watch: <script>`; everything else is generic.

**The check script.** Its `run(item: str, ...)` checks one item:
- `item` is the item exactly as the person gave it: an id or a page address. Extra arguments they gave when creating
  the watch (a zip code, say) are passed only if `run` declares them, as the declared type. `watch_items` refuses an
  argument the script doesn't take and asks for one it requires.
- It returns an object with `title` (string), an optional `url` (the page to open), `state` and optional `facts`.
  `state` holds flat fields, each a string, number, bool, null or list of strings: the things worth watching, e.g.
  `{"seller": "Acme", "price": 12.33, "strikethrough": 13.95, "badges": ["Deal"], "in_stock": true}`. Up to 40 fields
  count, and a value that isn't flat is compared as its JSON text. `facts` is anything else that helps explain the item;
  up to 8,000 characters are kept.
- An `error` key, an exception, no `state` object, or running past 60 seconds means "couldn't check". The reason shown
  is the first line of the error, without the script's file name or the Python error type.
- It runs through the bundled uv like any pack script, with the pack's `requires:` secrets and `NOTELING_CONTEXT` set
  to the item's page (app "Watch list", the item's address when known), and it stops when its watch is stopped.

```python
def run(item: str, zip: str = "") -> dict:
    """Check one item on the shop.

    Args:
        item: the item's id or its page address
        zip: delivery zip code
    """
    page = read_item(item, zip)   # the pack's own code
    return {"title": page["name"], "url": page["url"],
            "state": {"price": page["price"], "badges": page["badges"], "in_stock": page["in_stock"]},
            "facts": {"offers": page["offers"]}}
```

**What counts as right.** An item's first check that works sets it: every field in `state`, or only the `fields` the
person named, then any `expect` values they gave (which can add fields). An item whose first check fails gets it from
its first later success. `change_watch` with `expect` changes it for every item and compares again with the last check.
Numbers are equal within 0.005; text is trimmed, then exact; lists of strings are sets (order doesn't matter, and an
empty list is none); null is a value of its own ("none"). A number or yes/no given as text ("12.33", "$12.33", "yes")
counts as that number or answer. A field the check doesn't report is shown as not reported and never alerted on.

**When it notifies.** Never on an item's first check, since the chat shows it, and never for a result the chat waited
for. Otherwise it notifies when an item goes from as expected to not as expected, when it is not as expected in another
way than last told, when it is back to as expected ("Back to what you expected"), and when it couldn't be checked twice
in a row ("Couldn't check: <reason>", once until a check works again). Three or more items of one watch that couldn't
be checked for the same reason in one run make one notification ("Couldn't check 12 items: <reason>"). The title is the
item's title, the subtitle the watch's name, and the body plain words, one line per difference, e.g. "Price: 13.95 —
expected 12.33". Clicking it opens the chat on why the item is red or grey, or else the Watch List. Notifications use
UserNotifications and work only from the `.app` bundle; elsewhere (`swift run`, tests) alerts go to the log. macOS asks
for permission when the first watch is created; without it everything else works and the chat says they are off.

**Schedule.** Every 15 minutes by default (5 to 240). The runner ticks every 30 seconds, and 10 seconds after the Mac
wakes. It starts the watches that are due, runs at most two item checks at a time across all watches, and never runs
one watch twice at once. It starts once the packs have loaded.

**Chat tools** (`WatchListConversation`, in every general chat turn):
- `watch_items` {items, name?, every_minutes?, fields?, expect?, args?, check?} creates a watch and checks every item at
  once. It waits up to 90 seconds, then returns per item its title, status, what it shows now and what counts as right.
  `check` picks a pack when several have a `watch:` script; with none, the chat says to link the team's tools in Settings.
- `list_watches`, `check_watch_now` {watch?}, `change_watch` {watch, add_items?, remove_items?, every_minutes?, expect?,
  paused?} and `stop_watch` {watch}. A change leaves a receipt on the pad and an Open Watch List tab.

**Why?** `Assistant.explainWatched` sends what counts as right, what the latest check shows and when, and its facts.
The request is about the item's page (a synthetic context: app "Watch list", the item's address), so that page's pack
and its scripts are available, and it never takes control. The answer comes as **Why**, **What you can do** and, only
when something couldn't be confirmed, **Couldn't check**.

**Files.** `~/.noteling/watch-list.json` is owner-only and written whole. It holds each watch's name, check, items,
extra arguments, fields, expectations and schedule, and for each item its title and address, what counts as right, the
latest check's state and facts, when it ran, its status, failures in a row and what the person was last told. The code
is in `Sources/Familiar/Features/WatchList/`; the menu bar's **Watch List…** opens its window.

## Config (`~/.noteling/config.json`)
| key | default | meaning |
|---|---|---|
| connectionMode | api | `api` for the Messages API; `claudeCode` for the local Claude Code CLI |
| claudePath | "" | Claude Code executable path; empty = find automatically |
| claudeModel | "" | CLI model; empty = Claude Code's default |
| apiKey | "" | a key here overrides the one Settings saves (in the Keychain); with neither, `ANTHROPIC_API_KEY` is used |
| apiBaseURL | "" | corporate gateway base URL; empty = api.anthropic.com. With a gateway, an Anthropic key is optional, and Anthropic-only request extras (server-side refusal fallbacks) are not sent |
| apiHeaders | {} | extra headers for the gateway, e.g. `{"Authorization": "Bearer …"}` when it authenticates without an Anthropic key |
| model | claude-opus-5 | API model id |
| effort | medium | API: low / medium / high / xhigh / max; CLI: low / medium / high |
| maxTokens | 4096 | answer length cap |
| screenshotMode | auto | `auto`: attach a screenshot when the question sounds screen-related, otherwise the model may call `look_at_screen`; `always`; `never` |
| screenshotReuseSeconds | 0 | if > 0, quick follow-ups on the same screen reuse the last screenshot within this window |
| hideFromScreenShare | false | true makes the bubble invisible in screenshots, screen shares and recordings |
| toolsDir | "" | override tool packs folder |
| docsStuffLimitChars | 24000 | how much doc text to paste before switching to read_file |
| uvPath | "" | override the uv binary |
| wandHoldSeconds | 0.8 | how long to hold the bubble to pick up the pen |
| mascotStyle | innocent | character brows: `innocent` (v2, the default), `innocentV1`, `innocentV3` (experiment), `innocentV4` (bashful), or `sharp` (the original merge) |
| hotkey | control+option+space | pen hotkey, e.g. `cmd+shift+k` |
| allowControl | false | let Noteling move the mouse and type when asked |
| controlInBackground | true | do things in the window you asked from, keeping your mouse and keyboard (the hand icon on the pad) |
| backgroundPreciseClicks | false | experimental: click exact spots in a background window through a private macOS path (self-tested at first use) |
| backgroundVirtualDisplay | false | experimental: move task windows onto a temporary virtual monitor; return them on stop/completion |
| env | {} | non-secret variables handed to every script |
| bubbleX / bubbleY | | remembered bubble position |
| watcherEnabled / watcherIntervalSeconds | true / 2 | context polling |
| maxImageLongEdge | 1568 | screenshot downscale (pixels) |
| watchMaxImages | 60 | Watch me: most images sent when writing a recording up |
| watchCropWidth / watchCropHeight | 900 / 560 | Watch me: crop around each click (screen points) |
| recordingsDir | "" | override the recordings folder (default `~/.noteling/recordings`) |
| noteAuthor | "" | the name written on notes you leave with the pen; empty = your macOS full name |

## Dev notes
- macOS binds permission grants to the app's code signature. Ad-hoc builds change every time, so run
  `scripts/make-dev-cert.sh` once; the build script signs with the `Noteling Dev` identity it creates and grants persist.
  For other people's Macs this is replaced by an Apple Developer ID plus notarization (see Distribution below).

## Distribution (Apple Developer account)
One-time: install a **Developer ID Application** certificate (Keychain Access → Certificate Assistant → Request a
Certificate From a Certificate Authority, upload the request on the developer portal, install the .cer), and store a
notarization credential: `xcrun notarytool store-credentials familiar-notary --apple-id EMAIL --team-id TEAMID --password APP_SPECIFIC_PASSWORD`.
Then `./scripts/release.sh` signs with the hardened runtime, notarizes, staples, and writes `dist/<version>/Noteling-<version>.dmg`
and `.pkg` (signed too if a **Developer ID Installer** certificate exists).
The release script refuses an existing output directory; use a new version instead of replacing an earlier build.
`scripts/build.sh` picks the Developer ID
automatically when present; Developer ID builds keep secrets in the Keychain (`secretsStore: auto`).
IT can push the .pkg via MDM with a PPPC profile that pre-approves Accessibility; Screen Recording cannot be
pre-approved, so the user clicks one prompt on first launch, once per install.
- Source layout:
  - `Sources/FamiliarContracts`: shared conversation/tool interfaces and results.
  - `Sources/FamiliarRuntime`: API/CLI providers, conversation history, execution lifecycle, tool routing, and process helpers; no app/native imports.
  - `Sources/Familiar/App`: composition, desktop activity ownership, shell state, app entry point, and headless/render commands.
  - `Sources/Familiar/Features`: Chat, WatchLearn, ContextNotes, Companion, and Settings. Each workflow keeps its own state; chat presents Watch events without owning recordings.
    - `Features/Calendar`: sources and jobs (calendar, mail and web profiles in `CalendarStore`), screen reads (`SourceCollectionTask`) and script reads (`ScriptReading`, `ScriptReadWindow`), the run archive (`SourceRunStore`), chat's job tools (`SourceConversation`), and the Manage sources, Latest run and Run history screens. `App/CalendarCollectionRunner` runs the reads.
    - `Features/Morning`: cards, Who's Who and queued work in `morning.sqlite` (`MorningStore`), the card step and its judgments (`CardGenerationService`, `CardGenerationSubmission`), reconciliation with continuing cards, card discussions, and the Morning Files screens.
    - `Features/Attention`: the one-week attention test: its append-only ledger in `attention/`, labels from thumbs, explanations and card actions, the numbers, and the thumbs, daily line, rest and week screens.
    - `Features/BackgroundTasks`: `BackgroundTaskStore`, the task screen's state: the running task and up to 20 recent results with their last frame.
  - `Sources/Familiar/Native`: Accessibility context/hit testing, screen capture, control mechanics, and permissions/hotkeys.
  - `Sources/Familiar/Presentation`: shared shell surfaces and execution preview; `Configuration`, `ToolPacks`, and `Knowledge` retain current settings, pack storage, and context assembly.
- Cleanup goals and integration boundaries: [architecture plan](../architecture/next-phase-structure.md).
- Python helpers in `Resources/py/`: `introspect.py` (ast-only schema extraction), `run_tool.py` (executes `run(**args)`), `claude_mcp.py` (private CLI tool bridge).

## License
The code is under the Apache License 2.0, Copyright 2026 Yang Lu. See `LICENSE` and `NOTICE`.

- **Third-party software:** anything bundled in the app is listed in `THIRD_PARTY_NOTICES.md`, with its license text in `licenses/`. `scripts/build.sh` copies all of these into `Contents/Resources/Legal/` in every build. When you bundle something new, add it to both.
- **Brand:** the name, app icon and sticky-note character are covered by `TRADEMARKS.md`, not by the Apache License.
- **Contributions:** they need a signed CLA; see `CONTRIBUTING.md` and `CLA.md`.
- **Privacy:** `PRIVACY.md` describes what the app stores and sends. Update it whenever that changes.
