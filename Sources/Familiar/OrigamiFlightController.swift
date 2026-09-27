import AppKit
import SwiftUI

struct OrigamiFlightFrame {
    enum Phase { case folding, flying, unfolding, finished }
    var phase: Phase
    var position: CGPoint
    var fold: CGFloat
    var wingBeat: CGFloat
    var yaw: Double
    var bank: Double
}

/// A deterministic sequence shared by the desktop animation and its timing tests.
struct OrigamiFlightTiming {
    var reduceMotion = false
    var foldingDuration: Double { reduceMotion ? 1.2 : 2.2 }
    var flyingDuration: Double { reduceMotion ? 1.2 : 8.0 }
    var unfoldingDuration: Double { reduceMotion ? 1.2 : 2.0 }
    var duration: Double { foldingDuration + flyingDuration + unfoldingDuration }

    func frame(at elapsed: Double, path: OrigamiFlightPath) -> OrigamiFlightFrame {
        let t = max(0, elapsed)
        let flightEnd = foldingDuration + flyingDuration
        let phase: OrigamiFlightFrame.Phase
        let fold: Double
        let progress: Double
        var wingBeat = 0.0
        if t < foldingDuration {
            phase = .folding
            fold = smooth(t / foldingDuration)
            progress = 0
        } else if t < flightEnd {
            phase = .flying
            fold = 1
            let flightTime = t - foldingDuration
            progress = smooth(flightTime / flyingDuration)
            let envelope = smooth(flightTime / 0.45) * smooth((flyingDuration - flightTime) / 0.6)
            wingBeat = sin(flightTime * 2 * .pi / 0.78) * envelope * (reduceMotion ? 0.18 : 1)
        } else if t < duration {
            phase = .unfolding
            fold = 1 - smooth((t - flightEnd) / unfoldingDuration)
            progress = 1
        } else {
            phase = .finished
            fold = 0
            progress = 1
        }

        let heading = Double(path.heading(at: progress))
        // Turn edge-on when changing direction instead of snapping a mirrored crane across the screen.
        let turn = smooth((cos(heading) + 0.28) / 0.56)
        let birdWeight = smooth((fold - 0.55) / 0.45)
        let yaw = reduceMotion ? 0 : turn * 180 * birdWeight
        let bank = reduceMotion ? 0 : sin(heading) * (1 - 2 * turn) * 16 * birdWeight
        return OrigamiFlightFrame(
            phase: phase,
            position: path.position(at: reduceMotion ? 0 : progress),
            fold: CGFloat(fold), wingBeat: CGFloat(wingBeat), yaw: yaw, bank: bank
        )
    }

    private func smooth(_ value: Double) -> Double {
        let v = min(1, max(0, value))
        return v * v * (3 - 2 * v)
    }
}

@MainActor
private final class OrigamiFlightState: ObservableObject {
    @Published var frame: OrigamiFlightFrame
    init(frame: OrigamiFlightFrame) { self.frame = frame }
}

/// A transparent, click-through stage. The real bubble stays at home and returns after every exit path.
@MainActor
final class OrigamiFlightController {
    private var overlay: NSPanel?
    private var state: OrigamiFlightState?
    private var path: OrigamiFlightPath?
    private var timing = OrigamiFlightTiming()
    private var startedAt: TimeInterval = 0
    private var timer: Timer?
    private var localEscape: Any?
    private var globalEscape: Any?
    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var onFinish: (() -> Void)?

    var isFlying: Bool { overlay != nil }

    @discardableResult
    func start(home: CGPoint, screen: NSScreen, hideFromScreenShare: Bool, onFinish: @escaping () -> Void) -> Bool {
        guard !isFlying else { return false }
        let bounds = screen.visibleFrame
        let route = OrigamiFlightPath(home: home, visibleFrame: bounds)
        timing = OrigamiFlightTiming(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let state = OrigamiFlightState(frame: timing.frame(at: 0, path: route))
        let stage = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        stage.title = "Familiar paper crane"
        stage.level = .floating
        stage.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        stage.isOpaque = false
        stage.backgroundColor = .clear
        stage.hasShadow = false
        stage.hidesOnDeactivate = false
        stage.isReleasedWhenClosed = false
        stage.ignoresMouseEvents = true
        stage.sharingType = hideFromScreenShare ? .none : .readOnly
        let host = NSHostingView(rootView: OrigamiFlightStage(state: state, screenFrame: bounds))
        host.frame = NSRect(origin: .zero, size: bounds.size)
        stage.contentView = host

        self.state = state
        path = route
        self.onFinish = onFinish
        overlay = stage
        startedAt = ProcessInfo.processInfo.systemUptime
        stage.orderFrontRegardless()

        localEscape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.isFlying == true else { return event }
            self?.cancel()
            return nil
        }
        globalEscape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }

        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
        return true
    }

    private func advance() {
        guard let path, let state else { return }
        let frame = timing.frame(at: ProcessInfo.processInfo.systemUptime - startedAt, path: path)
        state.frame = frame
        if frame.phase == .finished { cancel() }
    }

    /// Idempotent: stop all work before restoring the real note, even if several interruptions arrive together.
    func cancel() {
        guard isFlying else { return }
        timer?.invalidate(); timer = nil
        if let localEscape { NSEvent.removeMonitor(localEscape) }
        if let globalEscape { NSEvent.removeMonitor(globalEscape) }
        localEscape = nil; globalEscape = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        screenObserver = nil; motionObserver = nil
        overlay?.orderOut(nil)
        overlay?.contentView = nil
        overlay?.close()
        overlay = nil
        state = nil
        path = nil
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}

private struct OrigamiFlightStage: View {
    @ObservedObject var state: OrigamiFlightState
    let screenFrame: CGRect

    var body: some View {
        let f = state.frame
        OrigamiMascotView(fold: f.fold, wingBeat: f.wingBeat, size: 64)
            .rotation3DEffect(.degrees(f.yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
            .rotationEffect(.degrees(f.bank))
            .position(x: f.position.x - screenFrame.minX, y: screenFrame.maxY - f.position.y)
            .frame(width: screenFrame.width, height: screenFrame.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
