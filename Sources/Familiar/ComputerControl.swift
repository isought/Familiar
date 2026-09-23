import AppKit
import Carbon.HIToolbox
import QuartzCore

/// Drives the mouse and keyboard for Claude's computer toolset. Coordinates from the model are screenshot pixels.
@MainActor
final class ComputerController {
    static let toolsetDefinition: [String: Any] = ["type": "computer_toolset_20260801"]
    static let findDefinition: [String: Any] = [
        "name": "find_on_screen",
        "description": "Find UI elements in the frontmost window by their visible text (button labels, field names, menu items, link text) via Accessibility. Returns each match's role and its center in screenshot pixel coordinates, which you can click directly. Use it before guessing coordinates from pixels; falls back to nothing for canvas-like content.",
        "input_schema": ["type": "object", "properties": ["query": ["type": "string", "description": "Text to look for, case-insensitive substring"]], "required": ["query"]],
    ]
    static let tag: Int64 = 0x5344_4B31   // marks our synthetic events

    var maxLongEdge = 1568
    var hudEnabled = true
    var onCaption: ((String) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    private(set) var stopped = false
    private(set) var active = false
    private var stopReason = ""
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var lastRaw: RawCapture?
    private var expectedCursor: NSPoint?
    private var huds: [NSPanel] = []
    private var captions: [CATextLayer] = []
    private var monitors: [Any] = []
    private var beganAt = Date.distantPast
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.userData = ComputerController.tag
        return s
    }()

    // MARK: session

    func reset() { stopped = false; stopReason = "" }

    func begin() {
        guard !active else { return }
        active = true
        stopped = false
        beganAt = Date()
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        expectedCursor = nil
        if hudEnabled { showHUD() }
        installMonitors()
        onBegin?()
        Log.info("control: began on \(Int(screen.frame.width))x\(Int(screen.frame.height))pt, scale \(String(format: "%.3f", scale))")
    }

    func end() {
        guard active else { return }
        active = false
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for p in huds { p.orderOut(nil) }
        huds.removeAll()
        captions.removeAll()
        onEnd?()
        Log.info("control: ended\(stopped ? " (stopped: \(stopReason))" : "")")
    }

    func stop(reason: String) {
        guard active, !stopped else { return }
        stopped = true
        stopReason = reason
        caption("Stopped (\(reason))")
        Log.info("control: stop requested: \(reason)")
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard let self, self.active, !self.stopped else { return }
            if let cg = e.cgEvent, cg.getIntegerValueField(.eventSourceUserData) == Self.tag { return }   // ours
            if Date().timeIntervalSince(self.beganAt) < 0.5 { return }                                     // settle time
            switch e.type {
            case .keyDown:
                self.stop(reason: e.keyCode == 53 ? "Escape" : "keyboard")
            case .mouseMoved, .leftMouseDragged:
                let here = NSEvent.mouseLocation
                if let exp = self.expectedCursor, hypot(here.x - exp.x, here.y - exp.y) < 6 { return }
                if self.expectedCursor == nil { return }   // we haven't moved the mouse yet; ignore drift
                self.stop(reason: "mouse moved")
            default:
                self.stop(reason: "mouse")
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { e in handler(e); return e }) { monitors.append(l) }
    }

    // MARK: geometry

    /// Screenshot pixels per screen point, for the current screen at the configured downscale.
    private var scale: CGFloat {
        let ppp = screen.backingScaleFactor
        let wPx = screen.frame.width * ppp, hPx = screen.frame.height * ppp
        let f = min(1, CGFloat(maxLongEdge) / max(wPx, hPx))
        return CGFloat(Int(wPx * f)) / screen.frame.width
    }

    private func cgPoint(_ coord: Any?) -> CGPoint? {
        guard let arr = coord as? [Any], arr.count == 2,
              let x = (arr[0] as? NSNumber)?.doubleValue, let y = (arr[1] as? NSNumber)?.doubleValue else { return nil }
        let s = scale
        let primaryMaxY = NSScreen.screens[0].frame.maxY
        let topCG = primaryMaxY - screen.frame.maxY
        return CGPoint(x: screen.frame.minX + x / s, y: topCG + y / s)
    }

    private func modelPoint(fromAppKit p: NSPoint) -> (Int, Int) {
        let s = scale
        return (Int((p.x - screen.frame.minX) * s), Int((screen.frame.maxY - p.y) * s))
    }

    private func appKit(_ cg: CGPoint) -> NSPoint {
        NSPoint(x: cg.x, y: NSScreen.screens[0].frame.maxY - cg.y)
    }

    // MARK: actions

    func perform(_ name: String, _ input: [String: Any]) async -> ToolResult {
        if !active { begin() }
        if stopped { return .text("Stopped by the user.", isError: true) }
        switch name {
        case "screenshot":
            caption("Looking at the screen")
            return await screenshot()
        case "zoom":
            caption("Zooming in")
            return await zoom(input["region"])
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            guard let p = input["coordinate"] == nil ? currentCG() : cgPoint(input["coordinate"]) else { return .text("Invalid coordinate.", isError: true) }
            let (x, y) = modelPoint(fromAppKit: appKit(p))
            caption("\(name.replacingOccurrences(of: "_", with: " ").capitalized) at \(x), \(y)")
            await glide(to: p)
            let flags = Self.flags(input["text"] as? String)
            switch name {
            case "right_click": click(p, button: .right, down: .rightMouseDown, up: .rightMouseUp, count: 1, flags: flags)
            case "middle_click": click(p, button: .center, down: .otherMouseDown, up: .otherMouseUp, count: 1, flags: flags)
            case "double_click": click(p, button: .left, down: .leftMouseDown, up: .leftMouseUp, count: 2, flags: flags)
            case "triple_click": click(p, button: .left, down: .leftMouseDown, up: .leftMouseUp, count: 3, flags: flags)
            default: click(p, button: .left, down: .leftMouseDown, up: .leftMouseUp, count: 1, flags: flags)
            }
            await sleep(0.15)
            return .text("OK")
        case "mouse_move":
            guard let p = cgPoint(input["coordinate"]) else { return .text("Invalid coordinate.", isError: true) }
            caption("Moving the mouse")
            await glide(to: p)
            return .text("OK")
        case "left_click_drag":
            guard let a = cgPoint(input["start_coordinate"]), let b = cgPoint(input["coordinate"]) else { return .text("Invalid coordinates.", isError: true) }
            caption("Dragging")
            await glide(to: a)
            post(mouse(.leftMouseDown, a, .left, flags: Self.flags(input["text"] as? String)))
            await sleep(0.08)
            await glide(to: b, dragging: true)
            await sleep(0.08)
            post(mouse(.leftMouseUp, b, .left))
            return .text("OK")
        case "left_mouse_down":
            guard let p = currentCG() else { return .text("No cursor.", isError: true) }
            post(mouse(.leftMouseDown, p, .left)); return .text("OK")
        case "left_mouse_up":
            guard let p = currentCG() else { return .text("No cursor.", isError: true) }
            post(mouse(.leftMouseUp, p, .left)); return .text("OK")
        case "cursor_position":
            let (x, y) = modelPoint(fromAppKit: NSEvent.mouseLocation)
            return .text("X=\(x), Y=\(y)")
        case "scroll":
            let dir = input["scroll_direction"] as? String ?? "down"
            let amount = Int((input["scroll_amount"] as? NSNumber)?.intValue ?? 3)
            if let p = cgPoint(input["coordinate"]) { await glide(to: p) }
            caption("Scrolling \(dir)")
            let lines = Int32(max(1, amount) * 3)
            let (v, h): (Int32, Int32) = dir == "up" ? (lines, 0) : dir == "down" ? (-lines, 0) : dir == "left" ? (0, lines) : (0, -lines)
            if let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0) {
                e.flags = Self.flags(input["text"] as? String)
                post(e)
            }
            await sleep(0.2)
            return .text("OK")
        case "type":
            guard let text = input["text"] as? String else { return .text("Missing text.", isError: true) }
            caption("Typing “\(text.prefix(40))\(text.count > 40 ? "…" : "")”")
            await typeText(text)
            return stopped ? .text("Stopped by the user.", isError: true) : .text("OK")
        case "key":
            guard let combo = input["text"] as? String else { return .text("Missing key.", isError: true) }
            let times = max(1, min(100, (input["repeat"] as? NSNumber)?.intValue ?? 1))
            caption("Pressing \(combo)")
            for _ in 0..<times {
                guard press(combo) else { return .text("Unknown key: \(combo)", isError: true) }
                await sleep(0.05)
            }
            return .text("OK")
        case "hold_key":
            guard let combo = input["text"] as? String, let (code, flags) = Self.parseCombo(combo) else { return .text("Unknown key.", isError: true) }
            let d = min(30, (input["duration"] as? NSNumber)?.doubleValue ?? 1)
            caption("Holding \(combo)")
            post(key(code, down: true, flags: flags)); await sleep(d); post(key(code, down: false, flags: flags))
            return .text("OK")
        case "wait":
            let d = min(30, (input["duration"] as? NSNumber)?.doubleValue ?? 1)
            caption("Waiting \(Int(d))s")
            await sleep(d)
            return .text("OK")
        default:
            return .text("Unsupported action \(name)", isError: true)
        }
    }

    /// Accessibility search of the frontmost window; centers reported in screenshot pixels.
    func find(_ query: String) -> ToolResult {
        if !active { begin() }
        let q = query.lowercased()
        guard !q.isEmpty else { return .text("Empty query.", isError: true) }
        guard Permissions.accessibilityGranted else { return .text("Accessibility permission is off.", isError: true) }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return .text("No frontmost app.", isError: true) }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)
        guard let win = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.element(axApp, kAXMainWindowAttribute) else { return .text("No focused window.", isError: true) }
        let primaryMaxY = NSScreen.screens[0].frame.maxY
        var hits: [String] = []
        var stack: [AXUIElement] = [win]
        var visited = 0
        while let el = stack.popLast(), visited < 3000, hits.count < 12 {
            visited += 1
            let texts = [AX.string(el, kAXTitleAttribute), AX.string(el, kAXDescriptionAttribute), AX.string(el, kAXValueAttribute), AX.string(el, kAXPlaceholderValueAttribute)]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if let t = texts.first(where: { $0.lowercased().contains(q) }) {
                var posRef: CFTypeRef?, sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
                   AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let posRef, let sizeRef, CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                    var pos = CGPoint.zero, size = CGSize.zero
                    AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                    if size.width > 0, size.height > 0 {
                        let center = NSPoint(x: pos.x + size.width / 2, y: primaryMaxY - pos.y - size.height / 2)
                        let (x, y) = modelPoint(fromAppKit: center)
                        let role = (AX.string(el, kAXRoleAttribute) ?? "").replacingOccurrences(of: "AX", with: "")
                        hits.append("\(role) “\(t.prefix(60))” center=[\(x), \(y)] size=\(Int(size.width))x\(Int(size.height))")
                    }
                }
            }
            for k in AX.children(el).reversed() { stack.append(k) }
        }
        return .text(hits.isEmpty ? "No element with text matching “\(query)”. Try a screenshot or zoom." : hits.joined(separator: "\n"))
    }

    // MARK: primitives

    private func screenshot() async -> ToolResult {
        do {
            let raw = try await ScreenCapture.captureDisplay(containing: NSPoint(x: screen.frame.midX, y: screen.frame.midY))
            lastRaw = raw
            let img = ScreenCapture.downscale(raw.image, maxLongEdge: maxLongEdge)
            guard let shot = ScreenCapture.encode(img) else { return .text("Could not encode screenshot.", isError: true) }
            return .blocks([["type": "image", "source": ["type": "base64", "media_type": shot.mediaType, "data": shot.data.base64EncodedString()]]])
        } catch { return .text(error.localizedDescription, isError: true) }
    }

    private func zoom(_ region: Any?) async -> ToolResult {
        guard let r = region as? [Any], r.count == 4, let vals = Optional(r.compactMap { ($0 as? NSNumber)?.doubleValue }), vals.count == 4 else {
            return .text("Invalid region.", isError: true)
        }
        if lastRaw == nil { _ = await screenshot() }
        guard let raw = lastRaw else { return .text("No screenshot yet.", isError: true) }
        let s = scale
        let rawPerPoint = raw.pixelsPerPoint
        let f = rawPerPoint / s   // raw pixels per screenshot pixel
        let x0 = max(0, vals[0] * f), y0 = max(0, vals[1] * f)
        let x1 = min(Double(raw.image.width), vals[2] * f), y1 = min(Double(raw.image.height), vals[3] * f)
        guard x1 > x0 + 4, y1 > y0 + 4, let crop = raw.image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else {
            return .text("Region is empty.", isError: true)
        }
        guard let shot = ScreenCapture.encode(ScreenCapture.downscale(crop, maxLongEdge: maxLongEdge)) else { return .text("Could not encode.", isError: true) }
        return .blocks([["type": "image", "source": ["type": "base64", "media_type": shot.mediaType, "data": shot.data.base64EncodedString()]]])
    }

    private func currentCG() -> CGPoint? {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: NSScreen.screens[0].frame.maxY - p.y)
    }

    private func post(_ e: CGEvent?) {
        guard let e else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Self.tag)
        e.post(tap: .cghidEventTap)
    }

    private func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, flags: CGEventFlags = []) -> CGEvent? {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.flags = flags
        return e
    }

    private func click(_ p: CGPoint, button: CGMouseButton, down: CGEventType, up: CGEventType, count: Int, flags: CGEventFlags) {
        for i in 1...count {
            let d = mouse(down, p, button, flags: flags); d?.setIntegerValueField(.mouseEventClickState, value: Int64(i)); post(d)
            let u = mouse(up, p, button, flags: flags); u?.setIntegerValueField(.mouseEventClickState, value: Int64(i)); post(u)
            if i < count { usleep(60_000) }
        }
    }

    /// Moves the cursor smoothly so the user can follow it.
    private func glide(to target: CGPoint, dragging: Bool = false) async {
        let start = currentCG() ?? target
        let dist = hypot(target.x - start.x, target.y - start.y)
        let steps = max(4, min(24, Int(dist / 30)))
        let duration = min(0.45, max(0.12, dist / 2500))
        for i in 1...steps {
            if stopped { return }
            let t = CGFloat(i) / CGFloat(steps)
            let ease = 1 - pow(1 - t, 3)
            let p = CGPoint(x: start.x + (target.x - start.x) * ease, y: start.y + (target.y - start.y) * ease)
            expectedCursor = appKit(p)
            post(mouse(dragging ? .leftMouseDragged : .mouseMoved, p, .left))
            await sleep(duration / Double(steps))
        }
        expectedCursor = appKit(target)
    }

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) -> CGEvent? {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        return e
    }

    private func typeText(_ text: String) async {
        for ch in text {
            if stopped { return }
            if ch == "\n" { _ = press("Return"); await sleep(0.03); continue }
            if ch == "\t" { _ = press("Tab"); await sleep(0.03); continue }
            var units = Array(String(ch).utf16)
            let d = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            d?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            post(d)
            let u = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            u?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            post(u)
            await sleep(0.012)
        }
    }

    @discardableResult
    private func press(_ combo: String) -> Bool {
        guard let (code, flags) = Self.parseCombo(combo) else {
            // Single printable character with no code: type it.
            if combo.count == 1 { var u = Array(combo.utf16); let d = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true); d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u); post(d); let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false); up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u); post(up); return true }
            return false
        }
        post(key(code, down: true, flags: flags))
        usleep(20_000)
        post(key(code, down: false, flags: flags))
        return true
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }

    private func caption(_ s: String) {
        onCaption?(s)
        for c in captions { c.string = "Familiar is controlling · \(s) · move the mouse or press Esc to stop" }
    }

    // MARK: key names (xdotool style, as the model uses them)

    static func flags(_ mods: String?) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in (mods ?? "").lowercased().split(separator: "+") {
            switch m.trimmingCharacters(in: .whitespaces) {
            case "shift": f.insert(.maskShift)
            case "ctrl", "control": f.insert(.maskControl)
            case "alt", "option", "opt": f.insert(.maskAlternate)
            case "super", "cmd", "command", "meta", "win": f.insert(.maskCommand)
            default: break
            }
        }
        return f
    }

    static let named: [String: Int] = [
        "return": kVK_Return, "enter": kVK_Return, "kp_enter": kVK_ANSI_KeypadEnter, "tab": kVK_Tab, "space": kVK_Space,
        "escape": kVK_Escape, "esc": kVK_Escape, "backspace": kVK_Delete, "delete": kVK_ForwardDelete, "del": kVK_ForwardDelete,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "page_up": kVK_PageUp, "pageup": kVK_PageUp, "page_down": kVK_PageDown, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9,
        "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash,
        "semicolon": kVK_ANSI_Semicolon, "apostrophe": kVK_ANSI_Quote, "bracketleft": kVK_ANSI_LeftBracket, "bracketright": kVK_ANSI_RightBracket,
        "backslash": kVK_ANSI_Backslash, "grave": kVK_ANSI_Grave,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
    ]
    static let letterCodes = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
                              kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
                              kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
    static let digitCodes = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// "cmd+s", "ctrl+shift+Tab", "Return", "alt+F4" → key code + flags. Modifier-only combos are rejected.
    static func parseCombo(_ combo: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard var keyName = parts.last, !keyName.isEmpty else { return nil }
        let mods = parts.dropLast().joined(separator: "+")
        var flags = flags(mods)
        keyName = keyName.lowercased()
        if keyName == "plus" { keyName = "="; flags.insert(.maskShift) }
        if keyName == "underscore" { keyName = "-"; flags.insert(.maskShift) }
        var code: Int?
        if let c = named[keyName] { code = c }
        else if keyName.count == 1, let ch = keyName.first {
            if ch.isLetter, let ascii = ch.asciiValue { code = letterCodes[Int(ascii - 97)] }
            else if let d = Int(String(ch)) { code = digitCodes[d] }
        }
        guard let code else { return nil }
        return (CGKeyCode(code), flags)
    }

    // MARK: HUD

    private func showHUD() {
        for s in NSScreen.screens {
            let p = NSPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            let v = NSView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.wantsLayer = true
            if let layer = v.layer {
                ShimmerBorder.install(on: layer, bounds: v.bounds, dim: 0)
                let (pill, text) = ShimmerBorder.captionPill(bounds: v.bounds, scale: s.backingScaleFactor, width: 620,
                                                              text: "Familiar is controlling · move the mouse or press Esc to stop")
                layer.addSublayer(pill)
                captions.append(text)
            }
            p.contentView = v
            p.orderFrontRegardless()
            huds.append(p)
        }
    }
}
