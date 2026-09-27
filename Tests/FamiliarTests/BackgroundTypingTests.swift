import AppKit
import ApplicationServices
import Testing
@testable import Familiar

@Suite
@MainActor
struct BackgroundTypingTests {
    @Test
    func absentTextFocusRejectsTypingBeforeAnyInputIsPosted() async {
        let fixture = Fixture(role: nil)

        let result = await fixture.ladder.run("type", ["text": "Hello world from bot 👋"])

        #expect(fixture.posted.isEmpty)
        #expect(fixture.mainRequests == 0)
        #expect(!result.isError) // A no-input refusal must allow the model to focus the field and retry.
        #expect((result.content as? String)?.contains("No text was entered") == true)
    }

    @Test(arguments: ["AXWebArea", "AXButton", "AXGroup", "AXWindow"])
    func nonTextFocusDoesNotReceiveTypingOrSpaceKeys(role: String) async {
        let fixture = Fixture(role: role)

        let result = await fixture.ladder.run("type", ["text": "words with spaces"])

        #expect(!result.isError)
        #expect(fixture.posted.isEmpty)
        #expect(fixture.mainRequests == 0)
    }

    @Test
    func textFieldInAnotherWindowCannotReceiveTheTargetsTyping() async {
        let fixture = Fixture(role: "AXTextField", belongsToTarget: false)

        let result = await fixture.ladder.run("type", ["text": "private draft"])

        #expect(!result.isError)
        #expect(fixture.posted.isEmpty)
        #expect(fixture.mainRequests == 0)
    }

    @Test(arguments: ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"])
    func focusedTextEntryKeepsTheExistingInputPath(role: String) async {
        let fixture = Fixture(role: role, toolkit: .chromium)
        let text = "Hello world from bot 👋"

        _ = await fixture.ladder.run("type", ["text": text])

        #expect(fixture.posted == [text])
        #expect(fixture.mainRequests == 1)
    }

    @Test
    func secureTextFocusStillRejectsInput() async {
        let fixture = Fixture(role: "AXSecureTextField")

        let result = await fixture.ladder.run("type", ["text": "secret"])

        #expect(result.isError)
        #expect(fixture.posted.isEmpty)
        #expect(fixture.mainRequests == 0)
    }

    @Test
    func focusLostWhileTakingTheBeforeSnapshotRejectsInput() async {
        let fixture = Fixture(role: "AXTextField")
        fixture.ladder.captureTypingState = { _ in
            fixture.ladder.readTypingFocus = { nil }
            return AXSnapshot()
        }

        let result = await fixture.ladder.run("type", ["text": "must not reach the page"])

        #expect(!result.isError)
        #expect(fixture.posted.isEmpty)
        #expect((result.content as? String)?.contains("No text was entered") == true)
    }

    @Test
    func focusMovingToAnotherTextFieldDoesNotRedirectInput() async {
        let fixture = Fixture(role: "AXTextField")
        fixture.ladder.captureTypingState = { _ in
            fixture.ladder.readTypingFocus = {
                ActionLadder.TypingFocus(element: AXUIElementCreateApplication(-23457),
                                        info: IrreversibleGuard.ElementInfo(role: "AXTextField"),
                                        belongsToTarget: true)
            }
            return AXSnapshot()
        }

        let result = await fixture.ladder.run("type", ["text": "must stay in the intended field"])

        #expect(!result.isError)
        #expect(fixture.posted.isEmpty)
    }

    @Test
    func stopWhileTakingTheBeforeSnapshotPreventsInput() async {
        let fixture = Fixture(role: "AXTextField")
        fixture.ladder.captureTypingState = { _ in
            fixture.stopped = true
            return AXSnapshot()
        }

        let result = await fixture.ladder.run("type", ["text": "stop before dispatch"])

        #expect(result.isError)
        #expect(fixture.posted.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let ladder: ActionLadder
        var posted: [String] = []
        var mainRequests = 0
        var stopped = false

        init(role: String?, belongsToTarget: Bool = true, toolkit: TargetWindow.Toolkit = .appKit) {
            let element = AXUIElementCreateApplication(-23456)
            let target = TargetWindow(pid: -23456, bundleID: "test.typing", appName: "Fixture", cgWindowID: 0,
                                      axApp: element, axWindow: element, toolkit: toolkit, backingScale: 1,
                                      scWindow: nil, frameCG: CGRect(x: 0, y: 0, width: 640, height: 480), title: "Fixture")
            ladder = ActionLadder(target: target, maxLongEdge: 640)
            ladder.refreshWindow = { _ in true }
            ladder.readTypingFocus = {
                guard let role else { return nil }
                return ActionLadder.TypingFocus(element: element,
                                               info: IrreversibleGuard.ElementInfo(role: role, isSecure: role == "AXSecureTextField"),
                                               belongsToTarget: belongsToTarget)
            }
            ladder.makeMainForTyping = { [unowned self] _ in
                mainRequests += 1
                return true
            }
            ladder.captureTypingState = { _ in AXSnapshot() }
            ladder.postTypedText = { [unowned self] _, text, _ in
                posted.append(text)
                stopped = true // End after the spy: verification must not read or capture a real application.
            }
            ladder.isStopped = { [unowned self] in stopped }
        }
    }
}
