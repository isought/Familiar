import Foundation
import Testing
@testable import Familiar

@Suite
@MainActor
struct WatchLearnSessionTests {
    @Test
    func descriptionAndOptionalContextProduceExactlyOneGeneration() async throws {
        let descriptions: [String?] = ["  Check unread email\n", nil, " \n "]
        let contexts: [String?] = ["  Only unread from the last 2 days.\nSkip promotions.  ", nil, " \n "]
        for description in descriptions {
            for context in contexts {
                let fixture = try Fixture()
                defer { fixture.remove() }
                let session = fixture.session()
                try await recordAndStop(session)
                #expect(session.submitContext(context) == nil)
                #expect(session.submitDescription(description))
                #expect(session.awaitingContext && !session.busy && !session.awaitingPurpose)
                #expect(fixture.summaryPurposes.isEmpty)
                #expect(session.hasPendingReview)
                #expect(fixture.eventNames == ["started", "stopped", "purpose", "context"])
                #expect(!session.submitDescription("Must not overwrite accepted description"))

                let expectedDescription = description?.contains("Check unread") == true ? "Check unread email" : nil
                let expectedContext = context?.contains("Only unread") == true ? "Only unread from the last 2 days.\nSkip promotions." : nil
                #expect(session.pendingRecording?.meta.purpose == expectedDescription)
                let task = try #require(session.submitContext(context))
                #expect(session.phase == .summarizing)
                #expect(session.submitContext("Must not start another generation") == nil)
                #expect(!session.submitDescription("Must not start another description"))
                await task.value

                #expect(fixture.summaryPurposes.count == 1)
                #expect(fixture.summaryRecordings.first?.meta.purpose == expectedDescription)
                #expect(fixture.summaryRecordings.first?.meta.context == expectedContext)
                #expect(session.phase == .review)
                #expect(session.submitContext(nil) == nil)
                let stored = try JSONDecoder().decode(WatchMeta.self, from: Data(contentsOf: fixture.recording.dir.appendingPathComponent("meta.json")))
                #expect(stored.purpose == expectedDescription)
                #expect(stored.context == expectedContext)
                #expect(fixture.metaSaves == 2)
            }
        }
    }

    @Test
    func contextSurvivesFailedGenerationAndRetryWithoutAnotherContextStep() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        #expect(try session.start(source: true))
        await (try #require(session.stop())).value
        #expect(session.submitDescription("Check my work inbox"))
        fixture.summaryError = Failure.model
        let first = try #require(session.submitContext("Only unread from the last 2 days; never open messages."))
        await first.value
        #expect(session.draftFailed)
        fixture.summaryError = nil
        let retry = try #require(session.retry())
        await retry.value
        #expect(fixture.summaryRecordings.count == 2)
        #expect(fixture.summaryPurposes[0] == fixture.summaryPurposes[1])
        for recording in fixture.summaryRecordings {
            #expect(recording.meta.purpose == "Check my work inbox")
            #expect(recording.meta.context == "Only unread from the last 2 days; never open messages.")
        }
        #expect(fixture.eventNames.filter { $0 == "context" }.count == 1)
        #expect(fixture.metaSaves == 2)
    }

    @Test
    func clearingOrDiscardingOptionalContextPreventsLateSubmission() async throws {
        for discard in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let session = fixture.session()
            try await recordAndStop(session)
            #expect(session.submitDescription("Read the inbox"))
            let lateContext = Task { @MainActor in session.submitContext("A delayed context submission") }
            if discard { session.discard() } else { session.clear() }
            #expect(await lateContext.value == nil)
            #expect(session.phase == .idle)
            #expect(session.pendingRecording == nil)
            #expect(fixture.summaryPurposes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.recording.dir.path))

            fixture.recording = try fixture.makeRecording("next")
            try await recordAndStop(session)
            #expect(session.submitContext("Old context must not apply to the new description step") == nil)
            #expect(session.awaitingPurpose)
            #expect(session.pendingRecording?.meta.context == nil)
            #expect(fixture.summaryPurposes.isEmpty)
        }
    }

    @Test
    func clearingJustAfterSubmittingContextPreventsQueuedProviderCall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        try await recordAndStop(session)
        #expect(session.submitDescription(nil))
        let task = try #require(session.submitContext("Only unread messages"))
        session.clear()
        await task.value
        #expect(fixture.summaryPurposes.isEmpty)
        #expect(session.phase == .idle)
        #expect(!session.hasPendingReview)
    }

    @Test
    func metadataWriteFailuresRetainTheCurrentInputStepWithoutGenerating() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        try await recordAndStop(session)
        fixture.metaError = Failure.write
        #expect(!session.submitDescription("Read work mail"))
        #expect(session.awaitingPurpose)
        #expect(session.pendingRecording?.meta.purpose == nil)
        #expect(fixture.summaryPurposes.isEmpty)
        fixture.metaError = nil
        #expect(session.submitDescription("Read work mail"))
        fixture.metaError = Failure.write
        #expect(session.submitContext("Only unread") == nil)
        #expect(session.awaitingContext)
        #expect(session.pendingRecording?.meta.context == nil)
        #expect(fixture.summaryPurposes.isEmpty)
        fixture.metaError = nil
        await (try #require(session.submitContext("Only unread"))).value
        #expect(fixture.summaryPurposes.count == 1)
        #expect(session.phase == .review)
        #expect(fixture.eventNames.filter { $0 == "summaryFailed" }.count == 2)
    }

    @Test
    func stopDrainsBeforeRequestingPurposeAndDeliveryCanWaitForChat() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate<Recording>()
        fixture.stopGate = gate
        let session = fixture.session()
        #expect(try session.start())
        fixture.onClick?(3)
        #expect(session.clickCount == 3)
        #expect(!session.busy)
        #expect(try !session.start())
        session.setPurposeDeliveryPaused(true)
        let stopping = try #require(session.stop())
        await gate.entered()

        #expect(session.stopping && session.watching)
        #expect(session.pendingRecording == nil)
        #expect(fixture.eventNames == ["started"])
        #expect(try !session.start())
        #expect(session.stop() == nil)

        gate.finish(.success(fixture.recording))
        await stopping.value
        #expect(!session.watching)
        #expect(session.phase == .waitingForDelivery)
        #expect(session.pendingRecording?.dir == fixture.recording.dir)
        #expect(fixture.eventNames == ["started", "stopped"])
        session.setPurposeDeliveryPaused(false)
        session.setPurposeDeliveryPaused(false)
        #expect(session.awaitingPurpose)
        #expect(fixture.eventNames == ["started", "stopped", "purpose"])
        #expect(FileManager.default.fileExists(atPath: fixture.recording.dir.path))
    }

    @Test
    func sceneOnlyRecordingIsRemovedWithoutRequestingPurpose() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.recording.events = [WatchEvent(index: 0, t: 0, kind: "scene")]
        let session = fixture.session()
        try await recordAndStop(session)

        #expect(session.phase == .idle)
        #expect(!session.hasPendingReview)
        #expect(session.summarize(purpose: nil) == nil)
        #expect(fixture.eventNames == ["started", "stopped", "empty"])
        #expect(!FileManager.default.fileExists(atPath: fixture.recording.dir.path))
    }

    @Test
    func failedAndUnparsedSummariesKeepTheRecordingForRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        try await recordAndStop(session)
        fixture.summaryError = Failure.model
        let first = try #require(session.summarize(purpose: "Submit the expense"))
        await first.value
        #expect(session.draftFailed && !session.busy && !session.awaitingPurpose)
        #expect(session.pendingDraft == nil)
        #expect(session.pendingRecording?.meta.purpose == "Submit the expense")
        let stored = try JSONDecoder().decode(WatchMeta.self, from: Data(contentsOf: fixture.recording.dir.appendingPathComponent("meta.json")))
        #expect(stored.purpose == "Submit the expense")

        fixture.summaryError = nil
        fixture.draft.parsed = false
        let unparsed = try #require(session.retry())
        await unparsed.value
        #expect(session.draftFailed)
        #expect(session.pendingDraft?.parsed == false)
        await session.keep()
        #expect(fixture.writeCalls == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.recording.dir.path))

        fixture.draft.parsed = true
        let retried = try #require(session.retry())
        await retried.value
        #expect(session.phase == .review)
        #expect(!session.draftFailed && !session.busy)
        #expect(fixture.summaryPurposes == ["Submit the expense", "Submit the expense", "Submit the expense"])
        #expect(fixture.eventNames == ["started", "stopped", "purpose", "summaryFailed", "draft", "draft"])
    }

    @Test
    func clearingDiscardingOrAbortingASummaryRemovesItsRecordingAndRejectsLateCompletion() async throws {
        for action in ["clear", "discard", "abort"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let gate = Gate<PackDraft>()
            fixture.summaryGate = gate
            let session = fixture.session()
            try await recordAndStop(session)
            let oldDirectory = fixture.recording.dir
            let summary = try #require(session.summarize(purpose: nil))
            await gate.entered()
            #expect(session.busy)
            switch action {
            case "discard": session.discard()
            case "abort": session.abort()
            default: session.clear()
            }
            #expect(session.phase == .idle && !session.busy)
            #expect(!session.hasPendingReview)
            #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))

            fixture.recording = try fixture.makeRecording("next")
            try await recordAndStop(session)
            fixture.progress?("Late progress")
            // Both a late result and a late error must leave the new recording untouched.
            gate.finish(action == "discard" ? .failure(Failure.model) : .success(fixture.draft))
            await summary.value
            #expect(session.awaitingPurpose)
            #expect(session.pendingRecording?.dir == fixture.recording.dir)
            #expect(session.pendingDraft == nil)
            #expect(session.status.isEmpty)
            #expect(!fixture.eventNames.contains("draft"))
            #expect(!fixture.eventNames.contains("summaryFailed"))
            #expect(fixture.deleted.filter { $0 == oldDirectory }.count == 1)
        }
    }

    @Test
    func abortDuringStopDrainsAndRemovesLateFilesWithoutDeliveringPurpose() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate<Recording>()
        fixture.stopGate = gate
        let session = fixture.session()
        #expect(try session.start())
        let stopping = try #require(session.stop())
        await gate.entered()
        session.abort()
        #expect(session.stopping)
        #expect(try !session.start())
        #expect(fixture.abandonCalls == 1)
        // A recorder already draining may finish writing after abort was requested.
        try FileManager.default.createDirectory(at: fixture.recording.dir, withIntermediateDirectories: true)
        try "late frame".write(to: fixture.recording.dir.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
        gate.finish(.success(fixture.recording))
        await stopping.value

        #expect(session.phase == .idle && !session.watching)
        #expect(!session.hasPendingReview)
        #expect(fixture.eventNames == ["started"])
        #expect(!FileManager.default.fileExists(atPath: fixture.recording.dir.path))
    }

    @Test
    func typedReviewFeedbackRewritesTheDraftAndEarlierRequestsStillApply() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        #expect(try session.start(source: true))
        await (try #require(session.stop())).value
        #expect(session.submitDescription("Check my work inbox"))
        await (try #require(session.submitContext("Only unread email."))).value
        #expect(session.phase == .review)

        await (try #require(session.revise("  Only the last 3 days, and skip newsletters. "))).value
        await (try #require(session.revise("Stop after 25 messages"))).value

        #expect(fixture.summaryRecordings.count == 3)
        #expect(fixture.summaryRecordings[1].meta.context == "Only unread email.\n\nChanges requested after reviewing the draft: Only the last 3 days, and skip newsletters.")
        let latest = try #require(fixture.summaryRecordings[2].meta.context)
        #expect(latest.contains("skip newsletters"))
        #expect(latest.hasSuffix("Changes requested after reviewing the draft: Stop after 25 messages"))
        #expect(fixture.summaryRecordings.allSatisfy { $0.meta.purpose == "Check my work inbox" })
        #expect(session.phase == .review)
        let stored = try JSONDecoder().decode(WatchMeta.self, from: Data(contentsOf: fixture.recording.dir.appendingPathComponent("meta.json")))
        #expect(stored.context == latest)
    }

    @Test
    func revisingNeedsADraftUnderReviewAndSomethingToSay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        #expect(session.revise("Only unread") == nil)
        #expect(try session.start(source: true))
        await (try #require(session.stop())).value
        #expect(session.revise("Only unread") == nil)
        #expect(session.submitDescription("Check my work inbox"))
        #expect(session.revise("Only unread") == nil)
        await (try #require(session.submitContext(nil))).value
        #expect(session.revise(" \n ") == nil)
        #expect(fixture.summaryRecordings.count == 1)
    }

    @Test
    func aFailedDraftCanBeRevisedWithWhatWasMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        #expect(try session.start(source: true))
        await (try #require(session.stop())).value
        #expect(session.submitDescription("Check my work inbox"))
        fixture.summaryError = Failure.model
        await (try #require(session.submitContext(nil))).value
        #expect(session.draftFailed)
        fixture.summaryError = nil

        await (try #require(session.revise("The inbox is https://mail.google.com/mail/u/0/#inbox"))).value

        #expect(session.phase == .review)
        #expect(fixture.summaryRecordings.last?.meta.context == "Changes requested after reviewing the draft: The inbox is https://mail.google.com/mail/u/0/#inbox")
    }

    @Test
    func keepFailuresPreserveReviewAndRetryReloadDoesNotWriteTwice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        try await prepareDraft(session)
        fixture.writeError = Failure.write
        await session.keep()
        #expect(session.phase == .review && !session.busy)
        #expect(session.pendingDraft?.parsed == true)
        #expect(session.pendingRecording != nil)
        #expect(fixture.writeCalls == 1 && fixture.reloadCalls == 0)
        #expect(fixture.deleted.isEmpty)

        fixture.writeError = nil
        fixture.reloadError = Failure.reload
        await session.keep()
        #expect(session.phase == .review)
        #expect(fixture.writeCalls == 2 && fixture.reloadCalls == 1)
        #expect(fixture.deleted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.writtenFile.path))

        fixture.reloadError = nil
        await session.keep()
        #expect(session.phase == .idle && !session.hasPendingReview)
        #expect(fixture.writeCalls == 2 && fixture.reloadCalls == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.recording.dir.path))
        #expect(FileManager.default.fileExists(atPath: fixture.writtenFile.path))
        #expect(fixture.eventNames.suffix(3) == ["keepFailed", "keepFailed", "kept"])
    }

    @Test
    func calendarTeachingAddsIntentWithoutChangingTheUsersPurposeAndResetsForOrdinaryWatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        #expect(try session.start(calendar: true))
        #expect(session.isTeachingCalendar)
        let stopping = try #require(session.stop())
        await stopping.value
        fixture.summaryError = Failure.model
        let first = try #require(session.summarize(purpose: "This is my work calendar"))
        await first.value
        #expect(session.pendingRecording?.meta.purpose == "This is my work calendar")
        fixture.summaryError = nil
        let retry = try #require(session.retry())
        await retry.value
        #expect(fixture.summaryPurposes.count == 2)
        #expect(fixture.summaryPurposes[0] == fixture.summaryPurposes[1])
        #expect(fixture.summaryPurposes[0]?.contains("calendar_source") == true)
        #expect(fixture.summaryPurposes[0]?.contains("User's description: This is my work calendar") == true)
        session.discard()
        #expect(!session.isTeachingCalendar)

        fixture.recording = try fixture.makeRecording("ordinary")
        try await recordAndStop(session)
        let summary = try #require(session.summarize(purpose: "Submit an expense"))
        await summary.value
        #expect((fixture.summaryPurposes.last ?? nil) == "Submit an expense")
        #expect(!session.isTeachingCalendar)
    }

    @Test
    func sourceSaveFailurePreservesReviewAndRetryDoesNotDuplicateTheWorkflow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.draft.calendarSource = LearnedCalendarSource(name: "Work calendar", meaning: "My work schedule", bundleID: "com.apple.iCal")
        let session = fixture.session()
        try await prepareDraft(session)
        fixture.sourceError = Failure.source
        await session.keep()
        #expect(session.phase == .review)
        #expect(session.pendingDraft?.calendarSource == fixture.draft.calendarSource)
        #expect(session.pendingRecording != nil)
        #expect(fixture.writeCalls == 1 && fixture.reloadCalls == 1 && fixture.sourceCalls == 1)
        #expect(fixture.deleted.isEmpty)

        fixture.sourceError = nil
        await session.keep()
        #expect(session.phase == .idle && !session.hasPendingReview)
        #expect(fixture.writeCalls == 1 && fixture.reloadCalls == 2 && fixture.sourceCalls == 2)
        #expect(fixture.savedSource?.id == fixture.draft.calendarSource?.id)
        #expect(fixture.deleted.count == 1)
    }

    @Test
    func clearDuringReloadDoesNotRestoreReviewOrEmitAReceiptForTheNewSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate<Void>()
        fixture.reloadGate = gate
        let session = fixture.session()
        try await prepareDraft(session)
        let oldDirectory = fixture.recording.dir
        let keep = Task { await session.keep() }
        await gate.entered()
        #expect(session.busy && session.phase == .saving)
        session.clear()
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
        fixture.recording = try fixture.makeRecording("next")
        try await recordAndStop(session)
        gate.finish(.success(()))
        await keep.value

        #expect(session.awaitingPurpose)
        #expect(session.pendingRecording?.dir == fixture.recording.dir)
        #expect(!fixture.eventNames.contains("kept"))
        #expect(!fixture.eventNames.contains("keepFailed"))
        #expect(fixture.sourceCalls == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.writtenFile.path))
    }

    @Test
    func clearingThePadDuringRecordingKeepsRecordingUntilStop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        #expect(try session.start())
        session.clear()
        fixture.onClick?(5)
        #expect(session.watching && session.clickCount == 5)
        #expect(fixture.abandonCalls == 0)
        let stopping = try #require(session.stop())
        await stopping.value
        #expect(session.awaitingPurpose)
        session.discard()
        #expect(!session.hasPendingReview)
        #expect(!FileManager.default.fileExists(atPath: fixture.recording.dir.path))
    }

    private func recordAndStop(_ session: WatchLearnSession) async throws {
        #expect(try session.start())
        let stopping = try #require(session.stop())
        await stopping.value
    }

    private func prepareDraft(_ session: WatchLearnSession) async throws {
        try await recordAndStop(session)
        let summary = try #require(session.summarize(purpose: "Fixture workflow"))
        await summary.value
        #expect(session.pendingDraft?.parsed == true)
    }

    private enum Failure: Error { case model, write, reload, source }

    @MainActor
    private final class Gate<Value> {
        private var continuation: CheckedContinuation<Value, Error>?
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let waiters = entryWaiters
                entryWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        func entered() async {
            if continuation != nil { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func finish(_ result: Result<Value, Error>) {
            let waiting = continuation
            continuation = nil
            waiting?.resume(with: result)
        }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        var recording: Recording
        var draft = PackDraft(packDir: "fixture", packName: "Fixture", matchURLs: ["fixture.example.test"],
                              workflowSlug: "submit", workflowTitle: "Submit a fixture", confidence: 0.8, parsed: true)
        var stopGate: Gate<Recording>?
        var summaryGate: Gate<PackDraft>?
        var reloadGate: Gate<Void>?
        var summaryError: Error?
        var writeError: Error?
        var reloadError: Error?
        var sourceError: Error?
        var metaError: Error?
        var savedSource: LearnedCalendarSource?
        var onClick: ((Int) -> Void)?
        var progress: ((String) -> Void)?
        var summaryPurposes: [String?] = []
        var summaryRecordings: [Recording] = []
        var metaSaves = 0
        var abandonCalls = 0
        var writeCalls = 0
        var reloadCalls = 0
        var sourceCalls = 0
        var deleted: [URL] = []
        var events: [WatchLearnSession.Event] = []
        var writtenFile: URL { root.appendingPathComponent("kept-workflow.md") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-watch-session-\(UUID().uuidString)")
            let dir = root.appendingPathComponent("recording")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            recording = Recording(dir: dir, events: [WatchEvent(index: 0, t: 0, kind: "click")],
                                  meta: WatchMeta(startedAt: "2026-01-01", clicks: 1))
        }

        func makeRecording(_ name: String) throws -> Recording {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return Recording(dir: dir, events: [WatchEvent(index: 0, t: 0, kind: "click")],
                             meta: WatchMeta(startedAt: "2026-01-01", clicks: 1))
        }

        func session() -> WatchLearnSession {
            let session = WatchLearnSession(operations: .init(
                start: { self.onClick = $0 },
                stop: { if let gate = self.stopGate { return try! await gate.wait() }; return self.recording },
                abandon: {
                    self.abandonCalls += 1
                    try? FileManager.default.removeItem(at: self.recording.dir)
                },
                summarize: { recording, purpose, progress in
                    self.summaryPurposes.append(purpose)
                    self.summaryRecordings.append(recording)
                    self.progress = progress
                    if let gate = self.summaryGate { return try await gate.wait() }
                    if let error = self.summaryError { throw error }
                    return self.draft
                },
                write: { _ in
                    self.writeCalls += 1
                    if let error = self.writeError { throw error }
                    try "kept".write(to: self.writtenFile, atomically: true, encoding: .utf8)
                    return [self.writtenFile]
                },
                reload: {
                    self.reloadCalls += 1
                    if let gate = self.reloadGate { try await gate.wait() }
                    if let error = self.reloadError { throw error }
                },
                saveSource: { draft in
                    self.sourceCalls += 1
                    if let error = self.sourceError { throw error }
                    self.savedSource = draft.calendarSource
                },
                saveMeta: { recording in
                    if let error = self.metaError { throw error }
                    self.metaSaves += 1
                    try recording.saveMeta()
                },
                deleteRecording: {
                    self.deleted.append($0.dir)
                    try? FileManager.default.removeItem(at: $0.dir)
                }
            ))
            session.onEvent = { self.events.append($0) }
            return session
        }

        var eventNames: [String] {
            events.map {
                switch $0 {
                case .started: return "started"
                case .stopped: return "stopped"
                case .purposeRequested: return "purpose"
                case .contextRequested: return "context"
                case .emptyRecording: return "empty"
                case .draftReady: return "draft"
                case .kept: return "kept"
                case .failed(let stage, _): return stage == .summarize ? "summaryFailed" : "keepFailed"
                case .discarded(_): return "discarded"
                }
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
