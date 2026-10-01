import AppKit
import ApplicationServices

/// One thing on a web page, as the page's own Accessibility tree names it.
struct PageElement: Equatable, Codable {
    /// "button", "link", "text field", "heading", "text"…
    var kind: String
    /// The Accessibility role, such as AXButton.
    var role: String
    /// What a person would call it: its title, else its description, placeholder or the text inside it.
    var label: String?
    /// A field's or control's value, clipped; never a password field's or one named like a secret.
    var value: String?
    /// The page's own id for it, steadier than its label.
    var domID: String?
    /// A link's address.
    var link: String?
    /// A heading's level, 1 to 6.
    var level: Int?
    /// On screen, in Accessibility's top-left coordinates.
    var frame: CGRect?
    /// Inside the window's visible area.
    var visible: Bool
    var enabled: Bool
    /// Which document it is in: 0 is the page, then the frames inside it in reading order.
    var document: Int
}

/// The page, or a frame inside it.
struct PageDocument: Equatable, Codable {
    var url: String
    var frame: CGRect?
}

/// What is on the page in a browser window: its documents, the controls, headings, links and text on it in reading
/// order, and the page's key. Read from the page's own Accessibility tree, never from pixels.
struct PageSnapshot {
    var appName: String
    var bundleID: String
    var windowTitle: String
    var documents: [PageDocument]
    var elements: [PageElement]
    var selectedText: String?
    /// A budget ran out before the whole page was read.
    var truncated: Bool
    var elapsed: TimeInterval

    var url: String? { documents.first?.url }
    var key: PageKey? { PageKey.of(documents) }

    /// The page as text for the model: its address and key, then one line per thing on it, in reading order, with
    /// what is outside the window's visible area marked.
    func text(limit: Int = 14_000) -> String {
        var out = "Page: \(windowTitle) (\(appName))\n"
        if let url, !url.isEmpty { out += "Address: \(url)\n" }
        if let key { out += "Page key: \(key)\n" }
        if documents.count > 1 { out += "Frames: " + documents.dropFirst().map(\.url).joined(separator: " · ") + "\n" }
        if let selectedText, !selectedText.isEmpty { out += "Selected text: “\(selectedText)”\n" }
        out += "\n"
        var hidden = 0
        for element in elements {
            var line: String
            switch element.kind {
            case "text": line = element.label ?? ""
            case "heading": line = "[heading\(element.level.map { " \($0)" } ?? "")] " + (element.label ?? "")
            default:
                line = "[\(element.kind)] " + (element.label ?? "(no name)")
                if let value = element.value, !value.isEmpty, value != element.label { line += " = “\(value)”" }
                if let link = element.link, !link.isEmpty { line += " → \(link)" }
                if !element.enabled { line += " (disabled)" }
            }
            if !element.visible { line += " ·off screen"; hidden += 1 }
            guard out.count + line.count < limit else { out += "…(more of the page not shown)\n"; return out }
            out += line + "\n"
        }
        if truncated { out += "…(the page is longer; only the first part was read)\n" }
        return out
    }
}

/// What the walk needs from an Accessibility element, so it can be tested on a made-up page.
protocol PageNode {
    func string(_ attribute: String) -> String?
    func number(_ attribute: String) -> Int?
    func flag(_ attribute: String) -> Bool?
    var frame: CGRect? { get }
    var children: [Self] { get }
}

/// Reads a page's Accessibility tree into documents and elements, within a budget of nodes, elements and time, so a
/// page of tens of thousands of nodes can't stall Noteling.
enum PageWalk {
    struct Budget {
        var nodes = 6_000
        var elements = 900
        var seconds: TimeInterval = 1.5
        /// How many of the browser's own controls to look through for the page itself.
        var chrome = 800
    }

    struct Result {
        var documents: [PageDocument]
        var elements: [PageElement]
        var truncated: Bool
    }

    static let kinds: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "text field", "AXTextArea": "text area",
        "AXSearchField": "search field", "AXCheckBox": "checkbox", "AXRadioButton": "radio button",
        "AXPopUpButton": "pop-up button", "AXComboBox": "combo box", "AXMenuButton": "menu button",
        "AXMenuItem": "menu item", "AXDisclosureTriangle": "disclosure", "AXSlider": "slider",
        "AXHeading": "heading", "AXStaticText": "text", "AXImage": "image", "AXTab": "tab",
    ]
    /// Read whole: the text inside them is their name, not more of the page.
    static let atomic: Set<String> = ["AXButton", "AXLink", "AXHeading", "AXMenuItem", "AXCheckBox", "AXRadioButton",
                                      "AXPopUpButton", "AXMenuButton", "AXTab", "AXDisclosureTriangle"]

    /// The page under a browser window, or nil when the window shows none. `viewport` is the window's frame, for
    /// telling what is on screen.
    static func read<N: PageNode>(window: N, viewport: CGRect?, budget: Budget = Budget(), now: () -> Date = Date.init) -> Result? {
        guard let top = webArea(under: window, limit: budget.chrome) else { return nil }
        let deadline = now().addingTimeInterval(budget.seconds)
        var documents = [PageDocument(url: top.string("AXURL") ?? "", frame: top.frame)]
        var elements: [PageElement] = []
        var visited = 0, truncated = false
        var stack: [(N, Int)] = top.children.reversed().map { ($0, 0) }
        while let (node, document) = stack.popLast() {
            if visited >= budget.nodes || elements.count >= budget.elements || (visited % 64 == 63 && now() > deadline) {
                truncated = true
                break
            }
            visited += 1
            let role = node.string(kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                documents.append(PageDocument(url: node.string("AXURL") ?? "", frame: node.frame))
                let index = documents.count - 1
                stack.append(contentsOf: node.children.reversed().map { ($0, index) })
                continue
            }
            if let element = element(node, role: role, document: document, viewport: viewport) {
                elements.append(element)
                if atomic.contains(role) { continue }
            }
            stack.append(contentsOf: node.children.reversed().map { ($0, document) })
        }
        return Result(documents: documents, elements: elements, truncated: truncated)
    }

    /// The page itself: the first web area, breadth first through the browser's tabs and toolbars.
    static func webArea<N: PageNode>(under window: N, limit: Int) -> N? {
        var queue = [window], index = 0
        while index < queue.count && index < limit {
            let node = queue[index]
            index += 1
            if node.string(kAXRoleAttribute) == "AXWebArea" { return node }
            queue.append(contentsOf: node.children)
        }
        return nil
    }

    static func element<N: PageNode>(_ node: N, role: String, document: Int, viewport: CGRect?) -> PageElement? {
        guard var kind = kinds[role] else { return nil }
        let subrole = node.string(kAXSubroleAttribute)
        switch subrole {
        case "AXTabButton": kind = "tab"
        case "AXSwitch": kind = "switch"
        case "AXSearchField": kind = "search field"
        case "AXSecureTextField": kind = "password field"
        default: break
        }
        let frame = node.frame
        let visible = frame.map { frame in
            frame.width > 0 && frame.height > 0 && viewport.map { !$0.intersection(frame).isNull } != false
        } ?? false
        let enabled = node.flag(kAXEnabledAttribute) ?? true
        if role == "AXStaticText" {
            guard let text = clip(node.string(kAXValueAttribute), 300) else { return nil }
            return PageElement(kind: kind, role: role, label: text, frame: frame, visible: visible, enabled: enabled, document: document)
        }
        var label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            .lazy.compactMap { node.string($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        if label == nil, atomic.contains(role) { label = contentName(node) }
        if role == "AXImage", label == nil { return nil }
        let secret = subrole == "AXSecureTextField" || WatchRecorder.looksSecret(label)
            || WatchRecorder.looksSecret(node.string(kAXPlaceholderValueAttribute))
        let value = role == "AXHeading" || secret ? nil : clip(node.string(kAXValueAttribute), 200)
        return PageElement(kind: kind, role: role, label: label.map { String($0.prefix(200)) }, value: value,
            domID: node.string("AXDOMIdentifier").flatMap { $0.isEmpty ? nil : $0 },
            link: role == "AXLink" ? node.string("AXURL") : nil,
            level: role == "AXHeading" ? node.number(kAXValueAttribute).flatMap { (1...6).contains($0) ? $0 : nil } : nil,
            frame: frame, visible: visible, enabled: enabled, document: document)
    }

    /// The text inside a control that has no name of its own, as a person reads it: up to 120 characters.
    static func contentName<N: PageNode>(_ node: N) -> String? {
        var words: [String] = [], count = 0
        var stack: [(N, Int)] = [(node, 0)]
        while let (current, depth) = stack.popLast(), count < 120 {
            if depth > 0, current.string(kAXRoleAttribute) == "AXStaticText",
               let text = current.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                words.append(text)
                count += text.count + 1
            }
            if depth < 4 { stack.append(contentsOf: current.children.reversed().map { ($0, depth + 1) }) }
        }
        let name = words.joined(separator: " ")
        return name.isEmpty ? nil : String(name.prefix(120))
    }

    private static func clip(_ text: String?, _ limit: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

/// An Accessibility element as a page node.
struct AXPageNode: PageNode {
    let element: AXUIElement

    func string(_ attribute: String) -> String? { AX.string(element, attribute) }

    func number(_ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    func flag(_ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    var frame: CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    var children: [AXPageNode] { AX.children(element).map(AXPageNode.init) }
}

/// Reads the page in a browser window. Call it off the main thread: a page's tree is read one Accessibility call at a
/// time. Chromium browsers build the page's tree only when asked, so the first read turns it on through Chromium's own
/// switch, AXManualAccessibility, never the system-wide one that changes how the whole app behaves; Noteling turns it
/// back off when it quits.
enum PageReader {
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// The page in front: the frontmost app's window, when that app is a browser.
    static func readFrontmost(budget: PageWalk.Budget = PageWalk.Budget()) -> PageSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              ContextWatcher.browserBundles.contains(bundle) else { return nil }
        return read(app, budget: budget)
    }

    /// The page in the browser window nearest the front, whatever app is frontmost: for reading a page from Terminal.
    static func readFrontBrowser(budget: PageWalk.Budget = PageWalk.Budget()) -> PageSnapshot? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, let app = NSRunningApplication(processIdentifier: pid),
                  let bundle = app.bundleIdentifier, ContextWatcher.browserBundles.contains(bundle) else { continue }
            return read(app, budget: budget)
        }
        return nil
    }

    static func read(_ app: NSRunningApplication, budget: PageWalk.Budget = PageWalk.Budget()) -> PageSnapshot? {
        guard Permissions.accessibilityGranted, let bundle = app.bundleIdentifier else { return nil }
        let started = Date()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let window = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.element(axApp, kAXMainWindowAttribute) else { return nil }
        if chromium.contains(bundle) { ManualAccessibility.shared.turnOn(axApp, pid: app.processIdentifier, window: window) }
        let node = AXPageNode(element: window)
        guard let result = PageWalk.read(window: node, viewport: node.frame, budget: budget) else { return nil }
        let selected = AX.element(axApp, kAXFocusedUIElementAttribute).flatMap { AX.string($0, kAXSelectedTextAttribute) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : String($0.prefix(1_000)) }
        return PageSnapshot(appName: app.localizedName ?? bundle, bundleID: bundle, windowTitle: AX.string(window, kAXTitleAttribute) ?? "",
                            documents: result.documents, elements: result.elements, selectedText: selected,
                            truncated: result.truncated, elapsed: Date().timeIntervalSince(started))
    }

    /// Turns the page trees Noteling asked for back off.
    static func restore() { ManualAccessibility.shared.restore() }
}

/// The Chromium processes whose page tree Noteling turned on, so it can turn them back off and never turns off one
/// that was on already, for example for a screen reader.
final class ManualAccessibility: @unchecked Sendable {
    static let shared = ManualAccessibility()
    private static let attribute = "AXManualAccessibility" as CFString
    private let lock = NSLock()
    private var turnedOn: Set<pid_t> = []

    /// Turns the tree on when it is off, then waits up to a second for the page to appear in it.
    func turnOn(_ app: AXUIElement, pid: pid_t, window: AXUIElement) {
        lock.lock()
        let already = turnedOn.contains(pid)
        lock.unlock()
        guard !already else { return }
        var current: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, Self.attribute, &current) == .success, (current as? NSNumber)?.boolValue == true { return }
        guard AXUIElementSetAttributeValue(app, Self.attribute, kCFBooleanTrue) == .success else { return }
        lock.lock()
        turnedOn.insert(pid)
        lock.unlock()
        Log.info("page reader: turned on the page tree of process \(pid)")
        for _ in 0..<10 {
            if let page = PageWalk.webArea(under: AXPageNode(element: window), limit: 800), !page.children.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func restore() {
        lock.lock()
        let pids = turnedOn
        turnedOn = []
        lock.unlock()
        for pid in pids where NSRunningApplication(processIdentifier: pid) != nil {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), Self.attribute, kCFBooleanFalse)
        }
    }
}
