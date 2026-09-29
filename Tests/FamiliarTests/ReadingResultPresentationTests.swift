import Foundation
import Testing
@testable import Familiar

struct ReadingResultPresentationTests {
    @Test func backgroundResultLeadsWithFindingsAndDoesNotRepeatRules() throws {
        let source = LearnedReadingSource(kind: .mail, name: "Inbox", meaning: "My incoming mail",
            application: "Chrome", url: "https://mail.example.test", scope: "Only unread messages today",
            workflowPath: "mail/read.md")
        let snapshot = ReadingSnapshot(requestID: UUID(), sourceID: source.id, source: source,
            items: [ReadingItem(id: "message", title: "Demo agenda", text: "Taylor asks for review", evidence: "Visible row")],
            coverage: .complete, coverageNotes: ["All visible rows read", "No messages were opened"],
            accountEvidence: "Observed account", sourceEvidence: "Inbox page", scopeEvidence: "Today")
        let text = ReadingBriefing.render(snapshot)
        let finding = try #require(text.range(of: "Demo agenda"))
        let details = try #require(text.range(of: "Collection details"))
        #expect(finding.lowerBound < details.lowerBound)
        #expect(!text.contains(source.scope))
        #expect(text.contains("Observed account"))
        #expect(text.contains("• All visible rows read\n• No messages were opened"))
    }

    @Test func emptyPartialResultNeverLooksLikeAnEmptyInbox() {
        let source = LearnedReadingSource(name: "Inbox", meaning: "Incoming mail", url: "https://mail.example.test", scope: "Today")
        let snapshot = ReadingSnapshot(requestID: UUID(), sourceID: source.id, source: source,
            items: [], coverage: .partial, coverageNotes: ["The rest of the list was unavailable"],
            accountEvidence: "Observed account", sourceEvidence: "Inbox", scopeEvidence: "First viewport")
        let text = ReadingBriefing.render(snapshot)
        #expect(text.contains("Partial read"))
        #expect(text.contains("does not establish an empty source"))
        #expect(text.contains("The rest of the list was unavailable"))
    }
}
