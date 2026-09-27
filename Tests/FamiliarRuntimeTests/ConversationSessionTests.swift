import Foundation
import Testing
@testable import FamiliarRuntime

@Suite
@MainActor
struct ConversationSessionTests {
    @Test
    func apiPreparationPreservesSignedToolHistoryAndNestedResultImages() throws {
        let session = ConversationSession()
        let first = try session.begin(content: [image("old-image"), text("First question")])
        let firstContent = try #require(first.messages.first?["content"] as? [[String: Any]])
        #expect(firstContent.first?["text"] as? String == "First question")
        #expect(firstContent.last?["type"] as? String == "image")
        #expect((firstContent.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        let signedToolTurn: [String: Any] = ["role": "assistant", "content": [
            ["type": "thinking", "thinking": "Inspect the screen.", "signature": "signed-thinking-fixture"],
            ["type": "tool_use", "id": "capture-1", "name": "screenshot", "toolset_name": "computer", "input": ["display_id": 4]],
        ]]
        let toolResult: [String: Any] = ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "capture-1", "toolset_name": "computer", "content": [image("tool-image")]],
        ]]
        let answer = message("assistant", "First answer")
        #expect(session.complete(first, messages: first.messages + [signedToolTurn, toolResult, answer]))
        #expect(!session.isCurrent(first))

        let second = try session.begin(content: [image("new-image"), text("Second question"), text("Extra context")])
        let expectedFirst = message("user", "First question", "[earlier screenshot omitted]")
        let expectedLatest: [String: Any] = ["role": "user", "content": [text("Second question"), text("Extra context"), cached(image("new-image"))]]
        let expected = [expectedFirst, signedToolTurn, toolResult, answer, expectedLatest]
        #expect(NSArray(array: second.messages).isEqual(to: expected))
        #expect(NSArray(array: session.messages).isEqual(to: expected))
        // Returned turns remain snapshots after preparing the following API request.
        #expect(NSArray(array: first.messages).isEqual(to: [["role": "user", "content": [text("First question"), cached(image("old-image"))]]]))
        #expect(session.fail(second))
    }

    @Test
    func cliPreparationLeavesImageOrderAndPriorHistoryUntouched() throws {
        let session = ConversationSession()
        let initial = [image("first"), cached(text("Keep this metadata"))]
        let first = try session.begin(content: initial, prepareImages: false)
        let answer = message("assistant", "Answer")
        #expect(session.complete(first, messages: first.messages + [answer]))
        let next = [image("second"), text("Text remains after image")]
        let second = try session.begin(content: next, prepareImages: false)
        let expected: [[String: Any]] = [["role": "user", "content": initial], answer, ["role": "user", "content": next]]
        #expect(NSArray(array: second.messages).isEqual(to: expected))
        #expect(session.fail(second))
    }

    @Test
    func historyLimitDropsAnEntireOldExchangeWithoutSplittingTools() throws {
        let session = ConversationSession()
        let first = try session.begin(content: [text("Old question")], prepareImages: false)
        let oldExchange: [[String: Any]] = [
            message("user", "Old question"), toolUse("old"), toolResult("old"), message("assistant", "Old answer"),
        ]
        var retained: [[String: Any]] = [
            message("user", "Retained question"), toolUse("retained"), toolResult("retained"), message("assistant", "Retained answer"),
        ]
        for index in 0..<8 { retained += [message("user", "Question \(index)"), message("assistant", "Answer \(index)")] }
        #expect(oldExchange.count + retained.count == 24)
        #expect(session.complete(first, messages: oldExchange + retained))

        let next = try session.begin(content: [text("Latest question")], prepareImages: false)
        #expect(next.messages.count == 21)
        #expect(NSArray(array: next.messages).isEqual(to: retained + [message("user", "Latest question")]))
        #expect(session.fail(next))
        #expect(NSArray(array: session.messages).isEqual(to: retained))
    }

    @Test
    func failureDropsOnlyItsCurrentUserTurnAndCanReleaseOnlyOnce() throws {
        let session = ConversationSession()
        let first = try session.begin(content: [text("Successful question")], prepareImages: false)
        let saved = first.messages + [toolUse("saved"), toolResult("saved"), message("assistant", "Saved answer")]
        #expect(session.complete(first, messages: saved))
        let failed = try session.begin(content: [text("Failed question")], prepareImages: false)
        #expect(session.isCurrent(failed))
        #expect(session.fail(failed))
        #expect(!session.isRunning)
        #expect(!session.isCurrent(failed))
        #expect(NSArray(array: session.messages).isEqual(to: saved))
        #expect(!session.fail(failed))
        #expect(!session.complete(failed, messages: []))
        #expect(NSArray(array: session.messages).isEqual(to: saved))
    }

    @Test
    func clearInvalidatesResultsButKeepsTheActiveSlotUntilCompletion() throws {
        let session = ConversationSession()
        let cleared = try session.begin(content: [text("Question before clear")])
        session.clear()
        #expect(session.messages.isEmpty)
        #expect(session.isRunning)
        #expect(!session.isCurrent(cleared))
        #expect(throws: ConversationSessionError.turnAlreadyRunning) { try session.begin(content: [text("Too early")]) }
        #expect(session.messages.isEmpty)
        #expect(!session.complete(cleared, messages: cleared.messages + [message("assistant", "Stale answer")]))
        #expect(!session.isRunning)
        #expect(session.messages.isEmpty)

        let next = try session.begin(content: [text("New question")])
        #expect(!session.fail(cleared))
        #expect(!session.complete(cleared, messages: []))
        #expect(session.isRunning)
        #expect(session.isCurrent(next))
        #expect(session.complete(next, messages: next.messages + [message("assistant", "New answer")]))
        #expect(!session.isRunning)
        #expect(session.messages.count == 2)
    }

    @Test
    func providerChangeRetainsOnlyTextAndAStaleFailureCannotRemoveIt() throws {
        let session = ConversationSession()
        let first = try session.begin(content: [text("Question")], prepareImages: false)
        let history: [[String: Any]] = [
            ["role": "user", "content": "Plain string history"],
            ["role": "assistant", "content": [text("First paragraph"), ["type": "thinking", "thinking": "Private reasoning", "signature": "provider-signature"], cached(text("Second paragraph")), image("discarded")]],
            toolUse("discarded"), toolResult("discarded"),
            ["role": "user", "content": [image("also-discarded")]],
        ]
        #expect(session.complete(first, messages: history))
        let running = try session.begin(content: [image("current-image"), text("Current question")], prepareImages: false)
        session.retainTextForProviderChange()
        let expected = [message("user", "Plain string history"), message("assistant", "First paragraph\nSecond paragraph"), message("user", "Current question")]
        #expect(NSArray(array: session.messages).isEqual(to: expected))
        #expect(session.isRunning)
        #expect(!session.isCurrent(running))
        #expect(throws: ConversationSessionError.turnAlreadyRunning) { try session.begin(content: [text("Too early")]) }
        #expect(!session.fail(running))
        #expect(!session.isRunning)
        #expect(NSArray(array: session.messages).isEqual(to: expected))
        let next = try session.begin(content: [text("Different provider question")], prepareImages: false)
        #expect(NSArray(array: next.messages).isEqual(to: expected + [message("user", "Different provider question")]))
        #expect(session.fail(next))
    }

    @Test
    func overlappingBeginRejectsBeforeMutatingHistoryAndOtherSessionsCannotFinishIt() throws {
        let session = ConversationSession()
        let first = try session.begin(content: [image("old-image"), text("Old question")], prepareImages: false)
        #expect(session.complete(first, messages: first.messages + [message("assistant", "Answer")]))
        let running = try session.begin(content: [image("active-image"), text("Active question")], prepareImages: false)
        let snapshot = session.messages
        #expect(throws: ConversationSessionError.turnAlreadyRunning) { try session.begin(content: [text("Must not strip images")]) }
        #expect(NSArray(array: session.messages).isEqual(to: snapshot))
        #expect(session.isCurrent(running))

        let other = ConversationSession()
        let unrelated = try other.begin(content: [text("Independent session")])
        #expect(!session.complete(unrelated, messages: []))
        #expect(!session.fail(unrelated))
        #expect(session.isRunning)
        #expect(session.isCurrent(running))
        #expect(session.fail(running))
        #expect(other.fail(unrelated))
    }

    private func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
    private func image(_ value: String) -> [String: Any] { ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": value]] }
    private func cached(_ block: [String: Any]) -> [String: Any] {
        var block = block
        block["cache_control"] = ["type": "ephemeral"]
        return block
    }
    private func message(_ role: String, _ texts: String...) -> [String: Any] { ["role": role, "content": texts.map { text($0) }] }
    private func toolUse(_ id: String) -> [String: Any] {
        ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": "inspect", "input": ["value": id]]]]
    }
    private func toolResult(_ id: String) -> [String: Any] {
        ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": [image(id)]]]]
    }
}
