import Foundation

/// The watch list, put together once by the app: where watches are kept, what checks them on schedule, how alerts
/// reach the person, the chat's tools and the window.
@MainActor
final class WatchListFeature {
    let store: WatchListStore
    let runner: WatchListRunner
    let notifier: WatchListNotifier
    let conversation: WatchListConversation
    let window: WatchListWindowController

    init(registry: ToolRegistry, store: WatchListStore? = nil) {
        let store = store ?? WatchListStore()
        let checker = WatchListChecker(registry: registry)
        let notifier = WatchListNotifier()
        let runner = WatchListRunner(store: store, check: { watch, item in await checker.check(watch, item) })
        runner.onAlert = { [weak notifier] alert in notifier?.post(alert) }
        let conversation = WatchListConversation(store: store, runner: runner)
        conversation.checks = { [weak registry] in registry.map(WatchListChecker.choices(in:)) ?? [] }
        conversation.askForNotifications = { [weak notifier] in notifier?.requestPermission() }
        conversation.notificationLine = { [weak notifier] in await notifier?.line() ?? "on" }
        self.store = store
        self.runner = runner
        self.notifier = notifier
        self.conversation = conversation
        window = WatchListWindowController(store: store, runner: runner, notifier: notifier)
    }

    /// Starts the schedule. With watches kept from before, macOS is asked again for notifications, which only prompts
    /// someone who never answered.
    func start() {
        if !store.watches.isEmpty { notifier.requestPermission() }
        runner.start()
    }

    func stop() {
        runner.stop()
        window.close()
    }
}
