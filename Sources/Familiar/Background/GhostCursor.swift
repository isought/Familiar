import AppKit
import QuartzCore

/// The arrow Familiar draws for itself: same path for the screen overlay and the peek-note thumbnail.
/// Everything draws into a y-down user space (a flipped NSImage, a SwiftUI Canvas, a layer whose contents are
/// flipped) with the tip at `tipAt`. Nothing depends on the context's base space, so the shadow falls the same way
/// in every host.
enum GhostCursorArt {
    static let purple = CGColor(red: 0.55, green: 0.3, blue: 0.95, alpha: 1)
    private static let noteYellow = CGColor(red: 1.0, green: 0.86, blue: 0.52, alpha: 1)
    private static let noteDeep = CGColor(red: 0.93, green: 0.80, blue: 0.40, alpha: 1)     // Pad.paperDeep
    private static let noteInk = CGColor(red: 0.12, green: 0.165, blue: 0.267, alpha: 0.45) // Pad.ink, faded
    private static let badgeSize: CGFloat = 8
    private static let shadowOffset = CGPoint(x: 1, y: 1.5)

    /// The macOS arrow on a 20-unit-tall grid, clockwise from the tip: left edge, notch, tail, back up to the barb.
    private static let outline: [CGPoint] = [(0, 0), (0, 16.8), (4.1, 13.0), (7.0, 20.0), (10.4, 18.6), (7.4, 12.1), (12.6, 12.1)]
        .map { CGPoint(x: $0.0, y: $0.1) }

    /// macOS-style arrow, tip at (0,0), pointing up-left, y down.
    static func path(height: CGFloat) -> CGPath {
        let k = height / 20
        let p = CGMutablePath()
        p.addLines(between: outline.map { CGPoint(x: $0.x * k, y: $0.y * k) })
        p.closeSubpath()
        return p
    }

    /// Purple fill, 1.5 pt white rim, soft shadow, and an 8x8 pt yellow note badge with a dog-ear at the bottom-right.
    static func draw(in ctx: CGContext, tipAt p: CGPoint, height: CGFloat, badge: Bool) {
        let arrow = path(height: height)
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.setLineJoin(.round)
        // Shadow: the silhouette nudged down-right in three softening passes. CGContext's own shadow offset lives in
        // base space, which flips with the host, so it is not used here.
        ctx.saveGState()
        ctx.translateBy(x: shadowOffset.x, y: shadowOffset.y)
        for (width, alpha) in [(6, 0.025), (4.5, 0.035), (3, 0.05), (1.5, 0.07)] as [(CGFloat, CGFloat)] {
            ctx.addPath(arrow); ctx.setLineWidth(width); ctx.setStrokeColor(CGColor(gray: 0, alpha: alpha)); ctx.strokePath()
        }
        ctx.addPath(arrow); ctx.setFillColor(CGColor(gray: 0, alpha: 0.24)); ctx.fillPath()
        ctx.restoreGState()
        // Rim then fill: a 3 pt stroke leaves 1.5 pt of white outside the purple.
        ctx.addPath(arrow); ctx.setLineWidth(3); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.strokePath()
        ctx.addPath(arrow); ctx.setFillColor(purple); ctx.fillPath()
        if badge { drawBadge(in: ctx, at: badgeOrigin(height: height)) }
        ctx.restoreGState()
    }

    /// A bitmap of the arrow with its badge and shadow, rasterised at `scale` pixels per point.
    static func image(height: CGFloat, scale: CGFloat) -> NSImage {
        let e = extent(height: height).integral
        let size = NSSize(width: e.width, height: e.height)
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = size
        let ctx = gc.cgContext
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)   // y down, like every other host
        draw(in: ctx, tipAt: CGPoint(x: -e.minX, y: -e.minY), height: height, badge: true)
        image.addRepresentation(rep)
        return image
    }

    /// The art's footprint relative to the tip, shadow and badge included, so a host can size and anchor it.
    fileprivate static func extent(height: CGFloat) -> CGRect {
        let badge = CGRect(origin: badgeOrigin(height: height), size: CGSize(width: badgeSize, height: badgeSize))
        return path(height: height).boundingBox.insetBy(dx: -4, dy: -4).union(badge.insetBy(dx: -2, dy: -2))
    }

    /// The badge sits on the arrow's bottom-right corner, overlapping the tail a little so it reads as pinned on.
    private static func badgeOrigin(height: CGFloat) -> CGPoint {
        CGPoint(x: path(height: height).boundingBox.maxX - 2, y: height - 7)
    }

    private static func drawBadge(in ctx: CGContext, at o: CGPoint) {
        let s = badgeSize, fold: CGFloat = 3
        let sheet = CGMutablePath()
        sheet.addLines(between: [o, CGPoint(x: o.x + s, y: o.y), CGPoint(x: o.x + s, y: o.y + s - fold),
                                 CGPoint(x: o.x + s - fold, y: o.y + s), CGPoint(x: o.x, y: o.y + s)])
        sheet.closeSubpath()
        ctx.addPath(sheet); ctx.setLineWidth(1.5); ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.strokePath()   // rim, so it reads on the purple
        ctx.addPath(sheet); ctx.setFillColor(noteYellow); ctx.fillPath()
        let flap = CGMutablePath()
        flap.addLines(between: [CGPoint(x: o.x + s - fold, y: o.y + s), CGPoint(x: o.x + s - fold, y: o.y + s - fold), CGPoint(x: o.x + s, y: o.y + s - fold)])
        flap.closeSubpath()
        ctx.addPath(flap); ctx.setFillColor(noteDeep); ctx.fillPath()
        // one ruled line: the hint of writing
        ctx.setLineWidth(0.6); ctx.setStrokeColor(noteInk); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: o.x + 1.5, y: o.y + 3)); ctx.addLine(to: CGPoint(x: o.x + s - 2.5, y: o.y + 3)); ctx.strokePath()
    }
}

/// A click-through overlay that follows the target window and shows where Familiar is working: the ghost arrow,
/// click rings, a wand-style highlight with a label, and an underline under the field being typed into. It never
/// activates the app: a non-activating panel ordered with orderFrontRegardless.
@MainActor final class GhostCursorPanel {
    nonisolated static let margin: CGFloat = 40
    nonisolated static let cursorHeight: CGFloat = 20   // read by the (non-isolated) drawing layer

    private let panel: NSPanel
    private let view = GhostView()
    private var frameCG = CGRect.zero          // the panel's frame, CG global; window-local = cg − frameCG.origin
    private var highlightRectCG: CGRect?
    private var highlightLabel: String?
    private(set) var positionCG = CGPoint.zero

    init(hideFromScreenShare: Bool) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 240), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none      // no order-front zoom; the panel is re-framed constantly
        panel.sharingType = hideFromScreenShare ? .none : .readOnly
        panel.contentView = view
    }

    /// Pure visibility rule: visible only when the target is on screen, not minimized, and nothing else covers the
    /// point (`topWindowAtPoint` is the target or nil).
    nonisolated static func shouldShow(topWindowAtPoint: CGWindowID?, targetWindowID: CGWindowID, targetOnScreen: Bool, targetMinimized: Bool) -> Bool {
        guard targetOnScreen, !targetMinimized else { return false }
        return topWindowAtPoint == nil || topWindowAtPoint == targetWindowID
    }

    /// Re-frames the panel to the target frame plus a margin (CG global in, AppKit out) and orders it front.
    func attach(targetFrameCG: CGRect) {
        frameCG = targetFrameCG.insetBy(dx: -Self.margin, dy: -Self.margin)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        panel.setFrame(NSRect(x: frameCG.minX, y: primaryMaxY - frameCG.maxY, width: frameCG.width, height: frameCG.height), display: false)
        view.setScale(panel.backingScaleFactor)
        view.placeCursor(at: local(positionCG), animated: false)   // keep the arrow on the same screen point
        view.setHighlight(rect: highlightRectCG.map(local), label: highlightLabel)
        panel.orderFrontRegardless()
    }

    /// Moves the arrow's tip; animated glides ease out over min(0.25, max(0.08, distance / 4000)) seconds.
    func move(toCG p: CGPoint, animated: Bool) {
        positionCG = p
        view.placeCursor(at: local(p), animated: animated)
    }

    /// Click rings at the arrow: 6→22 pt, white 4 pt under purple 2 pt, 350 ms, `count` of them 60 ms apart.
    func pulse(count: Int) {
        view.pulse(at: local(positionCG), count: max(1, count))
    }

    /// Wand-style rounded rect (white 6 % fill, systemPurple 2 pt, radius 6) and a label pill; nil clears both.
    func highlight(rectCG: CGRect?, label: String?) {
        highlightRectCG = rectCG
        highlightLabel = label
        view.setHighlight(rect: rectCG.map(local), label: label)
    }

    /// 2 pt purple underline under a field being typed into, gone after 600 ms; nil clears it now.
    func underline(rectCG: CGRect?) {
        view.setUnderline(rect: rectCG.map(local))
    }

    /// 150 ms fade. The panel stays ordered in, so a covered target costs nothing to uncover.
    func setVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.15
            panel.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Orders the panel out and clears every layer; the next `attach` starts fully visible.
    func hide() {
        panel.orderOut(nil)
        panel.alphaValue = 1
        highlightRectCG = nil
        highlightLabel = nil
        view.clear()
    }

    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frameCG.minX, y: p.y - frameCG.minY) }
    private func local(_ r: CGRect) -> CGRect { CGRect(origin: local(r.origin), size: r.size) }
}

/// The panel's content: a flipped, layer-backed view whose sublayers speak window-local CG points (y down).
private final class GhostView: NSView {
    private let cursor = GhostCursorLayer()
    private let rings = CALayer()
    private let highlight = CAShapeLayer()
    private let labelPill = CALayer()
    private let labelText = CATextLayer()
    private let underline = CAShapeLayer()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let root = CALayer()
        root.isGeometryFlipped = true     // AppKit sets this for a flipped view; every sublayer below relies on it

        let e = GhostCursorArt.extent(height: GhostCursorPanel.cursorHeight)
        cursor.height = GhostCursorPanel.cursorHeight
        cursor.bounds = CGRect(origin: .zero, size: e.size)
        cursor.anchorPoint = CGPoint(x: -e.minX / e.width, y: -e.minY / e.height)   // the tip, so position == tip
        cursor.position = .zero
        cursor.setNeedsDisplay()          // a draw(in:) layer paints nothing until asked
        root.addSublayer(rings)

        highlight.fillColor = CGColor(gray: 1, alpha: 0.06)
        highlight.strokeColor = NSColor.systemPurple.cgColor
        highlight.lineWidth = 2
        highlight.isHidden = true
        root.addSublayer(highlight)

        underline.fillColor = nil
        underline.strokeColor = GhostCursorArt.purple
        underline.lineWidth = 2
        underline.lineCap = .round
        underline.isHidden = true
        root.addSublayer(underline)

        labelPill.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.92).cgColor
        labelPill.cornerRadius = 13
        labelPill.isHidden = true
        labelText.fontSize = 12
        labelText.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        labelText.foregroundColor = NSColor.white.cgColor
        labelText.truncationMode = .end
        labelPill.addSublayer(labelText)
        root.addSublayer(labelPill)

        root.addSublayer(cursor)          // on top of everything it points at
        return root
    }

    func setScale(_ scale: CGFloat) {
        guard cursor.contentsScale != scale else { return }
        cursor.contentsScale = scale
        labelText.contentsScale = scale
        cursor.setNeedsDisplay()
    }

    func placeCursor(at p: CGPoint, animated: Bool) {
        let from = (cursor.presentation() ?? cursor).position   // glide from where it is on screen, mid-flight or not
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cursor.position = p
        CATransaction.commit()
        guard animated else { cursor.removeAnimation(forKey: "move"); return }
        let a = CABasicAnimation(keyPath: "position")
        a.fromValue = from
        a.toValue = p
        a.duration = min(0.25, max(0.08, hypot(p.x - from.x, p.y - from.y) / 4000))
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cursor.add(a, forKey: "move")
    }

    func pulse(at p: CGPoint, count: Int) {
        rings.sublayers?.filter { $0.animation(forKey: "pulse") == nil }.forEach { $0.removeFromSuperlayer() }   // stale rings
        func circle(_ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2), transform: nil) }
        let now = CACurrentMediaTime()
        for i in 0..<count {
            for (width, color) in [(4, CGColor(gray: 1, alpha: 0.95)), (2, GhostCursorArt.purple)] as [(CGFloat, CGColor)] {
                let ring = CAShapeLayer()
                ring.fillColor = nil
                ring.strokeColor = color
                ring.lineWidth = width
                ring.path = circle(22)
                ring.opacity = 0                  // the model is "gone"; only the animation shows it
                rings.addSublayer(ring)
                let grow = CABasicAnimation(keyPath: "path"); grow.fromValue = circle(6); grow.toValue = circle(22)
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
                let g = CAAnimationGroup()
                g.animations = [grow, fade]
                g.duration = 0.35
                g.beginTime = now + Double(i) * 0.06
                g.timingFunction = CAMediaTimingFunction(name: .easeOut)
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak ring] in ring?.removeFromSuperlayer() }
                ring.add(g, forKey: "pulse")
                CATransaction.commit()
            }
        }
    }

    func setHighlight(rect: CGRect?, label: String?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let rect else { highlight.isHidden = true; labelPill.isHidden = true; return }
        let r = rect.insetBy(dx: -3, dy: -3)
        highlight.path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
        highlight.isHidden = false
        guard let label, !label.isEmpty else { labelPill.isHidden = true; return }
        labelText.string = label
        let width = min(CGFloat(label.count) * 7.5 + 24, 420)
        var py = r.maxY + 8                                          // below the control, above it near the panel's bottom
        if py + 26 > bounds.height { py = r.minY - 34 }
        let px = min(max(8, r.minX), max(8, bounds.width - width - 8))
        labelPill.frame = CGRect(x: px, y: py, width: width, height: 26)
        labelText.frame = CGRect(x: 12, y: 5, width: width - 24, height: 18)
        labelPill.isHidden = false
    }

    func setUnderline(rect: CGRect?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        underline.removeAnimation(forKey: "linger")
        guard let rect else { underline.isHidden = true; return }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 1))
        p.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 1))
        underline.path = p
        underline.opacity = 0                 // as with the rings: shown by the animation, gone when it ends
        underline.isHidden = false
        let linger = CAKeyframeAnimation(keyPath: "opacity")   // 600 ms on, then a 200 ms fade; no timer to cancel
        linger.values = [1, 1, 0]
        linger.keyTimes = [0, 0.75, 1]
        linger.duration = 0.8
        underline.add(linger, forKey: "linger")
    }

    func clear() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.isHidden = true
        labelPill.isHidden = true
        underline.isHidden = true
        underline.removeAllAnimations()
        rings.sublayers?.forEach { $0.removeFromSuperlayer() }
        cursor.removeAllAnimations()
        CATransaction.commit()
    }
}

/// Draws GhostCursorArt itself instead of holding a bitmap, so the arrow is right way up whichever way the layer
/// tree is flipped: `contentsAreFlipped` says whether the context already lands y-down on screen.
private final class GhostCursorLayer: CALayer {
    var height: CGFloat = GhostCursorPanel.cursorHeight { didSet { setNeedsDisplay() } }

    override func draw(in ctx: CGContext) {
        let e = GhostCursorArt.extent(height: height)
        if !contentsAreFlipped() { ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1) }
        GhostCursorArt.draw(in: ctx, tipAt: CGPoint(x: -e.minX, y: -e.minY), height: height, badge: true)
    }
}
