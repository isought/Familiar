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
    /// A field's or control's value, clipped; never a password field's, one named like a secret, or one that looks
    /// like a key or a card number.
    var value: String?
    /// The page's own id for it, steadier than its label.
    var domID: String?
    /// A link's address.
    var link: String?
    /// A heading's level, 1 to 6.
    var level: Int?
    /// On screen, in Accessibility's top-left coordinates.
    var frame: CGRect?
    /// Inside the visible part of the page.
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
    /// The titles of the window's tabs, from the browser's own tab strip.
    var tabs: [String] = []
    /// A sheet open over the page, such as a file picker or a print dialog, as the window's text shows it.
    var sheet: String? = nil
    /// A budget ran out before the whole page was read.
    var truncated: Bool
    var elapsed: TimeInterval

    var url: String? { documents.first?.url }
    var key: PageKey? { PageKey.of(documents) }

    /// The page as text for the model: its address and key, then one line per thing on it, in reading order, with
    /// what is outside the visible part of the page marked. Addresses lose their fragments and any parameter that
    /// can carry a credential.
    func text(limit: Int = 14_000) -> String {
        var out = "Page: \(windowTitle) (\(appName))\n"
        if let url, !url.isEmpty { out += "Address: \(PageWalk.safeAddress(url))\n" }
        if let key { out += "Page key: \(key)\n" }
        if documents.count > 1 { out += "Frames: " + documents.dropFirst().map { PageWalk.safeAddress($0.url) }.joined(separator: " · ") + "\n" }
        if !tabs.isEmpty { out += "Tabs: " + tabs.joined(separator: " · ") + "\n" }
        if let selectedText, !selectedText.isEmpty { out += "Selected text: “\(selectedText)”\n" }
        if let sheet, !sheet.isEmpty { out += "\nA sheet is open over the page:\n\(sheet)\n" }
        out += "\n"
        for element in elements {
            var line: String
            switch element.kind {
            case "text": line = element.label ?? ""
            case "heading": line = "[heading\(element.level.map { " \($0)" } ?? "")] " + (element.label ?? "")
            default:
                line = "[\(element.kind)] " + (element.label ?? "(no name)")
                if let value = element.value, !value.isEmpty, value != element.label { line += " = “\(value)”" }
                if let link = element.link, !link.isEmpty { line += " → \(PageWalk.safeAddress(link))" }
                if !element.enabled { line += " (disabled)" }
            }
            if !element.visible { line += " ·off screen" }
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
        var tabs: [String]
        var truncated: Bool
    }

    static let kinds: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "text field", "AXTextArea": "text area",
        "AXSearchField": "search field", "AXCheckBox": "checkbox", "AXRadioButton": "radio button",
        "AXPopUpButton": "pop-up button", "AXComboBox": "combo box", "AXMenuButton": "menu button",
        "AXMenuItem": "menu item", "AXDisclosureTriangle": "disclosure", "AXSlider": "slider",
        "AXHeading": "heading", "AXStaticText": "text", "AXImage": "image", "AXTab": "tab",
    ]
    /// Their own text is their name, not more of the page; controls inside them, such as a link in a heading, are
    /// still read.
    static let atomic: Set<String> = ["AXButton", "AXLink", "AXHeading", "AXMenuItem", "AXCheckBox", "AXRadioButton",
                                      "AXPopUpButton", "AXMenuButton", "AXTab", "AXDisclosureTriangle"]
    /// Fields whose value a person typed, so a secret can be in them.
    static let editable: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// The page under a browser window, or nil when the window shows none. `viewport` is the window's frame; what is
    /// on screen is what falls inside both it and the page.
    static func read<N: PageNode>(window: N, viewport: CGRect?, budget: Budget = Budget(), now: () -> Date = Date.init) -> Result? {
        let deadline = now().addingTimeInterval(budget.seconds)
        let (found, tabs) = webAreas(under: window, limit: budget.chrome)
        guard let top = page(among: found) else { return nil }
        var documents = [PageDocument(url: top.string("AXURL") ?? "", frame: top.frame)]
        var elements: [PageElement] = []
        var visited = 0, truncated = false, hint: String?
        // Each node goes with its document, the part of the screen its document shows, and whether it is inside a
        // control whose text is its name.
        var stack: [(N, Int, CGRect?, Bool)] = top.children.reversed().map { ($0, 0, clip(viewport, top.frame), false) }
        while let (node, document, visibleArea, inAtomic) = stack.popLast() {
            if visited >= budget.nodes || (visited % 64 == 63 && now() > deadline) {
                truncated = true
                break
            }
            visited += 1
            let role = node.string(kAXRoleAttribute) ?? ""
            if role == "AXWebArea" {
                documents.append(PageDocument(url: node.string("AXURL") ?? "", frame: node.frame))
                let index = documents.count - 1, area = clip(visibleArea, node.frame)
                stack.append(contentsOf: node.children.reversed().map { ($0, index, area, false) })
                continue
            }
            // Once the elements are full, the walk goes on for the frames alone, so the page key can still find the form.
            if elements.count >= budget.elements {
                truncated = true
            } else if !(inAtomic && role == "AXStaticText"),
                      let element = element(node, role: role, document: document, visibleArea: visibleArea, hint: hint) {
                elements.append(element)
                if role == "AXStaticText" { hint = element.label }
                if atomic.contains(role) {
                    stack.append(contentsOf: node.children.reversed().map { ($0, document, visibleArea, true) })
                    continue
                }
            }
            stack.append(contentsOf: node.children.reversed().map { ($0, document, visibleArea, inAtomic) })
        }
        return Result(documents: documents, elements: elements, tabs: tabs, truncated: truncated)
    }

    /// The pages in a window, found breadth first through the browser's tabs and toolbars without going into them,
    /// and the titles of its tabs on the way.
    static func webAreas<N: PageNode>(under window: N, limit: Int) -> (areas: [N], tabs: [String]) {
        var queue = [window], index = 0, areas: [N] = [], tabs: [String] = []
        while index < queue.count && index < limit {
            let node = queue[index]
            index += 1
            let role = node.string(kAXRoleAttribute)
            if role == "AXWebArea" { areas.append(node); continue }
            if role == "AXRadioButton" || role == "AXTab", node.string(kAXSubroleAttribute) == "AXTabButton" || role == "AXTab",
               let title = node.string(kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, tabs.count < 30 {
                tabs.append(String(title.prefix(80)))
            }
            queue.append(contentsOf: node.children)
        }
        return (areas, tabs)
    }

    /// The page among a window's web areas: not developer tools, a browser page or an extension's panel, and of the
    /// rest the largest, so a docked side panel or the smaller half of a split view isn't taken for the page.
    static func page<N: PageNode>(among areas: [N]) -> N? {
        let pages = areas.filter { area in
            let address = area.string("AXURL") ?? ""
            guard let scheme = URLComponents(string: address)?.scheme?.lowercased() else { return true }
            return ["http", "https", "file"].contains(scheme) || address == "about:blank"
        }
        return pages.max { size($0.frame) < size($1.frame) }
    }

    static func element<N: PageNode>(_ node: N, role: String, document: Int, visibleArea: CGRect?, hint: String? = nil) -> PageElement? {
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
            frame.width > 0 && frame.height > 0 && visibleArea.map { !$0.intersection(frame).isNull } != false
        } ?? false
        let enabled = node.flag(kAXEnabledAttribute) ?? true
        if role == "AXStaticText" {
            guard let text = clip(node.string(kAXValueAttribute), 300) else { return nil }
            return PageElement(kind: kind, role: role, label: looksLikeSecretValue(text) ? "(hidden: looks like a secret)" : text,
                               frame: frame, visible: visible, enabled: enabled, document: document)
        }
        let placeholder = node.string(kAXPlaceholderValueAttribute)
        var label = [node.string(kAXTitleAttribute), node.string(kAXDescriptionAttribute), placeholder]
            .lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        if label == nil, atomic.contains(role) { label = contentName(node) }
        if role == "AXImage", label == nil { return nil }
        let domID = node.string("AXDOMIdentifier").flatMap { $0.isEmpty ? nil : $0 }
        // A field is secret by its kind, its name, its placeholder, the page's id for it, or, for one named only by
        // the text beside it, that text.
        let secret = subrole == "AXSecureTextField" || WatchRecorder.looksSecret(label) || WatchRecorder.looksSecret(placeholder)
            || WatchRecorder.looksSecret(domID.map(words)) || (editable.contains(role) && label == nil && WatchRecorder.looksSecret(hint))
        var value = role == "AXHeading" || secret ? nil : clip(node.string(kAXValueAttribute), 200)
        if let shown = value, looksLikeSecretValue(shown) { value = nil }
        return PageElement(kind: kind, role: role, label: label.map { String($0.prefix(200)) }, value: value, domID: domID,
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

    // MARK: - Secrets and addresses

    private static let keyPattern = try! NSRegularExpression(pattern:
        #"(sk-[A-Za-z0-9_-]{16,}|sk_(live|test)_[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY)"#)
    private static let digitRun = try! NSRegularExpression(pattern: #"(?<![\d])(?:\d[ -]?){12,18}\d(?![\d])"#)

    /// Text that shows a key or a token a service issues, or a card number (13 to 19 digits that pass the Luhn check).
    static func looksLikeSecretValue(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if keyPattern.firstMatch(in: text, range: range) != nil { return true }
        return digitRun.matches(in: text, range: range).contains { match in
            guard let run = Range(match.range, in: text) else { return false }
            return luhn(text[run].filter(\.isNumber))
        }
    }

    static func luhn(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if index % 2 == 1 { digit *= 2; if digit > 9 { digit -= 9 } }
            sum += digit
        }
        return sum % 10 == 0
    }

    private static let credentialParameter = try! NSRegularExpression(pattern:
        #"(?i)^(token|access_token|id_token|refresh_token|code|state|sig|signature|key|api_?key|auth|authorization|session|session_?id|sid|password|pwd|secret|otp|x-amz-.*|x-goog-.*)$"#)

    /// An address without its fragment or any parameter that can carry a credential, such as a reset link's token or
    /// an OAuth code.
    static func safeAddress(_ address: String) -> String {
        guard var components = URLComponents(string: address) else { return address }
        components.fragment = nil
        if let items = components.queryItems {
            let kept = items.filter { credentialParameter.firstMatch(in: $0.name, range: NSRange($0.name.startIndex..., in: $0.name)) == nil }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.string ?? address
    }

    /// An id such as "user_password" or "apiKey" as words, so the secret test sees them.
    private static func words(_ id: String) -> String {
        id.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[_-]", with: " ", options: .regularExpression)
    }

    private static func clip(_ text: String?, _ limit: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func clip(_ area: CGRect?, _ frame: CGRect?) -> CGRect? {
        guard let area else { return frame }
        guard let frame else { return area }
        return area.intersection(frame)
    }

    private static func size(_ frame: CGRect?) -> CGFloat { frame.map { $0.width * $0.height } ?? 0 }
}

/// An Accessibility element as a page node. Each one waits at most a quarter of a second for the browser, so a page
/// that stops answering can't hold a read for long.
struct AXPageNode: PageNode {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, 0.25)
    }

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
/// time. Noteling changes nothing in the browser to read it: Chromium browsers build a page's tree as soon as an app
/// asks about it, so a first read that finds the page empty waits up to a second and looks again.
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
        let node = AXPageNode(element: window)
        var result = PageWalk.read(window: node, viewport: node.frame, budget: budget)
        if chromium.contains(bundle) {
            for _ in 0..<10 where result?.elements.isEmpty != false {
                Thread.sleep(forTimeInterval: 0.1)
                result = PageWalk.read(window: node, viewport: node.frame, budget: budget)
            }
        }
        guard let result else { return nil }
        let sheet = AX.children(window).first { AX.string($0, kAXRoleAttribute) == "AXSheet" }
            .map { ScreenText.dumpWindow($0, appName: app.localizedName ?? bundle, maxNodes: 400, maxChars: 3_000) }
        return PageSnapshot(appName: app.localizedName ?? bundle, bundleID: bundle, windowTitle: AX.string(window, kAXTitleAttribute) ?? "",
                            documents: result.documents, elements: result.elements, selectedText: selectedText(axApp),
                            tabs: result.tabs, sheet: sheet, truncated: result.truncated, elapsed: Date().timeIntervalSince(started))
    }

    /// The text selected in the focused element, unless that element could hold a secret or the text looks like one.
    private static func selectedText(_ axApp: AXUIElement) -> String? {
        guard let focused = AX.element(axApp, kAXFocusedUIElementAttribute),
              AX.string(focused, kAXSubroleAttribute) != "AXSecureTextField",
              ![kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].contains(where: { WatchRecorder.looksSecret(AX.string(focused, $0)) }),
              let text = AX.string(focused, kAXSelectedTextAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !PageWalk.looksLikeSecretValue(text) else { return nil }
        return String(text.prefix(1_000))
    }
}
