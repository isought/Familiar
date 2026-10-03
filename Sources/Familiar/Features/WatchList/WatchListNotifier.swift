import CryptoKit
import Foundation
import UserNotifications

/// Tells the person about watched items through macOS notifications, and opens the chat when they click one.
/// macOS asks for permission when the first watch is created. Without it everything else still works: the window and
/// the chat say notifications are off. The notification center exists only for an app bundle; anywhere else (tests,
/// `swift run`) touching it crashes, so there alerts go to the log.
@MainActor
final class WatchListNotifier: NSObject, ObservableObject {
    /// Why notifications won't show, in plain words; nil when they will (or nobody has been asked yet).
    @Published private(set) var offReason: String?
    /// A notification was clicked: the watch and the item it was about.
    var onOpen: ((UUID, String) -> Void)?
    private var asked = false

    static var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter? { Self.available ? UNUserNotificationCenter.current() : nil }

    /// Set up at launch, so a click on a notification reaches the app.
    func activate() {
        center?.delegate = self
    }

    /// Asks macOS once whether Noteling may notify; it only asks the person if they haven't answered before.
    func requestPermission() {
        guard let center else { return }
        guard !asked else { return }
        asked = true
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                Log.info("watch list: notifications \(granted ? "allowed" : "not allowed")")
            } catch {
                Log.info("watch list: couldn't ask for notifications: \(error.localizedDescription)")
            }
            await refresh()
        }
    }

    func refresh() async {
        offReason = await reason()
    }

    /// The chat's word on notifications: "on", or why not and how to turn them on.
    func line() async -> String {
        await refresh()
        return offReason.map { "off: \($0)" } ?? "on"
    }

    private func reason() async -> String? {
        guard let center else { return "Notifications need Noteling to run as an app." }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            return "Notifications are off for Noteling. Turn them on in System Settings → Notifications → Noteling."
        case .notDetermined:
            return asked ? "Noteling is waiting for you to allow notifications." : nil
        default:
            return settings.alertSetting == .disabled
                ? "Noteling's alerts are turned off in System Settings → Notifications → Noteling." : nil
        }
    }

    func post(_ alert: WatchListAlert) {
        guard let center else {
            Log.info("watch list: not shown as a notification: Noteling isn't running as an app")   // the runner logged the alert
            return
        }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.itemKey.isEmpty ? "" : alert.watchName   // an alert about several items is titled with the watch
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.watchID.uuidString
        content.userInfo = ["watch": alert.watchID.uuidString, "item": alert.itemKey]
        // One per item: a newer alert replaces the one before it in Notification Center.
        let request = UNNotificationRequest(identifier: Self.identifier(alert), content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.info("watch list: couldn't show a notification: \(error.localizedDescription)") }
        }
    }

    nonisolated static func identifier(_ alert: WatchListAlert) -> String {
        let hash = SHA256.hash(data: Data(alert.itemKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "watch-\(alert.watchID.uuidString)-\(hash)"
    }
}

extension WatchListNotifier: UNUserNotificationCenterDelegate {
    /// Shown even while Noteling is the app in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let watch = (info["watch"] as? String).flatMap(UUID.init(uuidString:))
        let item = info["item"] as? String
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            if clicked, let watch, let item { self.onOpen?(watch, item) }
            completionHandler()
        }
    }
}
