import AppKit

/// Which input path a control session uses.
/// - foreground: today's lane. Synthetic events go to the global HID tap, the real cursor glides, and any human
///   input stops the session.
/// - background: one target window is driven through Accessibility actions and events posted to its process.
///   The human keeps the cursor and keyboard; only a click into the target window or the stop hotkey stops it.
enum Lane: String {
    case foreground, background
}

/// The rectangle the model sees, in points, and how its screenshot pixels map to screen coordinates.
/// The foreground lane builds one from the display the session runs on; the background lane from the target
/// window's frame. Both use CG global coordinates (origin top-left of the primary display, y down), which is what
/// CGEvent and Accessibility speak; `appKit(_:)` flips for NSEvent / NSScreen.
struct CaptureSpace: Equatable {
    var originCG: CGPoint      // top-left corner, CG global
    var sizePt: CGSize         // width and height in points
    var pxPerPt: CGFloat       // screenshot pixels per point after the downscale to maxLongEdge

    /// Screenshot pixels per point for a rectangle captured at `backingScale` and downscaled so the long edge is at
    /// most `maxLongEdge` pixels. Integer pixel widths, like the encoder produces, so the mapping matches the image.
    static func scale(sizePt: CGSize, backingScale: CGFloat, maxLongEdge: Int) -> CGFloat {
        guard sizePt.width > 0, sizePt.height > 0 else { return 1 }
        let wPx = sizePt.width * backingScale, hPx = sizePt.height * backingScale
        let f = min(1, CGFloat(maxLongEdge) / max(wPx, hPx))
        return CGFloat(Int(wPx * f)) / sizePt.width
    }

    /// The whole display `screen`, as the foreground lane captures it.
    static func display(_ screen: NSScreen, maxLongEdge: Int) -> CaptureSpace {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CaptureSpace(originCG: CGPoint(x: screen.frame.minX, y: primaryMaxY - screen.frame.maxY),
                            sizePt: screen.frame.size,
                            pxPerPt: scale(sizePt: screen.frame.size, backingScale: screen.backingScaleFactor, maxLongEdge: maxLongEdge))
    }

    /// A window with frame `frameCG` (CG global, as ScreenCaptureKit and Accessibility report it).
    static func window(frameCG: CGRect, backingScale: CGFloat, maxLongEdge: Int) -> CaptureSpace {
        CaptureSpace(originCG: frameCG.origin, sizePt: frameCG.size,
                     pxPerPt: scale(sizePt: frameCG.size, backingScale: backingScale, maxLongEdge: maxLongEdge))
    }

    var frameCG: CGRect { CGRect(origin: originCG, size: sizePt) }

    /// Model screenshot pixels -> CG global point.
    func cg(fromModel x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: originCG.x + CGFloat(x) / pxPerPt, y: originCG.y + CGFloat(y) / pxPerPt)
    }

    /// CG global point -> model screenshot pixels.
    func model(fromCG p: CGPoint) -> (Int, Int) {
        (Int((p.x - originCG.x) * pxPerPt), Int((p.y - originCG.y) * pxPerPt))
    }

    /// Window-local point (top-left origin, points) for a CG global point.
    func local(fromCG p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - originCG.x, y: p.y - originCG.y)
    }

    func contains(cg p: CGPoint) -> Bool { frameCG.contains(p) }

    /// CG global -> AppKit global (bottom-left origin of the primary display).
    static func appKit(_ cg: CGPoint) -> NSPoint {
        NSPoint(x: cg.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - cg.y)
    }

    /// AppKit global -> CG global.
    static func cg(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    /// AppKit global rect -> CG global rect.
    static func cg(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - r.maxY, width: r.width, height: r.height)
    }
}
