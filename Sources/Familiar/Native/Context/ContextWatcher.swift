import AppKit
import ApplicationServices

struct ScreenContext {
    var appName: String
    var bundleID: String
    var windowTitle: String
    var url: String?
    var focused: String?
    var timestamp: Date

    func sameScene(as other: ScreenContext) -> Bool {
        bundleID == other.bundleID && windowTitle == other.windowTitle && url == other.url
    }

    var json: [String: Any] {
        var d: [String: Any] = ["appName": appName, "bundleID": bundleID, "windowTitle": windowTitle]
        if let url { d["url"] = url }
        if let focused { d["focused"] = focused }
        return d
    }

    var summaryLine: String {
        var parts = [appName]
        if !windowTitle.isEmpty { parts.append("“\(windowTitle)”") }
        if let url, !url.isEmpty { parts.append(url) }
        return parts.joined(separator: " · ")
    }
}

enum AX {
    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        if let s = v as? String { return s }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }
}

/// Polls the frontmost app/window via Accessibility. No screenshots.
final class ContextWatcher {
    private let queue = DispatchQueue(label: "familiar.watcher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var urlCache: (key: String, url: String?)?

    private let lock = NSLock()
    private var _current: ScreenContext?
    private var _history: [ScreenContext] = []

    var current: ScreenContext? { lock.lock(); defer { lock.unlock() }; return _current }
    var history: [ScreenContext] { lock.lock(); defer { lock.unlock() }; return _history }
    var isRunning: Bool { timer != nil }

    /// Called on the main thread whenever the scene (app/window/url) changes.
    var onChange: ((ScreenContext) -> Void)?

    static let browserBundles: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.brave.Browser", "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.google.Chrome.canary",
    ]

    func start(interval: TimeInterval) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        Log.info("watcher started (every \(interval)s)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let ctx = sample() else { return }
        var changed = false
        lock.lock()
        if let cur = _current, cur.sameScene(as: ctx) {
            _current?.focused = ctx.focused
        } else {
            _current = ctx
            _history.append(ctx)
            if _history.count > 60 { _history.removeFirst(_history.count - 60) }
            changed = true
        }
        lock.unlock()
        if changed {
            Log.info("context: \(ctx.summaryLine)")
            DispatchQueue.main.async { self.onChange?(ctx) }
        }
    }

    func sample() -> ScreenContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? "unknown"
        let name = app.localizedName ?? bundleID
        if bundleID == Bundle.main.bundleIdentifier { return nil }

        var title = ""
        var url: String?
        var focused: String?

        if Permissions.accessibilityGranted {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            if let win = AX.element(axApp, kAXFocusedWindowAttribute) {
                title = AX.string(win, kAXTitleAttribute) ?? ""
                if ContextWatcher.browserBundles.contains(bundleID) {
                    let key = bundleID + "|" + title
                    if let c = urlCache, c.key == key {
                        url = c.url
                    } else {
                        url = browserURL(window: win)
                        urlCache = (key, url)
                    }
                }
            }
            if let el = AX.element(axApp, kAXFocusedUIElementAttribute) {
                let role = AX.string(el, kAXRoleAttribute) ?? ""
                let label = AX.string(el, kAXTitleAttribute)
                    ?? AX.string(el, kAXDescriptionAttribute)
                    ?? AX.string(el, kAXPlaceholderValueAttribute)
                if !role.isEmpty {
                    focused = label.map { "\(role) “\($0)”" } ?? role
                }
            }
        }

        return ScreenContext(appName: name, bundleID: bundleID, windowTitle: title,
                             url: url, focused: focused, timestamp: Date())
    }

    private func browserURL(window: AXUIElement) -> String? {
        if let doc = AX.string(window, kAXDocumentAttribute), !doc.isEmpty { return doc }
        var queue = [window]
        var visited = 0
        while !queue.isEmpty && visited < 500 {
            let el = queue.removeFirst()
            visited += 1
            let role = AX.string(el, kAXRoleAttribute)
            if role == "AXWebArea", let u = AX.string(el, "AXURL"), !u.isEmpty { return u }
            if role == kAXTextFieldRole,
               let desc = (AX.string(el, kAXDescriptionAttribute) ?? AX.string(el, kAXTitleAttribute))?.lowercased(),
               desc.contains("address") || desc.contains("url") || desc.contains("location"),
               let val = AX.string(el, kAXValueAttribute), !val.isEmpty {
                return val
            }
            queue.append(contentsOf: AX.children(el))
        }
        return nil
    }
}
