# Privacy

The app runs on your Mac and has no accounts. It sends nothing to its developer: no analytics, no telemetry, no crash reports. AI features send what each request needs to the Claude connection you choose, and nowhere else. The exception is tool-pack scripts, described below.

## What stays on your Mac

The app stores its data in `~/.noteling`, or in `$NOTELING_HOME` if you set it. If you used it before it was renamed from Familiar, your existing `~/.familiar` folder is moved there the first time you open Noteling.

| What | Where |
|---|---|
| Settings | `config.json` |
| Pack secrets in developer builds (signed builds use the macOS Keychain instead) | `secrets.json` |
| Tool packs, and the notes you leave on controls | `tools/` |
| Sources you set up, run history and findings, including everything a script read returned | `calendar/`, `runs/` |
| Cards, your decisions and context, Who's Who, queued work, what the card step has already judged, and the lessons you teach | `morning/` |
| Watch Me recordings, only while a draft is being written | `recordings/` |
| The attention test: each message a mail job read through a script (its subject, sender and address, a short preview and its link) and whether it became a card, and the names of mail jobs that read from the screen beside it; your thumbs, explanations and “Matters to me” marks; what you do with your cards; and when you open the pack | `attention/` |
| Activity log | `noteling.log` |
| Freeze diagnostics: the steps chat goes through, and a record of each time the app stopped responding | `diagnostics/main-thread/` |

Watch Me recordings, developer-build secrets, the attention test and the activity log can be read only by your macOS user account, and so can the freeze diagnostics.

The attention test measures whether cards show you what matters and leave the rest out. Noteling creates its file only once a mail job that reads through a script has run, and only ever adds to it. It stops adding what you do once a week passes with no such read, for example after you remove the job, and starts again with the next one. The file never leaves your Mac: Noteling doesn't send it anywhere. What you teach while the test runs, your thumbs, explanations and “Matters to me” marks, is also kept as lessons with your cards, and lessons are sent with the card step; see Lessons below. To erase the test, quit the app and delete the `attention` folder; the test starts again with the next read.

**Script reads.** A job that reads mail through a script saves everything the read returned with its run in `runs/`: for each message, its sender, subject, received time, flags (read or unread, starred, Gmail's Important marker, its Gmail tab, sent to a mailing list), a preview of up to 300 characters, its Message-ID and, for Gmail, a link to it. The run also records your mail address and the server it read. A read covers everything that arrived since the last read the card step sorted. The first read looks back 24 hours, no read looks back more than 7 days, and a read returns at most the newest 200 messages; it records how many more arrived.

**What the card step has judged.** After each read, the card step decides which items deserve a card. So that a later read can't turn something it already passed over into a card, the morning database (`morning/morning.sqlite`) keeps, for each item the card step has read, the item's key (for mail read through a script, its Message-ID), a hash of what the judgment rested on, and when the item was last seen. For mail read through a script, the hash covers the subject, sender and received time; for other items, the saved title, text, link and state. Both also cover the job's description and reading rules. A judgment that goes unseen for 30 days no longer counts, and the next card step deletes it.

**Lessons.** When you mark something “Matters to me” on a run's results or in the rest, give a card a thumb, or say why with “Why?” or “Let me explain…”, the morning database keeps a lesson about that item: its key, the job that read it, its subject or title, its sender for mail, what you said (matters, matters a lot, not for me, not at all) and your words, up to 500 characters. It keeps your 300 newest lessons. **What you've taught**, linked from a run's results, lists them all, and **Forget** removes one.

**Freeze diagnostics.** While the app runs, it writes the time of each step chat goes through, such as a question sent or a reply received, to `events.jsonl`, with two counts: how many messages the chat holds and how many characters they add up to. It never writes your questions, replies, web addresses or screenshots there. It also checks twice a second that it is still responding. When it stops responding for 3 seconds or more, it records for how long and saves a two-second sample of its own process, made with the macOS `/usr/bin/sample` tool. A sample shows which of Noteling's code was running, the libraries it loaded and its memory use. Noteling keeps at most five samples of up to 2 MB each, deleting the oldest first. Once `events.jsonl` reaches 256 KB it becomes `events.previous.jsonl`, replacing the one before, and a new file starts. Noteling doesn't send these files anywhere; you can delete the folder at any time.

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
- **reading a source from the screen:** screenshots and the Accessibility text of the window the job reads, with the job's description and reading rules. The job saves up to 25 new items it saw there, such as the visible rows and snippets of an inbox or the events in a calendar, and can check up to 10 items from your open cards again. A job that reads through a script sends nothing while it reads;
- **preparing cards (the card step):** after a read, the items that are new or changed since the card step last judged them. For mail read through a script, that is each message's sender, subject, received time, flags, preview, Message-ID and link; for a screen read, the rows, snippets or events it saved. With them go the job's description and reading rules, up to 40 of that job's newest lessons (each one's subject or title, sender, what you said and your words), your cards for those items with the context you added, and up to 40 of your Who's Who entries;
- **your saved jobs, in chat:** each job's name, where it reads, its description and reading rules, and when it last ran; when chat looks one up, up to 25 items from its latest read.

**Tool-pack scripts.** Scripts run on your Mac and can contact the services they were written for. The built-in shared pack can fetch web pages and open links.

**The mail pack.** The built-in `imap-mail` pack reads a mailbox over IMAP. It needs two secrets that you enter in Settings: `MAIL_ADDRESS` and `MAIL_APP_PASSWORD`, an app password rather than your normal one. Signed builds keep them in the macOS Keychain; developer builds keep them in `secrets.json`. Noteling hands a secret only to the scripts of packs that name it, and among the built-in packs only this one names these. The script connects only to the IMAP server for your address, over an encrypted connection: your provider's server (for example Gmail's or iCloud's), or one you set yourself with `MAIL_IMAP_HOST`. It opens the mailbox read-only and fetches messages with `BODY.PEEK`, so it never marks anything read, moves or deletes it. For each message it returns, it downloads the first 16 KB (the headers and the start of the text) and keeps only the facts listed under Script reads above. What a job reads reaches your Claude connection only through the card step, and through chat when chat looks the job up. In chat, Claude can also run the script itself when you ask about your mail; what it returns is then part of that conversation.

## How long it is kept

- Watch Me recordings are deleted when you keep or discard the draft, when you clear the chat pad, or when you quit. Anything left behind by a crash is deleted after 7 days.
- The card step's judgments stop counting after 30 days unseen and are then deleted. Lessons stay until you forget them, or until 300 newer ones replace them. Freeze diagnostics keep the five newest samples and the two newest step logs.
- Everything else stays until you delete it. This includes the activity log, which records the apps, window titles and web addresses you use while the app runs, the actions the app takes and any errors, and each source run's result, including the reader's own explanation when a run saves nothing.

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
