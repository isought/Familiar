import AppKit

/// Stops or pauses a background session when the human's input would collide with the target window.
/// The human keeps the mouse and keyboard while Familiar drives one window in the background, so most input is
/// none of our business; only a click into the target, or switching to its app, ends the job. Typing and a held
/// mouse button pause it briefly so posted keys never interleave with the human's.
@MainActor final class ConflictMonitor {
    enum Verdict: Equatable { case ignore, stop(String), pause(TimeInterval), dirty }
    struct Input: Equatable {
        enum Kind: Equatable { case mouseDown, mouseUp, scroll, keyDown(UInt16), mouseMoved, appActivated(pid_t) }
        var kind: Kind
        var locationCG: CGPoint
        var isOurs: Bool              // eventSourceUserData == ComputerController.tag
    }

    /// Pure classification. `topWindowAt` resolves the topmost on-screen window id at a CG point (nil = none).
    /// STOP: mouseDown whose top window is the target; appActivated(target pid) unless we asked for it. PAUSE 0.5 s:
    /// any keyDown, a mouseDown elsewhere (the button is held). PAUSE 1.5 s: keyDown while an activation record is
    /// outstanding (the caller aborts the record). DIRTY: scroll with the target on top. IGNORE: everything else.
    nonisolated static func classify(_ e: Input, targetPID: pid_t, targetWindowID: CGWindowID, targetFrameCG: CGRect, appName: String,
                         topWindowAt: (CGPoint) -> CGWindowID?, recordOutstanding: Bool, expectingActivation: Bool) -> Verdict {
        if e.isOurs { return .ignore }
        // Only ask the window server when the point is inside the target's frame: outside it the target cannot be on top.
        func onTarget() -> Bool { targetFrameCG.contains(e.locationCG) && topWindowAt(e.locationCG) == targetWindowID }
        switch e.kind {
        case .mouseDown:
            return onTarget() ? .stop("you clicked in \(appName)") : .pause(0.5)
        case .keyDown:
            return .pause(recordOutstanding ? 1.5 : 0.5)
        case .scroll:
            return onTarget() ? .dirty : .ignore
        case .appActivated(let pid):
            return pid == targetPID && !expectingActivation ? .stop("you switched to \(appName)") : .ignore
        case .mouseUp, .mouseMoved:
            return .ignore
        }
    }

    /// The topmost on-screen window at a CG point, excluding `excludingPID` (our own overlays sit above the target
    /// but let clicks through), layer < 20 (below menus and popovers' shields), alpha >= 0.05.
    nonisolated static func topWindow(atCG p: CGPoint, excludingPID: pid_t) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {   // front to back
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != excludingPID else { continue }
            guard let layer = w[kCGWindowLayer as String] as? Int, layer < 20 else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            guard let bdict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: bdict), bounds.contains(p),
                  let id = w[kCGWindowNumber as String] as? Int else { continue }
            return CGWindowID(id)
        }
        return nil
    }

    var targetFrameCG: CGRect             // refreshed by the owner as the window moves
    private(set) var pausedUntil: Date?
    private(set) var mouseButtonHeld = false

    private let targetPID: pid_t
    private let targetWindowID: CGWindowID
    private let appName: String
    private let recordOutstanding: () -> Bool
    private let expectingActivation: () -> Bool
    private let onStop: (String) -> Void
    private let onDirty: () -> Void
    private let onAbortRecord: () -> Void
    private var monitor: Any?
    private var activation: NSObjectProtocol?
    private var stopped = false

    init(target: TargetWindow, recordOutstanding: @escaping () -> Bool, expectingActivation: @escaping () -> Bool,
         onStop: @escaping (String) -> Void, onDirty: @escaping () -> Void, onAbortRecord: @escaping () -> Void) {
        targetPID = target.pid
        targetWindowID = target.cgWindowID
        appName = target.appName
        targetFrameCG = target.frameCG
        self.recordOutstanding = recordOutstanding
        self.expectingActivation = expectingActivation
        self.onStop = onStop
        self.onDirty = onDirty
        self.onAbortRecord = onAbortRecord
    }

    /// NSEvent global monitor (mouseDown/Up, scroll, keyDown, mouseMoved) + NSWorkspace didActivate. Global monitors
    /// never see events delivered to Familiar itself, and events posted with postToPid never reach them at all.
    func install() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
                                           .scrollWheel, .keyDown, .mouseMoved]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            guard let self else { return }
            let kind: Input.Kind
            switch e.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .mouseUp
            case .scrollWheel: kind = .scroll
            case .keyDown: kind = .keyDown(e.keyCode)
            default: kind = .mouseMoved
            }
            let ours = e.cgEvent?.getIntegerValueField(.eventSourceUserData) == ComputerController.tag
            self.handle(Input(kind: kind, locationCG: CaptureSpace.cg(NSEvent.mouseLocation), isOurs: ours))
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                self.handle(Input(kind: .appActivated(pid), locationCG: .zero, isOurs: false))
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
    }

    /// True when no pause is in effect (waits up to `timeout`, polling 50 ms); false on timeout.
    func waitUntilClear(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while paused {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    private var paused: Bool {
        // A missed mouseUp (the drag ended over Familiar's own window) must not pause forever: trust the hardware state.
        if mouseButtonHeld, NSEvent.pressedMouseButtons == 0 { mouseButtonHeld = false }
        if let until = pausedUntil, until > Date() { return true }
        return mouseButtonHeld
    }

    private func handle(_ e: Input) {
        guard !stopped else { return }
        if !e.isOurs {
            if e.kind == .mouseDown { mouseButtonHeld = true }
            if e.kind == .mouseUp { mouseButtonHeld = false }
        }
        let verdict = Self.classify(e, targetPID: targetPID, targetWindowID: targetWindowID, targetFrameCG: targetFrameCG, appName: appName,
                                    topWindowAt: { Self.topWindow(atCG: $0, excludingPID: ProcessInfo.processInfo.processIdentifier) },
                                    recordOutstanding: recordOutstanding(), expectingActivation: expectingActivation())
        switch verdict {
        case .ignore:
            break
        case .stop(let reason):
            stopped = true
            Log.info("conflict: stop (\(reason))")
            onStop(reason)
        case .pause(let seconds):
            let until = Date().addingTimeInterval(seconds)
            if pausedUntil.map({ $0 < until }) ?? true { pausedUntil = until }
            // A human keystroke while the activation record is up would land in the target: drop the record first.
            if case .keyDown = e.kind, recordOutstanding() { onAbortRecord() }
        case .dirty:
            onDirty()
        }
    }
}
