import AppKit

/// ⌥ Option pressed twice on its own: the one key that shows or hides the notes on the screen in front. Pure, so the
/// timing can be tested: it counts a tap only when Option goes down and up with no other key or modifier, and two taps
/// within `window` make the shortcut.
struct DoubleOptionTap {
    static let window: TimeInterval = 0.4
    private var down: TimeInterval?
    private var lastTap: TimeInterval?

    /// The modifiers now held. True when this change completes a second tap.
    mutating func flags(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
        let held = flags.intersection([.option, .command, .control, .shift, .function, .capsLock])
        if held == .option {
            down = time
            return false
        }
        guard held.isEmpty, let pressed = down else {   // another modifier joined in: not a tap
            down = nil
            lastTap = nil
            return false
        }
        down = nil
        guard time - pressed < Self.window else { lastTap = nil; return false }   // held, not tapped
        if let previous = lastTap, time - previous < Self.window {
            lastTap = nil
            return true
        }
        lastTap = time
        return false
    }

    /// Any other key in between means Option was part of typing, not a tap.
    mutating func key() {
        down = nil
        lastTap = nil
    }
}

/// Watches for ⌥ Option pressed twice, in any app, through the Accessibility permission Noteling already has. It only
/// reads which modifiers are held and that some key was pressed, never which.
@MainActor
final class NotesShortcut {
    var onPress: (() -> Void)?
    private var detector = DoubleOptionTap()
    private var monitors: [Any] = []

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let flags: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.detector.flags(event.modifierFlags, at: event.timestamp) { self.onPress?() }
            }
        }
        let key: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.detector.key() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(global) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(local) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { key($0); return $0 }) { monitors.append(local) }
        Log.info("notes shortcut: on (press Option twice)")
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        detector = DoubleOptionTap()
    }
}
