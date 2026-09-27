import FamiliarContracts
import AppKit
import Carbon.HIToolbox
import QuartzCore

/// Drives the mouse and keyboard for Claude's computer toolset. Coordinates from the model are screenshot pixels.
@MainActor
final class ComputerController {
    static let toolsetDefinition: [String: Any] = ["type": "computer_toolset_20260801"]
    static let findDefinition: [String: Any] = [
        "name": "find_on_screen",
        "description": "Find UI elements in the window Familiar is working in (the frontmost window when it has the mouse) by their visible text (button labels, field names, menu items, link text) via Accessibility. Returns each match's #id, role and center in screenshot pixel coordinates; in the background lane press it with click_element by id. Use it before guessing coordinates from pixels; finds nothing in canvas-like content.",
        "input_schema": ["type": "object", "properties": ["query": ["type": "string", "description": "Text to look for, case-insensitive substring"]], "required": ["query"]],
    ]
    static let targetWindowDefinition: [String: Any] = [
        "name": "target_window",
        "description": "Background lane: list the app windows Familiar can work in (id, app, title), or switch to one by id. The window that was in front when the user asked is the target by default; switch only when the task needs another app, then take a screenshot.",
        "input_schema": ["type": "object", "properties": ["select": ["type": "integer", "description": "Window id from the list; omit to just list"]]],
    ]
    static let clickElementDefinition: [String: Any] = [
        "name": "click_element",
        "description": "Background lane: press a control by the #id from the latest find_on_screen result. More reliable than clicking by pixels, and verified against the app's state.",
        "input_schema": ["type": "object", "properties": ["id": ["type": "integer", "description": "#id from find_on_screen"]], "required": ["id"]],
    ]
    static let askForMouseDefinition: [String: Any] = [
        "name": "ask_for_the_mouse",
        "description": "Background lane: ask the user to lend you the real mouse and keyboard for a moment, for something only that can do (a drag, a context menu, a point with nothing pressable, a ⌘ shortcut). First try a keyboard route, find_on_screen with click_element, or typing. Give a one-line reason in the user's own terms, e.g. \"to drag Invoice 8812 onto the Approved column\". Returns when the user answers on the pad (up to 45 s). If they agree, take a screenshot (coordinates become pixels of the whole display), do that part in one go, then call give_the_mouse_back.",
        "input_schema": ["type": "object", "properties": ["reason": ["type": "string"]], "required": ["reason"]],
    ]
    static let giveMouseBackDefinition: [String: Any] = [
        "name": "give_the_mouse_back",
        "description": "Background lane: hand the mouse back to the user as soon as the foreground part is done, and carry on in the background.",
        "input_schema": ["type": "object", "properties": [:]],
    ]
    static var backgroundDefinitions: [[String: Any]] { [targetWindowDefinition, clickElementDefinition, askForMouseDefinition, giveMouseBackDefinition] }
    static let backgroundToolNames: Set<String> = ["target_window", "click_element", "ask_for_the_mouse", "give_the_mouse_back"]
    nonisolated static let tag: Int64 = 0x5344_4B31   // marks our synthetic events (read from event monitors off the main actor)

    var maxLongEdge = 1568
    var hudEnabled = true
    var ghostEnabled = true                  // the purple cursor overlay in the background lane (off headless)
    var hideFromScreenShare = false
    var preciseClicks = false                // Config.backgroundPreciseClicks; the SkyLight rung still needs its self-test
    var onCaption: ((String) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    /// The background lane borrows the real mouse for a moment: true when entering the grant, false when leaving.
    var onGrant: ((Bool) -> Void)?
    /// Pack-declared irreversible controls and warning stickers for the current scene (set by the app per turn).
    var declaredIrreversible: [String] = []
    var warningNoteLabels: [String] = []

    /// Set by the app before a turn: foreground drives the real mouse; background drives one target window.
    var lane: Lane = .foreground
    /// The window the background lane works in. Set by the app before the turn (the window in front when the user asked).
    var target: TargetWindow?
    /// The pad's live peek of the target window; nil headless.
    var peek: PeekFeed?

    private(set) var stopped = false
    private(set) var active = false
    private var stopReason = ""
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    /// What the model's screenshot pixels refer to: the display (foreground) or the target window (background).
    private(set) var space = CaptureSpace(originCG: .zero, sizePt: CGSize(width: 1, height: 1), pxPerPt: 1)
    private var lastRaw: RawCapture?
    private var expectedCursor: NSPoint?
    private var huds: [NSPanel] = []
    private var captions: [CATextLayer] = []
    private var monitors: [Any] = []
    private var beganAt = Date.distantPast

    // Background lane state
    private(set) var ladder: ActionLadder?
    private var ghost: GhostCursorPanel?
    private var conflict: ConflictMonitor?
    private var watch: TargetWatch?
    private var warmUp: TargetWindow.AXWarmUp?
    private var userApp: NSRunningApplication?         // the app the human was in when the job started
    private var expectingActivation = false             // we are raising the target on purpose (peek click)
    private var actionRunning = false
    private var peekTimer: Task<Void, Never>?
    private var pendingConfirmation: IrreversibleGuard.Confirmation?
    private var pendingNotice: String?                  // told to the model on its next action
    private var handoff: CheckedContinuation<Bool, Never>?
    private var handoffTimeout: Task<Void, Never>?
    private var grantTask: Task<Void, Never>?
    private(set) var grantActive = false                // the human lent us the real mouse; foreground path for now
    private var grantRevoked = false
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.userData = ComputerController.tag
        return s
    }()

    // MARK: session

    func reset() { stopped = false; stopReason = "" }

    func begin() {
        guard !active else { return }
        if lane == .background, let target { beginBackground(target) } else { beginForeground() }
    }

    private func beginForeground() {
        active = true
        stopped = false
        beganAt = Date()
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        space = .display(screen, maxLongEdge: maxLongEdge)
        expectedCursor = nil
        if hudEnabled { showHUD() }
        installAbortMonitor()
        onBegin?()
        Log.info("control: began on \(Int(screen.frame.width))x\(Int(screen.frame.height))pt, scale \(String(format: "%.3f", scale))")
    }

    /// The background lane: no HUD, no real cursor. A ladder per target window, a ghost cursor, a conflict monitor that
    /// only minds the target window, and a watch on the window itself.
    private func beginBackground(_ t: TargetWindow) {
        active = true
        stopped = false
        beganAt = Date()
        var target = t
        userApp = NSWorkspace.shared.frontmostApplication
        target.sharedWithHuman = Self.humanInAnotherWindow(of: target)
        let l = ActionLadder(target: target, maxLongEdge: maxLongEdge)
        l.isStopped = { [weak self] in self?.stopped ?? true }
        l.caption = { [weak self] in self?.caption($0) }
        l.peek = peek
        l.declaredIrreversible = declaredIrreversible
        l.warningNoteLabels = warningNoteLabels
        l.confirmation = pendingConfirmation
        pendingConfirmation = nil
        if ghostEnabled {
            let g = GhostCursorPanel(hideFromScreenShare: hideFromScreenShare)
            g.attach(targetFrameCG: target.frameCG)
            ghost = g
            l.ghost = g
        }
        ladder = l
        space = l.space
        bindTarget(target)
        if let peek {
            peek.reset()
            peek.phase = .working
            peek.appName = target.appName
            peek.windowTitle = target.title
            peek.caption = "Getting started"
            peek.startedAt = Date()
            peek.onStop = { [weak self] in self?.stop(reason: "you asked") }
            peek.onRaise = { [weak self] in self?.raiseTarget() }
            startPeekTimer()
        }
        if target.toolkit == .chromium || target.toolkit == .electron {
            Task { [weak self] in
                guard let self, var t = self.ladder?.target else { return }
                let w = await t.warmUpAccessibility()
                self.warmUp = w
                self.ladder?.target = t
                if t.axDegraded { Log.info("control: \(t.appName) exposes no web accessibility tree; coordinates only") }
            }
        }
        if preciseClicks {
            Task { [weak self] in
                let ready = await SkyLightClick.shared.prepare(flagOn: true)
                self?.ladder?.preciseClicks = ready
            }
        }
        onBegin?()
        Log.info("control: began background on \(target.appName) “\(target.title.prefix(60))” \(Int(target.frameCG.width))x\(Int(target.frameCG.height))pt \(target.toolkit.rawValue)\(target.sharedWithHuman ? " shared-with-human" : "")")
    }

    /// Conflict monitor and window watch for one target; also used when the model switches target mid-job.
    private func bindTarget(_ target: TargetWindow) {
        conflict?.remove()
        watch?.stop()
        let m = ConflictMonitor(target: target,
                                recordOutstanding: { SkyLightClick.shared.recordOutstanding },
                                expectingActivation: { [weak self] in self?.expectingActivation ?? false },
                                onStop: { [weak self] r in self?.stop(reason: r) },
                                onDirty: { [weak self] in self?.ladder?.viewportDirty = true },
                                onAbortRecord: { [weak self] in if let t = self?.ladder?.target { SkyLightClick.shared.abortRecord(target: t) } })
        m.install()
        conflict = m
        ladder?.monitor = m
        watch = TargetWatch(target: target) { [weak self] ev in self?.targetEvent(ev) }
    }

    /// The human is in the target's app but in another of its windows: posted keys would land in their window, so
    /// the ladder keeps to Accessibility writes. Sitting in the target window itself is the normal case (they just
    /// asked from the pad) and is not a conflict.
    private static func humanInAnotherWindow(of t: TargetWindow) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid else { return false }
        guard let focused = AX.element(t.axApp, kAXFocusedWindowAttribute) else { return false }
        return !CFEqual(focused, t.axWindow)
    }

    private func targetEvent(_ ev: TargetEvent) {
        guard active, lane == .background else { return }
        switch ev {
        case .destroyed, .appTerminated:
            stop(reason: "the window closed")
        case .focusedWindowChanged:
            if let ladder {
                let shared = Self.humanInAnotherWindow(of: ladder.target)
                if shared != ladder.target.sharedWithHuman {
                    ladder.target.sharedWithHuman = shared
                    Log.info("control: human \(shared ? "moved to another" : "is back in the target") window of \(ladder.target.appName)")
                }
            }
        case .titleChanged(let t):
            peek?.windowTitle = t
            ladder?.viewportDirty = true
        case .resized, .sheetCreated, .windowCreated, .minimized, .deminiaturized:
            ladder?.viewportDirty = true
            if ev == .sheetCreated || ev == .windowCreated { pendingNotice = "A new window or sheet appeared in \(ladder?.target.appName ?? "the app"). Take a screenshot before continuing." }
        case .moved:
            if let f = ladder?.target.frameCG { ghost?.attach(targetFrameCG: f) }
        case .appActivated, .appHidden, .spaceChanged:
            break   // the conflict monitor decides what a human activation means
        }
        Log.info("control: target event \(ev)")
    }

    private func raiseTarget() {
        guard let t = ladder?.target else { return }
        expectingActivation = true
        NSRunningApplication(processIdentifier: t.pid)?.activate()
        AXUIElementPerformAction(t.axWindow, kAXRaiseAction as CFString)
        Task { [weak self] in try? await Task.sleep(nanoseconds: 1_000_000_000); self?.expectingActivation = false }
    }

    private func startPeekTimer() {
        peekTimer?.cancel()
        peekTimer = Task { [weak self] in
            while let self, self.active, !Task.isCancelled {
                if self.grantActive { try? await Task.sleep(nanoseconds: 300_000_000); continue }
                guard let iv = PeekCadence.interval(phase: self.peek?.phase ?? .idle, actionRunning: self.actionRunning) else {
                    try? await Task.sleep(nanoseconds: 300_000_000); continue
                }
                await self.ladder?.peekCapture()
                try? await Task.sleep(nanoseconds: UInt64(iv * 1_000_000_000))
            }
        }
    }

    func end() {
        guard active else { return }
        active = false
        if grantActive { leaveGrant(reason: "done") }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for p in huds { p.orderOut(nil) }
        huds.removeAll()
        captions.removeAll()
        // Background pieces
        peekTimer?.cancel(); peekTimer = nil
        resolveHandoff(false)
        conflict?.remove(); conflict = nil
        watch?.stop(); watch = nil
        ghost?.hide(); ghost = nil
        if let w = warmUp, let t = ladder?.target { t.restoreAccessibility(w) }
        warmUp = nil
        if let t = ladder?.target, SkyLightClick.shared.recordOutstanding { SkyLightClick.shared.abortRecord(target: t) }
        if let peek, lane == .background, ladder != nil { peek.phase = stopped ? .stopped : .done }
        ladder = nil
        pendingNotice = nil
        onEnd?()
        Log.info("control: ended\(stopped ? " (stopped: \(stopReason))" : "")")
    }

    func stop(reason: String) {
        guard active, !stopped else { return }
        stopped = true
        stopReason = reason
        caption("Stopped (\(reason))")
        ghost?.hide()
        resolveHandoff(false)
        Log.info("control: stop requested: \(reason)")
    }

    /// The pad's tab "Confirm: <label>" lets exactly one irreversible press through within two minutes.
    func confirm(label: String) {
        let c = IrreversibleGuard.Confirmation(label: label, expires: Date().addingTimeInterval(120), usesLeft: 1)
        if let ladder { ladder.confirmation = c } else { pendingConfirmation = c }
    }

    /// Summary for the receipt note.
    var summary: (steps: Int, appName: String)? {
        guard let ladder else { return nil }
        return (ladder.step, ladder.target.appName)
    }

    /// The foreground lane's monitor: any human input ends the session, or, while the human has lent us the mouse,
    /// hands it back.
    private func installAbortMonitor() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel, .keyDown]
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard let self, self.active, !self.stopped else { return }
            if let cg = e.cgEvent, cg.getIntegerValueField(.eventSourceUserData) == Self.tag { return }   // ours
            if Date().timeIntervalSince(self.beganAt) < 0.5 { return }                                     // settle time
            switch e.type {
            case .keyDown:
                self.humanInput(e.keyCode == 53 ? "Escape" : "keyboard")
            case .mouseMoved, .leftMouseDragged:
                let here = NSEvent.mouseLocation
                if let exp = self.expectedCursor, hypot(here.x - exp.x, here.y - exp.y) < 6 { return }
                if self.expectedCursor == nil { return }   // we haven't moved the mouse yet; ignore drift
                self.humanInput("mouse moved")
            default:
                self.humanInput("mouse")
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { e in handler(e); return e }) { monitors.append(l) }
    }

    private func humanInput(_ reason: String) {
        if grantActive {
            grantRevoked = true
            pendingNotice = "The user took the mouse back. Continue in the background if you can; otherwise stop and say what is left to do by hand."
            leaveGrant(reason: "You took the mouse back")
        } else {
            stop(reason: reason)
        }
    }

    // MARK: the mouse on loan (background lane → a short foreground stint)

    func askForMouse(_ input: [String: Any]) async -> ToolResult {
        guard lane == .background, active, ladder != nil else { return .text("You already have the mouse: this is the foreground lane.", isError: true) }
        if grantActive { return .text("You already have the mouse. Do the foreground part now, then give_the_mouse_back.", isError: true) }
        guard let peek else { return .text("The user said not now (no pad to ask on). Do what you can in the background, or stop and say what is left to do by hand.", isError: true) }
        let reason = (input["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        peek.phase = .asking(reason.isEmpty ? "for something only the real mouse can do" : reason)
        caption("Asking for the mouse")
        let allowed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            handoff = c
            peek.onGoAhead = { [weak self] in self?.resolveHandoff(true) }
            peek.onNotNow = { [weak self] in self?.resolveHandoff(false) }
            handoffTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                self?.resolveHandoff(false)
            }
        }
        guard allowed, active, !stopped else {
            peek.phase = stopped ? .stopped : .working
            caption("Carrying on without the mouse")
            return .text("The user said not now. Do what you can in the background, or stop and say what is left to do by hand.", isError: true)
        }
        enterGrant()
        return .text("The user handed you the mouse. Take a screenshot first: coordinates are now pixels of the whole display. Do the foreground part in one go, then call give_the_mouse_back.")
    }

    func giveMouseBack() -> ToolResult {
        guard grantActive else { return .text("You don't have the mouse right now.", isError: true) }
        leaveGrant(reason: "Back in the background")
        return .text("Thanks. You're back in the background lane: coordinates are pixels of the window capture again. Take a screenshot.")
    }

    private func resolveHandoff(_ allowed: Bool) {
        handoffTimeout?.cancel(); handoffTimeout = nil
        guard let c = handoff else { return }
        handoff = nil
        peek?.onGoAhead = nil
        peek?.onNotNow = nil
        c.resume(returning: allowed)
    }

    private func enterGrant() {
        grantActive = true
        grantRevoked = false
        peek?.phase = .foreground
        conflict?.remove()
        ghost?.setVisible(false)
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        space = .display(screen, maxLongEdge: maxLongEdge)
        expectedCursor = nil
        beganAt = Date()
        lastRaw = nil
        if hudEnabled { showHUD() }
        installAbortMonitor()
        onGrant?(true)
        caption("Has the mouse")
        grantTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, self.grantActive else { return }
            self.pendingNotice = "The minute with the mouse is over; it went back to the user. Continue in the background if you can."
            self.leaveGrant(reason: "The minute is up")
        }
        Log.info("control: grant began")
    }

    private func leaveGrant(reason: String) {
        guard grantActive else { return }
        grantActive = false
        grantTask?.cancel(); grantTask = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for p in huds { p.orderOut(nil) }
        huds.removeAll()
        captions.removeAll()
        if let ladder { space = ladder.space }
        conflict?.install()
        if active, !stopped { peek?.phase = .working }
        onGrant?(false)
        if let userApp, NSWorkspace.shared.frontmostApplication?.processIdentifier != userApp.processIdentifier { userApp.activate() }
        caption(reason)
        Log.info("control: grant ended (\(reason))")
    }

    // MARK: geometry

    /// Screenshot pixels per point of the capture space (the display, or the target window in the background lane).
    private var scale: CGFloat { space.pxPerPt }

    /// Model `[x, y]` (screenshot pixels) -> CG global point.
    private func cgPoint(_ coord: Any?) -> CGPoint? {
        guard let arr = coord as? [Any], arr.count == 2,
              let x = (arr[0] as? NSNumber)?.doubleValue, let y = (arr[1] as? NSNumber)?.doubleValue else { return nil }
        return space.cg(fromModel: x, y)
    }

    private func modelPoint(fromAppKit p: NSPoint) -> (Int, Int) {
        space.model(fromCG: CaptureSpace.cg(p))
    }

    private func appKit(_ cg: CGPoint) -> NSPoint { CaptureSpace.appKit(cg) }

    // MARK: actions

    func perform(_ name: String, _ input: [String: Any]) async -> ToolResult {
        if Task.isCancelled { return .text("Stopped.", isError: true) }
        if lane == .background, target == nil, !active { return .text("No target window. Call target_window to list the windows and pick one.", isError: true) }
        if !active { begin() }
        if interrupted { return .text("Stopped.", isError: true) }
        if let n = pendingNotice { pendingNotice = nil; return .text(n, isError: true) }
        if lane == .background, !grantActive {
            guard let ladder else { return .text("No target window. Call target_window to list the windows and pick one.", isError: true) }
            actionRunning = true
            defer { actionRunning = false }
            let r = await ladder.run(name, input)
            return stopped ? .text("Stopped.", isError: true) : r
        }
        let r = await performForeground(name, input)
        if grantRevoked { grantRevoked = false; if let n = pendingNotice { pendingNotice = nil; return .text(n, isError: true) } }
        return r
    }

    private func performForeground(_ name: String, _ input: [String: Any]) async -> ToolResult {
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
            if interrupted { return .text("Stopped.", isError: true) }
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
            return interrupted ? .text("Stopped.", isError: true) : .text("OK")
        case "left_click_drag":
            guard let a = cgPoint(input["start_coordinate"]), let b = cgPoint(input["coordinate"]) else { return .text("Invalid coordinates.", isError: true) }
            caption("Dragging")
            await glide(to: a)
            if interrupted { return .text("Stopped.", isError: true) }
            post(mouse(.leftMouseDown, a, .left, flags: Self.flags(input["text"] as? String)))
            await sleep(0.08)
            await glide(to: b, dragging: true)
            await sleep(0.08)
            post(mouse(.leftMouseUp, interrupted ? (currentCG() ?? a) : b, .left))
            return interrupted ? .text("Stopped.", isError: true) : .text("OK")
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
            if interrupted { return .text("Stopped.", isError: true) }
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
                if interrupted { return .text("Stopped.", isError: true) }
                guard press(combo) else { return .text("Unknown key: \(combo)", isError: true) }
                await sleep(0.05)
            }
            return interrupted ? .text("Stopped.", isError: true) : .text("OK")
        case "hold_key":
            guard let combo = input["text"] as? String, let (code, flags) = Self.parseCombo(combo) else { return .text("Unknown key.", isError: true) }
            let d = min(30, (input["duration"] as? NSNumber)?.doubleValue ?? 1)
            caption("Holding \(combo)")
            post(key(code, down: true, flags: flags)); await sleep(d); post(key(code, down: false, flags: flags))
            return interrupted ? .text("Stopped.", isError: true) : .text("OK")
        case "wait":
            let d = min(30, (input["duration"] as? NSNumber)?.doubleValue ?? 1)
            caption("Waiting \(Int(d))s")
            await sleep(d)
            return interrupted ? .text("Stopped.", isError: true) : .text("OK")
        default:
            return .text("Unsupported action \(name)", isError: true)
        }
    }

    /// Background lane: list the candidate windows, or switch the job to another one.
    func targetWindow(_ input: [String: Any]) async -> ToolResult {
        if let sel = (input["select"] as? NSNumber)?.intValue {
            switch await TargetWindow.resolve(windowID: CGWindowID(max(0, sel))) {
            case .failure(let e): return .text(e.localizedDescription, isError: true)
            case .success(var t):
                t.sharedWithHuman = Self.humanInAnotherWindow(of: t)
                if active, lane == .background, let ladder {
                    ladder.target = t
                    ghost?.attach(targetFrameCG: t.frameCG)
                    bindTarget(t)
                    peek?.appName = t.appName
                    peek?.windowTitle = t.title
                    space = ladder.space
                } else {
                    target = t
                }
                Log.info("control: target switched to \(t.appName) “\(t.title.prefix(60))”")
                return .text("Now working in \(t.appName) — “\(t.title)”. Take a screenshot.")
            }
        }
        let current = ladder?.target.cgWindowID ?? target?.cgWindowID
        let lines = TargetWindow.list().map { ($0.id == Int(current ?? 0) ? "* " : "  ") + $0.line }
        return .text(lines.isEmpty ? "No windows found." : "Windows (* = current target):\n" + lines.joined(separator: "\n"))
    }

    /// Background lane: press a control by the id from find_on_screen.
    func clickElement(_ input: [String: Any]) async -> ToolResult {
        if Task.isCancelled { return .text("Stopped.", isError: true) }
        guard lane == .background else { return .text("click_element works in the background lane; click by coordinates here.", isError: true) }
        if target == nil, !active { return .text("No target window. Call target_window to list the windows and pick one.", isError: true) }
        if !active { begin() }
        if interrupted { return .text("Stopped.", isError: true) }
        guard let ladder else { return .text("No target window.", isError: true) }
        guard let id = (input["id"] as? NSNumber)?.intValue else { return .text("Missing id.", isError: true) }
        actionRunning = true
        defer { actionRunning = false }
        let r = await ladder.clickElement(id: id)
        return stopped ? .text("Stopped.", isError: true) : r
    }

    /// Accessibility search of the working window; centers reported in screenshot pixels.
    func find(_ query: String) -> ToolResult {
        if lane == .background, !grantActive {
            if target == nil, !active { return .text("No target window. Call target_window to list the windows and pick one.", isError: true) }
            if !active { begin() }
            guard let ladder else { return .text("No target window.", isError: true) }
            return ladder.find(query)
        }
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
            if interrupted { return }
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
            if interrupted { return }
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

    /// Cancelling the CLI request also stops native actions. Release events still
    /// run so an interrupted drag or held key cannot leave a button pressed.
    private var interrupted: Bool {
        if Task.isCancelled { stop(reason: "request cancelled") }
        return stopped || Task.isCancelled || grantRevoked
    }

    private func sleep(_ s: Double) async {
        do { try await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }
        catch { stop(reason: "request cancelled") }
    }

    private func caption(_ s: String) {
        onCaption?(s)
        peek?.caption = s
        let line = hudLine(s)
        for c in captions { c.string = line }
    }

    private func hudLine(_ s: String) -> String {
        grantActive ? "Familiar has the mouse for a moment · \(s) · move it or press Esc to take it back"
                    : "Familiar is controlling · \(s) · move the mouse or press Esc to stop"
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
                                                              text: hudLine(grantActive ? "Has the mouse" : "Getting ready"))
                layer.addSublayer(pill)
                captions.append(text)
            }
            p.contentView = v
            p.orderFrontRegardless()
            huds.append(p)
        }
    }
}
