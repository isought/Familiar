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
    let checker: WatchListChecker

    init(registry: ToolRegistry, store: WatchListStore? = nil) {
        let store = store ?? WatchListStore()
        let checker = WatchListChecker(registry: registry, folder: { [weak store] id in store?.folder(for: id) })
        let notifier = WatchListNotifier()
        let runner = WatchListRunner(store: store, prepare: { watch in await checker.plan(watch) })
        runner.onAlert = { [weak notifier] alert in notifier?.post(alert) }
        let conversation = WatchListConversation(store: store, runner: runner)
        conversation.checks = { [weak registry] in registry.map(WatchListChecker.choices(in:)) ?? [] }
        conversation.takesList = { watch in (try? await checker.resolve(watch))?.takesList ?? false }
        conversation.askForNotifications = { [weak notifier] in notifier?.requestPermission() }
        conversation.notificationLine = { [weak notifier] in await notifier?.line() ?? "on" }
        self.store = store
        self.runner = runner
        self.notifier = notifier
        self.conversation = conversation
        self.checker = checker
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

    /// Which check a watch uses, as an explanation names it: its own check.py, or the pack's script.
    func checkLabel(_ watch: WatchListWatch) -> String {
        store.ownCheck(for: watch.id) == nil ? watch.check : "its own check.py (in its folder)"
    }
}
