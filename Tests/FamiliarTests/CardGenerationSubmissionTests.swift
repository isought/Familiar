import Foundation
import Testing
@testable import Familiar

/// The card step writes three parts: what it is, what it means for you, and 1 to 3 options.
@Suite @MainActor
struct CardGenerationSubmissionTests {
    @Test func aProposalBecomesTitleMeaningAndOptions() throws {
        let observation = Self.observation()
        let proposals = try CardGenerationSubmission(observations: [observation]).parse(["proposals": [[
            "observationKey": observation.id, "title": "Avery needs\na delivery date", "meaning": "Avery can't plan\nuntil you confirm.",
            "options": [Self.option("Prepare reply"), Self.option("Ask for a range", mode: "desktop"), Self.option("Propose Friday")]]]])
        let proposal = try #require(proposals.first)
        #expect(proposal.title == "Avery needs a delivery date")          // newlines folded, not rejected
        #expect(proposal.meaning == "Avery can't plan until you confirm.")
        #expect(proposal.action.title == "Prepare reply" && proposal.action.mode == .prepare)
        #expect(proposal.alternatives.map(\.title) == ["Ask for a range", "Propose Friday"])
        #expect(proposal.alternatives.first?.mode == .desktop)
    }

    @Test func longOrOldShapedProposalsAreTurnedDownWithTheirReason() throws {
        let observation = Self.observation()
        let submission = CardGenerationSubmission(observations: [observation])
        func row(_ changes: [String: Any]) -> [String: Any] {
            ["observationKey": observation.id, "title": "Avery needs a date", "meaning": "You owe Avery a date.",
             "options": [Self.option("Prepare reply")]].merging(changes) { _, new in new }
        }
        func reason(_ row: [String: Any]) -> String {
            do { _ = try submission.parse(["proposals": [row]]); return "" } catch { return error.localizedDescription }
        }
        let legacy: [String: Any] = ["observationKey": observation.id, "title": "Avery", "summary": "x", "rationale": "x", "timing": "", "unknowns": "",
                                     "action": Self.option("Prepare reply")]
        #expect(reason(legacy).contains("give exactly observationKey, title, meaning and options"))
        #expect(reason(row(["options": [[String: Any]]()])).contains("give 1 to 3 options"))
        #expect(reason(row(["options": Array(repeating: Self.option("Reply"), count: 4)])).contains("give 1 to 3 options"))
        #expect(reason(row(["title": String(repeating: "t", count: 101)])) == "Proposal \(observation.id): title is 101 characters; the limit is 100.")
        #expect(reason(row(["meaning": String(repeating: "m", count: 241)])).contains("meaning is 241 characters; the limit is 240"))
        #expect(reason(row(["options": [Self.option(String(repeating: "o", count: 61))]])).contains("title is 61 characters; the limit is 60"))
        #expect(reason(row(["options": [["title": "Reply", "instruction": String(repeating: "i", count: 1_001), "mode": "prepare"]]])).contains("instruction is 1001 characters"))
        #expect(reason(row(["options": [["title": "Reply", "instruction": "Draft", "mode": "auto"]]])).contains("prepare/desktop mode"))
        #expect(reason(row(["options": [["title": "Reply", "instruction": "Draft", "mode": "prepare", "why": "x"]]])).contains("prepare/desktop mode"))
        #expect(reason(row([:])).isEmpty)
    }

    @Test func thePromptAsksForShortCardsAndShowsOldCardsInTheShortForm() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MorningStore(directory: directory)
        let observation = Self.observation()
        _ = try store.applyCardGeneration(observations: [observation], proposals: [CardProposal(observationKey: observation.id,
            title: "Avery needs a date", meaning: "You owe Avery a date.", action: MorningAction(title: "Prepare reply", instruction: "Draft a reply"))],
            runIDs: [observation.runID])
        var long = store.cards[0]
        long.rationale = String(repeating: "A long explanation. ", count: 100)
        try store.saveCard(long)
        try store.updateCardContext(cardID: long.id, context: "Avery is a key customer")

        let plan = try CardGenerationSubmission(observations: [observation]).plan(morning: store)
        let text = plan.content.compactMap { $0["text"] as? String }.joined()
        let json = try #require(text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n").data(using: .utf8))
        let input = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let existing = try #require((input["existingCards"] as? [[String: Any]])?.first)
        #expect((existing["meaning"] as? String)?.count == CardGenerationSubmission.limits.meaning)
        #expect((existing["options"] as? [[String: Any]])?.first?["title"] as? String == "Prepare reply")
        #expect(existing["personalContext"] as? String == "Avery is a key customer")
        #expect(existing["summary"] == nil)
        let system = CardGenerationSubmission.system
        #expect(system.contains("Each card has exactly three parts") && system.contains("never restate, summarize or quote the item"))
        #expect(!system.contains("unknowns") && !system.contains("timing"))
    }

    private static func observation() -> CardObservation {
        CardObservation(runID: UUID(), sourceID: UUID(), itemKey: "mail-1", sourceName: "Inbox", kind: "mail", title: "Please confirm the date",
            excerpt: "Avery asks for a delivery date.", url: "", identityEvidence: "Message-ID mail-1",
            observedAt: Date(), state: .open, stateEvidence: "A question awaits a reply.")
    }

    private static func option(_ title: String, mode: String = "prepare") -> [String: Any] {
        ["title": title, "instruction": "Draft it from the saved message.", "mode": mode]
    }
}
