import AppKit

/// Window preferences are separate from card data. Sizes remain controlled by each surface.
@MainActor struct FloatingWindowPlacement {
    enum Anchor { case topLeft, topRight }
    let key: String
    let anchor: Anchor

    init(_ key: String, anchor: Anchor = .topLeft) {
        self.key = "Noteling.windowPlacement.\(key)"
        self.anchor = anchor
    }

    func restore(size: NSSize) -> NSRect? {
        guard let point = UserDefaults.standard.array(forKey: key) as? [Double],
              point.count == 2, point.allSatisfy(\.isFinite) else { return nil }
        return NSRect(x: point[0] - (anchor == .topRight ? size.width : 0),
                      y: point[1] - size.height, width: size.width, height: size.height)
    }

    func save(_ frame: NSRect) {
        UserDefaults.standard.set([anchor == .topRight ? frame.maxX : frame.minX, frame.maxY], forKey: key)
    }

    static func clamped(_ frame: NSRect, to visible: NSRect) -> NSRect {
        let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func screen(for frame: NSRect, fallback: NSScreen? = nil) -> NSScreen? {
        let screens = NSScreen.screens.filter {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != VirtualDisplayWorkspace.activeDisplayID
        }
        // Greatest overlap chooses the monitor the person actually dragged onto.
        let overlaps = screens.map { screen -> (NSScreen, CGFloat) in
            let intersection = screen.visibleFrame.intersection(frame)
            return (screen, intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return screens.first { $0 === fallback } ?? screens.first { $0 === NSScreen.main } ?? screens.first
    }
}
