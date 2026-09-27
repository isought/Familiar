import AppKit
import FamiliarContracts

/// A single prepared native action, with input returned before the model sees its result.
@MainActor final class OffscreenInputBorrow {
    struct Context {
        var pid: pid_t
        var window: AXUIElement?
        var cursor: CGPoint
        var fullScreen = false
    }
    enum Interruption { case input, pointer, app(pid_t), space }
    enum Event {
        case move(CGPoint)
        case mouse(CGEventType, CGPoint, CGMouseButton, CGEventFlags, Int)
        case key(CGKeyCode, Bool, CGEventFlags)
        case unicode(String, Bool)
        case scroll(CGPoint, Int32, Int32)
    }
    struct Adapters {
        var now: () -> TimeInterval
        var pause: (TimeInterval) async -> Void
        var displayBounds: (CGDirectDisplayID) -> CGRect?
        var frame: (TargetWindow) -> CGRect?
        var context: () -> Context?
        var frontPID: () -> pid_t?
        var inputBusy: () -> Bool
        var activate: (TargetWindow) -> Void
        var targetFocused: (TargetWindow) -> Bool
        var canType: (TargetWindow) -> Bool
        var monitor: (@escaping (Interruption) -> Void) -> (() -> Void)?
        var post: (Event) -> Void
        var restore: (Context) async -> Bool
        var restoreCursor: (CGPoint) -> Void
        var inputRefusal: ((TargetWindow) -> String?)? = nil
    }
    private let adapters: Adapters
    private var running = false
    init() { adapters = Self.liveAdapters() }
    init(adapters: Adapters) { self.adapters = adapters }

    private struct Packet {
        var down: Event
        var release: Event?
        var delay: TimeInterval = 0.004
        var requiresEditableFocus = false
    }

    func perform(_ name: String, _ input: [String: Any], target: TargetWindow, displayID: CGDirectDisplayID,
                 space: CaptureSpace, cancelled: @escaping () -> Bool) async -> ToolResult {
        guard !running else { return refusal("Another input operation is still returning control.") }
        guard !cancelled(), !Task.isCancelled else { return refusal("The operation was cancelled.") }
        let packets: [Packet]
        do { packets = try Self.prepare(name, input, space: space) }
        catch { return refusal(error.localizedDescription) }
        guard parked(target, displayID: displayID, space: space) else {
            return refusal("The target is not fully on the separate display, or its position changed. Take a fresh window screenshot.")
        }
        running = true
        defer { running = false }
        // The user retains focus during this wait. Never wait for inactivity after borrowing it.
        let quietDeadline = adapters.now() + 0.5
        while adapters.inputBusy(), adapters.now() < quietDeadline, !cancelled(), !Task.isCancelled {
            await adapters.pause(0.025)
        }
        guard !adapters.inputBusy(), !cancelled(), !Task.isCancelled else {
            return refusal("Your input is busy. No input was borrowed; try again after a brief pause.")
        }
        guard let previous = adapters.context(), previous.pid != target.pid, !previous.fullScreen else {
            return refusal("The current app is the task app, full screen, or cannot be restored reliably.")
        }
        guard parked(target, displayID: displayID, space: space) else { return refusal("The task window moved before the operation.") }

        var interruption: String?
        var pointerMoved = false
        var spaceChanged = false
        var dispatched = false
        var cursorUsed = false
        let started = adapters.now()
        let removeMonitor = adapters.monitor { event in
            switch event {
            case .input: interruption = "you used the keyboard or mouse"
            case .pointer: pointerMoved = true; interruption = "you moved the mouse"
            case .app(let pid):
                if pid != target.pid { interruption = "you switched apps" }
            case .space: spaceChanged = true; interruption = "the active desktop or display layout changed"
            }
        }
        guard let removeMonitor else {
            return refusal("Human-input monitoring is unavailable, so no input was borrowed.")
        }
        defer { removeMonitor() }
        func interrupted() -> Bool {
            interruption != nil || cancelled() || Task.isCancelled || adapters.now() - started >= 1.5
        }
        guard !interrupted() else { return refusal("The operation was interrupted before input was borrowed.") }
        adapters.activate(target)
        let activationDeadline = started + 0.45
        while !interrupted(), adapters.now() < activationDeadline,
              !(adapters.frontPID() == target.pid && adapters.targetFocused(target)) {
            await adapters.pause(0.015)
        }
        var failure: String?
        if interrupted() { failure = interruption ?? "the operation was cancelled or timed out" }
        else if adapters.frontPID() != target.pid || !adapters.targetFocused(target) {
            failure = "the parked window did not receive input focus"
        } else if !parked(target, displayID: displayID, space: space) {
            failure = "the window moved during activation"
        } else if let reason = adapters.inputRefusal?(target) {
            failure = reason
        } else if packets.contains(where: { $0.requiresEditableFocus }), !adapters.canType(target) {
            failure = "no editable text field in the task window has confirmed focus"
        }
        if failure == nil {
            for packet in packets {
                guard !interrupted(), adapters.frontPID() == target.pid,
                      adapters.targetFocused(target), parked(target, displayID: displayID, space: space) else {
                    failure = interruption ?? "focus, window placement, or the input time limit changed"
                    break
                }
                if packet.requiresEditableFocus, !adapters.canType(target) {
                    failure = "the text field lost focus"
                    break
                }
                if let reason = adapters.inputRefusal?(target) { failure = reason; break }
                guard !interrupted(), adapters.frontPID() == target.pid else {
                    failure = interruption ?? "the operation was cancelled or timed out"; break
                }
                if case .move = packet.down { cursorUsed = true }
                adapters.post(packet.down)
                dispatched = true
                // A release is unconditional: cancelling between down/up must not leave a key or button held.
                if let release = packet.release { adapters.post(release) }
                await adapters.pause(packet.delay)
            }
        }
        if failure == nil, interrupted() { failure = interruption ?? "the operation was cancelled or timed out" }
        var focusRestored = adapters.frontPID() == previous.pid
        // A new app/Space is the user's current choice. Never switch them back to a stale snapshot.
        // Raw input while our target is still active instead needs a prompt return of hidden keyboard focus.
        if !spaceChanged, adapters.frontPID() == target.pid {
            focusRestored = await adapters.restore(previous)
        }
        if cursorUsed, !pointerMoved, !spaceChanged { adapters.restoreCursor(previous.cursor) }
        Log.info("control: offscreen borrow action=\(name) duration=\(String(format: "%.3f", adapters.now() - started)) restored=\(focusRestored) interrupted=\(failure != nil)")
        if let failure {
            return .text(dispatched
                ? "Input returned: \(failure). The prepared operation may have partly run. Inspect a fresh window screenshot before continuing; do not automatically repeat it."
                : "Action not performed: \(failure). No action input was sent. The task window remains on its separate display.")
        }
        if !focusRestored {
            return .text("The prepared input was sent, but the previous focus could not be confirmed after returning control. Inspect the task window before continuing; do not automatically repeat the action.")
        }
        return .text("Prepared input completed and your input was returned. The task window stayed on its separate display. Take a fresh window screenshot to verify the result.")
    }

    private func parked(_ target: TargetWindow, displayID: CGDirectDisplayID, space: CaptureSpace) -> Bool {
        guard let bounds = adapters.displayBounds(displayID), let frame = adapters.frame(target),
              frame.width > 0, frame.height > 0, bounds.contains(frame) else { return false }
        let old = space.frameCG
        return abs(frame.minX - old.minX) < 0.5 && abs(frame.minY - old.minY) < 0.5
            && abs(frame.width - old.width) < 0.5 && abs(frame.height - old.height) < 0.5
    }

    private func refusal(_ message: String) -> ToolResult { .text("Action not performed: \(message)") }
    private struct Invalid: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }

    private static func prepare(_ name: String, _ input: [String: Any], space: CaptureSpace) throws -> [Packet] {
        func point() throws -> CGPoint {
            guard let xy = input["coordinate"] as? [NSNumber], xy.count == 2,
                  xy[0].doubleValue.isFinite, xy[1].doubleValue.isFinite, space.pxPerPt > 0 else {
                throw Invalid("This operation needs explicit coordinates from the latest window screenshot.")
            }
            let p = space.cg(fromModel: xy[0].doubleValue, xy[1].doubleValue)
            guard space.contains(cg: p) else { throw Invalid("The coordinates are outside the task window.") }
            return p
        }
        switch name {
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let p = try point()
            guard (input["text"] as? String ?? "").isEmpty else { throw Invalid("Modified clicks are not supported by a brief input loan yet.") }
            let button: CGMouseButton = name == "right_click" ? .right : name == "middle_click" ? .center : .left
            let down: CGEventType = button == .right ? .rightMouseDown : button == .center ? .otherMouseDown : .leftMouseDown
            let up: CGEventType = button == .right ? .rightMouseUp : button == .center ? .otherMouseUp : .leftMouseUp
            let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : 1
            return [Packet(down: .move(p), delay: 0.01)] + (1...count).map {
                Packet(down: .mouse(down, p, button, [], $0), release: .mouse(up, p, button, [], $0), delay: 0.025)
            }
        case "type":
            guard let text = input["text"] as? String, !text.isEmpty, text.count <= 256,
                  text.utf16.count <= 2048 else { throw Invalid("A brief input loan accepts 1–256 characters at a time.") }
            guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw Invalid("Type only draft text. Return, Tab, and other control characters need a separate approved action.")
            }
            return text.map { Packet(down: .unicode(String($0), true), release: .unicode(String($0), false), requiresEditableFocus: true) }
        case "key":
            guard let combo = input["text"] as? String, let (code, flags) = ComputerController.parseCombo(combo) else {
                throw Invalid("The key combination is invalid.")
            }
            let keyName = combo.lowercased().split(separator: "+").last?.trimmingCharacters(in: .whitespaces) ?? ""
            let navigation: Set<String> = ["left", "right", "up", "down", "home", "end", "page_up", "page_down", "pageup", "pagedown", "tab", "backspace", "delete", "del", "escape", "esc"]
            let selectAll = keyName == "a" && flags == .maskCommand
            guard selectAll || (navigation.contains(keyName) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)) else {
                throw Invalid("This brief input loan supports text editing/navigation and Command-A. Sending, submitting, and app-switching shortcuts need another action path.")
            }
            let repetitions = (input["repeat"] as? NSNumber)?.intValue ?? 1
            guard (1...20).contains(repetitions) else { throw Invalid("Repeat must be between 1 and 20.") }
            let requiresEditableFocus = selectAll || ["backspace", "delete", "del"].contains(keyName)
            return (0..<repetitions).map { _ in
                Packet(down: .key(code, true, flags), release: .key(code, false, flags), delay: 0.012, requiresEditableFocus: requiresEditableFocus)
            }
        case "scroll":
            let p = try point()
            let amount = (input["scroll_amount"] as? NSNumber)?.intValue ?? 3
            guard (1...20).contains(amount) else { throw Invalid("Scroll amount must be between 1 and 20.") }
            let n = Int32(amount * 3)
            let dir = input["scroll_direction"] as? String ?? "down"
            guard ["up", "down", "left", "right"].contains(dir) else { throw Invalid("Invalid scroll direction.") }
            return [Packet(down: .move(p), delay: 0.01), Packet(down: .scroll(p, dir == "up" ? n : dir == "down" ? -n : 0, dir == "left" ? n : dir == "right" ? -n : 0))]
        default:
            throw Invalid("A brief input loan supports clicks, draft text, editing keys, and scrolling. It cannot hold buttons across calls, drag, wait, or take screenshots; the task stays offscreen.")
        }
    }

    private static func liveAdapters() -> Adapters {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = ComputerController.tag
        return Adapters(now: { ProcessInfo.processInfo.systemUptime }, pause: { seconds in
            // Cleanup must still get a run-loop turn when the parent task is cancelled.
            await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { c.resume() } }
        }, displayBounds: { id in
            guard id == VirtualDisplayWorkspace.activeDisplayID, CGDisplayIsOnline(id) != 0 else { return nil }
            return CGDisplayBounds(id)
        }, frame: { target in
            guard axBool(target.axWindow, kAXMinimizedAttribute) != true,
                  axBool(target.axWindow, "AXFullScreen") != true,
                  let p = axPoint(target.axWindow), let size = axSize(target.axWindow) else { return nil }
            return CGRect(origin: p, size: size)
        }, context: {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let window = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) else { return nil }
            return Context(pid: app.processIdentifier, window: window,
                           cursor: CGEvent(source: nil)?.location ?? CaptureSpace.cg(NSEvent.mouseLocation),
                           fullScreen: axBool(window, "AXFullScreen") == true)
        }, frontPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier }, inputBusy: {
            let flags = CGEventSource.flagsState(.hidSystemState)
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            return NSEvent.pressedMouseButtons != 0 || !flags.intersection(modifiers).isEmpty
                || (0..<128).contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
                || CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 0.15
                || CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved) < 0.1
        }, activate: { target in
            AXUIElementSetAttributeValue(target.axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(target.axApp, kAXFocusedWindowAttribute as CFString, target.axWindow)
            // AXFrontmost uses the user's explicit accessibility/input grant. There is no window move or all-windows activation.
            AXUIElementSetAttributeValue(target.axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(target.axWindow, kAXRaiseAction as CFString)
        }, targetFocused: { target in
            guard let focused = AX.element(target.axApp, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(focused, target.axWindow)
        }, canType: { target in
            guard let element = AX.element(target.axApp, kAXFocusedUIElementAttribute) else { return false }
            let role = AX.string(element, kAXRoleAttribute)
            guard role != "AXSecureTextField", AX.string(element, kAXSubroleAttribute) != "AXSecureTextField" else { return false }
            guard let role, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) else { return false }
            var cursor: AXUIElement? = element
            for _ in 0..<20 {
                guard let current = cursor else { return false }
                if CFEqual(current, target.axWindow) { return true }
                if let window = AX.element(current, kAXWindowAttribute), CFEqual(window, target.axWindow) { return true }
                cursor = AX.element(current, kAXParentAttribute)
            }
            return false
        }, monitor: { callback in
            let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                               .otherMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                               .otherMouseDown, .otherMouseUp, .scrollWheel]
            let handler: (NSEvent) -> Void = { event in
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ComputerController.tag { return }
                let pointer = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
                callback(pointer ? .pointer : .input)
            }
            // A local-only monitor cannot see input delivered to the borrowed target application.
            guard let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) else { return nil }
            let local = NSEvent.addLocalMonitorForEvents(matching: mask) { handler($0); return $0 }
            let center = NSWorkspace.shared.notificationCenter
            let activation = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if let pid { callback(.app(pid)) } }
            }
            let spaces = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { callback(.space) }
            }
            let screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { callback(.space) }
            }
            return {
                NSEvent.removeMonitor(global); if let local { NSEvent.removeMonitor(local) }
                center.removeObserver(activation); center.removeObserver(spaces); NotificationCenter.default.removeObserver(screens)
            }
        }, post: { item in
            let event: CGEvent?
            switch item {
            case .move(let p): event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
            case .mouse(let type, let p, let button, let flags, let count):
                event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                event?.flags = flags; event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            case .key(let code, let down, let flags):
                event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down); event?.flags = flags
            case .unicode(let text, let down):
                event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                var units = Array(text.utf16)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event?.flags = []
            case .scroll(let p, let vertical, let horizontal):
                event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
                event?.location = p; event?.flags = []
            }
            event?.setIntegerValueField(.eventSourceUserData, value: ComputerController.tag)
            event?.post(tap: .cghidEventTap)
        }, restore: { previous in
            guard let app = NSRunningApplication(processIdentifier: previous.pid), !app.isTerminated else { return false }
            let axApp = AXUIElementCreateApplication(previous.pid)
            if let window = previous.window {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
            }
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if let window = previous.window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
            // One activation request only: a user's newer app choice always wins after this point.
            await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { c.resume() } }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.pid else { return false }
            guard let saved = previous.window, let focused = AX.element(axApp, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(saved, focused)
        }, restoreCursor: { _ = CGWarpMouseCursorPosition($0) }, inputRefusal: { target in
            let path = TargetPolicy.editorBundles.contains(target.bundleID) ? target.focusedPath() : []
            if let reason = TargetPolicy.refusal(bundleID: target.bundleID, appName: target.appName, focusedPath: path) { return reason }
            if let element = AX.element(target.axApp, kAXFocusedUIElementAttribute),
               AX.string(element, kAXRoleAttribute) == "AXSecureTextField" || AX.string(element, kAXSubroleAttribute) == "AXSecureTextField" {
                return "the focused field contains a password"
            }
            return nil
        })
    }

    private static func axBool(_ element: AXUIElement, _ key: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
    private static func axPoint(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?, result = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgPoint, &result) else { return nil }
        return result
    }
    private static func axSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?, result = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgSize, &result) else { return nil }
        return result
    }
}
