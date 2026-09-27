import Foundation
import Testing
@testable import Familiar

@Suite
struct PeekCadenceTests {
    @Test
    func quickWhileAnActionRunsSlowWhileThinking() {
        #expect(PeekCadence.interval(phase: .working, actionRunning: true) == 0.25)
        #expect(PeekCadence.interval(phase: .working, actionRunning: false) == 1.0)
        #expect(PeekCadence.interval(phase: .thinking, actionRunning: false) == 1.0)
        #expect(PeekCadence.interval(phase: .thinking, actionRunning: true) == 0.25)
        #expect(PeekCadence.interval(phase: .asking("to drag"), actionRunning: false) == 1.0)
    }

    @Test
    func noCapturesWhenThereIsNothingToWatch() {
        for phase: PeekFeed.Phase in [.idle, .done, .stopped, .foreground] {
            #expect(PeekCadence.interval(phase: phase, actionRunning: false) == nil)
            #expect(PeekCadence.interval(phase: phase, actionRunning: true) == nil)
        }
    }

    @Test @MainActor
    func workingCoversEveryLivePhase() {
        let feed = PeekFeed()
        for phase: PeekFeed.Phase in [.working, .thinking, .asking("why"), .foreground] {
            feed.phase = phase
            #expect(feed.isWorking)
        }
        for phase: PeekFeed.Phase in [.idle, .done, .stopped] {
            feed.phase = phase
            #expect(!feed.isWorking)
        }
    }

    @Test @MainActor
    func metaLineLeavesOutWhatIsMissing() {
        let feed = PeekFeed()
        #expect(feed.metaLine == "")
        feed.appName = "Chrome"
        #expect(feed.metaLine == "Chrome")
        feed.windowTitle = "New Report"
        #expect(feed.metaLine == "Chrome · New Report")
        feed.step = 4
        #expect(feed.metaLine == "Chrome · New Report · step 4")
        feed.appName = ""
        #expect(feed.metaLine == "New Report · step 4")
    }

    @Test @MainActor
    func resetGoesBackToABlankIdleNote() {
        let feed = PeekFeed()
        feed.phase = .working
        feed.caption = "Clicking Save"
        feed.appName = "Chrome"
        feed.windowTitle = "New Report"
        feed.step = 3
        feed.cursor = CGPoint(x: 0.5, y: 0.5)
        feed.highlight = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        feed.pulse = 2
        feed.startedAt = Date()
        feed.reset()
        #expect(feed.phase == .idle)
        #expect(feed.frame == nil)
        #expect(feed.step == 0)
        #expect(feed.caption.isEmpty && feed.metaLine.isEmpty)
        #expect(feed.cursor == nil && feed.highlight == nil && feed.pulse == 0)
        #expect(feed.startedAt == nil)
        #expect(!feed.isWorking)
    }
}
