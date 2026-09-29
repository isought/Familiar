import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

@Suite @MainActor
struct CardConversationTests {
    @Test func adjustmentsSaveContextAndHandoffSnapshotsTheAcceptedAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MorningStore(directory: directory)
        let card = MorningCard(folderID: store.folders[0].id, title: "Reply to Alex",
            action: MorningAction(title: "Prepare reply", instruction: "Draft a response"))
        try store.saveCard(card)
        let conversation = CardConversation(store: store)
        conversation.select(card.id)
        let router = try ToolRouter(routes: conversation.routes())
        let updated = await router.execute("update_card_context", ["context": "Keep the tone brief", "actionInstruction": "Draft a short reply asking for the date"], toolset: nil)
        #expect(!updated.isError)
        #expect(store.cards.first?.personalContext == "Keep the tone brief")
        #expect(store.workItems.isEmpty)
        var handoff: UUID?
        conversation.onHandoff = { handoff = $0.id }
        let accepted = await router.execute("queue_card_action", [:], toolset: nil)
        #expect(!accepted.isError)
        #expect(handoff == store.workItems.first?.id)
        #expect(store.workItems.first?.action.instruction == "Draft a short reply asking for the date")
        _ = await router.execute("update_card_context", ["context": "We now have the date", "actionInstruction": "Draft a confirmation"], toolset: nil)
        #expect(store.workItems.first?.action.instruction == "Draft a short reply asking for the date")
        #expect(store.cards.first?.action.instruction == "Draft a confirmation")
        #expect(conversation.context.contains("We now have the date"))
    }

    @Test func leavingTheDiscussionRevokesItsCardTools() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MorningStore(directory: directory)
        let card = MorningCard(folderID: store.folders[0].id, title: "Review",
            action: MorningAction(title: "Prepare", instruction: "Summarize"))
        try store.saveCard(card)
        let conversation = CardConversation(store: store)
        conversation.select(card.id)
        let router = try ToolRouter(routes: conversation.routes())
        conversation.clear()
        let reply = await router.execute("queue_card_action", [:], toolset: nil)
        #expect(reply.isError)
        #expect(store.workItems.isEmpty)
    }

    @Test func humanHandledIsSeparateFromExecutingAnAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MorningStore(directory: directory)
        let card = MorningCard(folderID: store.folders[0].id, title: "Reply",
            action: MorningAction(title: "Draft", instruction: "Draft response"))
        try store.saveCard(card)
        let conversation = CardConversation(store: store)
        conversation.select(card.id)
        let router = try ToolRouter(routes: conversation.routes())
        let result = await router.execute("set_card_handled", ["handled": true], toolset: nil)
        #expect(!result.isError)
        #expect(store.cards.first?.isResolved == true)
        #expect(store.workItems.isEmpty)
        let invalid = await router.execute("queue_card_action", [:], toolset: nil)
        #expect(invalid.isError)
    }
}
