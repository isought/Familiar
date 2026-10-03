import Foundation
import FamiliarContracts

@MainActor
enum WatchLearnComposition {
    static func make(recorder: WatchRecorder, registry: ToolRegistry, activities: NativeActivityGate,
                     calendarStore: CalendarStore? = nil,
                     config: @escaping () -> Config) -> WatchLearnSession {
        var lease: NativeActivityGate.Lease?
        var draining = false
        var writtenWorkflowPath: String?
        func release() {
            if let current = lease { activities.release(current) }
            lease = nil
        }
        return WatchLearnSession(operations: .init(start: { onClick in
            let settings = config()
            recorder.config = settings
            recorder.hotkeyLabel = HotKey.display(settings.hotkey.isEmpty ? "control+option+space" : settings.hotkey)
            recorder.onClickCount = onClick
            lease = try activities.acquire(.recording)
            do { try recorder.start() } catch { release(); throw error }
        }, stop: {
            draining = true
            defer { draining = false; release() }
            return await recorder.stop(purpose: nil)
        }, abandon: {
            recorder.abandon()
            if !draining { release() }
        }, summarize: { recording, purpose, onStatus in
            let settings = config()
            guard ConversationBackend.make(config: settings) != nil else {
                throw ClaudeError(message: ConversationBackend.setupMessage(config: settings) + " Then press Try again.")
            }
            var draft = try await WatchSummarizer.summarize(recording, purpose: purpose, config: settings, onStatus: onStatus)
            draft.packDir = registry.personalPackDir(for: draft.packDir)   // a folder of the team's pack name would hide theirs
            return draft
        }, write: { draft in
            let files = try PackWriter.write(draft, root: registry.root)
            let prefix = registry.root.path + "/"
            writtenWorkflowPath = files.first { $0.deletingLastPathComponent().lastPathComponent == "workflows" && $0.pathExtension == "md" }
                .flatMap { $0.path.hasPrefix(prefix) ? String($0.path.dropFirst(prefix.count)) : nil }
            return files
        }, reload: {
            await registry.reload()
            calendarStore?.refreshSavedWorkflows(root: registry.root)
        }, saveSource: { draft in
            var registered = draft
            if let writtenWorkflowPath {
                registered.calendarSource?.workflowPath = writtenWorkflowPath
                registered.readingSource?.workflowPath = writtenWorkflowPath
            }
            try saveSources(from: registered, to: calendarStore)
        }))
    }

    /// The app and functional tests share the actual registration boundary used by Keep.
    static func saveSources(from draft: PackDraft, to store: CalendarStore?) throws {
        guard draft.calendarSource != nil || draft.readingSource != nil else { return }
        guard draft.calendarSource == nil || draft.readingSource == nil else {
            throw ClaudeError(message: "Choose one source per demonstration before keeping it.")
        }
        guard let store else { throw ClaudeError(message: "The source could not be registered because source storage is unavailable. Your draft is still available to retry.") }
        if let source = draft.calendarSource { try store.saveSource(source) }
        if let source = draft.readingSource { try store.saveReadingSource(source) }
    }
}
