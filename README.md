# Familiar

**A little help with the work on your Mac.**

Familiar is a small desktop companion you can talk to and teach by showing.
Ask about something on your screen, show it where to check for updates, and turn
what it finds into cards you can review, discuss, or ask it to help with.

[Download Familiar for Mac](https://github.com/isought/Familiar/releases/latest) · [Share feedback](https://github.com/isought/Familiar/issues)

## Meet your Familiar

- **Ask about your screen.** Point at something confusing, or open chat and ask a question.
- **Show it how.** Use **Watch Me** to demonstrate where information lives. Add context in your own words, such as “Only check unread email from the last two days.”
- **Keep track of unfinished work.** Findings become cards that carry forward. Open a card to discuss it, add context, or decide what to do next.
- **Ask for help doing it.** Hand an action to Familiar and follow its progress in the task window. You can stop it at any time.

## Get started

You’ll need a Mac with Apple silicon (M1 or later), macOS 14 Sonoma or later, and a Claude connection.

1. **Install Familiar.** Download the `.dmg`, open it, and drag Familiar into Applications.
2. **Allow access when prompted.** Accessibility lets Familiar understand and interact with app controls. Screen Recording lets it see the screen when helping you. Quit and reopen Familiar after granting access.
3. **Connect Claude.** Right-click Familiar, open **Settings**, and enter your Anthropic API key under **Connection → API key**, then **Save**. This is still an early setup requirement; the key is separate from a regular Claude chat login.

Click Familiar in the Dock to open chat. You can also double-click the little note on your desktop.

## Try it with one small task

Start with a view you already use, such as your email inbox.

1. Open the small folder on your desktop, then choose **Manage sources → Teach a source with Watch Me**.
2. Show Familiar the app, account, and view you want it to check. Choose **Stop Watching** when you’re done.
3. Give it a short description, such as “Check unread email.” Add optional context about what to include, skip, or stop at.
4. Review what Familiar learned and choose **Keep it**. Confirm any source details it asks you to review.
5. In **Settings**, enable **Allow Familiar to control the mouse and keyboard when asked** so it can navigate the app you showed it. Then choose **Run all sources** to check for fresh information.

Click a completed run to read its findings. **Manage sources** is where you change the instructions; **Run history** is where you find earlier results.

## Pick up where you left off

Cards stay with you across days. Familiar tries to update the same card when it sees the same item again, and can update its status when it finds new evidence. An item disappearing from a scan doesn’t mean it is finished.

Open a card and choose **Discuss or adjust** to ask a question or explain what matters to you. You can handle it yourself, mark it handled, or ask Familiar to take on its proposed action. Discussing a card doesn’t start the action.

## Your information, your control

Your saved sources, cards, and run history are stored on your Mac. AI features send the relevant information—including screen text or images when needed—to your configured Claude connection. **Watch Me** records the demonstration you start.

Mouse and keyboard control is off until you enable it in Settings. Tasks show their progress and any approval requests in the task window; **Stop** ends the work. Checking a tracked email conversation may open it and mark it as read.

To quit, choose **Quit Familiar** or press **⌘Q** while Familiar is active. If it stops responding, use macOS **Force Quit** (**⌥⌘Esc**).

## Still growing

Familiar is an early version. You start source checks yourself; scheduled morning checks aren’t available yet. It works through the apps you show it, and some screens or controls aren’t supported. Card matching and AI interpretations can make mistakes, so review important findings and actions.

[Feedback and bug reports](https://github.com/isought/Familiar/issues) help us decide what to improve next.

---

[Developer guide](docs/development/guide.md) · [Architecture](docs/architecture/task-execution.md) · [Apache 2.0 license](LICENSE)
