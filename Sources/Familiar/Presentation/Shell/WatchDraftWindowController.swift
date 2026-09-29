import AppKit

/// Full Watch Me reviews use native text layout outside the compact chat surface.
@MainActor
final class WatchDraftWindowController {
    private(set) var window: NSWindow?
    private var textView: NSTextView?
    private let initialFrame: NSRect?

    init(initialFrame: NSRect? = nil) {
        self.initialFrame = initialFrame
    }

    func show(title: String, markdown: String, hideFromScreenShare: Bool) {
        if window == nil { makeWindow() }
        guard let window, let textView else { return }
        let title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        window.title = title.isEmpty ? "Watch Me draft" : "Watch Me draft — " + String(title.prefix(100))
        updateSharing(hideFromScreenShare)
        if textView.string != markdown {
            textView.string = markdown
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateSharing(_ hideFromScreenShare: Bool) {
        window?.sharingType = hideFromScreenShare ? .none : .readOnly
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
    }

    private func makeWindow() {
        let window = NSWindow(contentRect: initialFrame ?? NSRect(x: 0, y: 0, width: 780, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 440, height: 320)
        window.subtitle = "Read-only review. Keep or discard this draft in chat."

        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel("Full Watch Me draft")
        scroll.documentView = textView
        window.contentView = scroll
        if initialFrame == nil { window.center() }
        self.window = window
        self.textView = textView
    }
}
