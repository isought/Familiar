import AppKit
import SwiftUI

/// Static fixtures use a fabricated window image and never capture the desktop, call a provider, or show a panel.
enum BackgroundTaskRender {
    @MainActor static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let feed = PeekFeed()
        let store = BackgroundTaskStore(feed: feed)
        let sample = ImageRenderer(content: sampleWindow)
        sample.scale = 1
        let sampleFrame = sample.cgImage

        func populateFeed() {
            feed.phase = .working
            feed.frame = sampleFrame
            feed.appName = "Safari"
            feed.windowTitle = "Team notes"
            feed.step = 4
            feed.caption = "Organizing the next steps"
            feed.cursor = CGPoint(x: 0.32, y: 0.59)
            feed.highlight = CGRect(x: 0.18, y: 0.50, width: 0.64, height: 0.14)
        }

        func save(_ name: String) throws {
            let size = store.isExpanded ? NSSize(width: 360, height: 400) : NSSize(width: 320, height: 84)
            let view = BackgroundTaskPanelView(store: store, feed: feed)
                .environment(\.colorScheme, .light)
                .frame(width: size.width, height: size.height)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = hosting
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                                pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw RenderError.bitmap
            }
            bitmap.size = size
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.encoding }
            try data.write(to: directory.appendingPathComponent(name))
            print("wrote \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        }

        let first = UUID()
        populateFeed()
        store.start(id: first, title: "Organize action items from today’s notes")
        try save("task-working-compact.png")
        store.toggleExpanded()
        try save("task-working-expanded.png")
        feed.phase = .confirming("This will send the summary to the project channel.")
        try save("task-confirming-expanded.png")
        store.toggleExpanded()
        try save("task-confirming-compact.png")
        feed.phase = .asking("The calendar needs a brief foreground interaction to open the date picker.")
        store.toggleExpanded()
        try save("task-foreground-request.png")
        store.finish(id: first, outcome: .completed,
                     text: "Organized 6 action items in Team notes. Each item now has an owner and a next step.\n\nThe summary is saved in the same document.", elapsed: 72)
        try save("task-completed-expanded.png")
        store.toggleExpanded()
        try save("task-completed-compact.png")

        let stopped = UUID()
        populateFeed()
        store.start(id: stopped, title: "Collect the weekly updates")
        store.finish(id: stopped, outcome: .stopped,
                     text: "Stopped after reading 2 updates. The draft is still open; no message was sent.", elapsed: 16)
        store.toggleExpanded()
        try save("task-stopped.png")

        let failed = UUID()
        populateFeed()
        store.start(id: failed, title: "Prepare the release notes")
        store.finish(id: failed, outcome: .failed,
                     text: "The target window closed before I could finish. The draft was saved before the connection ended.", elapsed: 31)
        store.toggleExpanded()
        try save("task-failed.png")

        populateFeed()
        store.start(id: UUID(), title: "Prepare tomorrow’s checklist")
        store.selectTask(id: first)
        try save("task-history.png")
    }

    private enum RenderError: Error { case bitmap, encoding }

    private static var sampleWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red.opacity(0.55), .yellow.opacity(0.65), .green.opacity(0.6)], id: \.self) { color in
                    Circle().fill(color).frame(width: 11, height: 11)
                }
                Spacer()
                Text("Team notes").font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16).background(Color(white: 0.95))
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                Text("Today’s action items").font(.system(size: 31, weight: .semibold))
                Text("Six small steps to keep the project moving.").font(.system(size: 17)).foregroundStyle(.secondary)
                ForEach(["Outline the release summary", "Check the onboarding flow", "Confirm the next design review"], id: \.self) { title in
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.7), lineWidth: 1.5).frame(width: 21, height: 21)
                        Text(title).font(.system(size: 18))
                        Spacer()
                        Text("Today").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(18).background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(40)
            Spacer(minLength: 0)
        }
        .frame(width: 800, height: 500)
        .foregroundStyle(Color(white: 0.18))
        .background(Color.white)
    }
}
