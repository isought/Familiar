import Foundation
import CoreGraphics
import Testing
@testable import Familiar

@Suite
struct OrigamiFlightPathTests {
    @Test
    func closesAtHomeAndClampsProgress() {
        let home = CGPoint(x: 1374, y: 90)
        let path = OrigamiFlightPath(home: home,
                                     visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876))
        for progress in [-Double.infinity, -1, 0, 1, 2, Double.infinity, Double.nan] {
            #expect(path.position(at: progress) == home)
            #expect(path.heading(at: progress).isFinite)
        }
        #expect(path.position(at: 0.01).x < home.x)
    }

    @Test
    func remainsOnScreenForSecondaryAndCompactDisplays() {
        let frames = [
            CGRect(x: -1920, y: -260, width: 1920, height: 1080),
            CGRect(x: 1200, y: 900, width: 320, height: 200),
            CGRect(x: -120, y: -90, width: 120, height: 90),
        ]
        for frame in frames {
            let homes = [
                CGPoint(x: frame.maxX - 4, y: frame.minY + 4),
                CGPoint(x: frame.minX, y: frame.maxY),
                CGPoint(x: frame.midX, y: frame.midY),
                CGPoint(x: frame.midX + frame.width * 0.1, y: frame.midY),
            ]
            for home in homes {
                let path = OrigamiFlightPath(home: home, visibleFrame: frame)
                for step in 0...1000 {
                    let progress = Double(step) / 1000
                    let point = path.position(at: progress)
                    #expect(point.x.isFinite && point.y.isFinite)
                    #expect(path.heading(at: progress).isFinite)
                    // CGRect.contains excludes its upper boundary; a home on
                    // that boundary is nevertheless a valid exact endpoint.
                    #expect(point.x >= frame.minX && point.x <= frame.maxX)
                    #expect(point.y >= frame.minY && point.y <= frame.maxY)
                }
            }
        }
    }

    @Test
    func makesOneBroadClockwiseLapWithoutTangentJumps() {
        let frame = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let home = CGPoint(x: frame.maxX - 66, y: frame.minY + 66)
        let path = OrigamiFlightPath(home: home, visibleFrame: frame)
        var previous = home
        var previousHeading = path.heading(at: 0)
        var previousPolar = atan2(home.y - frame.midY, home.x - frame.midX)
        var angleTravel: CGFloat = 0
        var bounds = CGRect(origin: home, size: .zero)

        for step in 1...2000 {
            let progress = Double(step) / 2000
            let point = path.position(at: progress)
            let heading = path.heading(at: progress)
            let polar = atan2(point.y - frame.midY, point.x - frame.midX)
            var delta = polar - previousPolar
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            #expect(delta <= 0.000_001)
            angleTravel += delta
            #expect(hypot(point.x - previous.x, point.y - previous.y) < 6)
            #expect(abs(heading - previousHeading) < 0.05)
            bounds = bounds.union(CGRect(origin: point, size: .zero))
            previous = point
            previousHeading = heading
            previousPolar = polar
        }

        #expect(abs(angleTravel + 2 * .pi) < 0.000_001)
        #expect(bounds.minX < frame.minX + frame.width * 0.15)
        #expect(bounds.maxX > frame.maxX - frame.width * 0.15)
        #expect(bounds.minY < frame.minY + frame.height * 0.2)
        #expect(bounds.maxY > frame.maxY - frame.height * 0.2)
    }

    @Test
    func headingMatchesMotionIncludingBlendJoins() {
        let path = OrigamiFlightPath(home: CGPoint(x: -66, y: -134),
                                     visibleFrame: CGRect(x: -1440, y: -200, width: 1440, height: 900))
        for progress in [0.001, 0.04, 0.1599, 0.16, 0.1601, 0.3, 0.6, 0.8399, 0.84, 0.8401, 0.95, 0.999] {
            let before = path.position(at: progress - 0.000_001)
            let after = path.position(at: progress + 0.000_001)
            let dx = after.x - before.x
            let dy = after.y - before.y
            let length = hypot(dx, dy)
            let heading = path.heading(at: progress)
            #expect(length > 0)
            #expect(abs(cos(heading) - dx / length) < 0.000_01)
            #expect(abs(sin(heading) - dy / length) < 0.000_01)
        }
    }
}
