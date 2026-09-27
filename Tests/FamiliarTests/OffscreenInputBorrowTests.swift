import AppKit
import FamiliarContracts
import Testing
@testable import Familiar

@Suite(.serialized) @MainActor struct OffscreenInputBorrowTests {
    @Test func oneClickRestoresImmediateContextAndPointerBeforeReturning() async {
        let f = Fixture()
        let result = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(!result.isError)
        #expect(f.events == ["monitor", "activate", "move", "down", "up", "restore:12", "cursor", "unmonitor"])
        #expect(f.front == 12)
        #expect(f.positions == [CGPoint(x: 1740, y: 110)])
    }
    @Test func newerUserAppWinsAndPointerIsNotWarpedBack() async {
        let f = Fixture()
        f.afterPost = { event in
            if case .move = event { f.front = 99; f.callback?(.pointer); f.callback?(.app(99)) }
        }
        let result = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(!result.isError)
        #expect(f.front == 99)
        #expect(!f.events.contains("down"))
        #expect(!f.events.contains("restore:12"))
        #expect(!f.events.contains("cursor"))
    }
    @Test func cancellationAfterMouseDownStillReleasesAndRestores() async {
        let f = Fixture()
        f.afterPost = { if case .mouse(.leftMouseDown, _, _, _, _) = $0 { f.cancelled = true } }
        _ = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(f.events.contains("up"))
        #expect(f.events.contains("restore:12"))
        #expect(f.events.last == "unmonitor")
    }
    @Test func unicodeIsPreparedAndReturnedWithoutClipboardUse() async {
        let f = Fixture()
        _ = await f.run("type", ["text": "Hi 👋"])
        #expect(f.typed == "Hi 👋")
        #expect(f.events.contains("restore:12"))
    }
    @Test func typingRequiresConfirmedTextFocusAfterActivation() async {
        let f = Fixture(); f.typingAllowed = false
        _ = await f.run("type", ["text": "No input"])
        #expect(f.typed.isEmpty)
        #expect(f.events.contains("restore:12"))
    }
    @Test(arguments: ["left_mouse_down", "left_click_drag", "hold_key", "wait", "screenshot"])
    func unsupportedOperationsNeverActivate(name: String) async {
        let f = Fixture()
        _ = await f.run(name, [:])
        #expect(f.events.isEmpty)
    }
    @Test func unparkedAndStaleCoordinatesNeverActivate() async {
        let f = Fixture(); f.currentFrame.origin.x = 10
        _ = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(f.events.isEmpty)
        f.currentFrame = f.target.frameCG
        _ = await f.run("left_click", ["coordinate": [9999, 60]])
        #expect(f.events.isEmpty)
    }
    @Test func heldHumanInputAndFullScreenContextNeverActivate() async {
        let f = Fixture(); f.busy = true
        _ = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(!f.events.contains("activate"))
        f.busy = false; f.fullScreen = true
        _ = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(!f.events.contains("activate"))
    }
    @Test func activationTimeoutReturnsContextWithoutDispatch() async {
        let f = Fixture(); f.activationWorks = false
        _ = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(!f.events.contains("down"))
        #expect(f.time <= 2)
        #expect(f.events.last == "unmonitor")
    }
    @Test func spaceChangeStopsBeforeDispatchAndAvoidsFocusRestoration() async {
        let f = Fixture()
        f.afterActivate = { f.callback?(.space) }
        _ = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(!f.events.contains("down"))
        #expect(!f.events.contains("restore:12"))
    }
    @Test func humanTypingInterruptionReturnsHiddenFocusPromptly() async {
        let f = Fixture()
        f.afterPost = { if case .unicode(_, false) = $0 { f.callback?(.input) } }
        _ = await f.run("type", ["text": "abcdef"])
        #expect(f.typed == "a")
        #expect(f.front == 12)
    }
    @Test func keyAndTextSendCommandsAreNotInputPermissions() async {
        let f = Fixture()
        _ = await f.run("key", ["text": "Return"])
        _ = await f.run("key", ["text": "cmd+Tab"])
        _ = await f.run("type", ["text": "draft\n"])
        #expect(f.events.isEmpty)
    }
    @Test func deadlineStopsTextAndReturnsFocus() async {
        let f = Fixture()
        f.afterPost = { if case .unicode(_, false) = $0 { f.time += 0.4 } }
        _ = await f.run("type", ["text": "abcdefghijklmnop"])
        #expect(f.typed.count < 16)
        #expect(f.time < 2)
        #expect(f.front == 12)
    }
    @Test func sameAppContextDoesNotBorrowFocus() async {
        let f = Fixture(); f.front = f.target.pid
        _ = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(f.events.isEmpty)
    }
    @Test(arguments: ["Backspace", "Delete", "del", "option+Backspace", "cmd+a"])
    func editingKeysRequireConfirmedEditableFocus(combo: String) async {
        let f = Fixture(); f.typingAllowed = false
        let result = await f.run("key", ["text": combo])
        #expect(!result.isError)
        #expect(!f.events.contains("key"))
        #expect(f.front == 12)
    }
    @Test func repeatedDeleteStopsWhenEditableFocusIsLost() async {
        let f = Fixture()
        f.afterPost = { if case .key(_, false, _) = $0 { f.typingAllowed = false } }
        _ = await f.run("key", ["text": "Backspace", "repeat": 3])
        #expect(f.events.filter { $0 == "key" }.count == 2)
        #expect(f.front == 12)
    }
    @Test func missingHumanInputMonitorPreventsFocusBorrow() async {
        let f = Fixture(); f.monitorAvailable = false
        let result = await f.run("left_click", ["coordinate": [40, 60]])
        #expect(!result.isError)
        #expect(!f.events.contains("activate"))
        #expect(!f.events.contains("down"))
        #expect(f.front == 12)
    }
    @MainActor private final class Fixture {
        let target: TargetWindow
        var currentFrame: CGRect
        var time: TimeInterval = 0
        var front: pid_t = 12
        var busy = false, cancelled = false, fullScreen = false, typingAllowed = true, activationWorks = true, monitorAvailable = true
        var events: [String] = [], positions: [CGPoint] = [], typed = ""
        var callback: ((OffscreenInputBorrow.Interruption) -> Void)?
        var afterPost: ((OffscreenInputBorrow.Event) -> Void)?
        var afterActivate: (() -> Void)?
        init() {
            currentFrame = CGRect(x: 1700, y: 50, width: 800, height: 600)
            let ax = AXUIElementCreateApplication(-12345)
            target = TargetWindow(pid: -12345, bundleID: "test.borrow", appName: "Fixture", cgWindowID: 321,
                                  axApp: ax, axWindow: ax, toolkit: .electron, backingScale: 1, scWindow: nil,
                                  frameCG: currentFrame, title: "Fixture")
        }
        func run(_ name: String, _ input: [String: Any]) async -> FamiliarContracts.ToolResult {
            let a = OffscreenInputBorrow.Adapters(now: { self.time }, pause: { self.time += $0 },
                displayBounds: { _ in CGRect(x: 1600, y: 0, width: 1600, height: 1000) }, frame: { _ in self.currentFrame },
                context: { .init(pid: self.front, cursor: CGPoint(x: 100, y: 100), fullScreen: self.fullScreen) },
                frontPID: { self.front }, inputBusy: { self.busy },
                activate: { _ in self.events.append("activate"); if self.activationWorks { self.front = self.target.pid }; self.afterActivate?() },
                targetFocused: { _ in self.front == self.target.pid }, canType: { _ in self.typingAllowed },
                monitor: {
                    self.events.append("monitor")
                    guard self.monitorAvailable else { return nil }
                    self.callback = $0
                    return { self.events.append("unmonitor"); self.callback = nil }
                },
                post: { event in
                    switch event {
                    case .move(let p): self.events.append("move"); self.positions.append(p)
                    case .mouse(let type, _, _, _, _): self.events.append(type == .leftMouseDown ? "down" : "up")
                    case .unicode(let text, let down): if down { self.typed += text }
                    default: self.events.append("key")
                    }
                    self.afterPost?(event)
                }, restore: { context in self.events.append("restore:\(context.pid)"); self.front = context.pid; return true },
                restoreCursor: { _ in self.events.append("cursor") })
            return await OffscreenInputBorrow(adapters: a).perform(name, input, target: target, displayID: 7,
                space: .window(frameCG: target.frameCG, backingScale: 1, maxLongEdge: 800), cancelled: { self.cancelled })
        }
    }
}
