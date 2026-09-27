# Virtual background display experiment

The preserved baseline is `codex/background-task-screen` at `33dbd6c`.
The experiment builds on that baseline in `codex/virtual-background-display`.

## Question and decision

Can Familiar move an existing, signed-in application's window onto a virtual
display, keep capturing and controlling it with the current native controller,
and leave the user's physical workspace available?

Success means the window leaves the physical screen, the task preview remains
live, a representative browser task works without stealing the user's input, and
the original window returns on completion, stop, foreground handoff and quit.
Text selection, caret movement and emoji should be checked separately from
display placement. A virtual monitor provides rendering space; it does not
create a separate login session, application instance or independent focus.
Like an attached monitor, the virtual display extends the ordinary desktop: the
physical pointer can cross onto it. The experiment does not confine the user's
pointer or bypass the controller's same-app input restrictions.

If placement, capture and lifecycle work, retain this as an optional workspace
behind the existing task surface. App-specific input failures remain evidence
about the existing control backend. If placement or capture is unreliable,
disable the option and return to the preserved baseline; do not add another task
UI or parallel execution engine to compensate.

## Implementation boundary

- `FamiliarVirtualDisplayBridge` contains the private `CGVirtualDisplay` ABI and
  owns a single non-HiDPI display. It resolves classes at runtime and reports
  unavailable APIs without preventing the rest of Familiar from launching.
- `VirtualDisplayWorkspace` owns the temporary monitor and borrowed window
  positions. Its injected adapters allow lifecycle tests without moving real
  windows or configuring the test machine's displays.
- `ComputerController` requests placement only after the first work action.
  It requires fresh observation after movement, and finishes the workspace on
  stop/end. Foreground handoff returns the target to a physical display first.
- The existing task card, approvals, Accessibility actions and per-process
  keyboard input continue to do their current jobs. Settings defaults off.

The first version rejects full-screen windows and mirrored display arrangements.
It preserves existing display origins, checks the resulting arrangement, and
stops if the experiment cannot be established. There is no silent fallback that
starts operating a visible window after virtual placement fails.

## Verification record

On 2026-09-27, macOS 26.6.2 on Apple silicon:

- The signed release built successfully. The initial integrated test run passed
  187 tests in 31 suites, including 11 workspace lifecycle tests. Those tests use
  fake display/window adapters and do not configure real monitors.
- A live Chrome task used the existing local background-test fixture. The
  physical display remained at `(0, 0, 1710, 1107)`; a `1774 × 1203` virtual
  display appeared at `(1710, 0)`. The target moved from `(0, 34, 1710, 993)` to
  `(1742, 64, 1710, 993)` and returned to the exact original rectangle on finish.
  The extra display disappeared. The read-only observer recorded no pointer or
  foreground-app changes during the task (Familiar was already foreground).
- The task entered `Hello virtual display 👋`, edited `ABC` to `AxBC` using two
  Left-arrow presses followed by `x`, and pressed the local Set title button.
  It verified the fields by screenshot and waited ten seconds before finishing.
- That first trial also exposed a control problem: the model continued to type
  after relocation deferred its first focus click. Spaces scrolled the page
  before it recovered and completed the test. The relocation result must be an
  explicit unperformed-action response, and typing must reject an unconfirmed text
  target before sending events. The regression test reproduced a PID input
  attempt with no focused text field before the fix and passed afterward. Text
  entry now requires a text control in the target window and rechecks focus
  after capture before dispatch.
- A repeat trial found that marking relocation as a hard error tripped the CLI
  adapter's intentional stop-after-error latch. A process/MCP regression test
  reproduced the blocked screenshot/retry. Relocation and no-input focus
  refusals now remain recoverable; the test also verifies genuine hard errors
  still halt further computer actions. The full isolated suite passes 196 tests
  in 32 suites.
- The final live run passed on the signed build. The model initially attempted
  typing without repeating the deferred focus click; the guard refused it
  without sending any input, and the model recovered by observing and focusing
  the field. `Hello virtual display 👋`, `AxBC`, the Set title action, and
  `scrollY: 0` were independently verified through Chrome's Accessibility tree.
  The existing task card showed a live preview on the physical screen during
  the ten-second wait. Codex (`ChatGPT` in macOS process names) stayed foreground
  and the recorded pointer stayed at the same position throughout this run.
  Completion restored `(0, 34, 1710, 993)` and removed the extra display.
- The live Stop trial returned the target to its exact original rectangle and
  removed the virtual display during a 30-second wait. The pointer, foreground
  app and physical display geometry remained unchanged.

This evidence supports window placement and capture with the existing browser
controller. It does not establish reliable Discord typing, simultaneous use of
two windows of the same app, or compatibility across macOS versions.
Completion and Stop were tested live. A later Discord run also exercised
foreground-grant restoration, as recorded below. Other failure/cancellation
cases have automated lifecycle coverage. Graceful quit is wired to the same
controller cleanup, but was not tested mid-task in this run.

### Discord trial and foreground hand-back

The user's run at 21:28–21:29 UTC on 2026-09-27 moved Discord to the virtual
display and kept capturing it. Accessibility warm-up did not find a web area,
pressing the message composer produced no verified change, and the typing guard
refused input because it could not confirm a focused text field. The virtual
display therefore did not resolve Discord's background-input limitation.

At 21:29:10 the user granted foreground control. Familiar restored the Discord
window to its original `(0, 34, 1710, 997)` rectangle. About one second later the
input monitor revoked the grant; the user confirmed they continued using both
mouse and keyboard and switched away with ⌘Tab. This was an expected hand-back:
foreground grants temporarily require the user's physical input, even when the
task normally uses the virtual display. No successful typing was recorded.

The run also exposed a separate controller defect: revocation between tool
calls was checked as a generic interruption before its explanatory notice could
be delivered. The flag survived cleanup and could affect later requests. The
CLI adapter treated the resulting hard error as terminal. Recoverable hand-back
must abort any in-flight foreground action, deliver its explanation once, and
allow fresh background observation without carrying stale grant state into the
next request. A genuine Stop or request cancellation must still halt execution.

That recovery now has nine isolated controller tests. The initial test reproduced
the stuck hard error on consecutive tool calls; a second regression reproduced
acceptance of stale coordinates after hand-back. Both pass after separating the
recoverable grant notice from hard failures, clearing it on reset/end, and
invalidating the previous window observation on hand-back. Tests also cover
partly interrupted typing, key release, and real Stop/cancellation precedence.
The full suite passes 205 tests in 33 suites with an isolated `FAMILIAR_HOME`.
These tests dispatch no native input and do not send a Discord message.

## References

- [DeskPad private declarations](https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h)
- [Chromium virtual display implementation](https://github.com/chromium/chromium/blob/main/ui/display/mac/test/virtual_display_util_mac.mm)
- [VirtualDisplayKit lifecycle](https://github.com/xocialize/VirtualDisplayKit/blob/main/Sources/VirtualDisplayKit/Core/VirtualDisplay.swift)
- CoreGraphics SDK `CGDisplayConfiguration.h`: display layout normalization,
  origin configuration and application-scoped configuration lifetime.
