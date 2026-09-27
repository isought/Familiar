import AppKit
import SwiftUI

/// What the collapsed bubble senses about the world, polled at 30 Hz: where the pointer is relative to the panel
/// (so the eyes can follow it), whether it is hovering close, and whether the computer controller is driving the mouse.
/// While the panel is ordered out (hidden, or during control) it only tracks visibility, so the mascot can pause its clock.
@MainActor
final class BubbleSense: ObservableObject {
    @Published var visible = true
    @Published var gaze: CGPoint? = nil
    @Published var pointerNear = false
    @Published var proximity: CGFloat = 0      // 0 far away … 1 at the note; drives a gentle brow lift
    @Published var controlActive = false
    var isControlActive: () -> Bool = { false }
    private var timer: Timer?

    func begin() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func end() { timer?.invalidate(); timer = nil }

    private func sample() {
        guard let panel = NSApp.windows.first(where: { $0 is BubblePanel }) else { return }
        let active = isControlActive()
        if active != controlActive { controlActive = active }
        if panel.isVisible != visible { visible = panel.isVisible }
        guard visible else { return }
        let c = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let m = NSEvent.mouseLocation
        let dx = m.x - c.x, dy = c.y - m.y            // screen y is up; the mascot's y is down
        let dist = hypot(dx, dy)
        // full deflection from ~180pt away, eased in so nearby motion is gentle
        let k = min(1, dist / 180)
        let g = dist < 1 ? CGPoint.zero : CGPoint(x: dx / dist * k, y: dy / dist * k)
        if let old = gaze, abs(old.x - g.x) < 0.02, abs(old.y - g.y) < 0.02 {} else { gaze = g }
        let near = dist < 30            // curious only when the pointer is actually over the note; nearby motion just gets the eyes
        if near != pointerNear { pointerNear = near }
        let prox = max(0, 1 - dist / 240)
        if abs(prox - proximity) > 0.02 { proximity = prox }
    }
}
