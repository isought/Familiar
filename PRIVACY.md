# Privacy

The app runs on your Mac and has no accounts. It sends nothing to its developer: no analytics, no telemetry, no crash reports. AI features send what each request needs to the Claude connection you choose, and nowhere else. The exception is tool-pack scripts, described below.

## What stays on your Mac

The app stores its data in `~/.noteling`, or in `$NOTELING_HOME` if you set it. If you used it before it was renamed from Familiar, your existing `~/.familiar` folder is moved there the first time you open Noteling.

| What | Where |
|---|---|
| Settings | `config.json` |
| Pack secrets in developer builds (signed builds use the macOS Keychain instead) | `secrets.json` |
| Tool packs, and the notes you leave on controls | `tools/` |
| Sources you set up, run history and findings | `calendar/`, `runs/` |
| Cards, your decisions and context, Who's Who, queued work | `morning/` |
| Watch Me recordings, only while a draft is being written | `recordings/` |
| Activity log | `noteling.log` |

Watch Me recordings, developer-build secrets and the activity log can be read only by your macOS user account.

## What is sent, and where

**Where it goes.** Requests go to the connection you pick in Settings:

- **API key:** Anthropic's API, or the gateway you entered. Anthropic's [commercial terms](https://www.anthropic.com/legal/commercial-terms) and [privacy policy](https://www.anthropic.com/legal/privacy) apply, or your gateway's terms if you use one.
- **Local Claude CLI:** your installed Claude Code, signed in with your own Claude account. That account's terms apply, for example the [consumer terms](https://www.anthropic.com/legal/consumer-terms) for personal plans.

**What a request can include.** Depending on what you are doing:

- your question and the conversation so far;
- a screenshot of your screen, or of the window a task is working in. This happens when a question is about the screen, and while a task runs;
- the text and control names that macOS Accessibility exposes in that window;
- the current app, window title and web address, and up to eight you used recently;
- notes left on the current screen, and the documents and script results of matching tool packs;
- **Watch Me:**
  - frames of your screen, up to 60 images per recording;
  - the names of the controls you click;
  - text you type into named form fields. Text typed into password-like fields, into terminals, or outside form fields is never recorded;
- **reading sources:** what the app reads from the sources you set up, such as the visible rows and snippets of an inbox or the events in a calendar, together with your reading rules;
- **preparing cards:** saved findings, the context you added, and related Who's Who entries.

**Tool-pack scripts.** Scripts run on your Mac and can contact the services they were written for. The built-in shared pack can fetch web pages and open links.

## How long it is kept

- Watch Me recordings are deleted when you keep or discard the draft, when you clear the chat pad, or when you quit. Anything left behind by a crash is deleted after 7 days.
- Everything else stays until you delete it. This includes the activity log, which records the apps, window titles and web addresses you use while the app runs, and the actions the app takes.

## Deleting your data

1. Quit the app.
2. Delete `~/.noteling` (or your `$NOTELING_HOME` folder).
3. Delete the secrets that signed builds saved in the Keychain. Open Keychain Access and delete the items under `app.noteling.mac`, plus `com.isought.familiar`, `com.familiar.app` and `com.sidekick.app` from builds before the rename.

Data already sent to your Claude connection is handled under that provider's terms.

## Permissions

- **Screen Recording** lets the app see your screen when you ask a question, when you record with Watch Me, and while it works on a task you gave it.
- **Accessibility** lets it read which app, window and control you are using and record the steps you show it. Only when you turn on control does it also click and type for you.
- **Mouse and keyboard control** is off until you turn it on, in Settings or with the hand button on the chat pad.

## Changes and questions

This notice describes the current version of the app; its history is this file's history. For questions, open an issue at https://github.com/noteling/noteling/issues. Please don't post personal data there.
