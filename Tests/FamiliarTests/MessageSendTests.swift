import AppKit
import Testing
@testable import Familiar

@Suite @MainActor struct MessageSendTests {
    @Test func approvalShowsExactDraftAndSendsReturnOnlyOnce() async throws {
        let f = Fixture()
        defer { f.control.end() }
        let send = Task { await f.control.sendMessage(f.input) }
        try await f.waitForApproval()
        #expect(f.sent == 0)
        #expect(f.feed.approvalMessage == "Hello 👋")
        #expect(f.feed.approvalContext?.contains("Message to Avery") == true)
        #expect(f.feed.phase == .confirming("Send message to Avery"))
        f.feed.onGoAhead?()
        let result = await send.value
        #expect(f.sent == 1)
        #expect((result.content as? String)?.contains("Delivery is not yet verified") == true)
        #expect(f.feed.approvalMessage == nil)
        #expect(f.feed.onGoAhead == nil)
    }

    @Test(arguments: ["text", "recipient", "window", "field", "unreadable"])
    func changedDraftOrDestinationInvalidatesPendingApproval(change: String) async throws {
        let f = Fixture()
        defer { f.control.end() }
        let send = Task { await f.control.sendMessage(f.input) }
        try await f.waitForApproval()
        switch change {
        case "text": f.draft.text += " changed"
        case "recipient": f.draft.context = ["Message to Blake"]
        case "window": f.draft.windowID += 1
        case "field": f.draft.field = AXUIElementCreateApplication(-65432)
        default: f.readable = false
        }
        f.feed.onGoAhead?()
        let result = await send.value
        #expect(f.sent == 0)
        #expect((result.content as? String)?.contains("changed") == true)
    }

    @Test func focusChangeDuringNativePreparationIsCheckedAgainBeforeReturn() async throws {
        let f = Fixture()
        defer { f.control.end() }
        f.ladder.makeMainForTyping = { _ in f.draft.context = ["Message to Blake"]; return true }
        let send = Task { await f.control.sendMessage(f.input) }
        try await f.waitForApproval()
        f.feed.onGoAhead?()
        _ = await send.value
        #expect(f.sent == 0)
    }

    @Test(arguments: [false, true])
    func declineOrStopNeverSends(stop: Bool) async throws {
        let f = Fixture()
        defer { f.control.end() }
        let send = Task { await f.control.sendMessage(f.input) }
        try await f.waitForApproval()
        if stop { f.control.stop(reason: "test") } else { f.feed.onNotNow?() }
        _ = await send.value
        #expect(f.sent == 0)
        #expect(f.feed.onGoAhead == nil)
    }

    @Test func wrongTextOrRecipientDoesNotEvenRequestApproval() async {
        let f = Fixture()
        defer { f.control.end() }
        _ = await f.control.sendMessage(["recipient": "Blake", "message": "Hello 👋"])
        _ = await f.control.sendMessage(["recipient": "Avery", "message": "Different text"])
        #expect(f.sent == 0)
        #expect(f.feed.onGoAhead == nil)
        #expect(!f.draft.identifies("Aver"))
        #expect(f.draft.identifies("@Avery"))
    }

    @Test func anotherSendCannotReplaceThePendingDecision() async throws {
        let f = Fixture()
        defer { f.control.end() }
        let send = Task { await f.control.sendMessage(f.input) }
        try await f.waitForApproval()
        let id = f.feed.approvalRequestID
        let duplicate = await f.control.sendMessage(f.input)
        #expect((duplicate.content as? String)?.contains("pending") == true)
        #expect(f.feed.approvalRequestID == id)
        f.feed.onNotNow?()
        _ = await send.value
        #expect(f.sent == 0)
    }

    @MainActor private final class Fixture {
        let control: ComputerController
        let ladder: ActionLadder
        let feed = PeekFeed()
        var draft: KeyboardMessageDraft
        var readable = true
        var sent = 0
        var input: [String: Any] { ["recipient": "Avery", "message": "Hello 👋"] }
        init() {
            let ax = AXUIElementCreateApplication(-23456)
            let frame = CGRect(x: 20, y: 20, width: 800, height: 600)
            let target = TargetWindow(pid: -23456, bundleID: "test.message", appName: "Fixture", cgWindowID: 12,
                                      axApp: ax, axWindow: ax, toolkit: .electron, backingScale: 1,
                                      scWindow: nil, frameCG: frame, title: "Conversation")
            draft = KeyboardMessageDraft(pid: target.pid, windowID: target.cgWindowID, window: ax, field: ax,
                                         windowTitle: target.title, windowFrame: frame, role: "AXTextArea",
                                         context: ["Message to Avery"], text: "Hello 👋")
            ladder = ActionLadder(target: target, maxLongEdge: 800)
            ladder.refreshWindow = { _ in true }
            ladder.makeMainForTyping = { _ in true }
            control = ComputerController(backgroundSession: ladder, mouseGranted: false)
            control.peek = feed
            control.readMessageDraft = { _ in self.readable ? self.draft : nil }
            ladder.postMessageReturn = { _ in self.sent += 1 }
        }
        func waitForApproval() async throws {
            for _ in 0..<200 where feed.onGoAhead == nil { await Task.yield() }
            try #require(feed.onGoAhead != nil)
        }
    }
}
