import AppKit
import FamiliarContracts
import Testing
@testable import Familiar

@Suite
@MainActor
struct MouseGrantRecoveryTests {
    @Test
    func betweenCallsTakeoverReturnsNoticeThenAllowsBackgroundWork() async {
        let fixture = Fixture()
        fixture.control.humanInput("keyboard")

        let notice = await fixture.control.perform("wait", ["duration": 0])

        #expect(!notice.isError)
        #expect((notice.content as? String)?.contains("took the mouse back") == true)
        #expect(!fixture.control.stopped)
        #expect(!fixture.control.grantActive)
        #expect(fixture.ladder.step == 0)

        let resumed = await fixture.control.perform("wait", ["duration": 0])

        #expect(!resumed.isError)
        #expect(resumed.content as? String == "OK")
        #expect(fixture.ladder.step == 1)
    }

    @Test
    func inFlightTypingStopsAfterCurrentCharacterAndReportsPossiblePartialInput() async {
        let fixture = Fixture()
        var events: [CGEventType] = []
        fixture.control.dispatchEvent = { event in
            events.append(event.type)
            #expect(event.getIntegerValueField(.eventSourceUserData) == ComputerController.tag)
            if events.count == 1 { fixture.control.humanInput("keyboard") }
        }

        let result = await fixture.control.perform("type", ["text": "ABC"])

        #expect(!result.isError)
        #expect((result.content as? String)?.contains("may have partly run") == true)
        #expect(events == [.keyDown, .keyUp], "Release the posted key, but do not type the remaining characters")
        #expect(!fixture.control.stopped)
        let resumed = await fixture.control.perform("wait", ["duration": 0])
        #expect(resumed.content as? String == "OK")
    }

    @Test
    func clickElementConsumesBetweenCallsHandbackBeforeInspectingAnOldID() async {
        let fixture = Fixture()
        fixture.control.humanInput("keyboard")

        let notice = await fixture.control.clickElement(["id": 999])

        #expect(!notice.isError)
        #expect((notice.content as? String)?.contains("took the mouse back") == true)
        #expect(fixture.ladder.step == 0)
        let resumed = await fixture.control.perform("wait", ["duration": 0])
        #expect(resumed.content as? String == "OK")
    }

    @Test
    func handbackInvalidatesPreviouslyFreshCoordinatesUntilAnotherScreenshot() async {
        let fixture = Fixture()
        fixture.ladder.viewportDirty = false
        fixture.control.humanInput("keyboard")
        _ = await fixture.control.perform("wait", ["duration": 0])

        #expect(fixture.ladder.viewportDirty)
        for _ in 0..<2 {
            let result = await fixture.control.perform("left_click", ["coordinate": [100, 100]])
            #expect(!result.isError)
            #expect((result.content as? String)?.contains("Take a new screenshot before clicking") == true)
            #expect(fixture.ladder.viewportDirty)
        }
    }

    @Test
    func resetDiscardsOldHandbackRatherThanBlockingTheNextRequest() async {
        let fixture = Fixture()
        fixture.control.humanInput("keyboard")
        fixture.control.reset()

        let result = await fixture.control.perform("wait", ["duration": 0])

        #expect(result.content as? String == "OK")
        #expect(!result.isError)
    }

    @Test
    func endDiscardsOldHandbackAndStopsTheOldLadder() {
        let fixture = Fixture()
        fixture.control.humanInput("keyboard")
        fixture.control.end()

        #expect(fixture.control.takeGrantNotice() == nil)
        #expect(!fixture.control.active)
        #expect(fixture.ladder.isStopped())
    }

    @Test
    func explicitStopWinsOverPendingHandbackForBothEntryPoints() async {
        let fixture = Fixture()
        fixture.control.humanInput("keyboard")
        fixture.control.stop(reason: "test stop")

        for result in [await fixture.control.perform("wait", ["duration": 0]),
                       await fixture.control.clickElement(["id": 1])] {
            #expect(result.isError)
            #expect(result.content as? String == "Stopped.")
        }
        #expect(fixture.ladder.step == 0)
    }

    @Test
    func cancellationWinsOverPendingHandbackForBothEntryPoints() async {
        let fixture = Fixture()
        fixture.control.humanInput("keyboard")

        let results = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return [await fixture.control.perform("wait", ["duration": 0]),
                    await fixture.control.clickElement(["id": 1])]
        }.value

        for result in results {
            #expect(result.isError)
            #expect(result.content as? String == "Stopped.")
        }
        #expect(fixture.ladder.step == 0)
    }

    @Test
    func explicitStopDuringTypingRemainsAHardFailureAndReleasesThePostedKey() async {
        let fixture = Fixture()
        var events: [CGEventType] = []
        fixture.control.dispatchEvent = { event in
            events.append(event.type)
            if events.count == 1 { fixture.control.stop(reason: "test stop") }
        }

        let result = await fixture.control.perform("type", ["text": "ABC"])

        #expect(result.isError)
        #expect(result.content as? String == "Stopped.")
        #expect(events == [.keyDown, .keyUp])
        #expect(fixture.control.stopped)
    }

    @MainActor
    private final class Fixture {
        let ladder: ActionLadder
        let control: ComputerController

        init() {
            let element = AXUIElementCreateApplication(-23456)
            let target = TargetWindow(pid: -23456, bundleID: "test.handoff", appName: "Fixture", cgWindowID: 0,
                                      axApp: element, axWindow: element, toolkit: .appKit, backingScale: 1,
                                      scWindow: nil, frameCG: CGRect(x: 0, y: 0, width: 640, height: 480), title: "Fixture")
            ladder = ActionLadder(target: target, maxLongEdge: 640)
            ladder.refreshWindow = { _ in true }
            control = ComputerController(backgroundSession: ladder, mouseGranted: true)
            control.dispatchEvent = { _ in Issue.record("Unexpected native input") }
        }
    }
}
