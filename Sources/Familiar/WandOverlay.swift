import AppKit
import ApplicationServices
import QuartzCore

struct AXElementInfo {
    var role: String
    var title: String?
    var value: String?
    var description: String?
    var frame: NSRect?     // AppKit global coords

    /// e.g. `button “Submit”` or `text field “Cost Center” = “”`
    var label: String {
        let r = role.replacingOccurrences(of: "AX", with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
        let name = title?.isEmpty == false ? title : (description?.isEmpty == false ? description : nil)
        var s = name.map { "\(r) “\($0)”" } ?? r
        if let v = value, !v.isEmpty, v != name { s += " = “\(v.prefix(80))”" }
        return s
    }
}

struct WandTarget {
    let screenPoint: NSPoint
    let element: AXElementInfo?
    let windowOwner: String?
    let windowTitle: String?

    var shortLabel: String {
        if let e = element {
            let name = e.title?.isEmpty == false ? e.title! : (e.description?.isEmpty == false ? e.description! : e.role.replacingOccurrences(of: "AX", with: ""))
            return String(name.prefix(60))
        }
        return windowTitle.map { "somewhere in “\($0.prefix(50))”" } ?? "that spot"
    }
}

/// Wand mode: full-screen overlays with a shimmering border, element highlight under the wand, click to pick.
@MainActor
final class WandController {
    var onPick: ((WandTarget) -> Void)?
    var onCancel: (() -> Void)?
    private var panels: [WandPanel] = []
    private var lastHit: (Date, NSPoint, WandTarget)?

    var isActive: Bool { !panels.isEmpty }

    func activate() {
        guard !isActive else { return }
        for screen in NSScreen.screens {
            let p = WandPanel(screen: screen, controller: self)
            p.orderFrontRegardless()
            panels.append(p)
        }
        panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.makeKey()
        WandCursor.cursor.push()
        Log.info("wand: active")
    }

    func deactivate() {
        guard isActive else { return }
        NSCursor.pop()
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
    }

    func cancel() {
        deactivate()
        onCancel?()
    }

    func pick(at point: NSPoint) {
        let target = hitTest(at: point)
        deactivate()
        Log.info("wand: picked \(target.shortLabel) [\(target.element?.label ?? "no element")] in \(target.windowOwner ?? "?")")
        onPick?(target)
    }

    /// Throttled hit test for hover highlighting.
    func hover(at point: NSPoint) -> WandTarget {
        if let (t, p, target) = lastHit, Date().timeIntervalSince(t) < 0.04, abs(p.x - point.x) < 2, abs(p.y - point.y) < 2 { return target }
        let target = hitTest(at: point)
        lastHit = (Date(), point, target)
        return target
    }

    func hitTest(at point: NSPoint) -> WandTarget {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryMaxY - point.y)
        let myPID = ProcessInfo.processInfo.processIdentifier

        var ownerPID: pid_t?
        var owner: String?
        var title: String?
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
                                     frame: Self.frame(of: el, primaryMaxY: primaryMaxY))
                if (info?.title ?? "").isEmpty, (info?.description ?? "").isEmpty,
                   let parent = AX.element(el, kAXParentAttribute), let pt = AX.string(parent, kAXTitleAttribute), !pt.isEmpty {
                    info?.description = pt
                }
            }
        }
        return WandTarget(screenPoint: point, element: info, windowOwner: owner, windowTitle: title)
    }

    private static func frame(of el: AXUIElement, primaryMaxY: CGFloat) -> NSRect? {
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

final class WandPanel: NSPanel {
    init(screen: NSScreen, controller: WandController) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = WandView(frame: NSRect(origin: .zero, size: screen.frame.size), controller: controller, screen: screen)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WandView: NSView {
    private unowned let controller: WandController
    private let screen: NSScreen
    private let highlight = CAShapeLayer()
    private let labelPill = CALayer()
    private let labelText = CATextLayer()

    init(frame: NSRect, controller: WandController, screen: NSScreen) {
        self.controller = controller
        self.screen = screen
        super.init(frame: frame)
        wantsLayer = true
        buildLayers()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .cursorUpdate, .mouseEnteredAndExited], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { WandCursor.cursor.set() }
    override func mouseEntered(with event: NSEvent) { WandCursor.cursor.set() }

    override func mouseMoved(with event: NSEvent) {
        WandCursor.cursor.set()
        let global = screenPoint(event)
        let target = controller.hover(at: global)
        updateHighlight(target)
    }

    override func mouseDown(with event: NSEvent) {
        controller.pick(at: screenPoint(event))
    }

    override func rightMouseDown(with event: NSEvent) { controller.cancel() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller.cancel() } // Esc
    }

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        guard let w = window else { return .zero }
        let p = event.locationInWindow
        return NSPoint(x: w.frame.minX + p.x, y: w.frame.minY + p.y)
    }

    private func updateHighlight(_ target: WandTarget) {
        guard let frame = target.element?.frame, let w = window else {
            highlight.isHidden = true; labelPill.isHidden = true; return
        }
        let local = NSRect(x: frame.minX - w.frame.minX, y: frame.minY - w.frame.minY, width: frame.width, height: frame.height).insetBy(dx: -3, dy: -3)
        guard local.width < bounds.width * 0.95 || local.height < bounds.height * 0.95 else {
            highlight.isHidden = true; labelPill.isHidden = true; return   // whole-window hits are noise
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.path = CGPath(roundedRect: local, cornerWidth: 6, cornerHeight: 6, transform: nil)
        highlight.isHidden = false
        let text = target.shortLabel
        labelText.string = text
        let width = min(CGFloat(text.count) * 7.5 + 24, 420)
        var px = local.minX, py = local.maxY + 8
        if py + 26 > bounds.height { py = local.minY - 34 }
        px = min(max(8, px), bounds.width - width - 8)
        labelPill.frame = CGRect(x: px, y: py, width: width, height: 26)
        labelText.frame = CGRect(x: 12, y: 5, width: width - 24, height: 18)
        labelPill.isHidden = false
        CATransaction.commit()
    }

    private func buildLayers() {
        guard let root = layer else { return }
        let scale = screen.backingScaleFactor
        ShimmerBorder.install(on: root, bounds: bounds, dim: 0.10)

        highlight.fillColor = CGColor(gray: 1, alpha: 0.06)
        highlight.strokeColor = NSColor.systemPurple.cgColor
        highlight.lineWidth = 2
        highlight.isHidden = true
        root.addSublayer(highlight)

        labelPill.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.92).cgColor
        labelPill.cornerRadius = 13
        labelPill.isHidden = true
        labelText.fontSize = 12
        labelText.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        labelText.foregroundColor = NSColor.white.cgColor
        labelText.contentsScale = scale
        labelText.truncationMode = .end
        labelPill.addSublayer(labelText)
        root.addSublayer(labelPill)

        let (hint, _) = ShimmerBorder.captionPill(bounds: bounds, scale: scale, width: 440,
                                                  text: "Point the pen at what you need help with  ·  Esc to cancel")
        root.addSublayer(hint)
    }
}

/// Shared overlay chrome: the rotating rainbow border and a caption pill at the top.
enum ShimmerBorder {
    static func install(on root: CALayer, bounds: CGRect, dim: CGFloat) {
        root.backgroundColor = CGColor(gray: 0, alpha: dim)
        for (width, opacity) in [(CGFloat(28), Float(0.28)), (CGFloat(8), Float(0.95))] {
            let container = CALayer()
            container.frame = bounds
            let mask = CAShapeLayer()
            mask.frame = bounds
            mask.path = CGPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), cornerWidth: 18, cornerHeight: 18, transform: nil)
            mask.fillColor = nil
            mask.strokeColor = CGColor(gray: 0, alpha: 1)
            mask.lineWidth = width
            container.mask = mask
            let g = CAGradientLayer()
            g.type = .conic
            g.colors = [NSColor.systemBlue, NSColor.systemPurple, NSColor.systemPink, NSColor.systemOrange, NSColor.systemTeal, NSColor.systemBlue].map(\.cgColor)
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            let side = hypot(bounds.width, bounds.height) * 1.1
            g.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            g.opacity = opacity
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = 2 * Double.pi; spin.duration = 5; spin.repeatCount = .infinity
            g.add(spin, forKey: "spin")
            container.addSublayer(g)
            root.addSublayer(container)
        }
    }

    static func captionPill(bounds: CGRect, scale: CGFloat, width: CGFloat, text: String) -> (CALayer, CATextLayer) {
        let pill = CALayer()
        let t = CATextLayer()
        pill.frame = CGRect(x: bounds.midX - width / 2, y: bounds.height - 64, width: width, height: 34)
        pill.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.88).cgColor
        pill.cornerRadius = 17
        t.string = text
        t.fontSize = 13
        t.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        t.foregroundColor = NSColor.white.cgColor
        t.alignmentMode = .center
        t.truncationMode = .end
        t.contentsScale = scale
        t.frame = CGRect(x: 8, y: 8, width: width - 16, height: 20)
        pill.addSublayer(t)
        return (pill, t)
    }
}

enum WandCursor {
    /// Size of the cursor image in points; the hotspot is the nib tip, bottom-left.
    static let size = NSSize(width: 40, height: 40)
    static let hotSpot = NSPoint(x: 4, y: 36)

    static let cursor: NSCursor = {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx)
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }()

    /// A quill pen: metal nib at the bottom-left (the hotspot), feather sweeping up to the top-right, a purple ink drop at the tip.
    /// Draws into a flipped (top-left origin) context of `size` points; scale the context to draw it larger.
    static func draw(in ctx: CGContext) {
        let tip = CGPoint(x: hotSpot.x, y: hotSpot.y)
        // axis from the nib tip to the feather end, with a unit normal (n points down-right)
        let end = CGPoint(x: 36.5, y: 3.5)
        let dx = end.x - tip.x, dy = end.y - tip.y
        let len = hypot(dx, dy)
        let d = CGPoint(x: dx / len, y: dy / len), n = CGPoint(x: -d.y, y: d.x)
        func at(_ t: CGFloat, _ w: CGFloat) -> CGPoint { CGPoint(x: tip.x + d.x * len * t + n.x * w, y: tip.y + d.y * len * t + n.y * w) }
        let space = CGColorSpaceCreateDeviceRGB()

        // vane: a feather leaf, fuller on the upper side, narrower below, ending in a point
        let vane = CGMutablePath()
        vane.move(to: at(0.34, 0))
        vane.addCurve(to: at(1.0, -0.4), control1: at(0.50, -8.6), control2: at(0.86, -7.0))
        vane.addCurve(to: at(0.34, 0), control1: at(0.82, 4.2), control2: at(0.50, 5.0))
        vane.closeSubpath()
        // shaft: a thin tapered strip from just above the nib to the feather end
        let shaft = CGMutablePath()
        shaft.move(to: at(0.14, -1.6)); shaft.addLine(to: at(1.0, -0.6)); shaft.addLine(to: at(1.0, 0.6)); shaft.addLine(to: at(0.14, 1.6)); shaft.closeSubpath()
        // nib: a pointed blade
        let nib = CGMutablePath()
        nib.move(to: tip); nib.addLine(to: at(0.16, -3.2)); nib.addLine(to: at(0.28, -1.9)); nib.addLine(to: at(0.28, 1.9)); nib.addLine(to: at(0.16, 3.2)); nib.closeSubpath()

        // silhouette: one soft shadow under the whole pen plus a pale rim, so it reads on dark and light alike
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1, height: 1.5), blur: 3.5, color: CGColor(gray: 0, alpha: 0.55))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineJoin(.round)
        ctx.addPath(vane); ctx.addPath(shaft); ctx.addPath(nib)
        ctx.setLineWidth(2.4); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.strokePath()
        ctx.addPath(vane); ctx.addPath(shaft); ctx.addPath(nib)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // vane: warm white shading to a cool lavender at the shaft, a few barbs on the upper side, a sheen along the edge
        ctx.saveGState()
        ctx.addPath(vane); ctx.clip()
        if let g = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 1, blue: 0.99, alpha: 1), CGColor(red: 0.87, green: 0.84, blue: 0.94, alpha: 1)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: at(0.7, -8.5), end: at(0.7, 4.5), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.setLineCap(.round)
        ctx.setLineWidth(0.75); ctx.setStrokeColor(CGColor(red: 0.50, green: 0.45, blue: 0.64, alpha: 0.55))
        for i in 0..<6 {
            let t = 0.44 + 0.085 * CGFloat(i)
            ctx.move(to: at(t, -0.8)); ctx.addLine(to: at(t + 0.11, -7.2 + CGFloat(i) * 0.5))
        }
        ctx.strokePath()
        ctx.setLineWidth(1.2); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.move(to: at(0.48, -6.2)); ctx.addQuadCurve(to: at(0.92, -3.6), control: at(0.72, -7.6)); ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(vane); ctx.setLineWidth(1.0); ctx.setStrokeColor(CGColor(red: 0.30, green: 0.26, blue: 0.42, alpha: 0.95)); ctx.strokePath()

        // shaft: cream with a dark edge
        ctx.addPath(shaft); ctx.setFillColor(CGColor(red: 0.93, green: 0.88, blue: 0.72, alpha: 1)); ctx.fillPath()
        ctx.addPath(shaft); ctx.setLineWidth(0.8); ctx.setStrokeColor(CGColor(red: 0.42, green: 0.35, blue: 0.25, alpha: 0.9)); ctx.strokePath()

        // nib: dark metal with a highlight along one edge, a slit down the middle and a breather hole
        ctx.saveGState()
        ctx.addPath(nib); ctx.clip()
        if let g = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0.62, alpha: 1), CGColor(gray: 0.20, alpha: 1), CGColor(gray: 0.08, alpha: 1)] as CFArray, locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(g, start: at(0.2, -3.5), end: at(0.2, 3.5), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.setLineWidth(0.8); ctx.setStrokeColor(CGColor(gray: 0.85, alpha: 0.9))
        ctx.move(to: at(0.03, 0)); ctx.addLine(to: at(0.20, 0)); ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(nib); ctx.setLineWidth(0.8); ctx.setStrokeColor(CGColor(gray: 0.05, alpha: 1)); ctx.strokePath()
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fillEllipse(in: CGRect(x: at(0.16, 0).x - 0.9, y: at(0.16, 0).y - 0.9, width: 1.8, height: 1.8))

        // ink drop at the tip, in the brand purple
        let ink = CGPoint(x: tip.x + 1.6, y: tip.y - 0.4)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5, color: CGColor(red: 0.55, green: 0.3, blue: 0.95, alpha: 0.6))
        ctx.setFillColor(CGColor(red: 0.55, green: 0.3, blue: 0.95, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: ink.x - 2.6, y: ink.y - 2.6, width: 5.2, height: 5.2))
        ctx.restoreGState()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: ink.x - 1.7, y: ink.y - 1.9, width: 1.6, height: 1.3))
    }
}
