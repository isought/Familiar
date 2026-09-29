import AppKit

/// Coordinate clicks in a background window. A mouse event posted to a process is dropped unless AppKit believes
/// the app is active, so each click is bracketed by a SkyLight "application activated" / "deactivated" event record
/// that only the target sees: the human's frontmost app never changes. Private SkyLight SPI resolved with dlsym
/// (this is the only file allowed to); behind Config.backgroundPreciseClicks and an in-process self-test.
@MainActor final class SkyLightClick {
    static let shared = SkyLightClick()
    enum State: Equatable { case untested, ready, disabled(String) }
    private(set) var state: State = .untested
    private(set) var recordOutstanding = false      // an activation record was posted and not yet withdrawn
    var onRecordAborted: (() -> Void)?

    private var recordTarget: (pid: pid_t, windowID: CGWindowID)?   // who the outstanding record went to

    /// Pure. The 0xf8-byte event record: b[0x04]=0xf8 (length), b[0x08]=0x0d (NSAppKitDefined), b[0x8a]= activate ?
    /// 0x01 : 0x02 (NSEvent subtype applicationActivated / applicationDeactivated), windowID little-endian at 0x3c.
    nonisolated static func record(windowID: CGWindowID, activate: Bool) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 0xf8)
        b[0x04] = 0xf8
        b[0x08] = 0x0d
        b[0x8a] = activate ? 0x01 : 0x02
        let w = UInt32(windowID)
        for i in 0..<4 { b[0x3c + i] = UInt8(truncatingIfNeeded: w >> (8 * UInt32(i))) }
        return b
    }

    /// Pure. macOS 14.0 ..< 27.0: the record layout was verified on 14–26; anything newer is untested.
    nonisolated static func supportedOS(_ v: OperatingSystemVersion) -> Bool {
        v.majorVersion >= 14 && v.majorVersion < 27
    }

    /// dlsym(RTLD_DEFAULT) for SLPSPostEventRecordTo (SkyLight), GetProcessForPID, CGEventSetWindowLocation.
    nonisolated static var symbolsAvailable: Bool { SPI.symbols != nil }

    /// Runs once per launch when `flagOn`: OS gate, symbols, then the in-process self-test. Sets `state`; logs one
    /// line "skylight: …". Returns state == .ready. With the flag off nothing runs and `state` stays untested so a
    /// later call (the user turned it on in Settings) still tests.
    func prepare(flagOn: Bool) async -> Bool {
        guard flagOn else { return false }
        guard state == .untested else { return state == .ready }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        guard Self.supportedOS(v) else { return disable("macOS \(v.majorVersion).\(v.minorVersion) is outside the tested range") }
        guard Self.symbolsAvailable else { return disable("SkyLight symbols missing") }
        // Deactivating ourselves while the human is in Noteling would drop their focus; try again next time.
        if NSApplication.shared.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            Log.info("skylight: self-test deferred (Noteling is active)")
            return false
        }
        let t0 = Date()
        if let failure = await selfTest() { return disable(failure) }
        state = .ready
        Log.info("skylight: ready (self-test passed in \(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        return true
    }

    /// record(on) → stamped primer click at the point → `count` clicks (mouseEventClickState 1…count, 40 ms gaps) →
    /// record(off), with a 400 ms watchdog that re-posts the deactivation. The primer click is swallowed by views
    /// that refuse first mouse (text views) and only makes the window key; the real clicks follow it. After
    /// deactivation the target's kAXFrontmost must drop; if it stays up after a second deactivation the feature is
    /// disabled rather than leaving an app that thinks it is active. Returns true when the sequence completed and the
    /// record dropped.
    func click(target: TargetWindow, globalCG: CGPoint, local: CGPoint, button: CGMouseButton, count: Int, flags: CGEventFlags) async -> Bool {
        guard state == .ready, count >= 1, !recordOutstanding else { return false }
        let pid = target.pid, wid = target.cgWindowID
        guard postRecord(pid: pid, windowID: wid, activate: true) else { return false }
        recordOutstanding = true
        recordTarget = (pid, wid)
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, self.recordOutstanding else { return }
            self.withdrawRecord()
            Log.info("skylight: record leaked")
        }
        let completed = await clickSequence(pid: pid, windowID: wid, globalCG: globalCG, local: local, button: button, count: count, flags: flags)
        watchdog.cancel()
        // Verify the record dropped: AppKit answers kAXFrontmost from NSApp.isActive, which the record flipped.
        await sleep(ms: 30)
        if axBool(target.axApp, kAXFrontmostAttribute) == true {
            _ = postRecord(pid: pid, windowID: wid, activate: false)
            await sleep(ms: 60)
            if axBool(target.axApp, kAXFrontmostAttribute) == true {
                _ = disable("activation record leaked")
                return false
            }
        }
        return completed
    }

    /// Post the deactivation record now (called by the conflict monitor on a human keyDown).
    func abortRecord(target: TargetWindow) {
        guard recordOutstanding else { return }
        withdrawRecord(fallback: (target.pid, target.cgWindowID))
        Log.info("skylight: record aborted")
        onRecordAborted?()
    }

    // MARK: private: records

    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias PostEventRecordFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, Double, Double) -> Void

    private struct Symbols {
        let postRecord: PostEventRecordFn
        let getProcess: GetProcessForPIDFn
        let setWindowLocation: SetWindowLocationFn
    }

    private enum SPI {
        /// Resolved once, lazily. SkyLight must be loaded before its symbol resolves through RTLD_DEFAULT (-2 on
        /// Darwin); GetProcessForPID lives in HIServices, which the app links via Carbon, so its dlopen is a fallback.
        static let symbols: Symbols? = {
            let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
            guard dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) != nil else { return nil }
            func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(rtldDefault, name) }
            if sym("GetProcessForPID") == nil {
                _ = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
            }
            guard let post = sym("SLPSPostEventRecordTo"), let gp = sym("GetProcessForPID"), let loc = sym("CGEventSetWindowLocation") else { return nil }
            return Symbols(postRecord: unsafeBitCast(post, to: PostEventRecordFn.self),
                           getProcess: unsafeBitCast(gp, to: GetProcessForPIDFn.self),
                           setWindowLocation: unsafeBitCast(loc, to: SetWindowLocationFn.self))
        }()
    }

    private func postRecord(pid: pid_t, windowID: CGWindowID, activate: Bool) -> Bool {
        guard let s = SPI.symbols else { return false }
        var psn = ProcessSerialNumber()
        guard s.getProcess(pid, &psn) == noErr else { return false }
        var bytes = Self.record(windowID: windowID, activate: activate)
        let err = bytes.withUnsafeMutableBufferPointer { buf -> CGError in
            guard let base = buf.baseAddress else { return .failure }
            return withUnsafePointer(to: &psn) { s.postRecord($0, base) }
        }
        return err == .success
    }

    /// Deactivate whoever holds the outstanding record (or `fallback` when we lost track) and clear the flag.
    private func withdrawRecord(fallback: (pid: pid_t, windowID: CGWindowID)? = nil) {
        if let t = recordTarget ?? fallback { _ = postRecord(pid: t.pid, windowID: t.windowID, activate: false) }
        recordOutstanding = false
        recordTarget = nil
    }

    private func disable(_ reason: String) -> Bool {
        state = .disabled(reason)
        Log.info("skylight: disabled: \(reason)")
        return false
    }

    // MARK: private: clicks

    private static func mouseTypes(_ button: CGMouseButton) -> (down: CGEventType, up: CGEventType) {
        switch button {
        case .right: return (.rightMouseDown, .rightMouseUp)
        case .center: return (.otherMouseDown, .otherMouseUp)
        default: return (.leftMouseDown, .leftMouseUp)
        }
    }

    private func mouse(_ type: CGEventType, pid: pid_t, windowID: CGWindowID, globalCG: CGPoint, local: CGPoint,
                       button: CGMouseButton, clickState: Int, flags: CGEventFlags) {
        guard let e = CGEvent(mouseEventSource: PidEvents.source, mouseType: type, mouseCursorPosition: globalCG, mouseButton: button) else { return }
        e.flags = flags
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        PidEvents.stamp(e, windowID: windowID, globalCG: globalCG, local: local)
        PidEvents.post(e, to: pid)
    }

    /// mouseMoved, primer click, then the counted clicks; the record is withdrawn on every exit. False when the
    /// record was aborted underneath us (a human keyDown) before the last click went out.
    private func clickSequence(pid: pid_t, windowID: CGWindowID, globalCG: CGPoint, local: CGPoint, button: CGMouseButton, count: Int, flags: CGEventFlags) async -> Bool {
        defer { if recordOutstanding { withdrawRecord() } }
        let types = Self.mouseTypes(button)
        func send(_ type: CGEventType, _ state: Int, _ f: CGEventFlags) {
            mouse(type, pid: pid, windowID: windowID, globalCG: globalCG, local: local, button: button, clickState: state, flags: f)
        }
        send(.mouseMoved, 0, [])
        await sleep(ms: 20)
        guard recordOutstanding else { return false }
        send(types.down, 1, [])                      // primer: unmodified so a swallowed click carries no side effect
        await sleep(ms: 40)
        send(types.up, 1, [])
        await sleep(ms: 40)
        for i in 1...count {
            guard recordOutstanding else { return false }
            send(types.down, i, flags)
            await sleep(ms: 40)
            send(types.up, i, flags)
            if i < count { await sleep(ms: 40) }
        }
        return recordOutstanding
    }

    // MARK: private: self-test

    /// A 1x1 pt non-activating panel at alpha 0.01 whose view refuses first mouse, like a text view. Post the
    /// activation record to our own pid/window, a stamped primer click and a click via postToPid(getpid()); pass when
    /// mouseDown arrives with isKeyWindow within 150 ms, the frontmost app is unchanged, and NSApp.isActive returns
    /// to false within 100 ms of the deactivation record. Returns the failure reason, nil on pass.
    private func selfTest() async -> String? {
        let front0 = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screen = NSScreen.main ?? NSScreen.screens.first
        let origin = screen.map { NSPoint(x: $0.visibleFrame.minX + 2, y: $0.visibleFrame.minY + 2) } ?? NSPoint(x: 2, y: 2)
        let panel = ProbePanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.alphaValue = 0.01
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = ProbeView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        panel.contentView = view
        let hit = Hit()
        view.onMouseDown = { key in hit.mouseDown = true; hit.wasKey = key }
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.close()
            if NSApplication.shared.isActive, let wid = hit.windowID { _ = postRecord(pid: getpid(), windowID: wid, activate: false) }
        }
        await sleep(ms: 50)   // let the window server register the panel
        let wid = CGWindowID(panel.windowNumber)
        hit.windowID = wid
        guard panel.windowNumber > 0 else { return "self-test panel has no window number" }
        let globalCG = CaptureSpace.cg(NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        let local = CGPoint(x: 0.5, y: 0.5)
        let pid = getpid()

        guard postRecord(pid: pid, windowID: wid, activate: true) else { return "activation record refused" }
        await sleep(ms: 30)
        func send(_ type: CGEventType, _ state: Int) {
            mouse(type, pid: pid, windowID: wid, globalCG: globalCG, local: local, button: .left, clickState: state, flags: [])
        }
        send(.mouseMoved, 0)
        await sleep(ms: 20)
        send(.leftMouseDown, 1)       // primer: swallowed by acceptsFirstMouse == false, makes the panel key
        await sleep(ms: 40)
        send(.leftMouseUp, 1)
        await sleep(ms: 40)
        send(.leftMouseDown, 1)
        await sleep(ms: 40)
        send(.leftMouseUp, 1)
        let deadline = Date().addingTimeInterval(0.15)
        while !hit.mouseDown, Date() < deadline { await sleep(ms: 10) }
        var failure: String?
        if !hit.mouseDown { failure = "click did not arrive" }
        else if !hit.wasKey { failure = "click arrived without key window" }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != front0 { failure = failure ?? "frontmost app changed" }

        _ = postRecord(pid: pid, windowID: wid, activate: false)
        let off = Date().addingTimeInterval(0.1)
        while NSApplication.shared.isActive, Date() < off { await sleep(ms: 10) }
        if NSApplication.shared.isActive { failure = failure ?? "deactivation record ignored" }
        return failure
    }

    // MARK: private: helpers

    private func axBool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        return (v as? Bool) ?? (v as? NSNumber)?.boolValue
    }

    private func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
}

/// Borderless panels refuse key status by default; the self-test needs the panel to take it without activating us.
private final class ProbePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ProbeView: NSView {
    var onMouseDown: ((Bool) -> Void)?
    /// Like NSTextView: a click into a non-key window is swallowed, which is exactly what the primer click is for.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func mouseDown(with event: NSEvent) { onMouseDown?(window?.isKeyWindow ?? false) }
}

private final class Hit {
    var mouseDown = false
    var wasKey = false
    var windowID: CGWindowID?
}
