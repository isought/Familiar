import AppKit
import ApplicationServices

/// A job opens its own page. Before a read, when no window of the taught browser shows the saved address in its
/// front tab, Noteling opens exactly that address there in a new tab, without bringing the browser forward, and the
/// tab stays open. A taught app that isn't running, or has no window, is opened in the background. Nothing else is
/// ever opened: the reader has no way to open pages, so links found in mail or on pages never are.
///
/// Reusing a front tab keeps a daily job from adding a tab every morning unless that tab was moved away from.
/// Finding background tabs would need permission to control the browser, left out on purpose until tabs piling up
/// proves to be a problem.
@MainActor
struct SourcePageOpener {
    var timeout: TimeInterval = 15

    /// What was opened, as a line for the reader and the log; nil when nothing was.
    func prepare(_ source: LearnedReadingSource) async -> String? {
        guard Permissions.accessibilityGranted, !source.bundleID.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return nil }
        let appName = source.application.isEmpty ? appURL.deletingPathExtension().lastPathComponent : source.application
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        if ContextWatcher.browserBundles.contains(source.bundleID) {
            guard readingHTTPURL(source.url), let address = URL(string: source.url) else { return nil }
            if Self.showing(source.url, bundleID: source.bundleID) { return nil }
            do { _ = try await NSWorkspace.shared.open([address], withApplicationAt: appURL, configuration: configuration) }
            catch { return "Noteling couldn't open the saved address in \(appName): \(error.localizedDescription)" }
            return await wait({ Self.showing(source.url, bundleID: source.bundleID) })
                ? "Noteling opened the saved address in a new \(appName) tab for this read."
                : "Noteling asked \(appName) to open the saved address; it was still loading when this read began."
        }
        guard source.url.isEmpty, !Self.hasWindow(bundleID: source.bundleID) else { return nil }
        do { _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) }
        catch { return "Noteling couldn't open \(appName): \(error.localizedDescription)" }
        _ = await wait({ Self.hasWindow(bundleID: source.bundleID) })
        return "Noteling opened \(appName) in the background for this read."
    }

    /// Whether an address a browser shows is the saved one: the same place, ignoring the scheme, "www." and trailing
    /// slashes, and allowing a deeper route such as a message opened from the saved inbox.
    nonisolated static func sameAddress(saved: String, shown: String) -> Bool {
        let saved = normalized(saved), shown = normalized(shown)
        guard !saved.isEmpty, shown.hasPrefix(saved) else { return false }
        return shown.count == saved.count || "/#?&".contains(shown[saved.endIndex])
    }

    nonisolated private static func normalized(_ address: String) -> String {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func showing(_ saved: String, bundleID: String) -> Bool {
        windows(bundleID: bundleID).contains { window in
            ContextWatcher.browserURL(window: window).map { sameAddress(saved: saved, shown: $0) } ?? false
        }
    }

    private static func hasWindow(bundleID: String) -> Bool { !windows(bundleID: bundleID).isEmpty }

    private static func windows(bundleID: String) -> [AXUIElement] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).flatMap { app -> [AXUIElement] in
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return [] }
            return windows
        }
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return condition()
    }
}
