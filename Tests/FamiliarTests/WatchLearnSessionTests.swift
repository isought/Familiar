import Foundation
import Testing
@testable import Familiar

@Suite
@MainActor
struct WatchLearnSessionTests {
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

    private enum Failure: Error { case model, write, reload }

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
        var onClick: ((Int) -> Void)?
        var progress: ((String) -> Void)?
        var summaryPurposes: [String?] = []
        var abandonCalls = 0
        var writeCalls = 0
        var reloadCalls = 0
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
                summarize: { _, purpose, progress in
                    self.summaryPurposes.append(purpose)
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
                case .emptyRecording: return "empty"
                case .draftReady: return "draft"
                case .kept: return "kept"
                case .failed(let stage, _): return stage == .summarize ? "summaryFailed" : "keepFailed"
                case .discarded: return "discarded"
                }
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
