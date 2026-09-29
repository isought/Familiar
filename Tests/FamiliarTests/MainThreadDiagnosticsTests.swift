import Foundation
import Testing
@testable import Familiar

struct MainThreadDiagnosticsTests {
    @Test func queuesOneHeartbeatAndReportsOnlyOnceWhileMainThreadIsBlocked() throws {
        var detector = MainThreadStallDetector()
        let first = detector.poll(at: 10)
        let token = try #require(first.heartbeat)
        #expect(first.stalledFor == nil)
        #expect(detector.poll(at: 10.5) == .init())
        #expect(detector.poll(at: 12.9) == .init())
        #expect(detector.poll(at: 13) == .init(stalledFor: 3))
        #expect(detector.poll(at: 14) == .init())
        #expect(detector.poll(at: 18) == .init())
        #expect(detector.acknowledge(token, at: 18.5) == 8.5)
        let next = detector.poll(at: 19)
        #expect(next.heartbeat != nil && next.heartbeat != token)
        #expect(detector.poll(at: 22) == .init(stalledFor: 3))
    }

    @Test func healthyHeartbeatsNeverReportAStallOrARecovery() throws {
        var detector = MainThreadStallDetector()
        for tick in 0..<20 {
            let now = Double(tick) / 2
            let poll = detector.poll(at: now)
            let token = try #require(poll.heartbeat)
            #expect(poll.stalledFor == nil)
            #expect(detector.acknowledge(token, at: now + 0.01) == nil)
        }
    }

    @Test func suspendedProcessStartsFreshAndIgnoresItsOldHeartbeat() throws {
        var detector = MainThreadStallDetector()
        let stale = try #require(detector.poll(at: 10).heartbeat)
        let resumed = detector.poll(at: 100)
        let fresh = try #require(resumed.heartbeat)
        #expect(resumed.stalledFor == nil)
        #expect(fresh != stale)
        #expect(detector.acknowledge(stale, at: 100.1) == nil)
        #expect(detector.poll(at: 103) == .init(stalledFor: 3))
        #expect(detector.acknowledge(fresh, at: 103.5) == 3.5)
    }

    @Test func duplicateAcknowledgmentCannotClearAnotherOutstandingHeartbeat() throws {
        var detector = MainThreadStallDetector()
        let first = try #require(detector.poll(at: 0).heartbeat)
        #expect(detector.acknowledge(first, at: 0.1) == nil)
        let second = try #require(detector.poll(at: 0.5).heartbeat)
        #expect(detector.acknowledge(first, at: 1) == nil)
        #expect(detector.poll(at: 3.5) == .init(stalledFor: 3))
        #expect(detector.acknowledge(second, at: 4) == 3.5)
    }
}
