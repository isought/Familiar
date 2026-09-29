import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct ReadingSourceTeachingTests {
    @Test func gmailDemonstrationProducesAReviewableSourceForRunAll() throws {
        let location = "https://mail.google.com/mail/u/0/#inbox"
        let recording = Recording(dir: URL(fileURLWithPath: "/unused-gmail-teaching"),
            events: [WatchEvent(index: 0, t: 0, kind: "scene", app: "Google Chrome", title: "Inbox - Gmail", url: location),
                     WatchEvent(index: 1, t: 1, kind: "click", app: "Google Chrome", title: "Inbox - Gmail", url: location, label: "Primary")],
            meta: WatchMeta(startedAt: "2026-09-28", hosts: ["mail.google.com"], titles: ["Inbox - Gmail"],
                            apps: ["Google Chrome"], bundles: ["com.google.Chrome"]))
        let json: [String: Any] = [
            "pack_name": "Gmail", "match_titles": ["Gmail"],
            "workflow_title": "Check the Gmail inbox", "workflow_markdown": "Read the latest messages in Primary.",
            "reading_source": ["kind": "mail", "name": "Gmail inbox", "meaning": "My incoming mail",
                "application": "Google Chrome", "bundle_id": "com.google.Chrome", "url": location,
                "account": "alex@example.test", "scope": "Only unread emails from the last 2 days, up to 25 matching messages",
                "navigation_hints": "Find the Gmail tab and select Primary.",
                "completion_checks": "Verify account, Inbox, Primary and the visible page range.", "uncertainties": []]
        ]
        let reply = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        let draft = WatchSummarizer.parse(reply, recording: recording)
        let review = Assistant.draftBody(draft, root: URL(fileURLWithPath: "/unused-tools"), teachingCalendar: true)
        #expect(review.contains("**Reading source to keep**"))
        #expect(review.contains("My incoming mail"))
        #expect(draft.readingSource?.meaning == "My incoming mail")
        #expect(draft.readingSource?.scope == "Only unread emails from the last 2 days, up to 25 matching messages")
        #expect(review.contains("**Reading rules:** Only unread emails from the last 2 days"))
        #expect(review.contains("Run all sources"))
        #expect(!review.contains("This draft can keep the workflow only"))
    }

    @Test func keepingGmailThroughWatchSessionRegistersTheSourceForRunAll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-gmail-teaching-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingDirectory = root.appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        let recording = Recording(dir: recordingDirectory,
            events: [WatchEvent(index: 0, t: 0, kind: "click", app: "Google Chrome", title: "Inbox - Gmail",
                                url: "https://mail.google.com/mail/u/0/#inbox", label: "Primary")],
            meta: WatchMeta(startedAt: "2026-09-28", hosts: ["mail.google.com"], titles: ["Inbox - Gmail"],
                            apps: ["Google Chrome"], bundles: ["com.google.Chrome"]))
        let reply = #"{"pack_name":"Gmail","match_titles":["Gmail"],"workflow_title":"Read Primary","workflow_markdown":"Read the first visible page of Primary.","reading_source":{"kind":"mail","name":"Gmail inbox","meaning":"My incoming mail","application":"Google Chrome","bundle_id":"com.google.Chrome","url":"https://mail.google.com/mail/u/0/#inbox","account":"alex@example.test","scope":"The first visible page of Primary","navigation_hints":"Select Primary in the Gmail tab.","completion_checks":"Verify the account and the visible page range.","uncertainties":[]}}"#
        let store = CalendarStore(directory: root.appendingPathComponent("sources"))
        let toolsRoot = root.appendingPathComponent("tools")
        let session = WatchLearnSession(operations: .init(start: { _ in }, stop: { recording }, abandon: {},
            summarize: { record, _, _ in WatchSummarizer.parse(reply, recording: record) },
            write: { try PackWriter.write($0, root: toolsRoot) }, reload: {},
            saveSource: { try WatchLearnComposition.saveSources(from: $0, to: store) }))
        #expect(try session.start(source: true))
        let stopped = try #require(session.stop())
        await stopped.value
        let summary = try #require(session.summarize(purpose: "Check my Primary inbox"))
        await summary.value
        let source = try #require(session.pendingDraft?.readingSource)
        #expect(store.readingSources.isEmpty)
        await session.keep()

        #expect(session.phase == .idle)
        #expect(store.readingSources == [source])
        #expect(store.sources.isEmpty)
        try store.readingSources[0].validateForRead()
        #expect(FileManager.default.fileExists(atPath: toolsRoot.appendingPathComponent("gmail/docs/workflows/read-primary.md").path))
        #expect(!FileManager.default.fileExists(atPath: recordingDirectory.path))
        let reopened = CalendarStore(directory: root.appendingPathComponent("sources"))
        #expect(reopened.readingSources == [source])
    }

    @Test func manageSourcesDoesNotSilentlyKeepAnActionWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-action-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recording = Recording(dir: root, events: [WatchEvent(index: 0, t: 0, kind: "click", label: "Send")],
                                  meta: WatchMeta(startedAt: "2026-09-28"))
        var writes = 0
        var failure = ""
        let draft = PackDraft(packName: "Gmail", workflowTitle: "Send a reply", workflowMarkdown: "Press Send.", parsed: true)
        let session = WatchLearnSession(operations: .init(start: { _ in }, stop: { recording }, abandon: {},
            summarize: { _, _, _ in draft }, write: { _ in writes += 1; return [] }, reload: {}))
        session.onEvent = { if case .failed(.keep, let error) = $0 { failure = error.localizedDescription } }
        #expect(try session.start(source: true))
        let stopped = try #require(session.stop())
        await stopped.value
        let summary = try #require(session.summarize(purpose: "Send a reply"))
        await summary.value
        await session.keep()
        #expect(writes == 0)
        #expect(session.phase == .review && session.hasPendingReview)
        #expect(failure.contains("No reading source was established"))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func screenshotAddressNeedsActualImageContentAndExplicitEvidenceBeforeReview() throws {
        var json = readingReply()
        var profile = try #require(json["reading_source"] as? [String: Any])
        profile["url_evidence"] = "Screenshot [1] shows mail.google.com/mail/u/0/#inbox in the address bar."
        json["reading_source"] = profile
        let recording = readingRecording(location: "chrome://newtab/")
        let picks = [WatchSummarizer.ImagePick(file: "unavailable-frame.jpg", caption: "[1] the screen", order: (1, 0), bytes: 12)]
        let content = WatchSummarizer.buildContent(recording, purpose: "Read my inbox", picks: picks)
        let includedImages = content.contains { $0["type"] as? String == "image" }
        #expect(!includedImages)
        let withoutImages = WatchSummarizer.parse(try encode(json), recording: recording, includedImages: includedImages)
        #expect(withoutImages.readingSource == nil)

        let withImages = WatchSummarizer.parse(try encode(json), recording: recording, includedImages: true)
        let source = try #require(withImages.readingSource)
        #expect(source.url == gmailURL)
        #expect(source.requiresReview)
        #expect(source.uncertainties.contains { $0.contains("Screenshot [1]") })
        #expect(throws: CalendarDataError.self) { try source.validateForRead() }
        let review = Assistant.draftBody(withImages, root: URL(fileURLWithPath: "/unused-tools"))
        #expect(review.contains("Confirm its address there before Run all sources can read it"))

        profile.removeValue(forKey: "url_evidence")
        json["reading_source"] = profile
        #expect(WatchSummarizer.parse(try encode(json), recording: recording, includedImages: true).readingSource == nil)
    }

    @Test func recordedSourceDoesNotNeedScreenshotReviewAndCarriesItsWorkflowPath() throws {
        let draft = WatchSummarizer.parse(try encode(readingReply()), recording: readingRecording())
        let source = try #require(draft.readingSource)
        #expect(source.kind == .mail)
        #expect(source.url == gmailURL)
        #expect(!source.requiresReview)
        #expect(source.workflowPath == "gmail/docs/workflows/read-primary.md")
        #expect(!draft.matchURLs.contains("mail.google.com"))
        try source.validateForRead()
    }

    @Test func webReadingIsSupportedButUnknownKindsDoNotRegister() throws {
        var json = readingReply()
        var profile = try #require(json["reading_source"] as? [String: Any])
        profile["kind"] = "web"
        profile["url"] = "https://news.example.test/latest"
        profile["scope"] = "The first page of latest articles"
        json["reading_source"] = profile
        let recording = readingRecording(location: "https://news.example.test/latest")
        let draft = WatchSummarizer.parse(try encode(json), recording: recording)
        #expect(draft.readingSource?.kind == .web)
        profile["kind"] = "send-mail"
        json["reading_source"] = profile
        let action = WatchSummarizer.parse(try encode(json), recording: recording)
        #expect(action.parsed)
        #expect(action.readingSource == nil)
        #expect(action.caveats.contains { $0.contains("separately from actions") })
    }

    @Test func twoSourceProfilesAreRejectedBeforeEitherCanBeRegistered() throws {
        var json = readingReply()
        json["calendar_source"] = ["name": "Calendar", "meaning": "My schedule"]
        let parsed = WatchSummarizer.parse(try encode(json), recording: readingRecording())
        #expect(parsed.readingSource == nil && parsed.calendarSource == nil)
        #expect(parsed.caveats.contains { $0.contains("Choose one source per demonstration") })

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-source-registration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CalendarStore(directory: root)
        var direct = WatchSummarizer.parse(try encode(readingReply()), recording: readingRecording())
        direct.calendarSource = LearnedCalendarSource(name: "Calendar", meaning: "My schedule", bundleID: "com.apple.iCal")
        do {
            try WatchLearnComposition.saveSources(from: direct, to: store)
            Issue.record("A mixed source draft should not register either source.")
        } catch { #expect(error.localizedDescription.contains("Choose one source")) }
        #expect(store.sources.isEmpty && store.readingSources.isEmpty)
    }

    @Test func registrationRequiresAStoreButOrdinaryWorkflowCompatibilityIsPreserved() throws {
        let sourceDraft = WatchSummarizer.parse(try encode(readingReply()), recording: readingRecording())
        do {
            try WatchLearnComposition.saveSources(from: sourceDraft, to: nil)
            Issue.record("Keeping a reading source must fail when its store is unavailable.")
        } catch { #expect(error.localizedDescription.contains("storage is unavailable")) }

        var json = readingReply()
        json.removeValue(forKey: "reading_source")
        json["workflow_title"] = "Send a reply"
        json["workflow_markdown"] = "Compose a reply and press Send."
        let workflow = WatchSummarizer.parse(try encode(json), recording: readingRecording())
        #expect(workflow.parsed)
        #expect(workflow.readingSource == nil && workflow.calendarSource == nil)
        try WatchLearnComposition.saveSources(from: workflow, to: nil)
        let review = Assistant.draftDocument(workflow, root: URL(fileURLWithPath: "/unused-tools"))
        #expect(review.contains("Compose a reply and press Send"))
        #expect(!review.contains("Reading source to keep"))
    }

    private var gmailURL: String { "https://mail.google.com/mail/u/0/#inbox" }

    private func readingRecording(location: String? = nil) -> Recording {
        Recording(dir: URL(fileURLWithPath: "/unused-gmail-teaching"),
                  events: [WatchEvent(index: 0, t: 0, kind: "click", app: "Google Chrome", title: "Inbox - Gmail",
                                      url: location ?? gmailURL, label: "Primary")],
                  meta: WatchMeta(startedAt: "2026-09-28", hosts: ["mail.google.com"], titles: ["Inbox - Gmail"],
                                  apps: ["Google Chrome"], bundles: ["com.google.Chrome"]))
    }

    private func readingReply() -> [String: Any] {
        ["pack_name": "Gmail", "match_urls": ["mail.google.com"], "match_titles": ["Gmail"],
         "workflow_title": "Read Primary", "workflow_markdown": "Read the first visible page of Primary.",
         "reading_source": ["kind": "mail", "name": "Gmail inbox", "meaning": "My incoming mail",
                            "application": "Google Chrome", "bundle_id": "com.google.Chrome", "url": gmailURL,
                            "account": "alex@example.test", "scope": "The first visible page of Primary",
                            "navigation_hints": "Select Primary.", "completion_checks": "Verify account and visible page range.", "uncertainties": []]]
    }

    private func encode(_ json: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
}
