import AppKit
import ApplicationServices
import Foundation

/// Tools implemented natively: file access over the tools folder, and reading the current window's text.
enum BuiltinTools {
    static let names: Set<String> = ["read_file", "grep", "read_screen", "look_at_screen"]

    static var definitions: [[String: Any]] {
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
             "description": "Take a fresh screenshot of the display the user is working on and return it. Use only when the question is about what is on screen and no current screenshot was provided.",
             "input_schema": ["type": "object", "properties": [:]]],
            ["name": "read_screen",
             "description": "Return the text content of the user's current window via Accessibility (labels, values, buttons, links). Use it to read small text, dropdown values or error messages precisely.",
             "input_schema": ["type": "object", "properties": [:]]],
        ]
    }

    static func execute(_ name: String, _ input: [String: Any], root: URL) -> ToolResult {
        switch name {
        case "read_file":
            guard let rel = input["path"] as? String, let url = resolve(rel, root: root) else { return .text("Invalid path.", isError: true) }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .text("File not found: \(rel)", isError: true) }
            return .text(text.count > 40_000 ? String(text.prefix(40_000)) + "\n…(truncated)" : text)
        case "grep":
            guard let pattern = input["pattern"] as? String,
                  let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return .text("Invalid pattern.", isError: true) }
            let base = (input["path"] as? String).flatMap { resolve($0, root: root) } ?? root
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return .text("No files.", isError: true) }
            var hits: [String] = []
            for case let url as URL in e {
                guard ["md", "markdown", "txt", "py", "json", "csv", "yaml", "yml"].contains(url.pathExtension.lowercased()),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    if re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                        hits.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(240))")
                        if hits.count >= 60 { break }
                    }
                }
                if hits.count >= 60 { hits.append("…(more matches omitted)"); break }
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

    private static func resolve(_ rel: String, root: URL) -> URL? {
        let url = root.appendingPathComponent(rel).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        return url
    }
}

enum ScreenText {
    /// Depth-first text dump of the frontmost (non-Familiar) app's focused window.
    static func dumpFrontmostWindow(maxNodes: Int = 2000, maxChars: Int = 14_000) -> String {
        guard Permissions.accessibilityGranted else { return "" }
        let apps = NSWorkspace.shared.runningApplications
        guard let app = NSWorkspace.shared.frontmostApplication.flatMap({ $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 })
                ?? apps.first(where: { $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier }) else { return "" }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)
        guard let win = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.element(axApp, kAXMainWindowAttribute) else { return "" }
        var out = "Window: \(AX.string(win, kAXTitleAttribute) ?? "") (\(app.localizedName ?? ""))\n"
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
                let value = AX.string(el, kAXValueAttribute) ?? ""
                let text = [title, desc, value].filter { !$0.isEmpty }.joined(separator: " | ")
                if !text.isEmpty {
                    let short = role.replacingOccurrences(of: "AX", with: "")
                    out += String(repeating: "  ", count: min(depth, 8)) + "[\(short)] \(text.prefix(300))\n"
                }
            }
            let kids = AX.children(el)
            for k in kids.reversed() { stack.append((k, depth + 1)) }
        }
        if visited >= maxNodes || out.count >= maxChars { out += "…(truncated)\n" }
        return out
    }
}
