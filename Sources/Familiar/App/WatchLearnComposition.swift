import Foundation
import FamiliarContracts

@MainActor
enum WatchLearnComposition {
    static func make(recorder: WatchRecorder, registry: ToolRegistry, activities: NativeActivityGate,
                     config: @escaping () -> Config) -> WatchLearnSession {
        var lease: NativeActivityGate.Lease?
        var draining = false
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
            return try await WatchSummarizer.summarize(recording, purpose: purpose, config: settings, onStatus: onStatus)
        }, write: { draft in
            try PackWriter.write(draft, root: registry.root)
        }, reload: {
            await registry.reload()
        }))
    }
}
