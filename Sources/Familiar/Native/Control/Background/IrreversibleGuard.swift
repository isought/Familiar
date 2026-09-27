import Foundation

/// Decides which background actions run freely, which need the human's word first, and which never run.
/// Everything here is pure so the rules are unit-tested; the session applies them before each AX press,
/// key combo and typed string. The bias is towards asking: a missed "Send" costs more than an extra question.
enum IrreversibleGuard {
    enum Classification: Equatable { case safe, confirm(String), forbidden(String) }

    struct ElementInfo: Equatable {
        var role: String?; var subrole: String?; var title: String?; var description: String?; var domID: String?; var value: String?
        var isDefaultButton = false; var isSecure = false
        /// The name the human would use for the control. AX often reports an empty title on web buttons, so empty
        /// strings fall through to the next source rather than hiding a description that says "Submit".
        var label: String { [title, description, domID].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
    }

    /// Whole-word matches in a label, value or DOM id that mean the press probably cannot be undone.
    static let confirmWords: [String] = ["send", "submit", "pay", "purchase", "buy", "checkout", "confirm", "delete", "remove", "discard",
                                         "sign", "approve", "reject", "publish", "post", "transfer", "unsubscribe", "reply all"]

    /// Forbidden combos keyed by canonical spelling ("cmd+shift+w": modifiers sorted, one spelling each).
    private static let forbiddenCombos: [String: String] = [
        "cmd+q": "cmd+q quits the app",
        "cmd+w": "cmd+w closes the window",
        "cmd+shift+w": "cmd+shift+w closes the window",
        "cmd+option+w": "cmd+option+w closes every window of the app",
        "cmd+h": "cmd+h hides the app",
        "cmd+m": "cmd+m minimizes the window",
    ]

    /// Window chrome and menus: closing, minimizing or zooming the target loses the session's only window, and
    /// menu AXPress silently no-ops in inactive apps anyway.
    private static let forbiddenSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
    private static let forbiddenRoles: Set<String> = ["AXMenuBarItem", "AXMenuItem"]

    /// One regex for all confirm words: `\b` on both sides so "sender" and "posted" pass, `\s+` inside phrases so
    /// "Reply  all" still matches. Case-insensitive.
    private static let confirmRegex: NSRegularExpression = {
        let alternatives = confirmWords.map { word in
            word.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        }
        // The word list is a compile-time constant, so a bad pattern is a programming error, not a runtime condition.
        return try! NSRegularExpression(pattern: "\\b(?:" + alternatives.joined(separator: "|") + ")\\b", options: [.caseInsensitive])
    }()

    private static func containsConfirmWord(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        return confirmRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Pure. cmd+q, cmd+w, cmd+shift+w, cmd+option+w, cmd+h, cmd+m (any spelling/order of modifiers, case-insensitive) → forbidden; every other combo → safe.
    static func classifyKey(_ combo: String) -> Classification {
        guard let canonical = canonicalCombo(combo), let reason = forbiddenCombos[canonical] else { return .safe }
        return .forbidden(reason)
    }

    /// "Shift + Command + W" → "cmd+shift+w". Nil when a modifier token is not one we know, since the combo then
    /// cannot be one of the forbidden ones (the key is always the last token).
    private static func canonicalCombo(_ combo: String) -> String? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let key = parts.last else { return nil }
        var mods = Set<String>()
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "super", "meta", "⌘": mods.insert("cmd")
            case "shift", "⇧": mods.insert("shift")
            case "option", "alt", "opt", "⌥": mods.insert("option")
            case "ctrl", "control", "^", "⌃": mods.insert("ctrl")
            default: return nil
            }
        }
        return (mods.sorted() + [key]).joined(separator: "+")
    }

    /// Pure. Forbidden: subrole AXCloseButton/AXMinimizeButton/AXZoomButton/AXFullScreenButton, role AXMenuBarItem/AXMenuItem.
    /// Confirm: label/value/domID matches a confirm word as a whole word (case-insensitive), or isDefaultButton inside a sheet,
    /// or NoteAnchor.norm(label) equals a normalised `declared` entry, or `warningNoteLabels` contains it. Else safe.
    /// The confirm payload is the label the session should ask about (falls back to value, then domID, when the
    /// control has no label of its own).
    static func classifyPress(_ el: ElementInfo, inSheet: Bool, declared: [String], warningNoteLabels: [String]) -> Classification {
        if let subrole = el.subrole, forbiddenSubroles.contains(subrole) { return .forbidden("window controls (\(subrole))") }
        if let role = el.role, forbiddenRoles.contains(role) { return .forbidden("menus (\(role))") }
        let label = el.label
        let name = [label, el.value ?? "", el.domID ?? ""].first { !$0.isEmpty } ?? ""
        if containsConfirmWord(label) || containsConfirmWord(el.value) || containsConfirmWord(el.domID) { return .confirm(name) }
        if el.isDefaultButton && inSheet { return .confirm(name.isEmpty ? "the default button" : name) }
        if let n = NoteAnchor.norm(label) {
            if declared.contains(where: { NoteAnchor.norm($0) == n }) { return .confirm(label) }
            if warningNoteLabels.contains(where: { NoteAnchor.norm($0) == n }) { return .confirm(label) }
        }
        return .safe
    }

    /// Pure. isSecure → forbidden("a password field"); else safe.
    static func classifyType(into el: ElementInfo) -> Classification {
        el.isSecure ? .forbidden("a password field") : .safe
    }

    /// The human said yes to one press (or a few) of one control, for a little while.
    struct Confirmation: Equatable { var label: String; var expires: Date; var usesLeft: Int }

    /// Pure. A pending confirmation that matches (normalised label equality) and is not expired consumes one use.
    /// Expired or exhausted confirmations are cleared so a stale yes never covers a later, unrelated press.
    static func consume(_ c: inout Confirmation?, label: String, now: Date) -> Bool {
        guard let pending = c else { return false }
        if now >= pending.expires || pending.usesLeft <= 0 { c = nil; return false }
        guard let n = NoteAnchor.norm(label), n == NoteAnchor.norm(pending.label) else { return false }
        c?.usesLeft -= 1
        if c?.usesLeft == 0 { c = nil }
        return true
    }

    /// Message for the model when a press needs confirming.
    static func confirmMessage(label: String) -> String {
        "This looks irreversible (button “\(label)”). Ask the user and end your reply with `Suggestions: \(label) it | Don't`"
    }
}
