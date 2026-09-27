import AppKit

/// Input delivered to one process with public API: keys and stamped scroll. Never touches the HID tap, so the
/// human keeps the real cursor and keyboard while a background session runs.
enum PidEvents {
    /// A private-state source so the target sees our events as coming from a device of their own; tagged so the
    /// conflict monitor and the foreground lane's monitors can tell them apart from the human's.
    static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = ComputerController.tag
        return s
    }()

    static func post(_ e: CGEvent?, to pid: pid_t) {
        guard let e else { return }
        e.setIntegerValueField(.eventSourceUserData, value: ComputerController.tag)
        e.postToPid(pid)
    }

    static func press(pid: pid_t, code: CGKeyCode, flags: CGEventFlags) {
        let d = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        d?.flags = flags
        post(d, to: pid)
        usleep(20_000)
        let u = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        u?.flags = flags
        post(u, to: pid)
    }

    /// Types unicode text char by char (keyboardSetUnicodeString on virtualKey 0), 12 ms apart; "\n" → Return,
    /// "\t" → Tab. Stops early when `cancelled()` is true.
    static func type(pid: pid_t, text: String, cancelled: () -> Bool) async {
        for ch in text {
            if cancelled() { return }
            switch ch {
            case "\n", "\r\n", "\r": press(pid: pid, code: 36, flags: [])
            case "\t": press(pid: pid, code: 48, flags: [])
            default:
                // Both halves carry the string: AppKit reads `characters` off whichever one it is looking at.
                var units = Array(String(ch).utf16)
                let d = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                d?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                post(d, to: pid)
                let u = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                u?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                post(u, to: pid)
            }
            await sleep(ms: 12)
        }
    }

    static func holdKey(pid: pid_t, code: CGKeyCode, flags: CGEventFlags, seconds: Double) async {
        let d = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        d?.flags = flags
        post(d, to: pid)
        await sleep(ms: Int(max(0, seconds) * 1000))
        let u = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        u?.flags = flags
        post(u, to: pid)
    }

    /// Stamp a mouse/scroll event so AppKit routes it to the window: int field 51 = windowID, double fields 146/147 =
    /// window-local point (top-left origin, points). Also sets the event's global location. Without the stamp a
    /// posted mouse event is matched against the window under the real cursor and dropped.
    static func stamp(_ e: CGEvent, windowID: CGWindowID, globalCG: CGPoint, local: CGPoint) {
        e.location = globalCG
        e.setIntegerValueField(field(51), value: Int64(windowID))
        e.setDoubleValueField(field(146), value: local.x)
        e.setDoubleValueField(field(147), value: local.y)
    }

    /// Scroll `lines` (positive = up, like CGEvent scrollWheelEvent2 wheel1) at a point; posts a stamped mouseMoved
    /// first so the view under the point is the one that scrolls, then the stamped scroll.
    static func scroll(pid: pid_t, windowID: CGWindowID, globalCG: CGPoint, local: CGPoint, vertical: Int32, horizontal: Int32, flags: CGEventFlags) {
        if let mv = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: globalCG, mouseButton: .left) {
            stamp(mv, windowID: windowID, globalCG: globalCG, local: local)
            post(mv, to: pid)
            usleep(20_000)
        }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
        e.flags = flags
        stamp(e, windowID: windowID, globalCG: globalCG, local: local)
        post(e, to: pid)
    }

    /// Make the target window main so posted keys have a first responder: AX set kAXMinimized=false (if minimized)
    /// then kAXMain=true; returns the resulting kAXMain value. AX return codes are meaningless, so the state is read back.
    static func ensureMain(_ target: TargetWindow) -> Bool {
        let w = target.axWindow
        let wasMinimized = target.isMinimized
        if wasMinimized { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        if axBool(w, kAXMainAttribute) == true { return true }
        guard wasMinimized else { return false }
        // The deminiaturize animation runs ~250 ms; the window cannot become main until it lands.
        usleep(300_000)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        return axBool(w, kAXMainAttribute) == true
    }

    // MARK: private

    /// Fields 51/146/147 are not in the public enum; the initializer accepts any raw value for imported C enums.
    private static func field(_ raw: UInt32) -> CGEventField {
        CGEventField(rawValue: raw) ?? unsafeBitCast(raw, to: CGEventField.self)
    }

    private static func axBool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        return (v as? Bool) ?? (v as? NSNumber)?.boolValue
    }

    private static func sleep(ms: Int) async {
        guard ms > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
}
