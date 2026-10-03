import FamiliarContracts
import AppKit
import ApplicationServices
import Foundation

/// Tools implemented natively: file access over the tools folder, and reading the current window's text.
enum BuiltinTools {
    static let names: Set<String> = ["read_file", "grep", "read_screen", "look_at_screen"]

    static var definitions: [[String: Any]] { definitions(background: false) }

    static func definitions(background: Bool) -> [[String: Any]] {
        [
            ["name": "read_file",
             "description": "Read a documentation file from the tools folder. Paths are relative to the tools root, as listed in the prompt (e.g. \"expenses/docs/expense-reports.md\").",
             "input_schema": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]],
            ["name": "grep",
             "description": "Search all documentation and script files in the tools folder for a case-insensitive regex. Returns matching lines with file paths. Use this when the stuffed docs don't cover the question.",
             "input_schema": ["type": "object", "properties": [
                "pattern": ["type": "string", "description": "Regular expression"],
                "path": ["type": "string", "description": "Optional sub-folder to limit the search, e.g. \"expenses\""],
             ], "required": ["pattern"]]],
            ["name": "look_at_screen",
             "description": background
                ? "Take a fresh screenshot of the task's current target window. Follows target_window selections and never captures the user's other windows. Coordinates are pixels of this window capture; while borrowing the real mouse, use the computer screenshot action for display coordinates."
                : "Take a fresh screenshot of the display the user is working on and return it. Use only when the question is about what is on screen and no current screenshot was provided.",
             "input_schema": ["type": "object", "properties": [:]]],
            ["name": "read_screen",
             "description": background
                ? "Read text from the task's current target window via Accessibility (labels, values, buttons, links). Follows target_window selections and never reads the user's other windows."
                : "Return the text content of the user's current window via Accessibility (labels, values, buttons, links). Use it to read small text, dropdown values or error messages precisely.",
             "input_schema": ["type": "object", "properties": [:]]],
        ]
    }

    /// `root` is your own tools folder, `linkedRoot` the team's linked tools. A path names a file the way the prompt
    /// lists it (`<pack>/docs/…`), in the folder its pack is loaded from: your own when you have that pack, as the
    /// registry decides.
    static func execute(_ name: String, _ input: [String: Any], root: URL, linkedRoot: URL? = nil) -> ToolResult {
        let roots = [root] + (linkedRoot.map { [$0] } ?? [])
        switch name {
        case "read_file":
            guard let rel = input["path"] as? String, let url = resolve(rel, roots: roots)?.url else { return .text("Invalid path.", isError: true) }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .text("File not found: \(rel)", isError: true) }
            return .text(text.count > 40_000 ? String(text.prefix(40_000)) + "\n…(truncated)" : text)
        case "grep":
            guard let pattern = input["pattern"] as? String,
                  let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return .text("Invalid pattern.", isError: true) }
            // Your whole folder, then the linked packs you have none of your own for; or the one place asked for.
            var bases: [(dir: URL, root: URL)] = [(root, root)]
            if let linkedRoot {
                let own = Set(ToolRegistry.packFolders(in: root).map(\.lastPathComponent))
                bases += ToolRegistry.packFolders(in: linkedRoot).filter { !own.contains($0.lastPathComponent) }.map { ($0, linkedRoot) }
            }
            if let path = input["path"] as? String, let one = resolve(path, roots: roots) { bases = [(one.url, one.root)] }
            var hits: [String] = []
            search: for (base, top) in bases {
                guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let url as URL in e {
                    guard ["md", "markdown", "txt", "py", "json", "csv", "yaml", "yml"].contains(url.pathExtension.lowercased()),
                          let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    let rel = relative(url, to: top)
                    for (i, line) in text.components(separatedBy: "\n").enumerated() {
                        if re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                            hits.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(240))")
                            if hits.count >= 60 { break }
                        }
                    }
                    if hits.count >= 60 { hits.append("…(more matches omitted)"); break search }
                }
            }
            return .text(hits.isEmpty ? "No matches." : hits.joined(separator: "\n"))
        case "look_at_screen":
            return .text("look_at_screen must be handled by the caller.", isError: true)   // async capture; see Assistant
        case "read_screen":
            let text = ScreenText.dumpFrontmostWindow()
            return .text(text.isEmpty ? "Nothing readable (is Accessibility permission granted?)" : text)
        default:
            return .text("Unknown tool \(name)", isError: true)
        }
    }

    /// The file a tools-relative path names, and the folder it is in: the first folder with its pack, else your own.
    /// Never anything outside that folder.
    private static func resolve(_ rel: String, roots: [URL]) -> (url: URL, root: URL)? {
        let pack = rel.split(separator: "/").first.map(String.init) ?? ""
        let root = roots.first { !pack.isEmpty && FileManager.default.fileExists(atPath: $0.appendingPathComponent(pack).path) } ?? roots[0]
        let base = root.standardizedFileURL.path
        let url = root.appendingPathComponent(rel).standardizedFileURL
        guard url.path == base || url.path.hasPrefix(base + "/") else { return nil }
        return (url, root)
    }

    /// A found file's path as the prompt lists it, relative to its tools folder (which the walk may hand back resolved).
    private static func relative(_ url: URL, to root: URL) -> String {
        for base in [root.path, root.resolvingSymlinksInPath().path] where url.path.hasPrefix(base + "/") {
            return String(url.path.dropFirst(base.count + 1))
        }
        let resolved = url.resolvingSymlinksInPath().path, base = root.resolvingSymlinksInPath().path + "/"
        return resolved.hasPrefix(base) ? String(resolved.dropFirst(base.count)) : url.path
    }
}

enum ScreenText {
    /// The text of the window in front, read off the main thread: a browser's page through the page reader, which
    /// reads the page rather than the browser's tabs and toolbars, and anything else as before.
    static func readFrontmost() async -> ToolResult {
        await Task.detached(priority: .userInitiated) {
            let page = PageReader.readFrontmost().flatMap { $0.elements.isEmpty && $0.sheet == nil ? nil : $0 }
            let text = page?.text() ?? dumpFrontmostWindow()
            return ToolResult.text(text.isEmpty ? "Nothing readable (is Accessibility permission granted?)" : text)
        }.value
    }

    /// Depth-first text dump of the frontmost (non-Noteling) app's focused window.
    static func dumpFrontmostWindow(maxNodes: Int = 2000, maxChars: Int = 14_000) -> String {
        guard Permissions.accessibilityGranted else { return "" }
        let apps = NSWorkspace.shared.runningApplications
        guard let app = NSWorkspace.shared.frontmostApplication.flatMap({ $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 })
                ?? apps.first(where: { $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier }) else { return "" }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)
        guard let win = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.element(axApp, kAXMainWindowAttribute) else { return "" }
        return dumpWindow(win, appName: app.localizedName ?? "", maxNodes: maxNodes, maxChars: maxChars)
    }

    /// Read only the supplied window. The caller owns target selection and liveness checks.
    static func dumpWindow(_ win: AXUIElement, appName: String, maxNodes: Int = 2000, maxChars: Int = 14_000) -> String {
        var out = "Window: \(AX.string(win, kAXTitleAttribute) ?? "") (\(appName))\n"
        var visited = 0
        var stack: [(AXUIElement, Int)] = [(win, 0)]
        while let (el, depth) = stack.popLast(), visited < maxNodes, out.count < maxChars {
            visited += 1
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if role == "AXGroup" || role == "AXUnknown" || role == "AXSplitGroup" || role == "AXScrollArea" || role == "AXLayoutArea" {
                // structural: descend without printing
            } else {
                let title = AX.string(el, kAXTitleAttribute) ?? ""
                let desc = AX.string(el, kAXDescriptionAttribute) ?? ""
                var value = AX.string(el, kAXValueAttribute) ?? ""
                if !value.isEmpty, !safeValue(value, subrole: AX.string(el, kAXSubroleAttribute), names: [title, desc, AX.string(el, kAXPlaceholderValueAttribute) ?? ""]) {
                    value = "(hidden)"
                }
                let text = [title, desc, value].filter { !$0.isEmpty }.joined(separator: " | ")
                if !text.isEmpty {
                    let short = role.replacingOccurrences(of: "AX", with: "")
                    let clipped = text.count > 300 ? " …[element text truncated]" : ""
                    out += String(repeating: "  ", count: min(depth, 8)) + "[\(short)] \(text.prefix(300))\(clipped)\n"
                }
            }
            let kids = AX.children(el)
            for k in kids.reversed() { stack.append((k, depth + 1)) }
        }
        if visited >= maxNodes || out.count >= maxChars { out += "…(truncated)\n" }
        return out
    }

    /// Whether an element's value may be read out: not a password field's, one named like a secret, or a value that
    /// looks like a key or a card number.
    static func safeValue(_ value: String, subrole: String?, names: [String]) -> Bool {
        subrole != "AXSecureTextField" && !names.contains(where: { WatchRecorder.looksSecret($0) }) && !PageWalk.looksLikeSecretValue(value)
    }
}
