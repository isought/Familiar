import Foundation
import Testing
@testable import Familiar
@testable import FamiliarRuntime
import FamiliarContracts

@Suite @MainActor
struct BackgroundTaskPresentationTests {
    @Test func taskResultStaysOutsideChatAndDoesNotReopenIt() throws {
        let (assistant, desktop) = fixture()
        let id = UUID()
        let task = try desktop.executor.begin(TaskRequest(id: id, title: "Fill the report"))
        assistant.chatBusy = true
        assistant.shell.expanded = false
        #expect(assistant.backgroundTaskRunning)
        #expect(!assistant.chatResponding)

        assistant.completeExecution(reply("Filled the report.\nSuggestions: Inspect it | Next task"), task: task)

        #expect(assistant.transcript.isEmpty)
        #expect(assistant.suggestions.isEmpty)
        #expect(desktop.tasks.history.first?.text == "Filled the report.")
        #expect(!assistant.shell.expanded)
        #expect(!desktop.tasks.isExpanded)
    }

    @Test func clearingChatDoesNotEraseTaskOrLoseItsLateResult() throws {
        let (assistant, desktop) = fixture()
        let id = UUID()
        let task = try desktop.executor.begin(TaskRequest(id: id, title: "Background report"))
        assistant.transcript = [ChatMessage(role: .user, text: "Old question")]
        assistant.clearConversation()
        desktop.tasks.dismiss()

        assistant.completeExecution(reply("The result is ready.", accepted: false), task: task)

        #expect(desktop.tasks.history.first?.text == "The result is ready.")
        #expect(assistant.transcript.isEmpty)
        #expect(!desktop.tasks.isVisible)
        #expect(!assistant.shell.expanded)
    }

    @Test func stoppedAndFailedTaskResultsStayOnTheirTask() throws {
        let (assistant, desktop) = fixture()
        let stopped = UUID()
        let stoppedTask = try desktop.executor.begin(TaskRequest(id: stopped, title: "Stopped task"))
        assistant.completeExecution(.init(outcome: .cancelled, accepted: true, elapsed: 1), task: stoppedTask)
        #expect(desktop.tasks.history.first?.outcome == .stopped)
        let failed = UUID()
        let failedTask = try desktop.executor.begin(TaskRequest(id: failed, title: "Failed task"))
        assistant.completeExecution(.init(outcome: .failed(ClaudeError(message: "Connection failed")),
                                          accepted: true, elapsed: 2), task: failedTask)
        #expect(desktop.tasks.history.first?.outcome == .failed)
        #expect(desktop.tasks.history.first?.text == "Connection failed")
        #expect(assistant.transcript.isEmpty)
    }

    @Test func ordinaryConversationStillReceivesItsAnswer() throws {
        let (assistant, desktop) = fixture()
        let task = try desktop.executor.begin(TaskRequest(id: UUID(), title: "Explain this",
                                                         presentation: .conversation), coordinator: assistant.execution)
        assistant.completeExecution(reply("Here is the answer.\nSuggestions: Explain more | Example"), task: task)
        #expect(assistant.transcript.last?.role == .assistant)
        #expect(assistant.transcript.last?.text == "Here is the answer.")
        #expect(assistant.suggestions == ["Explain more", "Example"])
        #expect(!desktop.tasks.hasTasks)
    }

    @Test func invalidatedConversationDoesNotBecomeATaskOrRestoreClearedChat() throws {
        let (assistant, desktop) = fixture()
        let task = try desktop.executor.begin(TaskRequest(id: UUID(), title: "Explain this",
                                                         presentation: .conversation), coordinator: assistant.execution)
        assistant.clearConversation()
        assistant.completeExecution(reply("An old answer", accepted: false), task: task)
        #expect(assistant.transcript.isEmpty)
        #expect(!desktop.tasks.hasTasks)
        #expect(desktop.tasks.history.isEmpty)
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
