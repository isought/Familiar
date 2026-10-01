import AppKit
import ApplicationServices

struct AXElementInfo {
    var role: String
    var title: String?
    var value: String?
    var description: String?
    var frame: NSRect?     // AppKit global coords
    var subrole: String? = nil       // AXSecureTextField marks a password field
    var placeholder: String? = nil
    var domID: String? = nil         // a web page's own id for it (AXDOMIdentifier)

    /// e.g. `button “Submit”` or `text field “Cost Center” = “”`
    var label: String {
        let r = role.replacingOccurrences(of: "AX", with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
        let name = title?.isEmpty == false ? title : (description?.isEmpty == false ? description : nil)
        var s = name.map { "\(r) “\($0)”" } ?? r
        if let v = value, !v.isEmpty, v != name { s += " = “\(v.prefix(80))”" }
        return s
    }

    /// The name a note is anchored by: title, else description, else placeholder.
    var anchorLabel: String? { [title, description, placeholder].compactMap { $0 }.first { !$0.isEmpty } }
    var isSecure: Bool { subrole == "AXSecureTextField" || role == "AXSecureTextField" }
}

/// The native window and accessibility element under a screen point.
struct ScreenHit {
    var screenPoint: NSPoint
    var element: AXElementInfo?
    var windowOwner: String?
    var windowTitle: String?
    var ownerBundleID: String? = nil
    var windowFrame: NSRect? = nil     // AppKit global coordinates
}

@MainActor
enum ScreenHitTester {
    static func hitTest(at point: NSPoint) -> ScreenHit {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryMaxY - point.y)
        let myPID = ProcessInfo.processInfo.processIdentifier

        var ownerPID: pid_t?
        var owner: String?
        var title: String?
        var windowFrame: NSRect?
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != myPID else { continue }
            guard let layer = w[kCGWindowLayer as String] as? Int, layer < 20 else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            guard let bdict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: bdict), bounds.contains(cgPoint) else { continue }
            ownerPID = pid
            owner = w[kCGWindowOwnerName as String] as? String
            title = w[kCGWindowName as String] as? String
            windowFrame = NSRect(x: bounds.minX, y: primaryMaxY - bounds.maxY, width: bounds.width, height: bounds.height)
            break
        }

        var info: AXElementInfo?
        if let pid = ownerPID, Permissions.accessibilityGranted {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            var el: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(cgPoint.x), Float(cgPoint.y), &el) == .success, let el {
                info = AXElementInfo(role: AX.string(el, kAXRoleAttribute) ?? "AXUnknown",
                                     title: AX.string(el, kAXTitleAttribute),
                                     value: AX.string(el, kAXValueAttribute),
                                     description: AX.string(el, kAXDescriptionAttribute),
                                     frame: Self.axFrame(of: el, primaryMaxY: primaryMaxY),
                                     subrole: AX.string(el, kAXSubroleAttribute),
                                     placeholder: AX.string(el, kAXPlaceholderValueAttribute),
                                     domID: AX.string(el, "AXDOMIdentifier").flatMap { $0.isEmpty ? nil : $0 })
                if (info?.title ?? "").isEmpty, (info?.description ?? "").isEmpty,
                   let parent = AX.element(el, kAXParentAttribute), let pt = AX.string(parent, kAXTitleAttribute), !pt.isEmpty {
                    info?.description = pt
                }
            }
        }
        let bundle = ownerPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        return ScreenHit(screenPoint: point, element: info, windowOwner: owner, windowTitle: title, ownerBundleID: bundle, windowFrame: windowFrame)
    }

    /// An element's frame in AppKit global coordinates.
    nonisolated static func axFrame(of el: AXUIElement, primaryMaxY: CGFloat) -> NSRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return NSRect(x: pos.x, y: primaryMaxY - pos.y - size.height, width: size.width, height: size.height)
    }
}
