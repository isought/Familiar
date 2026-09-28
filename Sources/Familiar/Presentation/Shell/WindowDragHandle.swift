import AppKit
import SwiftUI

@MainActor protocol WindowDragHandling: AnyObject {
    func beganDragging(_ window: NSWindow)
    func finishedDragging(_ window: NSWindow)
}

/// A native drag surface; the optional click action lets a small launcher remain a button.
struct WindowDragHandle: NSViewRepresentable {
    var onClick: (() -> Void)? = nil
    var onFinished: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragView else { return }
        view.onClick = onClick
        view.onFinished = onFinished
    }

    private final class DragView: NSView {
        var onClick: (() -> Void)?
        var onFinished: (NSWindow) -> Void = { _ in }
        private var startPoint: NSPoint?
        private var startFrame: NSRect?
        private var didDrag = false
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startPoint = window.convertPoint(toScreen: event.locationInWindow)
            startFrame = window.frame
            didDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let startPoint, let startFrame else { return }
            // Use this event's location, not the global cursor: nonactivating panels
            // also receive app-targeted input that does not move the physical cursor.
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let delta = NSPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            guard didDrag || hypot(delta.x, delta.y) >= 4 else { return }
            if !didDrag { (window.delegate as? WindowDragHandling)?.beganDragging(window) }
            didDrag = true
            NSCursor.closedHand.set()
            window.setFrameOrigin(NSPoint(x: startFrame.minX + delta.x, y: startFrame.minY + delta.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard startPoint != nil, let window else { return }
            startPoint = nil
            startFrame = nil
            NSCursor.openHand.set()
            if didDrag {
                onFinished(window)
                (window.delegate as? WindowDragHandling)?.finishedDragging(window)
            } else {
                onClick?()
            }
            didDrag = false
        }
    }
}
