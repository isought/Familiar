import Foundation

/// Reading starts with visible lists and pages. Message rows and arbitrary links are
/// deliberately excluded: opening mail can change read state, and body links are not navigation.
enum ReadingNavigationPolicy {
    static func refusal(_ info: IrreversibleGuard.ElementInfo) -> String? {
        let roles: Set<String> = ["AXButton", "AXRadioButton", "AXTab"]
        guard let role = info.role, roles.contains(role), !info.isSecure, !info.isDefaultButton else { return blocked }
        guard case .safe = IrreversibleGuard.classifyPress(info, inSheet: false, declared: [], warningNoteLabels: []) else { return blocked }
        let metadata = [info.title, info.description, info.domID, info.value].compactMap { $0 }.joined(separator: " ").lowercased()
        let words = Set(metadata.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let mutations: Set<String> = ["compose", "reply", "forward", "send", "archive", "delete", "trash", "spam", "unsubscribe",
                                       "star", "unstar", "snooze", "mark", "label", "labels", "move", "settings", "select", "selection",
                                       "save", "edit", "create", "add", "submit", "confirm", "apply", "account", "sign", "switch"]
        guard words.isDisjoint(with: mutations) else { return blocked }
        let label = info.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let navigation: Set<String> = ["inbox", "primary", "social", "promotions", "updates", "forums", "all mail",
                                       "older", "newer", "back to inbox", "refresh", "reload", "next", "previous", "back",
                                       "next page", "previous page", "show more", "load more", "more results", "next results", "previous results"]
        // Mailbox tabs can include a displayed unread count without changing their purpose.
        let normalized = label.replacingOccurrences(of: #"\s*[\(\[]?\d+[\)\]]?\s*(?:unread)?$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return navigation.contains(normalized) ? nil : blocked
    }

    /// The extra capability is restricted to captured tracked subjects and row/cell
    /// roles. A matching word in a reply button or content link never permits it.
    static func followUpRefusal(_ info: IrreversibleGuard.ElementInfo, trackedItems: [TrackedSourceItem]) -> String? {
        if refusal(info) == nil { return nil }
        let label = info.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = [info.title, info.description, info.domID, info.value].compactMap { $0 }.joined(separator: " ").lowercased()
        guard !info.isSecure, !info.isDefaultButton,
              case .safe = IrreversibleGuard.classifyPress(info, inSheet: false, declared: [], warningNoteLabels: []) else { return followUpBlocked }
        if info.role == "AXButton", ["sent", "sent mail", "back to inbox", "back to all mail", "back to sent mail"].contains(label) {
            // Descriptive mutation metadata must still reject an otherwise safe label.
            let words = Set(metadata.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            if words.isDisjoint(with: ["delete", "archive", "compose", "reply", "forward", "mark", "select", "settings"]) { return nil }
        }
        guard info.role == "AXRow" || info.role == "AXCell" else { return followUpBlocked }
        let matched = trackedItems.prefix(ReadingSubmission.trackedItemLimit).contains { item in
            let title = item.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !title.isEmpty && metadata.contains(title)
        }
        return matched ? nil : followUpBlocked
    }

    static let followUpBlocked = "This control is not supported for tracked follow-up reading. Only matching tracked message rows/cells and recognized mailbox navigation can open. Unrelated messages, content links and mutation controls remain unavailable. Leave the item unresolved if it cannot be verified."

    static let blocked = "This control is not supported for source reading. Noteling can inspect the current list and use recognized mailbox or page navigation. It cannot open message rows, follow content links, change mail, or use unrecognized controls. Report incomplete coverage when needed."
}
