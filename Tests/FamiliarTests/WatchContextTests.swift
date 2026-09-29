import Foundation
import Testing
@testable import Familiar

struct WatchContextTests {
    @Test func oldRecordingMetadataWithoutContextStillDecodes() throws {
        let json = #"{"startedAt":"2026-09-28","endedAt":"2026-09-28","clicks":3,"frames":2,"hosts":[],"titles":[],"apps":[],"bundles":[],"purpose":"Check unread email"}"#
        let meta = try JSONDecoder().decode(WatchMeta.self, from: Data(json.utf8))
        #expect(meta.purpose == "Check unread email")
        #expect(meta.context == nil)
        var updated = meta
        updated.context = "Only unread from the last 2 days.\nSkip promotions."
        let roundTrip = try JSONDecoder().decode(WatchMeta.self, from: JSONEncoder().encode(updated))
        #expect(roundTrip.context == updated.context)
        #expect(roundTrip.purpose == meta.purpose)
    }

    @Test func oneGenerationPayloadContainsFullContextSeparatelyFromDescription() throws {
        let context = "Only unread from the last 2 days.\nSkip promotions.\n"
            + String(repeating: "Additional source context.\n", count: 1_000) + "CONTEXT END"
        let recording = Recording(dir: URL(fileURLWithPath: "/unused-context-fixture"),
            events: [WatchEvent(index: 0, t: 0, kind: "click", app: "Google Chrome", label: "Inbox")],
            meta: WatchMeta(startedAt: "2026-09-28", clicks: 1, purpose: "Check unread email", context: context))
        let content = WatchSummarizer.buildContent(recording, purpose: nil, picks: [])
        #expect(content.count == 1)
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("## What the user says they were doing\nCheck unread email\n\n## Additional context from the user\n"))
        #expect(text.contains(context))
        #expect(text.contains("Preserve the user's explicit constraints, reading rules and boundaries"))
        #expect(text.contains("do not treat context as evidence that unseen controls or content were demonstrated"))
        #expect(text.contains("## Event log"))
        #expect(text.contains("click on something “Inbox”"))
    }

    @Test func skippedContextAddsNoInventedConstraints() {
        let recording = Recording(dir: URL(fileURLWithPath: "/unused-context-fixture"), events: [],
            meta: WatchMeta(startedAt: "2026-09-28", purpose: "Check mail"))
        let text = WatchSummarizer.eventLog(recording, purpose: nil)
        #expect(text.contains("Check mail"))
        #expect(!text.contains("## Additional context"))
        #expect(!text.contains("Only unread"))
    }
}
