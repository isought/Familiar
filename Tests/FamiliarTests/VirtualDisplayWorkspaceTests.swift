import AppKit
import ApplicationServices
import Testing
@testable import Familiar

@Suite(.serialized)
@MainActor
struct VirtualDisplayWorkspaceTests {
    @Test func multipleTargetsUseOneDisplayAndRestoreBeforeDestroy() async throws {
        let fixture = Fixture()
        let first = fixture.target(11), second = fixture.target(12, frame: CGRect(x: 300, y: 200, width: 800, height: 600))
        let originalFirst = fixture.windows[11]!.frame, originalSecond = fixture.windows[12]!.frame
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())

        let movedFirst = try await workspace.park(first)
        let repeated = try await workspace.park(first)
        let movedSecond = try await workspace.park(second)

        #expect(movedFirst)
        #expect(!repeated)
        #expect(movedSecond)
        #expect(fixture.events.filter { $0 == "create" }.count == 1)
        #expect(workspace.displayID == fixture.virtualID)
        workspace.finish()
        #expect(fixture.windows[11]?.frame == originalFirst)
        #expect(fixture.windows[12]?.frame == originalSecond)
        #expect(fixture.events.last == "destroy")
        #expect(workspace.displayID == nil)
        let events = fixture.events
        workspace.finish()
        #expect(fixture.events == events)
    }

    @Test func grantIsVisibleAndFinalCleanupPreservesOriginalMinimization() async throws {
        let fixture = Fixture()
        let target = fixture.target(11, minimized: true)
        let original = fixture.windows[11]!.frame
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())
        _ = try await workspace.park(target)
        #expect(fixture.windows[11]?.isMinimized == false)

        try workspace.restore(windowID: 11, forInteraction: true)
        #expect(fixture.windows[11]?.frame == original)
        #expect(fixture.windows[11]?.isMinimized == false)
        workspace.finish()
        #expect(fixture.windows[11]?.isMinimized == true)
        #expect(fixture.events.last == "destroy")
    }

    @Test func failedMoveRestoresEvenWhenTheAppMovedBeforeReportingFailure() async throws {
        let fixture = Fixture()
        let target = fixture.target(11)
        let original = fixture.windows[11]!.frame
        fixture.failNextMoveAfterMutation = true
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())

        await #expect(throws: VirtualDisplayWorkspace.Failure.self) { try await workspace.park(target) }

        #expect(fixture.windows[11]?.frame == original)
        #expect(fixture.events.contains("restore:11"))
        workspace.finish()
        #expect(fixture.events.last == "destroy")
    }

    @Test func finishDuringCreationInvalidatesLateDisplayWithoutMovingWindow() async throws {
        let fixture = Fixture()
        fixture.delayCreation = true
        let target = fixture.target(11)
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())
        let task = Task { try await workspace.park(target) }
        await waitUntil { fixture.creationContinuation != nil }

        workspace.finish()
        fixture.resumeCreation()
        do { _ = try await task.value; Issue.record("A finished workspace parked a window") }
        catch {}

        #expect(!fixture.events.contains("park:11"))
        #expect(fixture.events.filter { $0 == "destroy" }.count == 1)
        #expect(workspace.displayID == nil)
    }

    @Test func lateOldCreationCannotOverwriteNewWorkspacesPublishedDisplay() async throws {
        let oldFixture = Fixture(virtualID: 101)
        oldFixture.delayCreation = true
        let oldTarget = oldFixture.target(11)
        let old = VirtualDisplayWorkspace(adapters: oldFixture.adapters(publishing: true))
        let oldTask = Task { try await old.park(oldTarget) }
        await waitUntil { oldFixture.creationContinuation != nil }
        old.finish()

        let newFixture = Fixture(virtualID: 202)
        let newTarget = newFixture.target(22)
        let current = VirtualDisplayWorkspace(adapters: newFixture.adapters(publishing: true))
        defer { current.finish() }
        _ = try await current.park(newTarget)
        #expect(VirtualDisplayWorkspace.activeDisplayID == 202)
        oldFixture.resumeCreation()
        do { _ = try await oldTask.value; Issue.record("The old workspace resumed") }
        catch {}

        #expect(VirtualDisplayWorkspace.activeDisplayID == 202)
        #expect(oldFixture.events.filter { $0 == "destroy" }.count == 1)
    }

    @Test func finishDuringMoveVerificationCannotReparkAfterRestoration() async throws {
        let fixture = Fixture()
        fixture.ignoreNextParkingMove = true
        fixture.delayPause = true
        let target = fixture.target(11)
        let original = fixture.windows[11]!.frame
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())
        let task = Task { try await workspace.park(target) }
        await waitUntil { fixture.pauseContinuation != nil }

        workspace.finish()
        let eventsAfterFinish = fixture.events
        fixture.resumePause()
        do { _ = try await task.value; Issue.record("The window was parked after cleanup") }
        catch {}

        #expect(fixture.events == eventsAfterFinish)
        #expect(fixture.windows[11]?.frame == original)
        #expect(fixture.events.last == "destroy")
    }

    @Test func failedRestoreRecordRemainsForFinishRetry() async throws {
        let fixture = Fixture()
        let target = fixture.target(11)
        let original = fixture.windows[11]!.frame
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())
        _ = try await workspace.park(target)
        fixture.restoreFailures = 1

        #expect(throws: VirtualDisplayWorkspace.Failure.self) { try workspace.restore(windowID: 11) }
        workspace.finish()

        #expect(fixture.windows[11]?.frame == original)
        #expect(fixture.events.filter { $0 == "restore:11" }.count == 2)
        #expect(fixture.events.last == "destroy")
    }

    @Test func lostOriginalMonitorRestoresIntoSurvivingDisplay() async throws {
        let fixture = Fixture()
        fixture.screens.append(.init(id: 2, frame: CGRect(x: 1600, y: 0, width: 1920, height: 1080), isMain: false, isMirrored: false))
        let target = fixture.target(11, frame: CGRect(x: 2400, y: 400, width: 1400, height: 800))
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())
        _ = try await workspace.park(target)
        fixture.screens.removeAll { $0.id == 2 }

        workspace.finish()

        let restored = try #require(fixture.windows[11]?.frame)
        #expect(fixture.screens[0].frame.contains(restored))
        #expect(restored.size == CGSize(width: 1400, height: 800))
    }

    @Test func unsupportedWindowsFailBeforeCreatingDisplay() async throws {
        for issue in ["fullscreen", "immovable", "huge"] {
            let fixture = Fixture()
            let target = fixture.target(11, frame: CGRect(x: 10, y: 10, width: issue == "huge" ? 5000 : 700, height: 500),
                                        fullScreen: issue == "fullscreen", canMove: issue != "immovable")
            let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())

            await #expect(throws: VirtualDisplayWorkspace.Failure.self) { try await workspace.park(target) }

            #expect(!fixture.events.contains("create"))
            workspace.finish()
        }
    }

    @Test func layoutChangesAreRejectedBeforeAnyWindowMove() async throws {
        let fixture = Fixture()
        fixture.disturbPhysicalLayout = true
        let target = fixture.target(11)
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())

        await #expect(throws: VirtualDisplayWorkspace.Failure.self) { try await workspace.park(target) }

        #expect(!fixture.events.contains("park:11"))
        #expect(fixture.events.contains("destroy"))
        #expect(fixture.events.last == "restore-layout")
        #expect(fixture.screens[0].frame.origin == .zero)
        workspace.finish()
    }

    @Test func displayRemovalPreservesTheUsersCurrentLayout() async throws {
        let fixture = Fixture()
        fixture.screens.append(.init(id: 2, frame: CGRect(x: 1600, y: 0, width: 1920, height: 1080), isMain: false, isMirrored: false))
        let target = fixture.target(11)
        let workspace = VirtualDisplayWorkspace(adapters: fixture.adapters())
        _ = try await workspace.park(target)
        // The user rearranges an existing monitor while the task runs; preserve that newer layout.
        fixture.screens = fixture.screens.map { screen in
            screen.id == 2 ? .init(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), isMain: false, isMirrored: false) : screen
        }
        let userLayout = fixture.screens.filter { $0.id != fixture.virtualID }
        fixture.shiftLayoutOnDestroy = true

        workspace.finish()

        #expect(fixture.screens == userLayout)
        #expect(fixture.events.last == "restore-layout")
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition())
    }

    @MainActor private final class Fixture {
        let virtualID: CGDirectDisplayID
        var screens: [VirtualDisplayWorkspace.DisplayState] = [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), isMain: true, isMirrored: false)]
        var windows: [CGWindowID: VirtualDisplayWorkspace.WindowState] = [:]
        var events: [String] = []
        var delayCreation = false
        var delayPause = false
        var creationContinuation: CheckedContinuation<Void, Never>?
        var pauseContinuation: CheckedContinuation<Void, Never>?
        var failNextMoveAfterMutation = false
        var ignoreNextParkingMove = false
        var restoreFailures = 0
        var disturbPhysicalLayout = false
        var shiftLayoutOnDestroy = false

        init(virtualID: CGDirectDisplayID = 100) { self.virtualID = virtualID }

        func target(_ id: CGWindowID, frame: CGRect = CGRect(x: 100, y: 100, width: 700, height: 500),
                    minimized: Bool = false, fullScreen: Bool = false, canMove: Bool = true) -> TargetWindow {
            windows[id] = .init(frame: frame, isMinimized: minimized, isFullScreen: fullScreen, canMove: canMove)
            let element = AXUIElementCreateApplication(-23456)
            return TargetWindow(pid: -23456, bundleID: "test.fixture", appName: "Fixture", cgWindowID: id,
                                axApp: element, axWindow: element, toolkit: .appKit, backingScale: 1,
                                scWindow: nil, frameCG: frame, title: "Fixture window")
        }

        func adapters(publishing: Bool = false) -> VirtualDisplayWorkspace.Adapters {
            .init(
                displays: { self.screens },
                createDisplay: { width, height in
                    self.events.append("create")
                    if self.delayCreation { await withCheckedContinuation { self.creationContinuation = $0 } }
                    self.screens.append(.init(id: self.virtualID, frame: CGRect(x: 0, y: 0, width: Int(width), height: Int(height)), isMain: false, isMirrored: false))
                    return .init(id: self.virtualID) {
                        self.events.append("destroy")
                        self.screens.removeAll { $0.id == self.virtualID }
                        if self.shiftLayoutOnDestroy {
                            self.screens = self.screens.map { .init(id: $0.id, frame: $0.frame.offsetBy(dx: -100, dy: 0), isMain: $0.isMain, isMirrored: $0.isMirrored) }
                        }
                    }
                },
                arrangeDisplay: { id, origin, preserving in
                    self.events.append("arrange")
                    #expect(preserving.allSatisfy { self.screens.contains($0) })
                    self.screens = self.screens.map { screen in
                        if screen.id == id { return .init(id: id, frame: CGRect(origin: origin, size: screen.frame.size), isMain: false, isMirrored: false) }
                        if self.disturbPhysicalLayout { return .init(id: screen.id, frame: screen.frame.offsetBy(dx: -100, dy: 0), isMain: screen.isMain, isMirrored: screen.isMirrored) }
                        return screen
                    }
                },
                restoreDisplayLayout: { original in
                    self.events.append("restore-layout")
                    self.screens = original
                },
                readWindow: { target in
                    guard let state = self.windows[target.cgWindowID] else { throw VirtualDisplayWorkspace.Failure.unavailable("Fixture window gone") }
                    return state
                },
                moveWindow: { target, frame in
                    let parking = self.screens.first(where: { $0.id == self.virtualID })?.frame.contains(frame) == true
                    self.events.append("\(parking ? "park" : "restore"):\(target.cgWindowID)")
                    if !parking, self.restoreFailures > 0 {
                        self.restoreFailures -= 1
                        throw VirtualDisplayWorkspace.Failure.unavailable("Fixture restore failed")
                    }
                    if parking, self.ignoreNextParkingMove { self.ignoreNextParkingMove = false; return }
                    let old = self.windows[target.cgWindowID]!
                    self.windows[target.cgWindowID] = .init(frame: frame, isMinimized: old.isMinimized, isFullScreen: old.isFullScreen, canMove: old.canMove)
                    if self.failNextMoveAfterMutation {
                        self.failNextMoveAfterMutation = false
                        throw VirtualDisplayWorkspace.Failure.unavailable("Fixture moved then failed")
                    }
                },
                setMinimized: { target, minimized in
                    let old = self.windows[target.cgWindowID]!
                    self.windows[target.cgWindowID] = .init(frame: old.frame, isMinimized: minimized, isFullScreen: old.isFullScreen, canMove: old.canMove)
                },
                pause: {
                    if self.delayPause { await withCheckedContinuation { self.pauseContinuation = $0 } }
                    else { await Task.yield() }
                },
                publishesActiveDisplay: publishing
            )
        }

        func resumeCreation() { creationContinuation?.resume(); creationContinuation = nil }
        func resumePause() { pauseContinuation?.resume(); pauseContinuation = nil; delayPause = false }
    }
}
