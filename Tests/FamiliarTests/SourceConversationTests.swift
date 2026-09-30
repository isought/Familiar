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

    @Test func aJobCanBeStartedFromChatThroughAScript() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.conversation.sourceScripts = { [SourceScript(id: "mail__today", pack: "Mail", description: "Lists what arrived in the inbox", missingSecrets: [])] }
        #expect(fixture.conversation.context.contains("Ways to read a new job without teaching (create_source): mail__today (Mail: Lists what arrived in the inbox)"))

        let result = try await fixture.call("create_source", ["name": "Morning mail", "meaning": "My personal inbox",
                                                               "reading_rules": "Skip promotions; show anything that needs a reply", "script": "mail__today"])

        #expect(!result.isError)
        let job = try #require(fixture.store.readingSources.first)
        #expect(job.script == "mail__today" && job.application == "Mail" && job.scope.hasPrefix("Skip promotions"))
        #expect(fixture.receipts == ["Created “Morning mail”: it reads through Mail. It can run now."])
        #expect(fixture.connectOffers.isEmpty)
        #expect(fixture.conversation.context.contains("reads through mail__today"))
    }

    /// A mail job read from the screen runs in the same card steps as a new script job, and if it reads the same inbox a
    /// message on its card can land in the attention test's rest. The receipt says so and suggests removing it; nothing
    /// is removed, and the model is told the receipt already said it.
    @Test func aNewScriptJobSaysWhichScreenReadMailJobsStillRun() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.conversation.sourceScripts = { [SourceScript(id: "imap-mail__today", pack: "Mail over IMAP", description: "Inbox", missingSecrets: [])] }
        let gmail = fixture.inbox(name: "Gmail inbox – today’s unread")
        let web = LearnedReadingSource(kind: .web, name: "Team wiki", meaning: "Changes to our wiki", url: "https://wiki.example.test",
                                       scope: "Pages changed today")
        try fixture.store.saveReadingSource(gmail)
        try fixture.store.saveReadingSource(web)

        let result = try await fixture.call("create_source", ["name": "Morning mail", "meaning": "My inbox", "reading_rules": "Skip promotions",
                                                               "script": "imap-mail__today"])

        #expect(!result.isError)
        #expect(fixture.receipts == ["Created “Morning mail”: it reads through Mail over IMAP. It can run now. “Gmail inbox – today’s unread”"
            + " also reads mail from the screen. If it reads the same inbox, a message shown on its card can land in the attention test’s"
            + " rest, and removing it in Manage sources keeps the test’s numbers clean."])
        let text = try #require(result.content as? String)
        #expect(text.hasSuffix(" The receipt already told the person about that screen-read job; don't repeat it, and use remove_source"
            + " only if they ask."))
        #expect(!text.contains("Suggest"))
        #expect(fixture.store.readingSources.map(\.id).contains(gmail.id))
        #expect(fixture.store.readingSources.count == 3 && fixture.store.removedSources.isEmpty)

        // Two of them are named together; a script job already there is not one of them.
        let apple = LearnedReadingSource(kind: .mail, name: "Mail inbox", meaning: "My incoming mail", application: "Mail",
                                         bundleID: "com.apple.mail", scope: "Today's unread messages")
        try fixture.store.saveReadingSource(apple)
        let second = try await fixture.call("create_source", ["name": "Work mail", "meaning": "Work", "reading_rules": "Skip lists",
                                                               "script": "imap-mail__today"])
        #expect(fixture.receipts.last == "Created “Work mail”: it reads through Mail over IMAP. It can run now. “Gmail inbox – today’s unread”"
            + " and “Mail inbox” also read mail from the screen. If they read the same inbox, a message shown on one of their cards can land"
            + " in the attention test’s rest, and removing them in Manage sources keeps the test’s numbers clean.")
        #expect((second.content as? String)?.contains("about those screen-read jobs; don't repeat it") == true)
        #expect(fixture.store.readingSources.count == 5 && fixture.store.removedSources.isEmpty)

        // Without one, the receipt is as it was.
        try fixture.store.removeSource(id: gmail.id)
        try fixture.store.removeSource(id: apple.id)
        let plain = try await fixture.call("create_source", ["name": "Side mail", "meaning": "Side", "reading_rules": "All", "script": "imap-mail__today"])
        #expect(fixture.receipts.last == "Created “Side mail”: it reads through Mail over IMAP. It can run now.")
        #expect((plain.content as? String)?.contains("remove_source") == false)
    }

    /// A new script job that still needs connecting can't read yet, and the screen-read job may be the person's only
    /// working mail reader, so removing it is mentioned only for once the new job reads.
    @Test func aScriptJobThatNeedsConnectingLeavesTheScreenReadJobForLater() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.conversation.sourceScripts = {
            [SourceScript(id: "imap-mail__today", pack: "Mail over IMAP", description: "Inbox", missingSecrets: ["IMAP_PASSWORD"])]
        }
        let gmail = fixture.inbox(name: "Gmail inbox – today’s unread")
        try fixture.store.saveReadingSource(gmail)

        let result = try await fixture.call("create_source", ["name": "Morning mail", "meaning": "My inbox", "reading_rules": "Skip promotions",
                                                               "script": "imap-mail__today"])

        #expect(fixture.receipts == ["Created “Morning mail”: it reads through Mail over IMAP. Connect it first: add IMAP_PASSWORD in Settings."
            + " “Gmail inbox – today’s unread” also reads mail from the screen. If it reads the same inbox, you can remove it in Manage sources"
            + " once this job reads your mail, for clean attention-test numbers."])
        let text = try #require(result.content as? String)
        #expect(!text.contains("Suggest") && text.contains("don't repeat it, and use remove_source only if they ask."))
        #expect(fixture.connectOffers == ["Mail over IMAP"])
        #expect(fixture.store.readingSources.map(\.id).contains(gmail.id) && fixture.store.removedSources.isEmpty)
    }

    @Test func aNewJobThatNeedsConnectingPointsToSettings() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.conversation.sourceScripts = { [SourceScript(id: "mail__today", pack: "Mail", description: "Inbox", missingSecrets: ["MAIL_ADDRESS", "MAIL_APP_PASSWORD"])] }
        #expect(fixture.conversation.context.contains("not connected yet, needs MAIL_ADDRESS, MAIL_APP_PASSWORD in Settings"))

        _ = try await fixture.call("create_source", ["name": "Morning mail", "meaning": "My inbox", "reading_rules": "Skip promotions", "script": "mail__today"])

        #expect(fixture.receipts.last == "Created “Morning mail”: it reads through Mail. Connect it first: add MAIL_ADDRESS and MAIL_APP_PASSWORD in Settings.")
        #expect(fixture.connectOffers == ["Mail"])
    }

    @Test func aScriptJobsAccountLivesInSettingsNotInTheJob() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let job = LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My inbox", application: "Mail over IMAP",
                                       scope: "Skip promotions", script: "imap-mail__today")
        try fixture.store.saveReadingSource(job)

        let result = try await fixture.call("update_source", ["id": job.id.uuidString, "account": "me@work.test"])

        #expect(result.isError)
        #expect((result.content as? String)?.contains("change it in Settings") == true)
        #expect(fixture.connectOffers == ["Mail over IMAP"])   // the Open Settings button it names is offered
        #expect(fixture.store.readingSources.first?.account == "")
        let details = try await fixture.call("get_source", ["id": job.id.uuidString])
        #expect((details.content as? String)?.contains("account: the one connected in Settings for Mail over IMAP") == true)
    }

    @Test func aNewJobKeepsLongRulesWhole() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.conversation.sourceScripts = { [SourceScript(id: "imap-mail__today", pack: "Mail over IMAP", description: "Inbox", missingSecrets: [])] }
        let rules = (1...40).map { "Rule \($0): skip messages from sender number \($0)." }.joined(separator: "\n")

        _ = try await fixture.call("create_source", ["name": "Morning mail", "meaning": "My inbox", "reading_rules": rules, "script": "imap-mail__today"])

        #expect(fixture.store.readingSources.first?.scope == rules)
        #expect(fixture.conversation.context.contains("[shortened here: read them in full with get_source before changing them"))
    }

    @Test func anUnknownWayToReadIsRefused() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.conversation.sourceScripts = { [SourceScript(id: "mail__today", pack: "Mail", description: "Inbox", missingSecrets: [])] }

        let result = try await fixture.call("create_source", ["name": "Slack", "meaning": "Team chat", "reading_rules": "Mentions", "script": "slack__today"])

        #expect(result.isError)
        #expect((result.content as? String)?.contains("Use one of: mail__today. For anything else, offer Watch Me.") == true)
        #expect(fixture.store.readingSources.isEmpty)
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
        var connectOffers: [String] = []

        init() {
            store = CalendarStore(directory: root.appendingPathComponent("sources"))
            conversation = SourceConversation(store: store)
            conversation.onChange = { [unowned self] in self.receipts.append($0) }
            conversation.onOfferRun = { [unowned self] id, name in self.offers.append((id, name)) }
            conversation.onOfferConnect = { [unowned self] pack in self.connectOffers.append(pack) }
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
