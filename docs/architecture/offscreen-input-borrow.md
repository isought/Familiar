# Offscreen input borrowing

Branch: `codex/offscreen-input-borrow`, based on the preserved virtual-display
version at `338c355` on `codex/virtual-background-display`.

## Question

Can a short, prepared native input action work on the virtual display and return
the user's immediately preceding focus and pointer, without bringing the task
window onto the physical screen or holding input while the model thinks?

The evidence needed is a live draft-only test: window/display geometry stays
parked throughout each action, the user's visible workspace does not switch,
the intended draft receives the exact text and emoji, and focus/pointer return
after success and interruption. This determines whether brief input borrowing
can replace the old desktop takeover for virtual-display tasks. Automated
tests establish controller and cleanup behavior; they cannot establish the
macOS/Electron behavior on their own.

## Implementation

The existing separate-display setting selects this behavior. There is no second
task engine or separate demo app.

- `ask_for_the_mouse` first verifies that the task window is parked. Approval
  grants permission for short input actions; it does not activate an app,
  move a window, change screenshot coordinates, hide the task panel, or show
  the desktop-control overlay. Permission expires after a minute.
- Screenshots, search, zoom, waits and the logical cursor remain on the task
  window. The user retains input between tool calls.
- `OffscreenInputBorrow` validates one prepared action, waits briefly for quiet
  input, records the current app/focused window/pointer, activates the parked
  target, sends a bounded sequence, and returns input before the tool returns.
  There are no screenshots, approval dialogs or model/network waits inside
  that interval.
- Native events are tagged. Human input, focus loss, a Space/display change,
  cancellation, or the dispatch time limit interrupts the sequence. Key/button
  releases still run. Cleanup respects a newer app choice or pointer movement.
- Stop/end defers window restoration and display removal until the native
  borrower has returned input. Quitting waits for that cleanup before terminating
  the app. Old screenshots and element IDs are invalidated after an input action.
- Nonvirtual sessions retain the explicit desktop-control option, whose prompt
  now names screen access. A virtual-display failure never silently selects it.

## Scope and limits

This first version supports short clicks, scrolling, single-line draft text
(up to 256 characters), and a limited set of editing/navigation keys. It
rejects split mouse-down/up actions, drags, long holds, app-switching shortcuts,
and raw Enter-to-send. Input borrowing does not approve a consequential action;
known guarded controls continue through the existing action-approval path.

`send_message` now supports Return-based chat composers through one-action
approval. It shows the recipient, observed window/composer context, and exact
readable draft, then revalidates window, composer identity, context and text
before dispatching one Return pair. Separate-display input permission must
still be active. The native runner rechecks after activation and immediately
before dispatch. Declined, stale, unreadable or cancelled approvals send no
input. Delivery must be checked afterward; uncertain sends are never retried
automatically. Recipient matching uses observed labels, not a service-level
recipient ID, so the visible context remains part of the user review.

It rejects full-screen user contexts, borrowing while the user is already in
the target app, changed target geometry, and text entry whose field focus
cannot be verified. Discord's incomplete accessibility tree may still prevent
typing even if a native click succeeds.

The dispatch budget is 1.5 seconds; native Accessibility calls and restoration
add latency that must be measured. This is shared input borrowed briefly, not a
second keyboard. The event monitors observe human input after delivery, so they
can abort subsequent input but cannot guarantee that an overlapping physical
keystroke never reaches the temporarily focused app.

## Verification

Regression tests first reproduced the old physical-window restoration, whole-
display coordinates and desktop presentation after approval. Controller tests
cover permission without takeover, observation without borrowing, logical
cursor coordinates, stale-coordinate refusal, initial parking, and Stop/end
cleanup ordering, including graceful app termination. Runner tests use injected
native adapters and never move a real window or send an OS input event.

On 2026-09-27, the full suite passed: **228 tests in 35 suites**, run with an
isolated `FAMILIAR_HOME`. `scripts/build.sh` produced the signed release app at
`build/Familiar.app`; `codesign --verify --deep --strict` passed.

Initial live verification was pending: the Mac was locked when the computer-use tool
attempted to begin the local fixture test, including a retry after the release
build. The running app has not been restarted into this build. No Discord
messages were sent as part of that implementation.

### Approved Return sending

The follow-up adds `send_message`, exact-draft/context approval, and one native
Return pair. The full suite passes **246 tests in 36 suites**, including denied
and changed approvals, changed focus during native preparation, input permission
revocation during approval, and cancellation immediately after Return key-down.

The local `Tests/Fixtures/message-send-test.html` has a labelled Avery composer,
no Send button, and an in-page message counter. It has no network behavior.
The live task card displayed the exact draft `Hello Avery 👋 — one approved
Return.` and requested separate input and send approvals. The first dispatch
attempt refused because Chrome was the active work app; the draft remained
unchanged and the counter stayed at zero. A successful native dispatch test is
pending switching the work app away from Chrome. No real messages were sent.
