import Foundation
import Testing
@testable import Familiar

/// A script read keeps the mail facts and mailbox counts it returns as data, while the text, ids and summary the
/// card step reads stay exactly as they were, and runs saved before this still load and save unchanged.
@Suite @MainActor
struct ScriptReadFactsTests {
    @Test func scriptRowsKeepStructuredMailFacts() throws {
        let snapshot = try ScriptReading.snapshot(from: Self.threeRows, request: ReadingReadRequest(source: mailJob()))
        let invoice = snapshot.items[0], sale = snapshot.items[1]

        // The row says nothing about starred or bulk, so neither is claimed.
        #expect(invoice.mail == MailFacts(from: "Billing <billing@example.test>", name: "Billing", address: "billing@example.test",
            domain: "example.test", received: "2026-09-30T08:10:00+00:00", unread: true, tab: "primary", important: true))
        #expect(sale.mail?.bulk == true && sale.mail?.tab == "promotions" && sale.mail?.unread == false)
        #expect(sale.mail?.address == "deals@example.test" && sale.mail?.name == "Shop")
        #expect(snapshot.scriptRead == ScriptReadCounts(arrived: 3, returned: 3, truncated: false,
            since: ISO8601DateFormatter().date(from: "2026-09-29T11:00:00Z")))

        // The app gets the same rows parsed from the script's JSON output.
        let parsed = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: Self.threeRows))
        let fromJSON = try ScriptReading.snapshot(from: parsed, request: ReadingReadRequest(source: mailJob()))
        #expect(fromJSON.items.map(\.mail) == snapshot.items.map(\.mail) && fromJSON.scriptRead == snapshot.scriptRead)
    }

    @Test func textIdsAndSummaryAreUnchanged() throws {
        let job = mailJob()
        let snapshot = try ScriptReading.snapshot(from: Self.threeRows, request: ReadingReadRequest(source: job))
        let invoice = snapshot.items[0]

        #expect(invoice.text.hasPrefix("From Billing <billing@example.test> · "))
        #expect(invoice.text.contains("unread · Primary tab · marked important by Gmail\nYour invoice is attached."))
        #expect(invoice.id == ObservedItemIdentity.id(sourceID: job.id, key: "a@example.test"))
        #expect(invoice.evidence == "Read through mail__today from INBOX on imap.example.test, received 2026-09-30T08:10:00+00:00")
        #expect(snapshot.summary?.hasPrefix("Read all 3 messages that arrived in INBOX since ") == true)
        #expect(snapshot.scopeEvidence.hasSuffix(": 3 messages") && snapshot.coverageNotes.isEmpty)
        try snapshot.validate()
    }

    @Test func fromHeaderShapesParse() throws {
        let named = try #require(MailFacts(row: ["from": "\"Ruiz, Dana\" <Dana@Rent.Example.test>"]))
        #expect(named.from == "\"Ruiz, Dana\" <Dana@Rent.Example.test>")
        #expect(named.name == "Ruiz, Dana" && named.address == "dana@rent.example.test" && named.domain == "rent.example.test")

        let bare = try #require(MailFacts(row: ["from": "Dana@Rent.Example.test"]))
        #expect(bare.name == nil && bare.address == "dana@rent.example.test" && bare.domain == "rent.example.test")

        let nameOnly = try #require(MailFacts(row: ["from": "Dana Ruiz"]))
        #expect(nameOnly.name == "Dana Ruiz" && nameOnly.address == nil && nameOnly.domain == nil)

        let angled = try #require(MailFacts(row: ["from": "<billing@example.test>"]))
        #expect(angled.name == nil && angled.address == "billing@example.test")
        #expect(MailFacts(row: ["tab": "Promotions"])?.tab == "promotions")
    }

    @Test func rowsWithTheirOwnTextHaveNoMailFacts() throws {
        #expect(MailFacts(row: ["key": "a", "title": "Agenda", "text": "The agenda is ready", "from": "Billing <billing@example.test>"]) == nil)
        #expect(MailFacts(row: ["key": "a", "title": "Agenda", "preview": "Only a preview"]) == nil)   // none of the mail fields
        #expect(MailFacts(row: ["key": "a", "title": "Agenda", "text": "  ", "unread": false])?.unread == false)   // blank text is no text

        let rows: [[String: Any]] = [["key": "own@example.test", "title": "Agenda", "text": "The agenda is ready", "from": "Taylor <t@example.test>"],
                                     ["key": "m1@example.test", "title": "Message 1"], ["key": "m2@example.test", "title": "Message 2"]]
        let snapshot = try ScriptReading.snapshot(from: ["mailbox": "INBOX", "arrived": 640, "truncated": true, "items": rows],
                                                  request: ReadingReadRequest(source: mailJob()))
        #expect(snapshot.items.allSatisfy { $0.mail == nil })
        #expect(snapshot.items[0].text == "The agenda is ready")
        #expect(snapshot.scriptRead == ScriptReadCounts(arrived: 640, returned: 3, truncated: true, since: nil))
    }

    /// Told when the last sorted read was, the mail script says how many it cut off that arrived after it. The count
    /// is kept as data beside the others; the text the card step reads is unchanged.
    @Test func aScriptToldTheLastReadKeepsWhatItCutOffSince() throws {
        let rows: [[String: Any]] = [["key": "m1@example.test", "title": "Message 1"], ["key": "m2@example.test", "title": "Message 2"]]
        let result: [String: Any] = ["mailbox": "INBOX", "arrived": 30, "returned": 2, "truncated": true, "cut_off_since_last_read": 12,
                                     "items": rows]
        let parsed = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: result))
        let snapshot = try ScriptReading.snapshot(from: parsed, request: ReadingReadRequest(source: mailJob()))
        #expect(snapshot.scriptRead == ScriptReadCounts(arrived: 30, returned: 2, truncated: true, since: nil, cutOffSinceLastRead: 12))
        var untold = result
        untold["cut_off_since_last_read"] = nil
        let plain = try ScriptReading.snapshot(from: untold, request: ReadingReadRequest(source: mailJob()))
        #expect(plain.scriptRead?.cutOffSinceLastRead == nil)
        #expect(snapshot.summary == plain.summary && snapshot.coverageNotes == plain.coverageNotes && snapshot.scopeEvidence == plain.scopeEvidence)
        #expect(snapshot.items.map(\.text) == plain.items.map(\.text))
    }

    @Test func runsSavedBeforeThisStillLoadAndRoundTrip() throws {
        let old = try SourceRunJSON.decoder().decode(ReadingSnapshot.self, from: Data(Self.savedBeforeThis.utf8))
        #expect(old.scriptRead == nil && old.items.allSatisfy { $0.mail == nil })

        let encoded = try SourceRunJSON.encoder().encode(old)
        #expect(try keys(in: encoded).isDisjoint(with: ["mail", "scriptRead"]))
        #expect(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
            == JSONSerialization.jsonObject(with: Data(Self.savedBeforeThis.utf8)) as? NSDictionary)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-read-facts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var oldEntry = SourceRunEntry(reading: ReadingReadRequest(id: old.requestID, source: old.source, requestedAt: old.collectedAt), state: .complete)
        oldEntry.finishedAt = old.collectedAt; oldEntry.readingSnapshot = old
        let request = ReadingReadRequest(source: mailJob())
        var newEntry = SourceRunEntry(reading: request, state: .complete)
        newEntry.readingSnapshot = try ScriptReading.snapshot(from: Self.threeRows, request: request)

        let store = SourceRunStore(directory: root)
        var finished: [SourceRunRecord] = []
        for entry in [oldEntry, newEntry] {
            let run = try store.begin(entries: [entry], origin: .single)
            finished.append(try store.finish(runID: run.id, status: .completed))   // a replace: what's on disk must read back equal
        }
        let saved = try finished.map { try Data(contentsOf: #require(store.directory(for: $0.id)).appendingPathComponent("run.json")) }
        #expect(try keys(in: saved[0]).isDisjoint(with: ["mail", "scriptRead"]))
        #expect(try keys(in: saved[1]).isSuperset(of: ["mail", "scriptRead"]))

        let reopened = SourceRunStore(directory: root)
        #expect(reopened.error == nil)
        #expect(finished.allSatisfy { reopened.run(id: $0.id) == $0 })
        #expect(reopened.run(id: finished[1].id)?.entries.first?.readingSnapshot?.scriptRead?.since != nil)
    }

    /// A copy of the fixture in ScriptJobTests: two messages, one of them delivered twice.
    private static let threeRows: [String: Any] = [
        "account": "me@example.test", "server": "imap.example.test", "mailbox": "INBOX", "since": "2026-09-29T11:00:00+00:00",
        "arrived": 3, "returned": 3, "truncated": false, "items": [
            ["key": "a@example.test", "title": "Invoice due Friday", "from": "Billing <billing@example.test>",
             "received": "2026-09-30T08:10:00+00:00", "unread": true, "tab": "primary", "important": true,
             "preview": "Your invoice is attached.", "url": "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Aa"],
            ["key": "b@example.test", "title": "50% off everything", "from": "Shop <deals@example.test>",
             "received": "2026-09-30T07:00:00+00:00", "unread": false, "tab": "promotions", "bulk": true, "preview": ""],
            ["key": "a@example.test", "title": "Invoice due Friday", "from": "Billing <billing@example.test>"],   // delivered twice
        ]]

    /// A script read as Noteling 0.5.4 saved it in run.json, before items kept their mail facts.
    private static let savedBeforeThis = """
        {
          "accountEvidence" : "Signed in as me@example.test",
          "collectedAt" : "2026-09-29T12:00:00.000000000Z",
          "coverage" : "complete",
          "coverageNotes" : [],
          "id" : "0F4C2A8E-5B7D-4E61-9A3F-2D8B6C1E7A01",
          "items" : [
            {
              "evidence" : "Read through mail__today from INBOX on imap.example.test, received 2026-09-29T08:10:00+00:00",
              "id" : "identified-0b1d",
              "identityEvidence" : "Message-ID a@example.test",
              "identityKey" : "a@example.test",
              "text" : "From Billing <billing@example.test> · Sep 29, 2026 at 8:10 AM · unread · Primary tab\\nYour invoice is attached.",
              "title" : "Invoice due Friday",
              "url" : "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Aa"
            }
          ],
          "requestID" : "0F4C2A8E-5B7D-4E61-9A3F-2D8B6C1E7A01",
          "scopeEvidence" : "Everything that arrived since Sep 28, 2026 at 12:00 PM: 1 message",
          "source" : {
            "account" : "",
            "application" : "Mail",
            "bundleID" : "",
            "completionChecks" : "",
            "id" : "7E3B9D24-1C6A-4F08-B5E2-3A9D0C4F6B12",
            "kind" : "mail",
            "learnedAt" : "2026-09-28T09:00:00.000000000Z",
            "meaning" : "My personal inbox",
            "name" : "Morning mail",
            "navigationHints" : "",
            "requiresReview" : false,
            "scope" : "Skip newsletters and promotions; show anything that needs a reply",
            "script" : "mail__today",
            "uncertainties" : [],
            "url" : "",
            "workflowPath" : ""
          },
          "sourceEvidence" : "INBOX on imap.example.test",
          "sourceID" : "7E3B9D24-1C6A-4F08-B5E2-3A9D0C4F6B12",
          "summary" : "Read all 1 messages that arrived in INBOX since Sep 28, 2026 at 12:00 PM."
        }
        """

    /// Every object key anywhere in the JSON.
    private func keys(in data: Data) throws -> Set<String> {
        func walk(_ value: Any) -> Set<String> {
            if let object = value as? [String: Any] { return object.reduce(Set(object.keys)) { $0.union(walk($1.value)) } }
            return (value as? [Any])?.reduce(Set<String>()) { $0.union(walk($1)) } ?? []
        }
        return walk(try JSONSerialization.jsonObject(with: data))
    }

    private func mailJob() -> LearnedReadingSource {
        LearnedReadingSource(kind: .mail, name: "Morning mail", meaning: "My personal inbox", application: "Mail",
                             scope: "Skip newsletters and promotions; show anything that needs a reply", script: "mail__today")
    }
}
