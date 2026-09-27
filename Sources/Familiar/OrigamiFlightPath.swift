import Foundation
import CoreGraphics

/// A clockwise lap in AppKit screen coordinates, beginning and ending at the note.
/// The crane's center follows this path; `inset` leaves room for its wings.
struct OrigamiFlightPath {
    private let home: CGPoint
    private let center: CGPoint
    private let radius: CGSize
    private let startAngle: CGFloat
    private let blendLength: CGFloat = 0.16

    init(home: CGPoint, visibleFrame: CGRect, inset: CGFloat = 88) {
        self.home = home
        let frame = visibleFrame.standardized
        center = CGPoint(x: frame.midX, y: frame.midY)
        // Keep a useful lap on small displays, where the requested wing margin
        // may be larger than half the available width or height.
        let horizontalInset = min(max(0, inset), frame.width * 0.2)
        let verticalInset = min(max(0, inset), frame.height * 0.2)
        radius = CGSize(width: frame.width / 2 - horizontalInset,
                        height: frame.height / 2 - verticalInset)
        let x = radius.width > 0 ? (home.x - center.x) / radius.width : 0
        let y = radius.height > 0 ? (home.y - center.y) / radius.height : 0
        startAngle = atan2(y, x)
    }

    func position(at progress: Double) -> CGPoint {
        let p = clamped(progress)
        guard p > 0 && p < 1 else { return home }
        let sample = ellipse(at: p)
        let weight = blend(at: p).value
        // Convex interpolation keeps the center within the screen even when
        // home sits outside the inset ellipse, as the default desktop note does.
        return CGPoint(x: home.x + weight * (sample.position.x - home.x),
                       y: home.y + weight * (sample.position.y - home.y))
    }

    /// An unwrapped angle, in radians. A caller can animate this rotation without
    /// snapping when the tangent passes through atan2's -π/π boundary.
    func heading(at progress: Double) -> CGFloat {
        let p = clamped(progress)
        let sample = ellipse(at: p)
        let weight = blend(at: p)
        var dx = weight.derivative * (sample.position.x - home.x)
            + weight.value * sample.velocity.dx
        var dy = weight.derivative * (sample.position.y - home.y)
            + weight.value * sample.velocity.dy

        // Smootherstep brings speed to zero at home. Use the limiting direction
        // there so folding/unfolding does not make the crane jump in rotation.
        if p == 0 || p == 1 {
            let start = ellipse(at: 0)
            let direction: CGFloat = p == 0 ? 1 : -1
            dx = direction * (start.position.x - home.x)
            dy = direction * (start.position.y - home.y)
            if hypot(dx, dy) < 0.000_001 {
                dx = start.velocity.dx
                dy = start.velocity.dy
            }
        }
        let reference = startAngle - 2 * .pi * p - .pi / 2
        guard hypot(dx, dy) > 0 else { return reference }
        let raw = atan2(dy, dx)
        return raw + 2 * .pi * ((reference - raw) / (2 * .pi)).rounded()
    }

    private func clamped(_ progress: Double) -> CGFloat {
        CGFloat(progress.isNaN ? 0 : min(1, max(0, progress)))
    }

    private func ellipse(at progress: CGFloat) -> (position: CGPoint, velocity: CGVector) {
        let angle = startAngle - 2 * .pi * progress
        return (
            CGPoint(x: center.x + radius.width * cos(angle),
                    y: center.y + radius.height * sin(angle)),
            CGVector(dx: 2 * .pi * radius.width * sin(angle),
                     dy: -2 * .pi * radius.height * cos(angle))
        )
    }

    private func blend(at progress: CGFloat) -> (value: CGFloat, derivative: CGFloat) {
        let departure = progress < blendLength
        let arrival = progress > 1 - blendLength
        guard departure || arrival else { return (1, 0) }
        let t = departure ? progress / blendLength : (1 - progress) / blendLength
        // Quintic smootherstep also matches acceleration at the ellipse joins.
        let value = t * t * t * (t * (6 * t - 15) + 10)
        let derivative = 30 * t * t * (1 - t) * (1 - t) / blendLength * (departure ? 1 : -1)
        // The blend occupies less than a quarter-turn. With the ellipse's start
        // on the same radial line as home, this preserves clockwise travel and
        // avoids a reversal while joining or leaving the lap.
        return (value, derivative)
    }
}
