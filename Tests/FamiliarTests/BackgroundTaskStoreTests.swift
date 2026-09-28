import AppKit
import Combine
import Testing
@testable import Familiar

@Suite @MainActor
struct BackgroundTaskStoreTests {
    @Test func newTaskIsVisibleCompactAndSeparateFromCompletedResults() {
        let feed = PeekFeed()
        let store = BackgroundTaskStore(feed: feed)
        let first = UUID(), second = UUID()
        store.start(id: first, title: "First task")
        store.toggleExpanded()
        store.finish(id: first, outcome: .completed, text: "First result", elapsed: 8)
        store.dismiss()

        store.start(id: second, title: "Second task")

        #expect(store.isVisible)
        #expect(!store.isExpanded)
        #expect(store.isTracking(id: second))
        #expect(store.isShowingActiveTask)
        #expect(store.history.map(\.text) == ["First result"])
    }

    @Test func completionSnapshotsFeedAndSurvivesNextFeedReset() throws {
        let feed = PeekFeed()
        let store = BackgroundTaskStore(feed: feed)
        let id = UUID()
        let context = try #require(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        feed.frame = try #require(context.makeImage())
        feed.appName = "Safari"
        feed.windowTitle = "Task window"
        feed.step = 7
        feed.caption = "Saved the report"
        store.start(id: id, title: "Prepare report")
        store.finish(id: id, outcome: .completed, text: "Report saved.", elapsed: 24)
        feed.reset()

        let record = try #require(store.selectedRecord)
        #expect(record.frame?.width == 2)
        #expect(record.frame?.height == 3)
        #expect(record.appName == "Safari")
        #expect(record.windowTitle == "Task window")
        #expect(record.step == 7)
        #expect(record.caption == "Saved the report")
        #expect(record.text == "Report saved.")
        #expect(record.outcome == .completed)
        #expect(!store.isTracking(id: id))
    }

    @Test func finishingPreservesCollapseAndDismissal() {
        let store = BackgroundTaskStore(feed: PeekFeed())
        let id = UUID()
        store.start(id: id, title: "Prepare report")
        store.toggleExpanded()
        store.toggleExpanded()
        store.dismiss()
        store.finish(id: id, outcome: .stopped, text: "Stopped", elapsed: 3)

        #expect(!store.isExpanded)
        #expect(!store.isVisible)
        store.show()
        #expect(store.isVisible)
        #expect(!store.isExpanded)
        #expect(store.selectedRecord?.outcome == .stopped)
    }

    @Test func historyDownsamplesLargeCaptures() throws {
        let feed = PeekFeed()
        let store = BackgroundTaskStore(feed: feed)
        let context = try #require(CGContext(data: nil, width: 1800, height: 1000, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        feed.frame = try #require(context.makeImage())
        let id = UUID()
        store.start(id: id, title: "A large window")
        store.finish(id: id, outcome: .completed, text: "Done", elapsed: 1)

        #expect(store.selectedRecord?.frame?.width == 720)
        #expect(store.selectedRecord?.frame?.height == 400)
        #expect(feed.frame?.width == 1800)
    }

    @Test func dismissingNeverStopsTheTask() {
        let feed = PeekFeed()
        let store = BackgroundTaskStore(feed: feed)
        var stops = 0
        feed.onStop = { stops += 1 }
        let id = UUID()
        store.start(id: id, title: "Running")
        store.dismiss()

        #expect(store.isTracking(id: id))
        #expect(stops == 0)
        #expect(!store.isVisible)
    }

    @Test func staleFinishesAndDuplicateStartsCannotReplaceTheActiveTask() {
        let store = BackgroundTaskStore(feed: PeekFeed())
        let id = UUID()
        store.start(id: id, title: "Real task")
        store.toggleExpanded()
        store.start(id: id, title: "Duplicate")
        store.start(id: UUID(), title: "Other task")
        store.finish(id: UUID(), outcome: .failed, text: "Stale", elapsed: 1)

        #expect(store.activeTask?.title == "Real task")
        #expect(store.isTracking(id: id))
        #expect(store.history.isEmpty)
        #expect(store.isExpanded)
    }

    @Test func historyRemainsBoundedAndNewestFirst() {
        let store = BackgroundTaskStore(feed: PeekFeed())
        for index in 0..<23 {
            let id = UUID()
            store.start(id: id, title: "Task \(index)")
            store.finish(id: id, outcome: .completed, text: "Result \(index)", elapsed: 0)
        }
        #expect(store.history.count == 20)
        #expect(store.history.first?.title == "Task 22")
        #expect(store.history.last?.title == "Task 3")
    }

    @Test func historyCanBeReadWhileTheNextTaskContinues() {
        let store = BackgroundTaskStore(feed: PeekFeed())
        let old = UUID(), current = UUID()
        store.start(id: old, title: "Old")
        store.finish(id: old, outcome: .failed, text: "A useful error", elapsed: 2)
        store.start(id: current, title: "Current")
        store.selectTask(id: old)

        #expect(store.selectedRecord?.text == "A useful error")
        #expect(!store.isShowingActiveTask)
        #expect(store.isTracking(id: current))
        #expect(store.isExpanded)
        store.showLatest()
        #expect(store.isShowingActiveTask)
        store.selectTask(id: old)
        store.finish(id: current, outcome: .completed, text: "New result", elapsed: 4)
        #expect(store.selectedRecord?.id == old)
    }

    @Test func emptyStoreDoesNotOpenAnEmptyPanel() {
        let store = BackgroundTaskStore(feed: PeekFeed())
        store.show()
        store.showLatest()
        store.selectTask(id: UUID())
        store.toggleExpanded()
        #expect(!store.isVisible)
        #expect(!store.isExpanded)
        #expect(!store.hasTasks)
    }

    @Test func newApprovalRevealsCompactDockWithoutReopeningOnRefresh() {
        let feed = PeekFeed()
        let store = BackgroundTaskStore(feed: feed)
        store.start(id: UUID(), title: "Prepare summary")
        store.dismiss()
        feed.phase = .confirming("Send the summary?")

        #expect(store.isVisible)
        #expect(!store.isExpanded)
        store.dismiss()
        feed.caption = "Still waiting"
        feed.phase = .confirming("Send the summary?")
        #expect(!store.isVisible)

        feed.phase = .working
        feed.phase = .asking("Open the calendar?")
        #expect(store.isVisible)
        #expect(!store.isExpanded)
    }

    @Test func approvalReturnsFromHistoryToCurrentTask() {
        let feed = PeekFeed()
        let store = BackgroundTaskStore(feed: feed)
        let old = UUID(), current = UUID()
        store.start(id: old, title: "Old")
        store.finish(id: old, outcome: .completed, text: "Result", elapsed: 1)
        store.start(id: current, title: "Current")
        store.selectTask(id: old)
        store.dismiss()
        feed.phase = .confirming("Submit?")

        #expect(store.selectedTaskID == current)
        #expect(store.isShowingActiveTask)
        #expect(store.isVisible)
        #expect(store.isExpanded)
    }

    @Test func automaticLifecycleNeverRequestsKeyboardFocus() {
        let feed = PeekFeed()
        let store = BackgroundTaskStore(feed: feed)
        var opens = 0
        let observation = store.explicitOpenRequests.sink { opens += 1 }
        defer { observation.cancel() }
        let id = UUID()
        store.start(id: id, title: "A background task")
        store.dismiss()
        feed.phase = .confirming("Submit?")
        feed.phase = .working
        feed.phase = .asking("Use the mouse?")
        store.finish(id: id, outcome: .completed, text: "Result", elapsed: 1)

        #expect(opens == 0)
    }

    @Test func onlyExplicitOpeningRequestsKeyboardFocus() {
        let store = BackgroundTaskStore(feed: PeekFeed())
        var opens = 0
        let observation = store.explicitOpenRequests.sink { opens += 1 }
        defer { observation.cancel() }
        store.show()
        #expect(opens == 0)
        let id = UUID()
        store.start(id: id, title: "A task")
        store.show()
        #expect(opens == 1)
        store.toggleExpanded()
        #expect(opens == 2)
        store.toggleExpanded()
        #expect(opens == 2)
        store.selectTask(id: id)
        #expect(opens == 3)
        store.dismiss()
        #expect(opens == 3)
    }

    @Test func explicitOpenIntentIsNotReplayedToANewPanel() {
        let store = BackgroundTaskStore(feed: PeekFeed())
        store.start(id: UUID(), title: "A task")
        store.show()
        var opens = 0
        let observation = store.explicitOpenRequests.sink { opens += 1 }
        defer { observation.cancel() }
        #expect(opens == 0)
        store.show()
        #expect(opens == 1)
    }
}
