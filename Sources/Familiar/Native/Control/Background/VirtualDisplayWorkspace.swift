import AppKit
import ApplicationServices
import FamiliarVirtualDisplayBridge

/// One execution's private display. Moving a window never activates its app. A finished workspace cannot be reused.
@MainActor
final class VirtualDisplayWorkspace {
    enum Failure: LocalizedError, Equatable {
        case closed
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .closed: return "The task workspace has already closed."
            case .unavailable(let message): return message
            }
        }
    }

    struct DisplayState: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let isMain: Bool
        let isMirrored: Bool
    }

    struct WindowState {
        let frame: CGRect
        let isMinimized: Bool
        let isFullScreen: Bool
        let canMove: Bool
    }

    /// The bridge handle must survive until every parked window has had a restoration attempt.
    final class DisplayHandle {
        let id: CGDirectDisplayID
        private var release: (() -> Void)?

        init(id: CGDirectDisplayID, invalidate: @escaping () -> Void) {
            self.id = id
            release = invalidate
        }

        @discardableResult func invalidate() -> Bool {
            guard let release else { return false }
            self.release = nil
            release()
            return true
        }
    }

    struct Adapters {
        var displays: () throws -> [DisplayState]
        var createDisplay: (_ width: UInt32, _ height: UInt32) async throws -> DisplayHandle
        var arrangeDisplay: (_ id: CGDirectDisplayID, _ origin: CGPoint, _ preserving: [DisplayState]) throws -> Void
        var restoreDisplayLayout: (_ original: [DisplayState]) throws -> Void
        var readWindow: (TargetWindow) throws -> WindowState
        var moveWindow: (TargetWindow, CGRect) throws -> Void
        var setMinimized: (TargetWindow, Bool) throws -> Void
        var pause: () async throws -> Void
        var publishesActiveDisplay = false
    }

    private struct ReadyDisplay {
        let handle: DisplayHandle
        let frame: CGRect
    }

    private struct WindowRecord {
        let target: TargetWindow
        let original: WindowState
        let originalDisplayID: CGDirectDisplayID?
        var needsRestore = true
        var parked = false
    }

    /// Presentation and display-under-pointer logic should exclude this display.
    static private(set) var activeDisplayID: CGDirectDisplayID?
    var displayID: CGDirectDisplayID? { display?.handle.id ?? creatingDisplayID }

    private let adapters: Adapters
    private var display: ReadyDisplay?
    private var creatingDisplayID: CGDirectDisplayID?
    private var creation: (id: UUID, task: Task<ReadyDisplay, Error>)?
    private var windows: [CGWindowID: WindowRecord] = [:]
    private var generation = 0
    private var finished = false

    convenience init() { self.init(adapters: .live) }

    init(adapters: Adapters) { self.adapters = adapters }

    /// Input loans may activate only a window that is still wholly on this workspace.
    /// Reading through the adapters also keeps permission tests independent of real monitors.
    func parkedDisplayID(for target: TargetWindow) throws -> CGDirectDisplayID {
        guard !finished, let display, windows[target.cgWindowID]?.parked == true else {
            throw Failure.unavailable("The task window is not on its separate display.")
        }
        let state = try adapters.readWindow(target)
        guard !state.isMinimized, !state.isFullScreen, contains(state.frame, in: display.frame) else {
            throw Failure.unavailable("The task window left its separate display. No input was borrowed.")
        }
        return display.handle.id
    }

    /// True when this call moves the target; false when it is already parked in this workspace.
    func park(_ target: TargetWindow) async throws -> Bool {
        let token = generation
        try checkCurrent(token)
        var state = try adapters.readWindow(target)
        try validateWindow(state)
        if let record = windows[target.cgWindowID], record.parked {
            guard let display, contains(state.frame, in: display.frame), !state.isMinimized else {
                throw Failure.unavailable("The target window left its task workspace. Stop the task before moving it again.")
            }
            return false
        }

        let originalState = state
        let originalScreens = try adapters.displays().filter { $0.id != displayID }

        let ready = try await ensureDisplay(for: state.frame.size, generation: token)
        try checkCurrent(token)
        // Creation can suspend: preserve the window's state as it is now, before any window mutation.
        state = try adapters.readWindow(target)
        try validateWindow(state)
        let destination = CGRect(x: ready.frame.minX + 32, y: ready.frame.minY + 64,
                                 width: state.frame.width, height: state.frame.height)
        guard contains(destination.insetBy(dx: -16, dy: -16), in: ready.frame) else {
            throw Failure.unavailable("This window is too large for the task workspace. Make it smaller before trying again.")
        }
        if windows[target.cgWindowID] == nil {
            let originalDisplay = originalScreens.max { intersectionArea(originalState.frame, $0.frame) < intersectionArea(originalState.frame, $1.frame) }
            windows[target.cgWindowID] = WindowRecord(target: target, original: originalState, originalDisplayID: originalDisplay?.id)
        }
        windows[target.cgWindowID]?.needsRestore = true
        do {
            if state.isMinimized { try adapters.setMinimized(target, false) }
            try adapters.moveWindow(target, destination)
            for attempt in 0..<20 {
                try checkCurrent(token)
                let actual = try adapters.readWindow(target)
                if !actual.isMinimized, close(actual.frame, destination) {
                    windows[target.cgWindowID]?.parked = true
                    Log.info("workspace: parked window=\(target.cgWindowID) display=\(ready.handle.id) frame=\(actual.frame)")
                    return true
                }
                if attempt < 19 { try await adapters.pause() }
            }
            throw Failure.unavailable("The app did not move its window into the task workspace. No background action was attempted.")
        } catch {
            // finish() may already have restored this window while a verification wait was suspended.
            if generation == token, !finished {
                do { try restore(windowID: target.cgWindowID) }
                catch { Log.info("workspace: could not restore after failed parking: \(error.localizedDescription)") }
            }
            throw error
        }
    }

    /// Temporarily returns a target for an explicitly approved mouse grant. Keeps its original restoration record.
    func restore(windowID: CGWindowID, forInteraction: Bool = false) throws {
        guard var record = windows[windowID], record.needsRestore else { return }
        let screens = try adapters.displays().filter { $0.id != displayID }
        guard !screens.isEmpty else { throw Failure.unavailable("No user display is available to restore the task window.") }
        let screen = screens.first { $0.id == record.originalDisplayID }
            ?? screens.max { intersectionArea(record.original.frame, $0.frame) < intersectionArea(record.original.frame, $1.frame) }!
        let destination = Self.restorationFrame(record.original.frame, on: screen.frame)
        let current = try adapters.readWindow(record.target)
        guard !current.isFullScreen else { throw Failure.unavailable("The task window entered full screen and could not be restored automatically.") }
        if current.isMinimized { try adapters.setMinimized(record.target, false) }
        try adapters.moveWindow(record.target, destination)
        let minimized = forInteraction ? false : record.original.isMinimized
        try adapters.setMinimized(record.target, minimized)
        let restored = try adapters.readWindow(record.target)
        guard close(restored.frame, destination), restored.isMinimized == minimized else {
            throw Failure.unavailable("The app has not restored its task window yet.")
        }
        record.needsRestore = forInteraction
        record.parked = false
        windows[windowID] = record
        Log.info("workspace: restored window=\(windowID) frame=\(restored.frame) minimized=\(minimized) forInteraction=\(forInteraction)")
    }

    /// Best effort restoration always precedes display release. Failed records remain available for a later retry.
    func finish() {
        if !finished {
            finished = true
            generation += 1
            creation?.task.cancel()
        }
        for id in windows.keys.sorted() {
            do {
                try restore(windowID: id)
                windows.removeValue(forKey: id)
            } catch {
                Log.info("workspace: restoration failed: \(error.localizedDescription)")
            }
        }
        if let display {
            let layout = try? adapters.displays().filter { $0.id != display.handle.id }
            Self.release(display.handle, restoring: layout, adapters: adapters)
        }
        display = nil
    }

    private func ensureDisplay(for size: CGSize, generation token: Int) async throws -> ReadyDisplay {
        if let display { return display }
        if creation == nil {
            let original = try adapters.displays()
            guard !original.isEmpty else { throw Failure.unavailable("No user display is available for the task workspace.") }
            guard !original.contains(where: \.isMirrored) else {
                throw Failure.unavailable("The task workspace is unavailable while displays are mirrored.")
            }
            let dimensions = try Self.dimensions(for: size, existing: original)
            let adapters = self.adapters
            let id = UUID()
            let task = Task { @MainActor [weak self] () throws -> ReadyDisplay in
                Log.info("workspace: creating display \(Int(dimensions.width))x\(Int(dimensions.height))")
                let handle = try await adapters.createDisplay(UInt32(dimensions.width), UInt32(dimensions.height))
                do {
                    try Task.checkCancellation()
                    guard let self, !self.finished, self.generation == token else { throw Failure.closed }
                    self.creatingDisplayID = handle.id
                    if adapters.publishesActiveDisplay { Self.activeDisplayID = handle.id }
                    _ = try await Self.waitForDisplay(handle.id, adapters: adapters)
                    let rightmost = original.max { $0.frame.maxX < $1.frame.maxX }!
                    let origin = CGPoint(x: rightmost.frame.maxX, y: rightmost.frame.minY)
                    try adapters.arrangeDisplay(handle.id, origin, original)
                    let frame = try await Self.waitForDisplay(handle.id, expected: CGRect(origin: origin, size: dimensions), adapters: adapters)
                    let current = try adapters.displays().filter { $0.id != handle.id }
                    guard Self.unchangedDisplays(original, current) else {
                        throw Failure.unavailable("Creating the task workspace changed the existing display layout; the workspace was closed.")
                    }
                    try Task.checkCancellation()
                    Log.info("workspace: ready display=\(handle.id) frame=\(frame)")
                    return ReadyDisplay(handle: handle, frame: frame)
                } catch {
                    Self.release(handle, restoring: original, adapters: adapters)
                    if self?.creatingDisplayID == handle.id { self?.creatingDisplayID = nil }
                    throw error
                }
            }
            creation = (id, task)
        }
        let pending = creation!
        do {
            let ready = try await pending.task.value
            guard generation == token, !finished else {
                let layout = try? adapters.displays().filter { $0.id != ready.handle.id }
                Self.release(ready.handle, restoring: layout, adapters: adapters)
                creatingDisplayID = nil
                throw Failure.closed
            }
            if display == nil { display = ready }
            if creation?.id == pending.id { creation = nil }
            creatingDisplayID = nil
            try Task.checkCancellation()
            return ready
        } catch {
            if creation?.id == pending.id { creation = nil }
            throw error
        }
    }

    private func checkCurrent(_ token: Int) throws {
        guard !finished, generation == token else { throw Failure.closed }
        try Task.checkCancellation()
    }

    private func validateWindow(_ state: WindowState) throws {
        guard !state.isFullScreen else { throw Failure.unavailable("Full-screen windows cannot move into the task workspace. Leave full screen first.") }
        guard state.canMove else { throw Failure.unavailable("This app does not allow its window to move into the task workspace.") }
        guard state.frame.width > 0, state.frame.height > 0 else { throw Failure.unavailable("The target window no longer has a usable frame.") }
    }

    private static func dimensions(for size: CGSize, existing: [DisplayState]) throws -> CGSize {
        let required = CGSize(width: ceil(size.width + 64), height: ceil(size.height + 96))
        guard required.width <= 4096, required.height <= 2560 else {
            throw Failure.unavailable("This window is too large for the task workspace (maximum 4096 × 2560). Make it smaller first.")
        }
        // Also fit normal windows from the existing monitors, so switching targets rarely needs a larger display.
        let width = max(1280, required.width, min(4096, (existing.map(\.frame.width).max() ?? 0) + 64))
        let height = max(900, required.height, min(2560, (existing.map(\.frame.height).max() ?? 0) + 96))
        return CGSize(width: ceil(width), height: ceil(height))
    }

    private static func waitForDisplay(_ id: CGDirectDisplayID, expected: CGRect? = nil, adapters: Adapters) async throws -> CGRect {
        for attempt in 0..<50 {
            try Task.checkCancellation()
            if let found = try adapters.displays().first(where: { $0.id == id }), found.frame.width > 0, found.frame.height > 0,
               expected.map({ close(found.frame, $0) }) ?? true { return found.frame }
            if attempt < 49 { try await adapters.pause() }
        }
        throw Failure.unavailable("The task display did not become ready. No window was moved.")
    }

    private static func unchangedDisplays(_ original: [DisplayState], _ current: [DisplayState]) -> Bool {
        original.count == current.count && original.allSatisfy { before in current.contains(before) }
    }

    private static func release(_ handle: DisplayHandle, restoring baseline: [DisplayState]?, adapters: Adapters) {
        guard handle.invalidate() else { return }
        Log.info("workspace: releasing display=\(handle.id)")
        if adapters.publishesActiveDisplay, activeDisplayID == handle.id { activeDisplayID = nil }
        guard let baseline else { return }
        do {
            let current = try adapters.displays().filter { $0.id != handle.id }
            guard !unchangedDisplays(baseline, current) else { return }
            // Never revive an unplugged monitor, override a new monitor, change modes, or break a mirror set.
            guard baseline.count == current.count, baseline.allSatisfy({ old in
                current.contains { $0.id == old.id && $0.frame.size == old.frame.size && $0.isMirrored == old.isMirrored }
            }), !current.contains(where: \.isMirrored) else {
                Log.info("workspace: display topology changed; skipping layout rollback")
                return
            }
            try adapters.restoreDisplayLayout(baseline)
            let restored = try adapters.displays().filter { $0.id != handle.id }
            Log.info(unchangedDisplays(baseline, restored) ? "workspace: restored user display layout" : "workspace: user display layout restoration could not be verified")
        } catch { Log.info("workspace: display layout rollback failed: \(error.localizedDescription)") }
    }

    static func restorationFrame(_ original: CGRect, on screen: CGRect) -> CGRect {
        let size = CGSize(width: min(original.width, screen.width), height: min(original.height, screen.height))
        return CGRect(x: min(max(original.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(original.minY, screen.minY), screen.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

private func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let intersection = a.intersection(b)
    return intersection.isNull ? 0 : intersection.width * intersection.height
}

private func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
}

private func contains(_ frame: CGRect, in display: CGRect) -> Bool {
    display.insetBy(dx: -2, dy: -2).contains(frame)
}

private extension VirtualDisplayWorkspace.Adapters {
    static var live: Self {
        Self(
            displays: {
                var count: UInt32 = 0
                guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw VirtualDisplayWorkspace.Failure.unavailable("Could not inspect the existing displays.") }
                var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
                guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { throw VirtualDisplayWorkspace.Failure.unavailable("Could not inspect the existing displays.") }
                return ids.prefix(Int(count)).map { id in
                    .init(id: id, frame: CGDisplayBounds(id), isMain: id == CGMainDisplayID(), isMirrored: CGDisplayIsInMirrorSet(id) != 0)
                }
            },
            createDisplay: { width, height in
                let bridge = try FAMVirtualDisplay(width: width, height: height)
                return .init(id: bridge.displayID) { bridge.invalidate() }
            },
            arrangeDisplay: { id, origin, existing in
                try configureOrigins(existing.map { ($0.id, $0.frame.origin) } + [(id, origin)])
            },
            restoreDisplayLayout: { original in
                try configureOrigins(original.map { ($0.id, $0.frame.origin) })
            },
            readWindow: strictWindowState,
            moveWindow: { target, desired in
                let current = try strictWindowState(target)
                if abs(current.frame.width - desired.width) > 2 || abs(current.frame.height - desired.height) > 2 {
                    var size = desired.size
                    guard let value = AXValueCreate(.cgSize, &size),
                          AXUIElementSetAttributeValue(target.axWindow, kAXSizeAttribute as CFString, value) == .success else {
                        throw VirtualDisplayWorkspace.Failure.unavailable("The app would not restore its window size.")
                    }
                }
                var point = desired.origin
                guard let value = AXValueCreate(.cgPoint, &point),
                      AXUIElementSetAttributeValue(target.axWindow, kAXPositionAttribute as CFString, value) == .success else {
                    throw VirtualDisplayWorkspace.Failure.unavailable("The app would not move its window.")
                }
            },
            setMinimized: { target, minimized in
                guard try strictBool(target.axWindow, attribute: kAXMinimizedAttribute) != minimized else { return }
                guard AXUIElementSetAttributeValue(target.axWindow, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success else {
                    throw VirtualDisplayWorkspace.Failure.unavailable("The app would not restore its window's minimized state.")
                }
            },
            pause: { try await Task.sleep(nanoseconds: 50_000_000) },
            publishesActiveDisplay: true
        )
    }
}

/// Unlike TargetWindow.refresh(), mutation verification must never accept a cached frame after an AX timeout.
private func strictWindowState(_ target: TargetWindow) throws -> VirtualDisplayWorkspace.WindowState {
    var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(target.axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(target.axWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
          let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
        throw VirtualDisplayWorkspace.Failure.unavailable("Could not read a fresh frame for the task window.")
    }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else {
        throw VirtualDisplayWorkspace.Failure.unavailable("The task window has no usable frame.")
    }
    var settable = DarwinBoolean(false)
    let canMove = AXUIElementIsAttributeSettable(target.axWindow, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
    return .init(frame: CGRect(origin: point, size: size),
                 isMinimized: try strictBool(target.axWindow, attribute: kAXMinimizedAttribute),
                 isFullScreen: try strictBool(target.axWindow, attribute: "AXFullScreen", unsupported: false), canMove: canMove)
}

private func strictBool(_ element: AXUIElement, attribute: String, unsupported: Bool? = nil) throws -> Bool {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    if result == .success, let number = value as? NSNumber { return number.boolValue }
    if result == .attributeUnsupported || result == .noValue, let unsupported { return unsupported }
    throw VirtualDisplayWorkspace.Failure.unavailable("Could not read the task window's \(attribute) state.")
}

private func configureOrigins(_ origins: [(CGDirectDisplayID, CGPoint)]) throws {
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
        throw VirtualDisplayWorkspace.Failure.unavailable("Could not arrange the task display.")
    }
    do {
        for (id, origin) in origins {
            guard CGConfigureDisplayOrigin(configuration, id, Int32(origin.x), Int32(origin.y)) == .success else {
                throw VirtualDisplayWorkspace.Failure.unavailable("Could not preserve the display positions.")
            }
        }
    } catch {
        CGCancelDisplayConfiguration(configuration)
        throw error
    }
    guard CGCompleteDisplayConfiguration(configuration, .forAppOnly) == .success else {
        throw VirtualDisplayWorkspace.Failure.unavailable("macOS did not accept the task display arrangement.")
    }
}
