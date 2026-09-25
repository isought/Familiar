import AppKit
import ApplicationServices
import Foundation

/// Where a note is stuck. A scene (a site's host and path, or an app's bundle id and window) plus a control on it
/// (its Accessibility role and the label shown on screen). Spots without a label, and circled regions, keep a
/// rectangle relative to the window instead.
struct NoteAnchor: Codable, Equatable {
    var host: String? = nil       // "127.0.0.1:4310" for a site (lowercase, with the port when there is one)
    var path: String? = nil       // URL path; nil or "/" means any page on the host
    var bundle: String? = nil     // bundle id for a native app
    var window: String? = nil     // a window-title fragment for a native app (nil for browsers: page titles change)
    var role: String? = nil       // "AXButton"
    var label: String? = nil      // the control's title / description / placeholder as shown
    var rect: [Double]? = nil     // x, y, w, h as fractions of the window frame, top-left origin

    var isRegion: Bool { label == nil && rect != nil }

    /// `button “Save page” on 127.0.0.1:4310`, or `a spot in “Untitled” (com.apple.TextEdit)`.
    var summary: String {
        let place = host.map { $0 + (path.map { $0 == "/" ? "" : $0 } ?? "") } ?? window.map { "“\($0)”" } ?? bundle ?? "?"
        if let label { return "\(Self.roleWord(role)) “\(label)” on \(place)" }
        return "a circled spot on \(place)"
    }

    /// The control alone: `button “Save page”`, or `a circled spot`.
    var controlSummary: String {
        if let label { return "\(Self.roleWord(role)) “\(label)”" }
        return "a circled spot"
    }

    /// A context that stands for the scene, so pack match rules can be applied to it.
    var sceneContext: ScreenContext {
        ScreenContext(appName: "", bundleID: bundle ?? "", windowTitle: window ?? "",
                      url: host.map { "http://\($0)\(path ?? "/")" }, focused: nil, timestamp: Date())
    }

    static func roleWord(_ role: String?) -> String {
        guard let role, !role.isEmpty else { return "control" }
        return role.replacingOccurrences(of: "AX", with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
    }

    /// Lowercased, whitespace collapsed; nil when empty.
    static func norm(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return t.isEmpty ? nil : t
    }

    static func hostKey(_ url: String?) -> String? {
        guard let url, let c = URLComponents(string: url), let h = c.host?.lowercased(), !h.isEmpty else { return nil }
        return c.port.map { "\(h):\($0)" } ?? h
    }

    static func pathKey(_ url: String?) -> String {
        guard let url, let c = URLComponents(string: url) else { return "/" }
        return c.path.isEmpty ? "/" : c.path
    }

    func matchesScene(_ ctx: ScreenContext) -> Bool {
        if let host {
            guard Self.hostKey(ctx.url) == host.lowercased() else { return false }
            if let path, !path.isEmpty, path != "/" { return Self.pathKey(ctx.url) == path }
            return true
        }
        if let bundle {
            guard ctx.bundleID == bundle else { return false }
            if let w = Self.norm(window) { return Self.norm(ctx.windowTitle)?.contains(w) ?? false }
            return true
        }
        return false
    }

    func matchesElement(role r: String?, label l: String?) -> Bool {
        guard let role, let label, let r, role == r, let want = Self.norm(label), let have = Self.norm(l) else { return false }
        return want == have
    }

    /// The rect anchor as a screen rect inside `windowFrame` (AppKit coordinates).
    func screenRect(in windowFrame: NSRect) -> NSRect? {
        guard let r = rect, r.count == 4, windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        let w = windowFrame.width * r[2], h = windowFrame.height * r[3]
        let x = windowFrame.minX + windowFrame.width * r[0]
        let top = windowFrame.maxY - windowFrame.height * r[1]
        return NSRect(x: x, y: top - h, width: w, height: h)
    }

    static func fractions(of rect: NSRect, in windowFrame: NSRect) -> [Double] {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return [0, 0, 0, 0] }
        let x = (rect.minX - windowFrame.minX) / windowFrame.width
        let top = (windowFrame.maxY - rect.maxY) / windowFrame.height
        return [x, top, rect.width / windowFrame.width, rect.height / windowFrame.height]
            .map { (Double(min(max($0, 0), 1)) * 10000).rounded() / 10000 }
    }
}

/// One sticky note, kept in the pack's `notes.json`.
struct StickyNote: Codable, Identifiable, Equatable {
    var id: String
    var anchor: NoteAnchor
    var kind: String          // "tip" | "warning"
    var text: String
    var by: String
    var at: String            // yyyy-MM-dd
    var confirmed: String     // yyyy-MM-dd, last time someone said it still holds

    var isWarning: Bool { kind == "warning" }
    var byline: String { "\(by) · \(confirmed)" }
}

/// What the pen hands over when a note is written: enough to build a `StickyNote`, and the frame to stick it at.
struct NoteDraft {
    var existingID: String?
    var anchor: NoteAnchor
    var kind: String
    var text: String
    var frame: NSRect          // where the sticker goes on screen, AppKit global coordinates
}

/// `notes.json` in a pack folder: `{"notes": [...]}`.
enum NoteStore {
    static let fileName = "notes.json"
    private struct File: Codable { var notes: [StickyNote] }
    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    static func load(packDir: URL) -> [StickyNote] {
        let url = packDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        do { return try JSONDecoder().decode(File.self, from: data).notes }
        catch { Log.info("notes: cannot read \(url.path): \(error.localizedDescription)"); return [] }
    }

    static func save(_ notes: [StickyNote], packDir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(File(notes: notes)).write(to: packDir.appendingPathComponent(fileName), options: .atomic)
    }

    static func author(_ config: Config) -> String {
        let n = config.noteAuthor.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? NSUserName() : full
    }

    static func make(_ d: NoteDraft, by: String, date: Date = Date()) -> StickyNote {
        let when = day.string(from: date)
        return StickyNote(id: d.existingID ?? UUID().uuidString.lowercased(), anchor: d.anchor,
                          kind: d.kind == "warning" ? "warning" : "tip",
                          text: d.text.trimmingCharacters(in: .whitespacesAndNewlines), by: by, at: when, confirmed: when)
    }

    /// The scene half of an anchor: host and path for a page in a browser, bundle and window for anything else.
    static func sceneAnchor(bundleID: String?, windowTitle: String?, url: String?) -> NoteAnchor {
        var a = NoteAnchor()
        if let b = bundleID, ContextWatcher.browserBundles.contains(b), let host = NoteAnchor.hostKey(url) {
            a.host = host
            a.path = NoteAnchor.pathKey(url)
        } else {
            a.bundle = bundleID
            let t = windowTitle?.trimmingCharacters(in: .whitespaces) ?? ""
            a.window = t.isEmpty ? nil : String(t.prefix(80))
        }
        return a
    }

    /// Folder name for a scene that has no pack yet: the host or the app's name, as a slug.
    static func packSlug(for anchor: NoteAnchor, appName: String?) -> String {
        let base = anchor.host ?? appName ?? anchor.bundle?.split(separator: ".").last.map(String.init) ?? "notes"
        let s = PackWriter.slug(base)
        return s.isEmpty ? "notes" : s
    }

    /// Creates a minimal pack (a SKILL.md with a match rule) so the note has a home. Returns the pack folder.
    @discardableResult
    static func ensurePack(for anchor: NoteAnchor, appName: String?, root: URL) throws -> URL {
        let dir = root.appendingPathComponent(packSlug(for: anchor, appName: appName))
        let skill = dir.appendingPathComponent("SKILL.md")
        guard !FileManager.default.fileExists(atPath: skill.path) else { return dir }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (anchor.host ?? appName ?? dir.lastPathComponent).replacingOccurrences(of: "\n", with: " ")
        var s = "---\nname: \(name)\ndescription: Notes left with the pen.\nmatch:\n"
        if let host = anchor.host { s += "  urls: [\(host)]\n" }
        if let bundle = anchor.bundle { s += "  bundles: [\(bundle)]\n" }
        s += "---\nNotes left by people who use this. See notes.json; each note is stuck to a control by its role and label.\n"
        try s.write(to: skill, atomically: true, encoding: .utf8)
        Log.info("notes: created pack \(dir.lastPathComponent) for \(anchor.summary)")
        return dir
    }
}

/// A walk of the frontmost app's focused window: labelled controls with their frames, for placing stickers and for
/// naming what sits inside a circled region.
enum AXScan {
    struct Item {
        let role: String
        let label: String?
        let frame: NSRect      // AppKit global coordinates
        var summary: String { label.map { "\(NoteAnchor.roleWord(role)) “\($0.prefix(60))”" } ?? NoteAnchor.roleWord(role) }
    }
    struct Result {
        var bundleID: String?
        var windowFrame: NSRect?
        var items: [Item] = []
    }

    static let structural: Set<String> = ["AXGroup", "AXUnknown", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXWebArea", "AXList", "AXTable", "AXOutline"]

    static func frontmostWindow(maxNodes: Int = 2500) -> Result {
        var out = Result()
        guard Permissions.accessibilityGranted,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return out }
        out.bundleID = app.bundleIdentifier
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)
        guard let win = AX.element(axApp, kAXFocusedWindowAttribute) ?? AX.element(axApp, kAXMainWindowAttribute) else { return out }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        out.windowFrame = WandController.axFrame(of: win, primaryMaxY: primaryMaxY)
        var stack: [AXUIElement] = [win]
        var visited = 0
        while let el = stack.popLast(), visited < maxNodes {
            visited += 1
            let role = AX.string(el, kAXRoleAttribute) ?? "AXUnknown"
            if !structural.contains(role), let frame = WandController.axFrame(of: el, primaryMaxY: primaryMaxY), frame.width > 0, frame.height > 0 {
                let label = [AX.string(el, kAXTitleAttribute), AX.string(el, kAXDescriptionAttribute), AX.string(el, kAXPlaceholderValueAttribute)]
                    .compactMap { $0 }.first { !$0.isEmpty }
                out.items.append(Item(role: role, label: label, frame: frame))
            }
            for k in AX.children(el).reversed() { stack.append(k) }
        }
        return out
    }
}
