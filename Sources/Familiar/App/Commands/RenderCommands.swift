import AppKit
import SwiftUI
import FamiliarContracts
import FamiliarRuntime

/// `Noteling --render-mascot <dir>`: render every mascot mood at 256pt and 48pt (@2x PNG), a charging variant, gaze samples,
/// contact sheets (light at 256/48/32/24, dark at 48/32, and the 24pt card-header row), the quill cursor as a vector at 4x
/// with its hotspot marked, and `icon-1024.png` (the idle note at 512pt @2x, for the app icon), then exit.
/// Used to eyeball the character without launching the app.
@MainActor
func runRenderMascot() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-mascot"), i + 1 < args.count else {
        print("usage: --render-mascot <dir> [--style \(MascotStyle.allCases.map(\.rawValue).joined(separator: "|"))]")
        exit(2)
    }
    if let si = args.firstIndex(of: "--style"), si + 1 < args.count, let st = MascotStyle(rawValue: args[si + 1]) { MascotStyle.current = st }
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let paper = Color(red: 0.98, green: 0.975, blue: 0.96)
    let dark = Color(white: 0.16)

    func save(_ cg: CGImage, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { print("encode failed: \(name)"); return }
        do { try data.write(to: dir.appendingPathComponent(name)); print("wrote \(name) \(cg.width)x\(cg.height)") }
        catch { print("write failed: \(name): \(error)") }
    }
    func render<V: View>(_ v: V, _ name: String, scale: CGFloat = 2) {
        let r = ImageRenderer(content: v)
        r.scale = scale
        guard let cg = r.cgImage else { print("render failed: \(name)"); return }
        save(cg, name)
    }
    func mascot(_ mood: MascotMood, _ size: CGFloat, charge: CGFloat = 0, lookAt: CGPoint? = nil, on bg: Color = paper) -> some View {
        MascotView(mood: mood, lookAt: lookAt, charge: charge, size: size, animated: false)
            .padding(size * 0.14)
            .background(bg)
    }

    for mood in MascotMood.allCases {
        render(mascot(mood, 256), "\(mood.rawValue)-256.png")
        render(mascot(mood, 48), "\(mood.rawValue)-48.png")
    }
    render(mascot(.charging, 256, charge: 0.5), "charging-0.5-256.png")
    render(mascot(.charging, 48, charge: 0.5), "charging-0.5-48.png")
    // gaze: the pupils follow a pointer up-right (idle) and down-right (curious), showing the sclera crescent
    render(mascot(.idle, 256, lookAt: CGPoint(x: 0.9, y: -0.4)), "idle-look-256.png")
    render(mascot(.curious, 256, lookAt: CGPoint(x: 0.7, y: 0.6)), "curious-look-256.png")
    render(mascot(.curious, 48, lookAt: CGPoint(x: 0.7, y: 0.6)), "curious-look-48.png")
    // the app icon source: idle in a 512pt frame @2x = 1024px on a transparent background, with a little margin around the note
    render(MascotView(mood: .idle, size: 480, animated: false).frame(width: 512, height: 512), "icon-1024.png")

    // contact sheet: every mood at 160, 48, 32 and 24 (the card header), plus 48 and 32 on a dark bubble background
    func row(_ mood: MascotMood, sizes: [CGFloat], darkSizes: [CGFloat]) -> some View {
        HStack(spacing: 16) {
            ForEach(sizes, id: \.self) { sz in
                MascotView(mood: mood, charge: mood == .charging ? 0.6 : 0, size: sz, animated: false).frame(width: sz * 1.3, height: sz * 1.3)
            }
            ForEach(darkSizes, id: \.self) { sz in
                MascotView(mood: mood, charge: mood == .charging ? 0.6 : 0, size: sz, animated: false).frame(width: sz * 1.3, height: sz * 1.3)
                    .background(dark, in: RoundedRectangle(cornerRadius: 12))
            }
            Text(mood.rawValue).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
        }
    }
    let sheet = VStack(spacing: 12) {
        ForEach(MascotMood.allCases, id: \.rawValue) { mood in row(mood, sizes: [160, 48, 32, 24], darkSizes: [48, 32]) }
    }.padding(16).background(paper)
    render(sheet, "sheet.png")
    // the tiny sizes on their own, at 1x and 2x, as the card header (24-28pt, no decorations) will show them
    let tiny = HStack(spacing: 14) {
        ForEach(MascotMood.allCases, id: \.rawValue) { mood in
            VStack(spacing: 6) {
                MascotView(mood: mood, size: 24, animated: false, decorations: false).frame(width: 32, height: 32)
                MascotView(mood: mood, size: 28, animated: false, decorations: false).frame(width: 36, height: 36)
                MascotView(mood: mood, size: 48, animated: false).frame(width: 60, height: 60).background(dark, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }.padding(12).background(paper)
    render(tiny, "sheet-24.png", scale: 1)
    render(tiny, "sheet-24@2x.png")

    // the quill cursor drawn as a vector at 4x over a checkerboard, hotspot marked with a red cross
    let scale: CGFloat = 4
    let px = Int(WandCursor.size.width * scale), py = Int(WandCursor.size.height * scale)
    guard let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    let cell = 8
    for y in stride(from: 0, to: py, by: cell) { for x in stride(from: 0, to: px, by: cell) {
        ctx.setFillColor(CGColor(gray: ((x / cell + y / cell) % 2 == 0) ? 0.86 : 0.72, alpha: 1))
        ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
    } }
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(py)); ctx.scaleBy(x: scale, y: -scale)   // flip to the cursor's top-left origin
    WandCursor.draw(in: ctx)
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9)); ctx.setLineWidth(1)
    let hx = WandCursor.hotSpot.x * scale, hy = CGFloat(py) - WandCursor.hotSpot.y * scale   // CG context is bottom-left; hotspot is top-left based
    ctx.move(to: CGPoint(x: hx - 6, y: hy)); ctx.addLine(to: CGPoint(x: hx + 6, y: hy))
    ctx.move(to: CGPoint(x: hx, y: hy - 6)); ctx.addLine(to: CGPoint(x: hx, y: hy + 6)); ctx.strokePath()
    if let out = ctx.makeImage() { save(out, "quill.png") }
    // and the real cursor image at 1x on white, gray, black and blue, as the pointer will actually appear
    let img = WandCursor.cursor.image
    let strip = HStack(spacing: 24) {
        ForEach([Color.white, Color(white: 0.5), Color(white: 0.12), Color.blue], id: \.self) { bg in
            Image(nsImage: img).interpolation(.none).frame(width: 60, height: 60).background(bg)
        }
    }.padding(8).background(Color(white: 0.9))
    render(strip, "quill-1x.png")
    exit(0)
}

/// `Noteling --render-card <dir>`: render the expanded chat card (the sticky-note pad) with a sample conversation at the
/// default 400x540 and the large 560x760, @2x, plus a dark-appearance variant of the default size, then exit.
/// Files: pad-400.png, pad-560.png, pad-400-dark.png. Used to eyeball the pad without launching the app.
@MainActor
func runRenderCard() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-card"), i + 1 < args.count else { print("usage: --render-card <dir>"); exit(2) }
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var config = Config()
    config.apiKey = "render-only"   // so the footer shows the status line instead of the no-key button; nothing is sent
    let shell = ShellState()
    let watcher = ContextWatcher()
    let registry = ToolRegistry(root: FileManager.default.temporaryDirectory, runner: ScriptRunner(config: config))
    let learning = WatchLearnComposition.make(recorder: WatchRecorder(config: config, watcher: watcher), registry: registry, activities: NativeActivityGate(), config: { config })
    let state = Assistant(config: config, watcher: watcher, registry: registry, shell: shell, learning: learning)
    shell.expanded = true
    state.contextLine = "Google Chrome · New Report - Concur"
    state.transcript = [
        ChatMessage(role: .wand, text: "Cost Center (dropdown, empty)"),
        ChatMessage(role: .note, text: "Pick the one ending in your department code, not the project one, or Finance bounces it.", meta: "Priya · 2026-09-18", warning: true),
        ChatMessage(role: .assistant, text: """
            That's the **Cost Center** field: it tells Finance which team's budget pays for this report. It's required, so the form won't submit while it's empty.
            To fill it:
            1. Click the dropdown and start typing your team name — the list filters as you type.
            2. Pick the entry that ends in your department code (yours is usually 4310).
            3. If you don't see your team, choose "Other" and add a line in Comments.
            If this report is for a client project, use the project's cost center instead of your own.
            """),
        ChatMessage(role: .user, text: "how do I split this across two cost centers"),
        ChatMessage(role: .assistant, text: """
            You can't split at the report level, but you can per line item.
            Open an expense line, click **Allocate** (bottom of the line editor), then add a second row and set a percentage or an amount for each cost center. The two rows must add up to 100%.
            Do that for every line you want shared; the rest stays on the report's default cost center.
            """),
        ChatMessage(role: .error, text: "Waxwing API rejected the request (401). Check the API key in Settings and try again."),
    ]
    state.suggestions = ["Why is it required?", "Fill it for me", "Show my reports"]
    state.chatBusy = false
    state.status = "3,652 in · 312 out · 2 tool calls · 6.1s"

    // ImageRenderer only draws pure SwiftUI; the card's ScrollView, TextField, buttons and Menu are AppKit-backed and come
    // out as placeholders. So the card is hosted in an off-screen window and its view tree is drawn into a 2x bitmap.
    func render(_ size: NSSize, dark: Bool, _ name: String) {
        shell.cardSize = size
        let view = BubbleView(state: state, shell: shell)
            .environment(\.padStatic, true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let SwiftUI lay the lazy stack out and scroll to the newest note
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { print("rep failed: \(name)"); return }
        rep.size = size   // points; twice as many pixels = @2x
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let cg = rep.cgImage else { print("render failed: \(name)"); return }
        guard let data = rep.representation(using: .png, properties: [:]) else { print("encode failed: \(name)"); return }
        do { try data.write(to: dir.appendingPathComponent(name)); print("wrote \(name) \(cg.width)x\(cg.height)") }
        catch { print("write failed: \(name): \(error)") }
    }
    print("heading font: \(HandFont.family ?? "system rounded")")
    render(BubblePanel.defaultExpandedSize, dark: false, "pad-400.png")
    render(BubblePanel.largeExpandedSize, dark: false, "pad-560.png")
    render(BubblePanel.defaultExpandedSize, dark: true, "pad-400-dark.png")
    if args.contains("--states") {   // extra checks: the empty pad, and a pick being written up
        let full = state.transcript, sugg = state.suggestions
        state.transcript = []; state.suggestions = []; state.status = ""
        render(BubblePanel.defaultExpandedSize, dark: false, "pad-400-empty.png")
        state.transcript = Array(full.prefix(3)); state.chatBusy = true; state.status = "Reading the page…"
        render(BubblePanel.defaultExpandedSize, dark: false, "pad-400-busy.png")
        state.transcript = full; state.suggestions = sugg; state.chatBusy = false
    }
    exit(0)
}

/// `Noteling --render-pen <dir>`: the pen overlay over a fake window, with two stickers (one open) and the note editor,
/// drawn into a PNG. For eyeballing the paper without a mouse.
@MainActor
func runRenderPen() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-pen"), i + 1 < args.count else { print("usage: --render-pen <dir>"); exit(2) }
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let size = NSSize(width: 1100, height: 720)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor

    // a fake page: a title, a toolbar of buttons, a form and a table, so the stickers have something to stick to
    let controls: [(String, NSRect)] = [("Save page", NSRect(x: 900, y: 640, width: 96, height: 28)), ("Update", NSRect(x: 796, y: 640, width: 92, height: 28)),
                                        ("Cost Center", NSRect(x: 80, y: 500, width: 320, height: 30)), ("Amount", NSRect(x: 80, y: 430, width: 200, height: 30)),
                                        ("Submit report", NSRect(x: 80, y: 360, width: 130, height: 30))]
    for (label, r) in controls {
        let v = NSView(frame: r); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.cgColor; v.layer?.cornerRadius = 6; v.layer?.borderWidth = 1; v.layer?.borderColor = NSColor(calibratedWhite: 0.78, alpha: 1).cgColor
        let t = NSTextField(labelWithString: label); t.font = NSFont.systemFont(ofSize: 13); t.textColor = NSColor(calibratedWhite: 0.25, alpha: 1); t.sizeToFit()
        t.frame.origin = NSPoint(x: 10, y: (r.height - t.frame.height) / 2); v.addSubview(t)
        container.addSubview(v)
    }
    let table = NSView(frame: NSRect(x: 480, y: 300, width: 520, height: 260)); table.wantsLayer = true
    table.layer?.backgroundColor = NSColor.white.cgColor; table.layer?.borderWidth = 1; table.layer?.borderColor = NSColor(calibratedWhite: 0.8, alpha: 1).cgColor
    for row in 0..<6 {
        let l = NSView(frame: NSRect(x: 0, y: CGFloat(row) * 40, width: 520, height: 1)); l.wantsLayer = true; l.layer?.backgroundColor = NSColor(calibratedWhite: 0.9, alpha: 1).cgColor; table.addSubview(l)
    }
    container.addSubview(table)
    let title = NSTextField(labelWithString: "Expense report · September"); title.font = NSFont.systemFont(ofSize: 22, weight: .semibold); title.sizeToFit(); title.frame.origin = NSPoint(x: 80, y: 640); container.addSubview(title)

    let controller = WandController()
    let view = WandView(frame: NSRect(origin: .zero, size: size), controller: controller, screen: NSScreen.main ?? NSScreen.screens[0])
    container.addSubview(view)
    window.contentView = container

    var a1 = NoteStore.sceneAnchor(bundleID: "com.google.Chrome", windowTitle: "Concur", url: "https://expenses.internal.example.com/reports/new")
    a1.role = "AXPopUpButton"; a1.label = "Cost Center"
    var a2 = a1; a2.role = "AXButton"; a2.label = "Submit report"
    var a3 = a1; a3.role = nil; a3.label = nil; a3.rect = NoteAnchor.fractions(of: table.frame, in: container.frame)
    let n1 = StickyNote(id: "n1", anchor: a1, kind: "warning", text: "Pick the one ending in your department code, not the project one, or Finance bounces it a week later.", by: "Priya", at: "2026-09-18", confirmed: "2026-09-18")
    let n2 = StickyNote(id: "n2", anchor: a2, kind: "tip", text: "Submitting after 3pm on Friday means it waits until Tuesday's batch.", by: "Tom", at: "2026-08-30", confirmed: "2026-09-12")
    let n3 = StickyNote(id: "n3", anchor: a3, kind: "tip", text: "Filters up top apply to this table only, the totals below ignore them.", by: "david", at: "2026-09-24", confirmed: "2026-09-24")
    view.showStickers([.init(note: n1, frame: controls[2].1), .init(note: n2, frame: controls[4].1), .init(note: n3, frame: table.frame)])
    view.setExpanded("n1", true)
    view.present(anchor: a2, at: controls[1].1, existing: nil)   // the editor open on "Update"
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { print("rep failed"); exit(1) }
    rep.size = size
    container.cacheDisplay(in: container.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { print("encode failed"); exit(1) }
    do { try data.write(to: dir.appendingPathComponent("pen.png")); print("wrote pen.png \(rep.pixelsWide)x\(rep.pixelsHigh)") }
    catch { print("write failed: \(error)"); exit(1) }

    // The same page after the bubble's badge was clicked: the notes open where they are stuck, no border, no caption.
    view.removeFromSuperview()
    let shown = WandView(frame: NSRect(origin: .zero, size: size), controller: controller, screen: NSScreen.main ?? NSScreen.screens[0], passive: true)
    container.addSubview(shown)
    shown.showStickers([.init(note: n1, frame: controls[2].1), .init(note: n2, frame: controls[4].1)])
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    container.cacheDisplay(in: container.bounds, to: rep)
    if let shownData = rep.representation(using: .png, properties: [:]) {
        try? shownData.write(to: dir.appendingPathComponent("notes-shown.png")); print("wrote notes-shown.png")
    }

    // The bubble holding the badge for the notes on this page.
    let bubble = ZStack(alignment: .topTrailing) {
        MascotView(mood: .idle, size: 64, animated: false).frame(width: 64, height: 64).padding(8)
        NotesBadge(notes: [n1, n2]) {}.padding(.top, 2).padding(.trailing, 2)
    }.frame(width: 80, height: 80).background(Color(white: 0.96))
    let renderer = ImageRenderer(content: bubble.scaleEffect(3).frame(width: 240, height: 240))
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: dir.appendingPathComponent("notes-badge.png")); print("wrote notes-badge.png")
    }
    exit(0)
}
