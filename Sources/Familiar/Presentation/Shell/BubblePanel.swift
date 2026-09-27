import AppKit
import SwiftUI

/// Floating, non-activating panel that stays above everything and follows across Spaces.
final class BubblePanel: NSPanel {
    static let collapsedSize = NSSize(width: 84, height: 84)
    static let defaultExpandedSize = NSSize(width: 400, height: 540)
    static let largeExpandedSize = NSSize(width: 560, height: 760)

    init(hideFromScreenShare: Bool) {
        super.init(contentRect: NSRect(origin: .zero, size: BubblePanel.collapsedSize),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false   // the orb handles its own drag
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = hideFromScreenShare ? .none : .readOnly
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Resize keeping the top-left corner where it is (used by the corner grip).
    func resizeKeepingTopLeft(to size: NSSize) {
        var f = frame
        f.origin.y = f.maxY - size.height
        f.size = size
        if let vis = (screen ?? NSScreen.main)?.visibleFrame {
            f.origin.y = max(f.origin.y, vis.minY)
        }
        setFrame(f, display: true)
    }

    func resize(to size: NSSize, animate: Bool) {
        var f = frame
        f.origin.x = f.maxX - size.width
        f.size = size
        if let vis = (screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - size.width)
            f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - size.height)
        }
        setFrame(f, display: true, animate: animate)
    }

    func placeAtBottomRight() {
        guard let vis = NSScreen.main?.visibleFrame else { return }
        setFrame(NSRect(x: vis.maxX - BubblePanel.collapsedSize.width - 24, y: vis.minY + 24,
                        width: BubblePanel.collapsedSize.width, height: BubblePanel.collapsedSize.height), display: true)
    }
}
