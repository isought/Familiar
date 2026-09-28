import AppKit
import SwiftUI

/// Renders the maintained views with fictional local fixtures; no provider or desktop access.
enum MorningRender {
    @MainActor static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-morning-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let store = MorningStore(directory: fixtures)
        let navigation = MorningNavigation()
        func save(_ name: String) throws {
            try image(MorningFilesView(store: store, navigation: navigation, close: {}, filed: {}, handoff: { _ in }),
                      size: NSSize(width: 650, height: MorningPanelController.preferredHeight(for: navigation.route, isEmpty: store.cards.isEmpty)),
                      to: directory.appendingPathComponent(name))
        }
        try image(MorningLauncherView(store: store, open: {}, people: {}), size: NSSize(width: 86, height: 78),
                  to: directory.appendingPathComponent("morning-launcher.png"))
        try save("morning-empty.png")
        try store.loadSamples()
        try save("morning-folders.png")
        if let card = store.cards.first {
            navigation.route = .folder(card.folderID)
            try save("morning-spread.png")
            navigation.route = .card(card.id)
            try save("morning-file.png")
            let work = try store.enqueue(cardID: card.id)
            let feed = PeekFeed()
            let tasks = BackgroundTaskStore(feed: feed)
            tasks.syncMorning(store.workItems, message: "Waiting for your configured Claude connection.")
            tasks.selectTask(id: work.id)
            try image(BackgroundTaskPanelView(store: tasks, feed: feed), size: NSSize(width: 360, height: 400),
                      to: directory.appendingPathComponent("morning-queue.png"))
        }
        navigation.route = .people
        try save("morning-people.png")
        navigation.route = .editPerson(nil)
        try save("morning-person-editor.png")
        navigation.route = .editCard(nil)
        try save("morning-note-editor.png")
    }

    @MainActor private static func image<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light).frame(width: size.width, height: size.height))
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
            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw RenderError.bitmap }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.encoding }
        try data.write(to: url)
        print("wrote \(url.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
    private enum RenderError: Error { case bitmap, encoding }
}
