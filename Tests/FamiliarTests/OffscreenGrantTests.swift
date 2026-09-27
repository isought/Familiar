import AppKit
import Testing
@testable import Familiar

@Suite @MainActor
struct OffscreenGrantTests {
    @Test func approvingVirtualInputKeepsWindowParkedAndNeverEntersDesktopPresentation() async throws {
        let fixture = Fixture()
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters)
        _ = try await workspace.park(fixture.target())
        let parked = fixture.state.frame
        let ladder = ActionLadder(target: fixture.target(), maxLongEdge: 640)
        ladder.refreshWindow = { _ in true }
        let control = ComputerController(backgroundSession: ladder, mouseGranted: false, workspace: workspace)
        control.virtualDisplayEnabled = true
        control.hudEnabled = false
        control.ghostEnabled = false
        let feed = PeekFeed()
        control.peek = feed
        var presentation: [Bool] = []
        control.onGrant = { presentation.append($0) }
        defer { control.end() }

        let request = Task { await control.askForMouse(["reason": "focus the test field"]) }
        for _ in 0..<100 where feed.onGoAhead == nil { await Task.yield() }
        try #require(feed.onGoAhead != nil)
        feed.onGoAhead?()
        let result = await request.value

        #expect(!result.isError)
        #expect(fixture.state.frame == parked)
        #expect(presentation.isEmpty)
        #expect(control.space == ladder.space)
        #expect(feed.phase == .working)
        #expect((result.content as? String)?.lowercased().contains("window capture") == true)
        _ = control.giveMouseBack()
        #expect(fixture.state.frame == parked)
        #expect(presentation.isEmpty)
    }

    @Test func permissionBetweenActionsLeavesHumanInputAndWindowObservationsAlone() async throws {
        let (_, control, ladder) = try await approvedSession()
        defer { control.end() }
        var borrowed = 0
        control.offscreenExecutor = { _, _, _, _, _ in borrowed += 1; return .text("unexpected") }
        control.humanInput("keyboard")
        control.humanInput("mouse")
        #expect(!control.stopped)
        #expect(control.offscreenInputPermission)
        let waiting = await control.perform("wait", ["duration": 0])
        #expect(waiting.content as? String == "OK")
        _ = await control.perform("mouse_move", ["coordinate": [120, 80]])
        let found = control.find("anything")
        #expect((found.content as? String)?.contains("No element with text matching") == true)
        #expect(borrowed == 0)
        #expect(control.space == ladder.space)
    }

    @Test func borrowedClickUsesWindowCoordinatesAndRequiresFreshObservationAfterward() async throws {
        let (fixture, control, ladder) = try await approvedSession()
        defer { control.end() }
        let parked = fixture.state.frame
        ladder.viewportDirty = false // stands in for the fresh window screenshot
        _ = await control.perform("mouse_move", ["coordinate": [120, 80]])
        var calls = 0
        control.offscreenExecutor = { name, input, target, displayID, space in
            calls += 1
            #expect(name == "left_click")
            #expect(input["coordinate"] as? [Int] == [120, 80])
            #expect(target.cgWindowID == 11)
            #expect(displayID == 100)
            #expect(space.originCG == parked.origin)
            #expect(fixture.state.frame == parked)
            return .text("Input returned")
        }
        let result = await control.perform("left_click", [:])
        #expect(result.content as? String == "Input returned")
        #expect(calls == 1)
        #expect(ladder.viewportDirty)
        let stale = await control.perform("left_click", ["coordinate": [120, 80]])
        #expect((stale.content as? String)?.contains("Take a new screenshot") == true)
        #expect(calls == 1)
        #expect(fixture.state.frame == parked)
    }

    @Test func firstBorrowRequestParksWindowBeforeShowingThePermission() async throws {
        let fixture = Fixture()
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters)
        let ladder = ActionLadder(target: fixture.target(), maxLongEdge: 640)
        ladder.refreshWindow = { _ in true }
        let control = ComputerController(backgroundSession: ladder, mouseGranted: false, workspace: workspace)
        control.virtualDisplayEnabled = true
        let feed = PeekFeed()
        control.peek = feed
        defer { control.end() }
        let request = Task { await control.askForMouse(["reason": "focus the field"]) }
        for _ in 0..<100 where feed.onGoAhead == nil { await Task.yield() }
        try #require(feed.onNotNow != nil)
        #expect(fixture.state.frame.minX >= 1024)
        #expect(feed.borrowKeepsWindowOffscreen)
        feed.onNotNow?()
        _ = await request.value
    }

    @Test(arguments: [false, true])
    func stopOrEndWaitsForBorrowerCleanupBeforeReturningTheWindow(endSession: Bool) async throws {
        let (fixture, control, ladder) = try await approvedSession()
        defer { control.end() }
        let parked = fixture.state.frame
        ladder.viewportDirty = false
        control.offscreenExecutor = { _, _, _, _, _ in
            if endSession { control.end() } else { control.stop(reason: "test stop") }
            // The native borrower still owns focus here. Returning a physical
            // window before this callback cleans up would expose it on the user's screen.
            #expect(fixture.state.frame == parked)
            #expect(fixture.screens.contains { $0.id == 100 })
            await Task.yield()
            return .text("Focus and pointer restored")
        }
        let result = await control.perform("left_click", ["coordinate": [100, 100]])
        #expect(result.isError)
        #expect(fixture.state.frame.minX < 1024)
        #expect(!fixture.screens.contains { $0.id == 100 })
    }

    private func approvedSession() async throws -> (Fixture, ComputerController, ActionLadder) {
        let fixture = Fixture()
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters)
        _ = try await workspace.park(fixture.target())
        let ladder = ActionLadder(target: fixture.target(), maxLongEdge: 640)
        ladder.refreshWindow = { _ in true }
        let control = ComputerController(backgroundSession: ladder, mouseGranted: false, workspace: workspace)
        control.virtualDisplayEnabled = true
        let feed = PeekFeed()
        control.peek = feed
        let request = Task { await control.askForMouse(["reason": "focus the field"]) }
        for _ in 0..<100 where feed.onGoAhead == nil { await Task.yield() }
        try #require(feed.onGoAhead != nil)
        feed.onGoAhead?()
        let result = await request.value
        #expect(!result.isError)
        return (fixture, control, ladder)
    }

    @Test func gracefulQuitWaitsForNativeCleanupBeforeEndingSession() async throws {
        let (fixture, control, ladder) = try await approvedSession()
        let parked = fixture.state.frame
        ladder.viewportDirty = false
        var quitting: Task<Void, Never>?
        control.offscreenExecutor = { _, _, _, _, _ in
            quitting = Task { await control.endAfterInputReturns() }
            for _ in 0..<100 where !control.stopped { await Task.yield() }
            #expect(control.stopped)
            #expect(control.isBorrowingOffscreenInput)
            #expect(fixture.state.frame == parked)
            return .text("Input returned")
        }
        _ = await control.perform("left_click", ["coordinate": [100, 100]])
        await quitting?.value
        #expect(!control.active)
        #expect(!control.isBorrowingOffscreenInput)
        #expect(!fixture.screens.contains { $0.id == 100 })
    }

    @MainActor private final class Fixture {
        var state = VirtualDisplayWorkspace.WindowState(frame: CGRect(x: 30, y: 40, width: 640, height: 480),
                                                        isMinimized: false, isFullScreen: false, canMove: true)
        var screens = [VirtualDisplayWorkspace.DisplayState(id: 1, frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
                                                             isMain: true, isMirrored: false)]
        func target() -> TargetWindow {
            let element = AXUIElementCreateApplication(-23456)
            return TargetWindow(pid: -23456, bundleID: "test.offscreen", appName: "Fixture", cgWindowID: 11,
                                axApp: element, axWindow: element, toolkit: .appKit, backingScale: 1,
                                scWindow: nil, frameCG: state.frame, title: "Fixture")
        }
        var adapters: VirtualDisplayWorkspace.Adapters {
            .init(displays: { self.screens }, createDisplay: { width, height in
                self.screens.append(.init(id: 100, frame: CGRect(x: 1024, y: 0, width: Int(width), height: Int(height)),
                                          isMain: false, isMirrored: false))
                return .init(id: 100, invalidate: { self.screens.removeAll { $0.id == 100 } })
            }, arrangeDisplay: { _, _, _ in }, restoreDisplayLayout: { _ in }, readWindow: { _ in self.state },
                  moveWindow: { _, frame in self.state = .init(frame: frame, isMinimized: self.state.isMinimized,
                                                              isFullScreen: false, canMove: true) },
                  setMinimized: { _, minimized in self.state = .init(frame: self.state.frame, isMinimized: minimized,
                                                                   isFullScreen: false, canMove: true) }, pause: {})
        }
    }
}
