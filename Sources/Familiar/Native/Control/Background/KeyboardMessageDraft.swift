import AppKit

/// Observed state bound to one Return-to-send approval. The model supplies the
/// intended recipient/text; Accessibility supplies the actual composer and context.
struct KeyboardMessageDraft {
    var pid: pid_t
    var windowID: CGWindowID
    var window: AXUIElement
    var field: AXUIElement
    var windowTitle: String
    var windowFrame: CGRect
    var role: String
    var context: [String]
    var text: String

    var displayContext: String {
        // Keep the card readable; the full ancestor context still binds approval.
        let composer = context.first { !$0.isEmpty && $0 != windowTitle }
        return ([windowTitle] + [composer].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func identifies(_ recipient: String) -> Bool {
        let name = Self.words(recipient)
        guard !name.isEmpty else { return false }
        return ([windowTitle] + context).contains { (" " + Self.words($0) + " ").contains(" " + name + " ") }
    }

    func matches(_ other: Self) -> Bool {
        pid == other.pid && windowID == other.windowID && CFEqual(window, other.window)
            && CFEqual(field, other.field) && windowTitle == other.windowTitle
            && windowFrame == other.windowFrame && role == other.role
            && context == other.context && text == other.text
    }

    private static func words(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    @MainActor static func capture(_ target: TargetWindow) -> Self? {
        guard !target.isMinimized,
              let windowTitle = AX.string(target.axWindow, kAXTitleAttribute),
              let focusedWindow = AX.element(target.axApp, kAXFocusedWindowAttribute), CFEqual(focusedWindow, target.axWindow),
              let field = AX.element(target.axApp, kAXFocusedUIElementAttribute),
              let role = AX.string(field, kAXRoleAttribute), ["AXTextField", "AXTextArea"].contains(role),
              AX.string(field, kAXSubroleAttribute) != "AXSecureTextField",
              let text = AX.string(field, kAXValueAttribute) else { return nil }
        var context: [String] = []
        var node: AXUIElement? = field
        var attached = false
        // Chat apps can reuse a composer when switching recipients in one window.
        for _ in 0..<128 {
            guard let current = node else { break }
            if CFEqual(current, target.axWindow) { attached = true; break }
            let role = AX.string(current, kAXRoleAttribute)
            let subrole = AX.string(current, kAXSubroleAttribute)
            guard role != "AXSheet", role != "AXDialog", subrole != "AXDialog" else { return nil }
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"] {
                if let label = AX.string(current, attribute), !label.isEmpty { context.append(label) }
            }
            node = AX.element(current, kAXParentAttribute)
        }
        guard attached, AX.string(target.axWindow, kAXSubroleAttribute) != "AXDialog" else { return nil }
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXEnabledAttribute as CFString, &enabled) == .success,
           let enabled = enabled as? NSNumber, !enabled.boolValue { return nil }
        return Self(pid: target.pid, windowID: target.cgWindowID, window: target.axWindow, field: field,
                    windowTitle: windowTitle, windowFrame: target.frameCG, role: role, context: context, text: text)
    }
}
