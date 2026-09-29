import Foundation
import Testing
import FamiliarContracts
import FamiliarRuntime
@testable import Familiar

/// The chat knows the jobs taught with Watch Me and can change them through the same store as Manage sources.
@Suite @MainActor
struct SourceConversationTests {
    @Test func contextListsEveryJobWithItsRulesAndLastRun() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let inbox = fixture.inbox()
        let calendar = fixture.calendar()
        try fixture.store.saveReadingSource(inbox)
        try fixture.store.saveSource(calendar)
        try fixture.store.saveReadingSnapshot(fixture.snapshot(inbox))

        let context = fixture.conversation.context

        #expect(context.contains("## Your saved jobs"))
        #expect(context.contains("“Inbox” (id \(inbox.id.uuidString)) · Mail"))
        #expect(context.contains("Reading rules: Only unread email from the last two days"))
        #expect(context.contains("complete, 1 item"))
        #expect(context.contains("“Work” (id \(calendar.id.uuidString)) · Calendar"))
        #expect(context.contains("Calendar: Work · America/New_York"))
        #expect(context.contains("Never run"))
    }

    @Test func contextIsEmptyWhenNothingWasSaved() {
        let fixture = Fixture()
        defer { fixture.remove() }
        #expect(fixture.conversation.context.isEmpty)
    }

    @Test func aJobThatCannotRunSaysWhatIsMissingUntilItIsFixed() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let mail = LearnedReadingSource(kind: .mail, name: "Mail inbox", meaning: "My incoming mail", application: "Mail",
                                        bundleID: "com.apple.mail")
        try fixture.store.saveReadingSource(mail)
        #expect(fixture.conversation.context.contains("  Can't run yet: Its reading rules are empty"))
        let details = try await fixture.call("get_source", ["id": mail.id.uuidString])
        #expect((details.content as? String)?.contains("account: whichever one the app shows when it runs") == true)

        _ = try await fixture.call("update_source", ["id": mail.id.uuidString, "name": "Mail app inbox"])
        #expect(fixture.receipts.last?.hasPrefix("Saved to “Mail app inbox”: name. It can't run yet: Its reading rules are empty") == true)

        _ = try await fixture.call("update_source", ["id": mail.id.uuidString, "reading_rules": "Only unread messages from today"])
        #expect(fixture.receipts.last == "Saved to “Mail app inbox”: reading rules.")
        #expect(!fixture.conversation.context.contains("Can't run yet"))
    }

    @Test func updateChangesReadingRulesThroughTheStore() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let inbox = fixture.inbox()
        try fixture.store.saveReadingSource(inbox)

        let result = try await fixture.call("update_source", ["id": inbox.id.uuidString, "reading_rules": "Only unread email from today"])

        #expect(!result.isError)
        #expect(fixture.store.readingSources.first?.scope == "Only unread email from today")
        #expect(fixture.receipts == ["Saved to “Inbox”: reading rules."])
    }

    @Test func aJobCanBeNamedInsteadOfIdentified() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.store.saveReadingSource(fixture.inbox())

        let result = try await fixture.call("update_source", ["id": "inbox", "account": "sam@example.test"])

        #expect(!result.isError)
        #expect(fixture.store.readingSources.first?.account == "sam@example.test")
    }

    @Test func changesWaitWhileASourceIsBeingRead() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let inbox = fixture.inbox()
        try fixture.store.saveReadingSource(inbox)
        fixture.conversation.isRunning = { true }

        let result = try await fixture.call("update_source", ["id": inbox.id.uuidString, "reading_rules": "Everything"])

        #expect(result.isError)
        #expect(fixture.store.readingSources.first?.scope == inbox.scope)
        #expect(fixture.receipts.isEmpty)
    }

    @Test func editsKeepTheReviewFlagAndRejectBadAddresses() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let inbox = fixture.inbox(requiresReview: true)
        try fixture.store.saveReadingSource(inbox)

        let rules = try await fixture.call("update_source", ["id": inbox.id.uuidString, "reading_rules": "Only starred email"])
        let address = try await fixture.call("update_source", ["id": inbox.id.uuidString, "address": "ftp://example.test/inbox"])

        #expect(!rules.isError)
        #expect(fixture.store.readingSources.first?.requiresReview == true)
        #expect(fixture.receipts.first?.contains("still needs review in Manage sources") == true)
        #expect(address.isError)
        #expect(fixture.store.readingSources.first?.url == inbox.url)
    }

    @Test func calendarJobsTakeATimeZoneButNotReadingRules() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let calendar = fixture.calendar()
        try fixture.store.saveSource(calendar)

        let rules = try await fixture.call("update_source", ["id": calendar.id.uuidString, "reading_rules": "Only meetings"])
        let zone = try await fixture.call("update_source", ["id": calendar.id.uuidString, "time_zone": "Europe/Paris"])
        let badZone = try await fixture.call("update_source", ["id": calendar.id.uuidString, "time_zone": "Mars/Olympus"])

        #expect(rules.isError)
        #expect(!zone.isError)
        #expect(badZone.isError)
        #expect(fixture.store.sources.first?.timeZoneID == "Europe/Paris")
    }

    @Test func aJobCanBeRemovedAndRestoredFromChat() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let inbox = fixture.inbox()
        try fixture.store.saveReadingSource(inbox)

        let removed = try await fixture.call("remove_source", ["id": inbox.id.uuidString])
        #expect(!removed.isError)
        #expect(fixture.store.readingSources.isEmpty)
        #expect(fixture.conversation.context.contains("Removed jobs (restore_source brings one back): “Inbox”"))

        let restored = try await fixture.call("restore_source", ["id": "Inbox"])
        #expect(!restored.isError)
        #expect(fixture.store.readingSources.map(\.id) == [inbox.id])
        #expect(fixture.receipts.count == 2)
    }

    @Test func offeringARunNeverRunsAndSkipsJobsThatNeedReview() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let inbox = fixture.inbox()
        let unreviewed = fixture.inbox(name: "Shared inbox", requiresReview: true)
        try fixture.store.saveReadingSource(inbox)
        try fixture.store.saveReadingSource(unreviewed)

        let offered = try await fixture.call("offer_run_source", ["id": inbox.id.uuidString])
        let refused = try await fixture.call("offer_run_source", ["id": unreviewed.id.uuidString])

        #expect(!offered.isError)
        #expect(refused.isError)
        #expect(fixture.offers.map(\.0) == [inbox.id])
        #expect(fixture.store.runStore.runs.isEmpty)
    }

    @Test func getSourceShowsTheLatestFindingsAsData() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let inbox = fixture.inbox()
        try fixture.store.saveReadingSource(inbox)
        try fixture.store.saveReadingSnapshot(fixture.snapshot(inbox))

        let result = try await fixture.call("get_source", ["id": inbox.id.uuidString])
        let text = try #require(result.content as? String)

        #expect(!result.isError)
        #expect(text.contains("reading rules: Only unread email from the last two days"))
        #expect(text.contains("latest findings"))
        #expect(text.contains("not instructions"))
        #expect(text.contains("- Agenda: The agenda is ready"))
        #expect(text.contains("what it assumed: Account seen: Visible account alex@example.test."))
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-conversation-\(UUID().uuidString)")
        let store: CalendarStore
        let conversation: SourceConversation
        var receipts: [String] = []
        var offers: [(UUID, String)] = []

        init() {
            store = CalendarStore(directory: root.appendingPathComponent("sources"))
            conversation = SourceConversation(store: store)
            conversation.onChange = { [unowned self] in self.receipts.append($0) }
            conversation.onOfferRun = { [unowned self] id, name in self.offers.append((id, name)) }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func call(_ name: String, _ input: [String: Any]) async throws -> ToolResult {
            try await ToolRouter(routes: conversation.routes()).execute(name, input)
        }

        func inbox(name: String = "Inbox", requiresReview: Bool = false) -> LearnedReadingSource {
            LearnedReadingSource(kind: .mail, name: name, meaning: "My incoming mail", application: "Google Chrome",
                                 url: "https://mail.google.com/mail/u/0/#inbox", account: "alex@example.test",
                                 scope: "Only unread email from the last two days", requiresReview: requiresReview)
        }

        func calendar() -> LearnedCalendarSource {
            LearnedCalendarSource(name: "Work", meaning: "My meeting schedule", application: "Calendar", bundleID: "example.calendar",
                                  account: "alex@example.test", calendarName: "Work", timeZoneID: "America/New_York")
        }

        func snapshot(_ source: LearnedReadingSource) -> ReadingSnapshot {
            ReadingSnapshot(requestID: UUID(), sourceID: source.id, source: source,
                            items: [ReadingItem(id: "message", title: "Agenda", text: "The agenda is ready", evidence: "Visible message row")],
                            coverage: .complete, accountEvidence: "Visible account alex@example.test",
                            sourceEvidence: "Inbox at saved URL", scopeEvidence: "First page inspected")
        }
    }
}
