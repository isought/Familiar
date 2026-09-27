# Familiar

A quiet macOS helper for non-technical people in companies full of internal tools. A familiar knows your world
and acts on your behalf: point the pen at anything on screen and it explains what you are looking at; ask it to
do something and it takes the mouse. It sits as a small floating sticky-note character whose eyes follow your
mouse, and it uses the company's own notes and scripts for the tool you are in.

## How it works
1. **Watcher** (Accessibility, no screenshots) polls the frontmost app, window title and browser URL.
2. **Tool packs** in `~/.familiar/tools/<pack>/` match the current app/URL and supply docs plus scripts.
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
   notes on the current screen as well. Notes live in the matching pack's `notes.json` (a pack is created for the site or app
   if none matches), anchored by host+path or app+window, plus the control's role and label as shown, or a rectangle
   relative to the window for circled spots. Nothing is stuck to a password field.
5. **Chat**: double-click the note and type, for questions that have no single thing to point at. A single click just pokes it. The note reacts as it goes:
   curious when you hover, thinking while it works, happy or sad when the answer lands.
   The chat is a pad of sticky notes: each question is a note with the answer written on it (inked in line by line as it
   arrives), follow-ups are paper tabs under the note, and the character peeks over the newest one.
   For a little paper adventure, right-click the note → **Fold into a crane** (also in the pad's More menu and menu bar).
   It folds, flaps around the current screen once, lands at the same spot, and unfolds. The flight is click-through;
   **Esc** or menu bar → **Land Familiar** brings it back early. Starting work brings it back too. Available while idle;
   with macOS Reduce Motion enabled, the fold and gentle flap stay at home.
6. Claude can call the pack's scripts, `read_file` / `grep` over the docs, and `read_screen` (accessibility text).
7. **Control** (off by default, Settings → "Allow Familiar to control the mouse and keyboard"): ask it to do something
   ("type the sum formula for me") and it does it through Claude's computer toolset. By default it works **in the
   background**: it drives the window you were in when you asked through Accessibility and events sent to that app, so
   your mouse and keyboard stay yours and you can carry on elsewhere. A purple ghost cursor shows what it presses, and the
   pad shows a live peek of that window with each step and a **Stop** tab (⌃⌥Space stops too). When something needs the
   real mouse (a drag, a context menu, a ⌘ shortcut) it asks on the note first: **Go ahead** lends it the mouse with the
   shimmer border as before, and moving the mouse or pressing Esc takes it back. The hand icon on the pad, next to the
   eye, turns background mode off; then it takes the mouse as before (the shimmer border, a caption per step, moving the
   mouse or pressing Esc stops it). It asks before Send / Submit / Delete / Pay either way, and a pack can list more
   controls to confirm under `irreversible:` in its SKILL.md. `find_on_screen` gives it labelled controls via Accessibility;
   in the background it presses them by id with `click_element`.

8. **Watch me**: menu bar → **Watch Me** (or the eye on the pad). Do the task the way you normally do, then press ⌃⌥Space or
   **Stop Watching**. Familiar records clicks (with the real labels of what you clicked, via Accessibility), a crop around each
   click, a full frame whenever the screen changes, and text typed into named form fields, into
   `~/.familiar/recordings/<stamp>/` (folder 0700, files 0600). It asks what you were doing, writes the recording up through
   Claude and puts a draft on the pad: numbered steps with the real button and field names, the screens seen, the caveats and
   the match rule (which hosts, titles or apps the pack will apply to). **Keep it** writes a tool pack (`SKILL.md`,
   `docs/screens.md`, `docs/workflows/<task>.md`, `docs/glossary.md`) into `~/.familiar/tools/<site>/` without touching
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

## Try it on another Mac (5 minutes)
```bash
xcode-select --install                      # Command Line Tools, if `swift --version` fails
curl -LsSf https://astral.sh/uv/install.sh | sh   # uv, gets bundled into the app for pack scripts
git clone https://github.com/isought/Familiar.git && cd Familiar
./scripts/make-dev-cert.sh                  # local signing identity so permission grants survive rebuilds
./scripts/run.sh                            # builds build/Familiar.app and launches it
```
Then, once:
1. macOS asks for **Accessibility** and **Screen Recording**. Grant both (System Settings → Privacy & Security), then quit and relaunch Familiar from the menu bar.
2. Right-click the note → **Settings…** → choose **API key** and paste an Anthropic API key, or choose **Local Claude CLI** to use your installed, signed-in Claude Code → **Save**.
3. Menu bar → **Watch Me**, do a short task in the app you want it to learn, then **Stop Watching** (or ⌃⌥Space). Answer "what were you doing?" or skip it, read the draft, **Keep it**. It becomes a tool pack under `~/.familiar/tools/`.

No packs are needed to start: watching creates them. Nothing leaves the machine except the write-up request you trigger.

## Requirements
- macOS 14+, Xcode Command Line Tools (Swift 5.9+). No Xcode needed.
- `uv` on the build machine (gets bundled into the app; scripts declare deps inline, PEP 723).
- An Anthropic API key (or a gateway that speaks the Messages API), or an installed Claude Code CLI with its own login.

## Build and run
```bash
./scripts/make-dev-cert.sh                # once: local signing identity so permission grants survive rebuilds
./scripts/run.sh                          # builds build/Familiar.app and launches it
./scripts/test.sh                         # deterministic tests; current Swift tools, no API/login needed
.build/release/Familiar --selftest tools  # loads the packs, runs three scripts, no UI, no API
.build/release/Familiar --render-mascot /tmp/mascot [--style innocent|innocentV1|innocentV3|innocentV4|sharp]   # renders every mood, the quill cursor and the app-icon source as PNGs
.build/release/Familiar --render-origami /tmp/origami [--style innocentV4]   # folding stages and crane wing poses as PNGs
.build/release/Familiar --render-card /tmp/card [--states]   # the pad with a pick, a note sticker and answers, as PNGs
.build/release/Familiar --render-pen /tmp/pen               # the pen overlay over a fake page: stickers and the note editor, as a PNG
build/Familiar.app/Contents/MacOS/Familiar --ask "question" [url] [--shot] [--control] [--claude-cli]   # headless Claude call, real tool loop
```
First launch creates `~/.familiar/` (or `$FAMILIAR_HOME`) with `config.json`, `tools/` (example packs copied in) and `familiar.log`.
Right-click the bubble → **Settings…** to choose the Claude connection, enter pack secrets, and set the hotkey, hold time and start-at-login.
Secrets never go into `config.json`: dev builds keep them owner-only in `~/.familiar/secrets.json` (a self-signed app is re-identified by macOS on every rebuild, so the Keychain would prompt each time); set `secretsStore` to `keychain` for Developer ID builds.

### Use your Claude Code login
The API connection remains the default, including for existing configurations. To use the local CLI:
1. Install Claude Code and sign in through its normal flow (`claude auth login` in Terminal).
2. In Familiar **Settings… → Connection**, choose **Local Claude CLI**. Leave the executable path blank to find it automatically, or enter its full path. Leave the model blank to use Claude Code's default.
3. Click **Check connection** to check installation and login status, then **Save**.

Familiar runs the unmodified Claude Code executable using its own login; no additional API key is needed for this mode. Requests share your Claude Code usage allowance, including your existing subscription allowance when signed in through a Claude plan. Switching connections preserves your API credentials and gateway settings.

For a single headless run, append `--claude-cli` to `--ask` or `--summarize-recording`; this override does not change your saved connection. Tool packs, screen access and optional mouse/keyboard control run through Familiar's tools. Claude Code's own filesystem and shell tools are disabled. Private temporary bridge data is removed after each turn, and CLI sessions are not persisted.

## Permissions
Both are user-consent only; MDM cannot pre-grant them. The menu bar menu shows their status and opens the right pane.
- **Accessibility**: watcher context, element under the wand, `read_screen`.
- **Screen Recording**: the screenshot when you ask. Relaunch after granting.

## Tool packs
```
~/.familiar/tools/
  expenses/
    SKILL.md            manifest: name, description, match rules, short overview
    docs/               any files, any structure (md/txt are stuffed or indexed)
    notes.json          sticky notes left with the pen: {"notes": [{id, anchor, kind, text, by, at, confirmed}]}
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
Scripts receive `FAMILIAR_CONTEXT` (JSON of app/window/url) and `FAMILIAR_TOOL_DIR` in the environment, plus the
config's `env` map and, for each name the pack lists under `requires:` in its front matter, the secret of that name from
the Keychain (entered in Settings). The menu bar shows which packs are missing a secret.
Docs under the stuff limit are pasted into the prompt; larger ones are listed and read on demand.

### The Waxwing pack (current target)
`tools/waxwing/` explains the Waxwing App (127.0.0.1:4310). Its scripts talk to the app's API, which needs a read
token: in Waxwing open **Account and access → Create agent token (Read)**, then paste it in Familiar Settings as
`WAXWING_API_TOKEN` (the pack declares `requires: [WAXWING_API_TOKEN]`). `whats_here` resolves the current browser URL to the real page,
collection, model revision, record or work report; `search`, `library` and `attention` cover the rest.
The docs were generated from the app's repo and use its real button labels.

## Config (`~/.familiar/config.json`)
| key | default | meaning |
|---|---|---|
| connectionMode | api | `api` for the Messages API; `claudeCode` for the local Claude Code CLI |
| claudePath | "" | Claude Code executable path; empty = find automatically |
| claudeModel | "" | CLI model; empty = Claude Code's default |
| apiKey | "" | fallback only; Settings stores the key in the Keychain (or use `ANTHROPIC_API_KEY`) |
| apiBaseURL | "" | corporate gateway base URL; empty = api.anthropic.com |
| apiHeaders | {} | extra headers for the gateway |
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
| allowControl | false | let Familiar move the mouse and type when asked |
| controlInBackground | true | do things in the window you asked from, keeping your mouse and keyboard (the hand icon on the pad) |
| backgroundPreciseClicks | false | experimental: click exact spots in a background window through a private macOS path (self-tested at first use) |
| env | {} | non-secret variables handed to every script |
| bubbleX / bubbleY | | remembered bubble position |
| watcherEnabled / watcherIntervalSeconds | true / 2 | context polling |
| maxImageLongEdge | 1568 | screenshot downscale (pixels) |
| watchMaxImages | 60 | Watch me: most images sent when writing a recording up |
| watchCropWidth / watchCropHeight | 900 / 560 | Watch me: crop around each click (screen points) |
| recordingsDir | "" | override the recordings folder (default `~/.familiar/recordings`) |
| noteAuthor | "" | the name written on notes you leave with the pen; empty = your macOS full name |

## Dev notes
- macOS binds permission grants to the app's code signature. Ad-hoc builds change every time, so run
  `scripts/make-dev-cert.sh` once; the build script signs with the `Familiar Dev` identity it creates and grants persist.
  For other people's Macs this is replaced by an Apple Developer ID plus notarization (see Distribution below).

## Distribution (Apple Developer account)
One-time: install a **Developer ID Application** certificate (Keychain Access → Certificate Assistant → Request a
Certificate From a Certificate Authority, upload the request on the developer portal, install the .cer), and store a
notarization credential: `xcrun notarytool store-credentials familiar-notary --apple-id EMAIL --team-id TEAMID --password APP_SPECIFIC_PASSWORD`.
Then `./scripts/release.sh` signs with the hardened runtime, notarizes, staples, and writes `dist/Familiar-<version>.dmg`
and `.pkg` (signed too if a **Developer ID Installer** certificate exists). `scripts/build.sh` picks the Developer ID
automatically when present; Developer ID builds keep secrets in the Keychain (`secretsStore: auto`).
IT can push the .pkg via MDM with a PPPC profile that pre-approves Accessibility; Screen Recording cannot be
pre-approved, so the user clicks one prompt on first launch, once per install.
- Source layout:
  - `Sources/FamiliarContracts`: shared conversation/tool interfaces and results.
  - `Sources/FamiliarRuntime`: API/CLI providers, conversation history, execution lifecycle, tool routing, and process helpers; no app/native imports.
  - `Sources/Familiar/App`: composition, desktop activity ownership, shell state, app entry point, and headless/render commands.
  - `Sources/Familiar/Features`: Chat, WatchLearn, ContextNotes, Companion, and Settings. Each workflow keeps its own state; chat presents Watch events without owning recordings.
  - `Sources/Familiar/Native`: Accessibility context/hit testing, screen capture, control mechanics, and permissions/hotkeys.
  - `Sources/Familiar/Presentation`: shared shell surfaces and execution preview; `Configuration`, `ToolPacks`, and `Knowledge` retain current settings, pack storage, and context assembly.
- Cleanup goals and integration boundaries: [architecture plan](docs/architecture/next-phase-structure.md).
- Python helpers in `Resources/py/`: `introspect.py` (ast-only schema extraction), `run_tool.py` (executes `run(**args)`), `claude_mcp.py` (private CLI tool bridge).

## License
Apache License 2.0. Copyright 2026 isought. See `LICENSE`.
