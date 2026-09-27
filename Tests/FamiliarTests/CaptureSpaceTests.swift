import AppKit
import Testing
@testable import Familiar

/// CaptureSpace must map model pixels to screen points exactly the way the encoder sizes the screenshot.
@Suite
struct CaptureSpaceTests {
    /// The formula the foreground lane used before CaptureSpace existed: integer pixel width over point width.
    private func legacy(width: CGFloat, height: CGFloat, backingScale f: CGFloat, maxLongEdge: Int) -> CGFloat {
        let wPx = width * f, hPx = height * f
        let s = min(1, CGFloat(maxLongEdge) / max(wPx, hPx))
        return CGFloat(Int(wPx * s)) / width
    }

    @Test
    func scaleMatchesTheLegacyFormula() {
        let cases: [(CGFloat, CGFloat, CGFloat, Int)] = [
            (1512, 982, 2, 1568), (1728, 1117, 2, 1568), (2560, 1440, 1, 1568), (1440, 900, 1, 1568),
            (800, 600, 2, 1568), (3024, 1964, 2, 1024), (1000, 700, 1, 4000), (1512, 982, 2, 1),
        ]
        for (w, h, f, edge) in cases {
            let got = CaptureSpace.scale(sizePt: CGSize(width: w, height: h), backingScale: f, maxLongEdge: edge)
            #expect(abs(got - legacy(width: w, height: h, backingScale: f, maxLongEdge: edge)) < 1e-9, "\(w)x\(h)@\(f) edge \(edge)")
        }
        #expect(CaptureSpace.scale(sizePt: .zero, backingScale: 2, maxLongEdge: 1568) == 1)
    }

    @Test
    func displaySpaceCoversTheScreenWithTheLegacyScale() {
        guard let screen = NSScreen.main else { return }   // headless test runs have no display to check
        let space = CaptureSpace.display(screen, maxLongEdge: 1568)
        let f = screen.backingScaleFactor
        #expect(space.sizePt == screen.frame.size)
        #expect(abs(space.pxPerPt - legacy(width: screen.frame.width, height: screen.frame.height, backingScale: f, maxLongEdge: 1568)) < 1e-9)
        #expect(space.originCG.x == screen.frame.minX)
        #expect(space.contains(cg: CGPoint(x: space.originCG.x + 1, y: space.originCG.y + 1)))
        if screen == NSScreen.screens.first { #expect(space.originCG == .zero) }   // the primary display anchors CG space
    }

    @Test
    func modelAndCGRoundTripWithinHalfAPixel() {
        for f in [CGFloat(1), 2] {
            let space = CaptureSpace.window(frameCG: CGRect(x: 120, y: 64, width: 1280, height: 800), backingScale: f, maxLongEdge: 1568)
            #expect(space.pxPerPt > 0 && space.pxPerPt <= f)
            for (x, y) in [(0, 0), (1, 1), (7, 3), (640, 400), (1279, 799), (Int(1280 * space.pxPerPt) - 1, Int(800 * space.pxPerPt) - 1)] {
                // A pixel centre survives the trip exactly: the truncation in model(fromCG:) has half a pixel to spare.
                let p = space.cg(fromModel: Double(x) + 0.5, Double(y) + 0.5)
                let (mx, my) = space.model(fromCG: p)
                #expect(mx == x && my == y, "\(x),\(y) at \(f)x came back as \(mx),\(my)")
                #expect(abs((p.x - space.originCG.x) * space.pxPerPt - (CGFloat(x) + 0.5)) < 0.5)
                #expect(abs((p.y - space.originCG.y) * space.pxPerPt - (CGFloat(y) + 0.5)) < 0.5)
                #expect(space.contains(cg: p))
            }
            // Any CG point comes back within a pixel after truncation.
            let q = CGPoint(x: 555.37, y: 321.91)
            let (qx, qy) = space.model(fromCG: q)
            let back = space.cg(fromModel: Double(qx), Double(qy))
            #expect(abs(back.x - q.x) * space.pxPerPt < 1 && abs(back.y - q.y) * space.pxPerPt < 1)
        }
    }

    @Test
    func windowSpaceKeepsItsOrigin() {
        let frame = CGRect(x: 300, y: 150, width: 800, height: 600)
        let space = CaptureSpace.window(frameCG: frame, backingScale: 2, maxLongEdge: 1568)
        #expect(space.frameCG == frame)
        #expect(abs(space.pxPerPt - 1.96) < 1e-9)              // 1600 px wide → 1568 px, over 800 pt
        #expect(space.cg(fromModel: 0, 0) == frame.origin)
        #expect(space.local(fromCG: CGPoint(x: 310, y: 170)) == CGPoint(x: 10, y: 20))
        #expect(space.local(fromCG: frame.origin) == .zero)
        let (mx, my) = space.model(fromCG: CGPoint(x: 700, y: 450))
        #expect(mx == 784 && my == 588)
        #expect(space.contains(cg: CGPoint(x: 1099, y: 749)))
        #expect(!space.contains(cg: CGPoint(x: 299, y: 400)))
        #expect(!space.contains(cg: CGPoint(x: 1100, y: 750)))   // the far edge is exclusive
        // No downscale needed: a small window at 1x maps 1:1.
        let tiny = CaptureSpace.window(frameCG: CGRect(x: 10, y: 20, width: 400, height: 300), backingScale: 1, maxLongEdge: 1568)
        #expect(tiny.pxPerPt == 1)
        #expect(tiny.cg(fromModel: 25, 35) == CGPoint(x: 35, y: 55))
    }

    @Test
    func appKitAndCGFlipAboutThePrimaryDisplay() {
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        let cg = CGPoint(x: 123, y: 45)
        let ak = CaptureSpace.appKit(cg)
        #expect(ak.x == 123 && ak.y == maxY - 45)
        #expect(CaptureSpace.cg(ak) == cg)                                   // the flip is its own inverse
        #expect(CaptureSpace.appKit(CaptureSpace.cg(NSPoint(x: 9, y: 8))) == NSPoint(x: 9, y: 8))
        let r = NSRect(x: 100, y: 200, width: 300, height: 50)
        let flipped = CaptureSpace.cg(r)
        #expect(flipped.minX == 100 && flipped.width == 300 && flipped.height == 50)
        #expect(flipped.minY == maxY - r.maxY)                               // top edge in AppKit becomes the CG origin
        #expect(CaptureSpace.cg(NSPoint(x: r.minX, y: r.maxY)) == flipped.origin)
    }
}
