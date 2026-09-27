import Combine
import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct BackgroundActionApprovalTests {
    @Test func messageApprovalShowsTheWholeDraftAndClearsItAfterApproval() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        let message = String(repeating: "A long draft with an emoji 👋\n", count: 40)
        let context = "Discord · Aiiiiiii · Message @Aiiiiiii"
        let result = Task {
            await approval.request(label: "Send message to Aiiiiiii", on: feed, message: message, context: context)
        }
        await waitForPrompt(feed)
        #expect(feed.approvalMessage == message)
        #expect(feed.approvalContext == context)
        #expect(feed.phase == .confirming("Send message to Aiiiiiii"))
        feed.onGoAhead?()
        #expect(await result.value == .approved)
        #expect(feed.approvalMessage == nil && feed.approvalContext == nil)
    }

    @Test func declinedMessageCannotLeakIntoTheNextControlApproval() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        let first = Task {
            await approval.request(label: "Send message to Alice", on: feed, message: "Private draft", context: "Chat · Alice")
        }
        await waitForPrompt(feed)
        let staleYes = feed.onGoAhead
        feed.onNotNow?()
        #expect(await first.value == .denied)
        #expect(feed.approvalMessage == nil && feed.approvalContext == nil)

        let next = Task { await approval.request(label: "Submit", on: feed) }
        await waitForPrompt(feed)
        #expect(feed.approvalMessage == nil && feed.approvalContext == nil)
        staleYes?()
        #expect(approval.isPending)
        feed.onNotNow?()
        #expect(await next.value == .denied)
    }

    @Test func alteredMessageApprovalCannotAuthorizeTheOriginalDraft() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        let result = Task {
            await approval.request(label: "Send message to Alice", on: feed, message: "Original draft", context: "Chat · Alice")
        }
        await waitForPrompt(feed)
        feed.approvalMessage = "Changed displayed draft"
        feed.onGoAhead?()
        #expect(await result.value == .cancelled)
        #expect(feed.approvalMessage == nil && feed.approvalContext == nil)
    }

    @Test func timeoutAndResetRemoveMessageApprovalDetails() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        let timed = Task {
            await approval.request(label: "Send message to Alice", on: feed, timeout: 0.01, message: "Draft", context: "Chat · Alice")
        }
        await waitForPrompt(feed)
        #expect(await timed.value == .timedOut)
        #expect(feed.approvalMessage == nil && feed.approvalContext == nil)

        let reset = Task {
            await approval.request(label: "Send message to Bob", on: feed, message: "New draft", context: "Chat · Bob")
        }
        await waitForPrompt(feed)
        let staleYes = feed.onGoAhead
        feed.reset()
        #expect(feed.approvalMessage == nil && feed.approvalContext == nil)
        staleYes?()
        #expect(await reset.value == .cancelled)
        #expect(feed.phase == .idle)
    }

    @Test func approvalIsPendingOnTheTaskAndConsumedOnce() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        let result = Task { await approval.request(label: "Send", on: feed) }
        await waitForPrompt(feed)
        #expect(approval.isPending)
        #expect(feed.phase == .confirming("Send"))
        #expect(feed.isWorking)
        #expect(PeekCadence.interval(phase: feed.phase, actionRunning: false) == 1)
        let yes = feed.onGoAhead
        yes?()
        yes?() // A double click cannot resume the suspended action twice.
        #expect(await result.value == .approved)
        #expect(!approval.isPending)
        #expect(feed.onGoAhead == nil && feed.onNotNow == nil)
        #expect(feed.approvalRequestID == nil)
        #expect(feed.phase == .working)
    }

    @Test func decliningDoesNotStopUnrelatedWork() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        let result = Task { await approval.request(label: "Delete", on: feed) }
        await waitForPrompt(feed)
        feed.onNotNow?()
        #expect(await result.value == .denied)
        #expect(feed.phase == .working)
        #expect(!approval.isPending)
    }

    @Test func stoppedPromptCannotApproveTheNextPromptWithTheSameLabel() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        feed.onStop = { approval.cancel() }
        let first = Task { await approval.request(label: "Send", on: feed) }
        await waitForPrompt(feed)
        let staleYes = feed.onGoAhead
        let staleNo = feed.onNotNow
        feed.onStop?()
        #expect(await first.value == .cancelled)
        #expect(feed.phase == .stopped)

        let second = Task { await approval.request(label: "Send", on: feed) }
        await waitForPrompt(feed)
        let secondID = feed.approvalRequestID
        staleYes?()
        staleNo?()
        #expect(approval.isPending)
        #expect(feed.approvalRequestID == secondID)
        #expect(feed.phase == .confirming("Send"))
        feed.onNotNow?()
        #expect(await second.value == .denied)
    }

    @Test func timeoutCleansCallbacksAndCannotApproveLater() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        let first = Task { await approval.request(label: "Publish", on: feed, timeout: 0.01) }
        await waitForPrompt(feed)
        let staleYes = feed.onGoAhead
        #expect(await first.value == .timedOut)
        #expect(feed.onGoAhead == nil && feed.onNotNow == nil)
        #expect(!approval.isPending)
        let second = Task { await approval.request(label: "Publish", on: feed) }
        await waitForPrompt(feed)
        staleYes?()
        #expect(approval.isPending)
        approval.cancel()
        #expect(await second.value == .cancelled)
    }

    @Test func taskCancellationResumesAndClearsPendingApproval() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        let result = Task { await approval.request(label: "Send", on: feed) }
        await waitForPrompt(feed)
        result.cancel()
        #expect(await result.value == .cancelled)
        #expect(!approval.isPending)
        #expect(feed.onGoAhead == nil && feed.onNotNow == nil)
        #expect(feed.phase == .stopped)
    }

    @Test func missingUIOrOverlappingRequestNeverApproves() async {
        let approval = BackgroundActionApproval()
        #expect(await approval.request(label: "Send", on: nil) == .unavailable)
        let feed = PeekFeed()
        let first = Task { await approval.request(label: "Send", on: feed) }
        await waitForPrompt(feed)
        let id = feed.approvalRequestID
        #expect(await approval.request(label: "Delete", on: feed) == .unavailable)
        #expect(feed.approvalRequestID == id)
        #expect(feed.phase == .confirming("Send"))
        feed.onGoAhead?()
        #expect(await first.value == .approved)
    }

    @Test func resetInvalidatesAnAlreadyRenderedApprovalButton() async {
        let approval = BackgroundActionApproval()
        let feed = PeekFeed()
        let result = Task { await approval.request(label: "Send", on: feed) }
        await waitForPrompt(feed)
        let staleYes = feed.onGoAhead
        feed.reset()
        staleYes?()
        #expect(await result.value == .cancelled)
        #expect(feed.phase == .idle)
        #expect(!approval.isPending)
    }

    private func waitForPrompt(_ feed: PeekFeed) async {
        if case .confirming = feed.phase { return }
        await withCheckedContinuation { continuation in
            var subscription: AnyCancellable?
            subscription = feed.$phase.sink { phase in
                guard case .confirming = phase else { return }
                subscription?.cancel()
                subscription = nil
                continuation.resume()
            }
        }
    }
}
