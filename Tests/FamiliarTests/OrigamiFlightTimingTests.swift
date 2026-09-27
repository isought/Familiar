import Foundation
import Testing
@testable import Familiar

@Suite
struct OrigamiFlightTimingTests {
    private let home = CGPoint(x: 1300, y: 100)
    private var path: OrigamiFlightPath {
        OrigamiFlightPath(home: home, visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876))
    }

    @Test
    func foldsBeforeTakingOffAndUnfoldsOnlyAfterReturningHome() {
        let timing = OrigamiFlightTiming()
        let resting = timing.frame(at: -1, path: path)
        #expect(resting.position == home && resting.fold == 0)
        #expect(resting.yaw == 0 && resting.bank == 0)
        for time in stride(from: 0.0, to: timing.foldingDuration, by: 0.05) {
            let frame = timing.frame(at: time, path: path)
            #expect(frame.phase == .folding)
            #expect(frame.position == home && frame.wingBeat == 0)
        }

        let flying = timing.frame(at: timing.foldingDuration + timing.flyingDuration / 2, path: path)
        #expect(flying.phase == .flying && flying.fold == 1)
        #expect(hypot(flying.position.x - home.x, flying.position.y - home.y) > 400)

        let landedAt = timing.foldingDuration + timing.flyingDuration
        for time in stride(from: landedAt, to: timing.duration, by: 0.05) {
            let frame = timing.frame(at: time, path: path)
            #expect(frame.phase == .unfolding)
            #expect(frame.position == home && frame.wingBeat == 0)
        }
        let finished = timing.frame(at: timing.duration + 1, path: path)
        #expect(finished.phase == .finished)
        #expect(finished.position == home && finished.fold == 0)
        #expect(finished.yaw == 0 && finished.bank == 0)
    }

    @Test
    func phaseChangesHaveNoVisiblePositionOrPoseJump() {
        let timing = OrigamiFlightTiming()
        for boundary in [timing.foldingDuration, timing.foldingDuration + timing.flyingDuration, timing.duration] {
            let before = timing.frame(at: boundary - 0.0001, path: path)
            let after = timing.frame(at: boundary + 0.0001, path: path)
            #expect(hypot(after.position.x - before.position.x, after.position.y - before.position.y) < 0.01)
            #expect(abs(after.fold - before.fold) < 0.001)
            #expect(abs(after.wingBeat - before.wingBeat) < 0.001)
            #expect(abs(after.yaw - before.yaw) < 0.01)
            #expect(abs(after.bank - before.bank) < 0.01)
        }
    }

    @Test
    func reduceMotionKeepsTheWholeSequenceAtHome() {
        let timing = OrigamiFlightTiming(reduceMotion: true)
        #expect(timing.duration < OrigamiFlightTiming().duration)
        var didFold = false
        for time in stride(from: 0.0, through: timing.duration + 0.1, by: 0.02) {
            let frame = timing.frame(at: time, path: path)
            #expect(frame.position == home)
            #expect(frame.yaw == 0 && frame.bank == 0)
            #expect(abs(frame.wingBeat) <= 0.18)
            if frame.fold == 1 { didFold = true }
        }
        #expect(didFold)
        #expect(timing.frame(at: timing.duration, path: path).phase == .finished)
    }
}
