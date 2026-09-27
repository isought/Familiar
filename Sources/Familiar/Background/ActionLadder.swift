import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Runs one computer action in the background lane against the target window.
/// Rung A is Accessibility (press, focus, set value). Rung B is events posted to the target's process (keys, stamped
/// scroll). Rung S is a SkyLight coordinate click, only behind the precise-clicks flag. Anything else, or a rung that
/// provably did nothing, ends as `needs_foreground` so the model can ask for the mouse. Return codes are never
/// trusted: every rung is verified by reading state back, and a rung falls through only on a verified no-effect.
@MainActor
final class ActionLadder {
    var target: TargetWindow
    private(set) var space: CaptureSpace
    var maxLongEdge: Int
    var preciseClicks = false                    // Config flag and the SkyLight self-test both passed
    var monitor: ConflictMonitor?
    var ghost: GhostCursorPanel?
    var peek: PeekFeed?
    var isStopped: () -> Bool = { false }
    var caption: (String) -> Void = { _ in }
    var declaredIrreversible: [String] = []      // from the matching pack's manifest
    var warningNoteLabels: [String] = []         // sticky warnings anchored on controls in this scene
    var confirmation: IrreversibleGuard.Confirmation?
    var viewportDirty = false                    // the human scrolled or resized since the model last looked
    private(set) var lastRaw: RawCapture?
    private var shotFrameSize: CGSize?
    private(set) var step = 0
    private var hits: [Int: AXUIElement] = [:]
    private(set) var ghostCG: CGPoint

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]

    init(target: TargetWindow, maxLongEdge: Int) {
        self.target = target
        self.maxLongEdge = maxLongEdge
        space = target.space(maxLongEdge: maxLongEdge)
        ghostCG = CGPoint(x: target.frameCG.midX, y: target.frameCG.midY)
    }

    static func needsForeground(_ why: String) -> ToolResult {
        .text("needs_foreground: \(why). This needs the real mouse. Try another way first: a keyboard shortcut without ⌘, find_on_screen and click_element, or typing. If there is no other way, call ask_for_the_mouse with a one-line reason the user will understand; they will answer on the pad.")
    }

    // MARK: dispatch

    func run(_ name: String, _ input: [String: Any]) async -> ToolResult {
        step += 1
        peek?.step = step
        if let gone = refreshTarget() { return gone }
        let started = Date()
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let result: ToolResult
        switch name {
        case "screenshot": caption("Looking at \(target.appName)"); result = await screenshot()
        case "zoom": caption("Zooming in"); result = await zoom(input["region"])
        case "left_click", "double_click", "triple_click": result = await click(name, input)
        case "right_click": result = Self.needsForeground("a context menu is a separate window I can't reach in the background")
        case "middle_click": result = Self.needsForeground("a middle click")
        case "left_click_drag": result = Self.needsForeground("a drag")
        case "left_mouse_down", "left_mouse_up": result = Self.needsForeground("holding the mouse button")
        case "mouse_move":
            guard let p = cgPoint(input["coordinate"]) else { return .text("Invalid coordinate.", isError: true) }
            updateGhost(at: p)
            caption("Pointing")
            result = .text("OK (only my own cursor moved; the app sees no hover in the background)")
        case "cursor_position":
            let (x, y) = space.model(fromCG: ghostCG)
            result = .text("X=\(x), Y=\(y)")
        case "scroll": result = await scroll(input)
        case "type":
            guard let text = input["text"] as? String else { return .text("Missing text.", isError: true) }
            result = await type(text)
        case "key":
            guard let combo = input["text"] as? String else { return .text("Missing key.", isError: true) }
            result = await key(combo, times: max(1, min(100, (input["repeat"] as? NSNumber)?.intValue ?? 1)), hold: nil)
        case "hold_key":
            guard let combo = input["text"] as? String else { return .text("Missing key.", isError: true) }
            result = await key(combo, times: 1, hold: min(30, (input["duration"] as? NSNumber)?.doubleValue ?? 1))
        case "wait":
            let d = min(30, (input["duration"] as? NSNumber)?.doubleValue ?? 1)
            caption("Waiting \(Int(d))s")
            await sleep(d)
            result = isStopped() ? .text("Stopped.", isError: true) : .text("OK")
        default: result = .text("Unsupported action \(name)", isError: true)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let summary = (result.content as? String).map { String($0.prefix(90)) } ?? "image"
        Log.info("bg: #\(step) \(name) \(result.isError ? "error" : "ok") \(ms)ms front=\(front)\(after == front ? "" : "→\(after)") \(summary)")
        return result
    }

    // MARK: looking

    func screenshot() async -> ToolResult {
        target.setSCWindow(await target.fetchSCWindow())
        guard let w = target.scWindow else { return .text("The target window is gone.", isError: true) }
        do {
            let raw = try await ScreenCapture.captureWindow(w, backingScale: target.backingScale)
            lastRaw = raw
            shotFrameSize = target.frameCG.size
            viewportDirty = false
            let img = ScreenCapture.downscale(raw.image, maxLongEdge: maxLongEdge)
            guard let shot = ScreenCapture.encode(img) else { return .text("Could not encode screenshot.", isError: true) }
            peek?.frame = ScreenCapture.downscale(raw.image, maxLongEdge: 640)
            return .blocks([["type": "image", "source": ["type": "base64", "media_type": shot.mediaType, "data": shot.data.base64EncodedString()]]])
        } catch { return .text(error.localizedDescription, isError: true) }
    }

    private func zoom(_ region: Any?) async -> ToolResult {
        guard let r = region as? [Any], r.count == 4, let vals = Optional(r.compactMap { ($0 as? NSNumber)?.doubleValue }), vals.count == 4 else {
            return .text("Invalid region.", isError: true)
        }
        if lastRaw == nil { _ = await screenshot() }
        guard let raw = lastRaw else { return .text("No screenshot yet.", isError: true) }
        let f = raw.pixelsPerPoint / space.pxPerPt   // raw pixels per screenshot pixel
        let x0 = max(0, vals[0] * f), y0 = max(0, vals[1] * f)
        let x1 = min(Double(raw.image.width), vals[2] * f), y1 = min(Double(raw.image.height), vals[3] * f)
        guard x1 > x0 + 4, y1 > y0 + 4, let crop = raw.image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else {
            return .text("Region is empty.", isError: true)
        }
        guard let shot = ScreenCapture.encode(ScreenCapture.downscale(crop, maxLongEdge: maxLongEdge)) else { return .text("Could not encode.", isError: true) }
        return .blocks([["type": "image", "source": ["type": "base64", "media_type": shot.mediaType, "data": shot.data.base64EncodedString()]]])
    }

    /// A small live frame for the peek note (not sent to the model).
    func peekCapture() async {
        guard let peek, let w = target.scWindow else { return }
        if let raw = try? await ScreenCapture.captureWindow(w, backingScale: target.backingScale) {
            peek.frame = ScreenCapture.downscale(raw.image, maxLongEdge: 640)
        }
    }

    // MARK: find / click by element

    /// Accessibility search of the target window; every hit gets an id for click_element.
    func find(_ query: String) -> ToolResult {
        let q = query.lowercased()
        guard !q.isEmpty else { return .text("Empty query.", isError: true) }
        if let gone = refreshTarget() { return gone }
        var lines: [String] = []
        var stack: [AXUIElement] = [target.axWindow]
        var visited = 0
        hits.removeAll()
        while let el = stack.popLast(), visited < 3000, lines.count < 12 {
            visited += 1
            let title = AX.string(el, kAXTitleAttribute), desc = AX.string(el, kAXDescriptionAttribute)
            let texts = [title, desc, AX.string(el, kAXValueAttribute), AX.string(el, kAXPlaceholderValueAttribute), AX.string(el, "AXDOMIdentifier")]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if let t = texts.first(where: { $0.lowercased().contains(q) }), let frame = axFrame(el), frame.width > 0, frame.height > 0,
               desc != "Address and search bar" {   // Chrome's omnibox is the first text field in the tree; never the page's
                let id = lines.count + 1
                hits[id] = el
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let (x, y) = space.model(fromCG: center)
                let role = (AX.string(el, kAXRoleAttribute) ?? "").replacingOccurrences(of: "AX", with: "")
                let pressable = axActions(el).contains(kAXPressAction)
                lines.append("#\(id) \(role) “\(t.prefix(60))” center=[\(x), \(y)] size=\(Int(frame.width))x\(Int(frame.height))\(pressable ? " pressable" : "")\(space.contains(cg: center) ? "" : " (off the visible window)")")
            }
            for k in AX.children(el).reversed() { stack.append(k) }
        }
        return .text(lines.isEmpty ? "No element with text matching “\(query)”. Try a screenshot or zoom." : lines.joined(separator: "\n"))
    }

    func clickElement(id: Int) async -> ToolResult {
        guard let el = hits[id] else { return .text("No element #\(id). Call find_on_screen first; ids are only valid for its latest result.", isError: true) }
        if let gone = refreshTarget() { return gone }
        step += 1
        peek?.step = step
        let info = axInfo(el)
        caption("Pressing “\(plainName(info))”")
        if let frame = axFrame(el) { updateGhost(at: CGPoint(x: frame.midX, y: frame.midY)) }
        let noReaction = Self.needsForeground("“\(info.label)” did not react to being pressed")
        return await press(el, info: info, then: { noReaction }) ?? noReaction
    }

    // MARK: click

    private func click(_ name: String, _ input: [String: Any]) async -> ToolResult {
        let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : 1
        let cg = input["coordinate"] == nil ? ghostCG : cgPoint(input["coordinate"])
        guard let cg else { return .text("Invalid coordinate.", isError: true) }
        if let stale = staleViewport() { return stale }
        guard space.contains(cg: cg) else { return .text("That point is outside the window I'm working in. Take a screenshot; coordinates are pixels of the window capture.", isError: true) }
        updateGhost(at: cg)
        let (mx, my) = space.model(fromCG: cg)
        let flags = ComputerController.flags(input["text"] as? String)
        if count == 1, flags.isEmpty {
            // Rung A: a text field wants focus, a control wants a press.
            if let el = target.element(atCG: cg, pressable: false) {
                let info = axInfo(el)
                if let role = info.role, Self.textRoles.contains(role) {
                    caption("Clicking into the \(plainName(info))")
                    if let r = await focus(el, info: info) { return r }
                }
            }
            if let el = target.element(atCG: cg, pressable: true) {
                let info = axInfo(el)
                caption("Pressing “\(plainName(info))”")
                let r = await press(el, info: info, then: { nil as ToolResult? })
                if let r { return r }
            }
        }
        caption("Clicking at \(mx), \(my)")
        if let r = await coordinateClick(at: cg, count: count, flags: flags) { return r }
        return Self.needsForeground(count == 1 ? "nothing pressable at [\(mx), \(my)]" : "a \(count == 2 ? "double" : "triple") click")
    }

    /// Rung S: the SkyLight coordinate click. Nil when the rung is unavailable or provably did nothing.
    private func coordinateClick(at cg: CGPoint, count: Int, flags: CGEventFlags) async -> ToolResult? {
        guard preciseClicks, !target.sharedWithHuman, SkyLightClick.shared.state == .ready else { return nil }
        guard await clear() else { return busyResult }
        let before = await snapshot(element: nil, cropAroundCG: cg)
        let ok = await SkyLightClick.shared.click(target: target, globalCG: cg, local: space.local(fromCG: cg), button: .left, count: count, flags: flags)
        ghost?.pulse(count: count)
        peek?.pulse += count
        let v = await verify(before: before, element: nil, cropAroundCG: cg, expecting: .anyChange)
        Log.info("bg: rung=skylight ok=\(ok) \(v)")
        switch v {
        case .confirmed: return .text("OK")
        case .unverifiable(let why): return .text("OK — clicked; no change seen yet (\(why)). Screenshot to check.")
        case .noEffect: return nil
        }
    }

    /// Rung A press with the irreversible guard and verification. `then` supplies the fall-through result (nil = try the next rung).
    private func press(_ el: AXUIElement, info: IrreversibleGuard.ElementInfo, then fallback: () -> ToolResult?) async -> ToolResult? {
        if let blocked = guardPress(el, info: info) { return blocked }
        ghost?.highlight(rectCG: axFrame(el), label: info.label.isEmpty ? nil : String(info.label.prefix(40)))
        defer { ghost?.highlight(rectCG: nil, label: nil) }
        let point = axFrame(el).map { CGPoint(x: $0.midX, y: $0.midY) }
        let before = await snapshot(element: el, cropAroundCG: point)
        AXUIElementPerformAction(el, kAXPressAction as CFString)
        ghost?.pulse(count: 1)
        peek?.pulse += 1
        let v = await verify(before: before, element: el, cropAroundCG: point, expecting: .anyChange)
        Log.info("bg: rung=ax.press “\(info.label.prefix(40))” \(v)")
        switch v {
        case .confirmed: return .text("OK — pressed “\(info.label)”")
        case .unverifiable(let why): return .text("OK — pressed “\(info.label)”; no change seen yet (\(why)). Screenshot to check.")
        case .noEffect: return fallback()
        }
    }

    /// Rung A for text fields: give the field keyboard focus. Nil when it did not take.
    private func focus(_ el: AXUIElement, info: IrreversibleGuard.ElementInfo) async -> ToolResult? {
        if case .forbidden(let why) = IrreversibleGuard.classifyType(into: info) { return .text("Not done: \(why).", isError: true) }
        let before = await snapshot(element: el, cropAroundCG: nil)
        axSet(el, kAXFocusedAttribute, kCFBooleanTrue)
        ghost?.underline(rectCG: axFrame(el))
        let v = await verify(before: before, element: el, cropAroundCG: nil, expecting: .focusOn)
        Log.info("bg: rung=ax.focus “\(info.label.prefix(40))” \(v)")
        switch v {
        case .confirmed: return .text("OK — the \(plainName(info)) has keyboard focus; type to fill it")
        case .unverifiable: return .text("OK — asked the \(plainName(info)) for focus; type to fill it and screenshot to check")
        case .noEffect: return nil
        }
    }

    // MARK: type / keys

    private func type(_ text: String) async -> ToolResult {
        caption("Typing “\(text.prefix(40))\(text.count > 40 ? "…" : "")”")
        let field = focusedElement()
        let info = field.map(axInfo)
        if let info, case .forbidden(let why) = IrreversibleGuard.classifyType(into: info) { return .text("Not done: \(why). Familiar never types there.", isError: true) }
        if let field { ghost?.underline(rectCG: axFrame(field)) }
        let expecting: ActionVerifier.Expectation = field == nil ? .anyChange : .valueContains(String(text.prefix(24)))
        // Rung B first: real keystrokes land at the caret. Not when the human shares the app (keys go to the app's main
        // window, which may be theirs) or the window is minimized (keys are dropped).
        if !target.sharedWithHuman, !target.isMinimized, PidEvents.ensureMain(target) {
            guard await clear() else { return busyResult }
            if target.toolkit == .chromium || target.toolkit == .electron, let field { axSet(field, kAXFocusedAttribute, kCFBooleanTrue) }
            let before = await snapshot(element: field, cropAroundCG: nil)
            await PidEvents.type(pid: target.pid, text: text, cancelled: isStopped)
            if isStopped() { return .text("Stopped.", isError: true) }
            let v = await verify(before: before, element: field, cropAroundCG: nil, expecting: expecting)
            Log.info("bg: rung=pid.keys \(v)")
            switch v {
            case .confirmed: return .text("OK")
            case .unverifiable(let why): return .text("OK — typed; not verified (\(why)). Screenshot to check.")
            case .noEffect: break
            }
        }
        // Rung A: write the field through Accessibility. AppKit inserts at the caret; Chromium only accepts a whole value.
        guard let field, let info else {
            return .text(target.isMinimized ? "Not done: the window is minimized, so keystrokes are dropped and no field is focused. I can press buttons and set values; ask the user to bring the window back for typing."
                         : "Not done: no text field has keyboard focus. Click into the field first (find_on_screen, then click_element or left_click).")
        }
        let before = await snapshot(element: field, cropAroundCG: nil)
        if target.toolkit == .appKit {
            axSet(field, kAXSelectedTextAttribute, text as CFString)
        } else {
            axSet(field, kAXFocusedAttribute, kCFBooleanTrue)
            axSet(field, kAXValueAttribute, ((info.value ?? "") + text) as CFString)
        }
        let v = await verify(before: before, element: field, cropAroundCG: nil, expecting: expecting)
        Log.info("bg: rung=ax.value \(v)")
        switch v {
        case .confirmed: return .text("OK")
        case .unverifiable(let why): return .text("OK — set the field; not verified (\(why)). Screenshot to check.")
        case .noEffect: return .text("Not done: typing did not take in the \(plainName(info)). Click into the field again, or ask_for_the_mouse.")
        }
    }

    private func key(_ combo: String, times: Int, hold: Double?) async -> ToolResult {
        if case .forbidden(let why) = IrreversibleGuard.classifyKey(combo) { return .text("Not done: \(why). Familiar never does that in the background.", isError: true) }
        caption(hold == nil ? "Pressing \(combo)" : "Holding \(combo)")
        guard let (code, flags) = ComputerController.parseCombo(combo) else {
            if combo.count == 1 { return await type(combo) }
            return .text("Unknown key: \(combo)", isError: true)
        }
        if flags.contains(.maskCommand) { return Self.needsForeground("⌘ shortcuts go through the menu bar, which only answers the frontmost app") }
        if target.sharedWithHuman { return Self.needsForeground("keystrokes would go to the window you are using in \(target.appName)") }
        if target.isMinimized { return .text("Not done: the window is minimized, so keystrokes are dropped. I can press buttons and set values; ask the user to bring it back for keys.") }
        guard PidEvents.ensureMain(target) else { return .text("Not done: I couldn't make the window take keys (it isn't the app's main window).") }
        guard await clear() else { return busyResult }
        let field = focusedElement()
        let before = await snapshot(element: field, cropAroundCG: nil)
        if let hold {
            await PidEvents.holdKey(pid: target.pid, code: code, flags: flags, seconds: hold)
        } else {
            for _ in 0..<times {
                if isStopped() { return .text("Stopped.", isError: true) }
                PidEvents.press(pid: target.pid, code: code, flags: flags)
                await sleep(0.05)
            }
        }
        let v = await verify(before: before, element: field, cropAroundCG: nil, expecting: .anyChange)
        Log.info("bg: rung=pid.key \(combo) \(v)")
        if case .confirmed = v { return .text("OK") }
        return .text("OK — pressed \(combo); no visible change (that can be normal for this key). Screenshot to check.")
    }

    // MARK: scroll

    private func scroll(_ input: [String: Any]) async -> ToolResult {
        let dir = input["scroll_direction"] as? String ?? "down"
        let amount = max(1, min(100, (input["scroll_amount"] as? NSNumber)?.intValue ?? 3))
        let cg = input["coordinate"] == nil ? ghostCG : cgPoint(input["coordinate"])
        guard let cg else { return .text("Invalid coordinate.", isError: true) }
        guard space.contains(cg: cg) else { return .text("That point is outside the window I'm working in.", isError: true) }
        updateGhost(at: cg)
        caption("Scrolling \(dir)")
        let lines = Int32(amount * 3)
        let (v, h): (Int32, Int32) = dir == "up" ? (lines, 0) : dir == "down" ? (-lines, 0) : dir == "left" ? (0, lines) : (0, -lines)
        let flags = ComputerController.flags(input["text"] as? String)
        // Rung B: a scroll event stamped for the window (verified in an occluded Chrome window).
        if !target.sharedWithHuman {
            guard await clear() else { return busyResult }
            let before = await snapshot(element: nil, cropAroundCG: cg)
            PidEvents.scroll(pid: target.pid, windowID: target.cgWindowID, globalCG: cg, local: space.local(fromCG: cg), vertical: v, horizontal: h, flags: flags)
            let verdict = await verify(before: before, element: nil, cropAroundCG: cg, expecting: .anyChange)
            Log.info("bg: rung=pid.scroll \(verdict)")
            switch verdict {
            case .confirmed: return .text("OK")
            case .unverifiable(let why): return .text("OK — scrolled; not verified (\(why)). Screenshot to check.")
            case .noEffect: break
            }
        }
        // Rung A: nudge the scroll area's scroll bar.
        if let bar = scrollBar(atCG: cg, vertical: dir == "up" || dir == "down"), let current = axNumber(bar, kAXValueAttribute) {
            let delta = Double(amount) * 0.05 * ((dir == "down" || dir == "right") ? 1 : -1)
            let before = await snapshot(element: nil, cropAroundCG: cg)
            axSet(bar, kAXValueAttribute, NSNumber(value: min(1, max(0, current + delta))))
            let verdict = await verify(before: before, element: nil, cropAroundCG: cg, expecting: .anyChange)
            Log.info("bg: rung=ax.scrollbar \(verdict)")
            if case .noEffect = verdict {} else { return .text("OK") }
        }
        return Self.needsForeground("this view does not scroll from the background")
    }

    // MARK: guards and verification

    private func guardPress(_ el: AXUIElement, info: IrreversibleGuard.ElementInfo) -> ToolResult? {
        switch IrreversibleGuard.classifyPress(info, inSheet: isInSheet(el), declared: declaredIrreversible, warningNoteLabels: warningNoteLabels) {
        case .safe: return nil
        case .forbidden(let why): return .text("Not done: \(why). Familiar never does that in the background.", isError: true)
        case .confirm(let label):
            if IrreversibleGuard.consume(&confirmation, label: label, now: Date()) { return nil }
            return .text("Not pressed: this looks irreversible (\((info.role ?? "AXControl").replacingOccurrences(of: "AX", with: "").lowercased()) “\(label)”) and nobody is watching. Ask the user, and end your reply with `Suggestions: Confirm: \(label) | Don't`. When they confirm, press it again.")
        }
    }

    private func snapshot(element: AXUIElement?, cropAroundCG: CGPoint?) async -> AXSnapshot {
        await ActionVerifier.snapshot(target: target, element: element, cropAroundCG: cropAroundCG)
    }

    private func verify(before: AXSnapshot, element: AXUIElement?, cropAroundCG: CGPoint?, expecting: ActionVerifier.Expectation) async -> Verdict {
        let t = target
        // Electron echoes AX writes without applying them, and a Chromium window with no web tree has nothing to read: pixels only.
        let trustAX = t.toolkit != .electron && !t.axDegraded
        return await ActionVerifier.verify(before: before, expecting: expecting, pollMs: [80, 200, 400], trustAX: trustAX) {
            await ActionVerifier.snapshot(target: t, element: element, cropAroundCG: cropAroundCG)
        }
    }

    /// Waits for the human's input to settle before posting to the target's process.
    private func clear() async -> Bool {
        guard let monitor else { return true }
        return await monitor.waitUntilClear(timeout: 5)
    }
    private var busyResult: ToolResult { .text("Not done: the user is typing or holding the mouse right now. Wait a moment and try again.") }

    /// Nil when the window is still there; otherwise the result to hand back.
    private func refreshTarget() -> ToolResult? {
        guard target.refresh() else { return .text("The target window closed. Nothing more was done.", isError: true) }
        space = target.space(maxLongEdge: maxLongEdge)
        monitor?.targetFrameCG = target.frameCG
        ghost?.attach(targetFrameCG: target.frameCG)
        if let s = shotFrameSize, abs(s.width - target.frameCG.width) > 2 || abs(s.height - target.frameCG.height) > 2 { viewportDirty = true }
        return nil
    }

    private func staleViewport() -> ToolResult? {
        guard viewportDirty else { return nil }
        viewportDirty = false
        return .text("Not done: the window changed since your last screenshot (the user scrolled or resized it). Take a new screenshot before clicking by coordinates.")
    }

    private func cgPoint(_ coord: Any?) -> CGPoint? {
        guard let arr = coord as? [Any], arr.count == 2,
              let x = (arr[0] as? NSNumber)?.doubleValue, let y = (arr[1] as? NSNumber)?.doubleValue else { return nil }
        return space.cg(fromModel: x, y)
    }

    private func updateGhost(at cg: CGPoint) {
        ghostCG = cg
        if let ghost {
            let top = ConflictMonitor.topWindow(atCG: cg, excludingPID: ProcessInfo.processInfo.processIdentifier)
            ghost.setVisible(GhostCursorPanel.shouldShow(topWindowAtPoint: top, targetWindowID: target.cgWindowID,
                                                         targetOnScreen: target.isOnScreen, targetMinimized: target.isMinimized))
            ghost.move(toCG: cg, animated: true)
        }
        let local = space.local(fromCG: cg)
        peek?.cursor = CGPoint(x: local.x / max(1, space.sizePt.width), y: local.y / max(1, space.sizePt.height))
    }

    private func sleep(_ s: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
    }

    // MARK: Accessibility helpers

    private func focusedElement() -> AXUIElement? { AX.element(target.axApp, kAXFocusedUIElementAttribute) }

    /// "Save", or the role in plain words when the control has no label (a text area, a checkbox).
    private func plainName(_ info: IrreversibleGuard.ElementInfo) -> String {
        if !info.label.isEmpty { return String(info.label.prefix(30)) }
        let role = (info.role ?? "control").replacingOccurrences(of: "AX", with: "")
        var words = ""
        for ch in role { if ch.isUppercase, !words.isEmpty { words += " " }; words.append(ch) }
        return words.lowercased()
    }

    func axInfo(_ el: AXUIElement) -> IrreversibleGuard.ElementInfo {
        var info = IrreversibleGuard.ElementInfo()
        info.role = AX.string(el, kAXRoleAttribute)
        info.subrole = AX.string(el, kAXSubroleAttribute)
        info.title = AX.string(el, kAXTitleAttribute)
        info.description = AX.string(el, kAXDescriptionAttribute)
        info.domID = AX.string(el, "AXDOMIdentifier")
        info.value = AX.string(el, kAXValueAttribute)
        info.isSecure = info.role == "AXSecureTextField"
        if let w = AX.element(el, kAXWindowAttribute), let def = AX.element(w, kAXDefaultButtonAttribute) { info.isDefaultButton = CFEqual(def, el) }
        return info
    }

    private func isInSheet(_ el: AXUIElement) -> Bool {
        guard let w = AX.element(el, kAXWindowAttribute) else { return false }
        return AX.string(w, kAXRoleAttribute) == "AXSheet"
    }

    /// Frame in CG global coordinates (kAXPosition is already top-left CG).
    private func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef, CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private func axActions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let arr = names as? [String] else { return [] }
        return arr
    }

    private func axNumber(_ el: AXUIElement, _ attr: String) -> Double? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let n = ref as? NSNumber else { return nil }
        return n.doubleValue
    }

    @discardableResult
    private func axSet(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, value) == .success
    }

    /// The scroll bar of the nearest scroll area around a point.
    private func scrollBar(atCG p: CGPoint, vertical: Bool) -> AXUIElement? {
        var el = target.element(atCG: p, pressable: false)
        var hops = 0
        while let cur = el, hops < 12 {
            if AX.string(cur, kAXRoleAttribute) == "AXScrollArea" {
                return AX.element(cur, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute)
            }
            el = AX.element(cur, kAXParentAttribute)
            hops += 1
        }
        return nil
    }
}
