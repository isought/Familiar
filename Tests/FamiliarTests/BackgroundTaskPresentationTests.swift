import Foundation
import Testing
@testable import Familiar
@testable import FamiliarRuntime
import FamiliarContracts

@Suite @MainActor
struct BackgroundTaskPresentationTests {
    @Test func taskResultStaysOutsideChatAndDoesNotReopenIt() {
        let (assistant, desktop) = fixture()
        let id = UUID()
        desktop.tasks.start(id: id, title: "Fill the report")
        assistant.chatBusy = true
        assistant.shell.expanded = false
        #expect(assistant.backgroundTaskRunning)
        #expect(!assistant.chatResponding)

        assistant.presentExecutionResult(reply("Filled the report.\nSuggestions: Inspect it | Next task"),
                                         requestID: id, receipt: nil)

        #expect(assistant.transcript.isEmpty)
        #expect(assistant.suggestions.isEmpty)
        #expect(desktop.tasks.history.first?.text == "Filled the report.")
        #expect(!assistant.shell.expanded)
        #expect(!desktop.tasks.isExpanded)
    }

    @Test func clearingChatDoesNotEraseTaskOrLoseItsLateResult() {
        let (assistant, desktop) = fixture()
        let id = UUID()
        desktop.tasks.start(id: id, title: "Background report")
        assistant.transcript = [ChatMessage(role: .user, text: "Old question")]
        assistant.clearConversation()
        desktop.tasks.dismiss()

        assistant.presentExecutionResult(reply("The result is ready.", accepted: false), requestID: id, receipt: nil)

        #expect(desktop.tasks.history.first?.text == "The result is ready.")
        #expect(assistant.transcript.isEmpty)
        #expect(!desktop.tasks.isVisible)
        #expect(!assistant.shell.expanded)
    }

    @Test func stoppedAndFailedTaskResultsStayOnTheirTask() {
        let (assistant, desktop) = fixture()
        let stopped = UUID()
        desktop.tasks.start(id: stopped, title: "Stopped task")
        assistant.presentExecutionResult(reply("Completed the first field."), requestID: stopped,
                                         receipt: .init(steps: 1, appName: "Test app", stopped: true))
        #expect(desktop.tasks.history.first?.outcome == .stopped)
        let failed = UUID()
        desktop.tasks.start(id: failed, title: "Failed task")
        assistant.presentExecutionResult(.init(outcome: .failed(ClaudeError(message: "Connection failed")),
                                               accepted: true, elapsed: 2), requestID: failed, receipt: nil)
        #expect(desktop.tasks.history.first?.outcome == .failed)
        #expect(desktop.tasks.history.first?.text == "Connection failed")
        #expect(assistant.transcript.isEmpty)
    }

    @Test func ordinaryConversationStillReceivesItsAnswer() {
        let (assistant, desktop) = fixture()
        assistant.presentExecutionResult(reply("Here is the answer.\nSuggestions: Explain more | Example"),
                                         requestID: UUID(), receipt: nil)
        #expect(assistant.transcript.last?.role == .assistant)
        #expect(assistant.transcript.last?.text == "Here is the answer.")
        #expect(assistant.suggestions == ["Explain more", "Example"])
        #expect(!desktop.tasks.hasTasks)
    }

    private func reply(_ text: String, accepted: Bool = true) -> ExecutionResult {
        .init(outcome: .reply(.init(text: text, inputTokens: 1, outputTokens: 1, cacheRead: 0, toolCalls: 1)),
              accepted: accepted, elapsed: 3)
    }

    private func fixture() -> (Assistant, DesktopExecutionService) {
        var config = Config()
        config.apiKey = "fixture-no-network"
        config.screenshotMode = "never"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry = ToolRegistry(root: root, runner: ScriptRunner(config: config))
        let learning = WatchLearnSession(operations: .init(
            start: { _ in }, stop: { Recording(dir: root, events: [], meta: WatchMeta(startedAt: "test", clicks: 0)) }, abandon: {},
            summarize: { _, _, _ in throw ClaudeError(message: "Not recording") }, write: { _ in [] }, reload: {}
        ))
        let desktop = DesktopExecutionService(control: ComputerController(), activities: NativeActivityGate())
        let assistant = Assistant(config: config, watcher: ContextWatcher(), registry: registry,
                                  shell: ShellState(), learning: learning, desktop: desktop)
        return (assistant, desktop)
    }
}
