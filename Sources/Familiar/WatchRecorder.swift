import AppKit
import ApplicationServices
import QuartzCore

/// One thing that happened while Familiar was watching. Written to `events.json` as it goes.
struct WatchEvent: Codable {
    var index: Int
    var t: Double            // seconds since the recording started
    var kind: String         // click | scene | typed | note
    var app: String?
    var title: String?
    var url: String?
    var role: String?        // the clicked element's role (e.g. "button"), or "password field" for a secure typed event
    var label: String?       // the element's name as shown on screen, or the field typed into
    var value: String?
    var crop: String?        // NNN-crop.jpg, around the click
    var full: String?        // NNN-full.jpg, the whole display
    var text: String?        // typed text, or a note

    /// The label the wand would show: `button “Submit”`, `text field “Cost Center” = “…”`.
    var elementLabel: String {
        var s = role ?? "something"
        if let l = label, !l.isEmpty { s += " “\(l)”" }
        if let v = value, !v.isEmpty, v != label { s += " = “\(v.prefix(80))”" }
        return s
    }
}

struct WatchMeta: Codable {
    var startedAt: String
    var endedAt: String?
    var clicks: Int = 0
    var frames: Int = 0
    var hosts: [String] = []
    var titles: [String] = []
    var apps: [String] = []
    var bundles: [String] = []
    var purpose: String?
}

/// A finished (or loaded) recording: the folder plus what is in it.
struct Recording {
    let dir: URL
    var events: [WatchEvent]
    var meta: WatchMeta

    static func load(_ dir: URL) throws -> Recording {
        let dec = JSONDecoder()
        let events = try dec.decode([WatchEvent].self, from: Data(contentsOf: dir.appendingPathComponent("events.json")))
        let meta = try dec.decode(WatchMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
        return Recording(dir: dir, events: events, meta: meta)
    }

    func saveMeta() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }
}

/// "Watch me": a passive recorder. Global click and key monitors (never intercepting), a screenshot crop around
/// every click outside Familiar's own windows, a full frame whenever the scene changes, typed text per field
/// (never for password fields), all written to `~/.familiar/recordings/<stamp>/` as it happens.
@MainActor
final class WatchRecorder {
    static let maxEvents = 400
    static let maxTypedChars = 200
    static let cropMaxLongEdge = 1200

    var config: Config
    let watcher: ContextWatcher
    var hotkeyLabel = "⌃⌥Space"
    var onClickCount: ((Int) -> Void)?

    private(set) var isRecording = false
    private(set) var dir: URL?
    private var events: [WatchEvent] = []
    private var meta = WatchMeta(startedAt: "")
    private var startedAt = Date()
    private var lastFullScene: ScreenContext?
    private var lastScene: ScreenContext?
    private var monitors: [Any] = []
    private var huds: [NSPanel] = []
    private var captions: [CATextLayer] = []
    private var pollTimer: Timer?
    private var captureChain: Task<Void, Never>?
    private var typing: (label: String, secure: Bool, text: String)?
    private var focusedCache: (at: Date, label: String, secure: Bool)?
    private let hitTester = WandController()   // inert until activate(); only hitTest(at:) is used

    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f }()
    private static let iso = ISO8601DateFormatter()

    init(config: Config, watcher: ContextWatcher) {
        self.config = config
        self.watcher = watcher
    }

    var clickCount: Int { meta.clicks }

    // MARK: session

    func start() throws {
        guard !isRecording else { return }
        try beginSession(dir: config.resolvedRecordingsDir.appendingPathComponent(Self.stamp.string(from: Date())))
        isRecording = true
        installMonitors()
        showHUD()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollScene() } }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        pollScene()   // the starting screen
        Log.info("watch: recording into \(dir!.path)")
    }

    /// Stops and returns what was recorded. The recording folder stays on disk until the user discards it.
    func stop(purpose: String?) -> Recording {
        flushTyping()
        isRecording = false
        pollTimer?.invalidate(); pollTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for p in huds { p.orderOut(nil) }
        huds.removeAll(); captions.removeAll()
        captureChain?.cancel(); captureChain = nil
        if let purpose, !purpose.isEmpty { append(WatchEvent(index: 0, t: 0, kind: "note", text: purpose)) }
        return endSession(purpose: purpose)
    }

    /// For testing without a person: 3 full frames a second apart and 3 crops around the mouse, from the current screen.
    func recordSynthetic(into target: URL) async throws -> Recording {
        guard !isRecording else { throw ClaudeError(message: "already recording") }
        try beginSession(dir: target)
        isRecording = true
        defer { isRecording = false }
        let mouse = NSEvent.mouseLocation
        let ctx = watcher.sample() ?? watcher.current
        let hit = hitTester.hitTest(at: mouse)
        let fakes = [("button", "Synthetic click 1"), ("text field", "Synthetic field"), ("link", "Synthetic link")]
        for i in 0..<3 {
            noteScene(ctx)
            append(WatchEvent(index: 0, t: elapsed, kind: "scene", app: ctx?.appName, title: ctx?.windowTitle, url: ctx?.url))
            await captureFull(eventIndex: events.last?.index ?? 0, at: mouse)
            var click = WatchEvent(index: 0, t: elapsed, kind: "click", app: hit.windowOwner ?? ctx?.appName, title: hit.windowTitle ?? ctx?.windowTitle, url: ctx?.url)
            if i == 0, let e = hit.element {
                click.role = Self.prettyRole(e.role); click.label = e.title?.isEmpty == false ? e.title : e.description; click.value = Self.short(e.value)
            } else {
                click.role = fakes[i].0; click.label = fakes[i].1
            }
            meta.clicks += 1
            append(click)
            await captureCrop(eventIndex: events.last?.index ?? 0, at: mouse)
            if i == 1 { append(WatchEvent(index: 0, t: elapsed, kind: "typed", app: ctx?.appName, title: ctx?.windowTitle, url: ctx?.url, role: "text field", label: "Synthetic field", text: "hello from the synthetic recorder")) }
            if i < 2 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        return endSession(purpose: nil)
    }

    private func beginSession(dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
        events.removeAll()
        startedAt = Date()
        meta = WatchMeta(startedAt: Self.iso.string(from: startedAt))
        lastFullScene = nil; lastScene = nil; typing = nil; focusedCache = nil
        try saveMeta()
        try saveEvents()
    }

    private func endSession(purpose: String?) -> Recording {
        meta.endedAt = Self.iso.string(from: Date())
        if let purpose, !purpose.isEmpty { meta.purpose = purpose }
        try? saveMeta()
        try? saveEvents()
        Log.info("watch: stopped, \(events.count) events, \(meta.clicks) clicks, \(meta.frames) frames")
        return Recording(dir: dir!, events: events, meta: meta)
    }

    private var elapsed: Double { (Date().timeIntervalSince(startedAt) * 10).rounded() / 10 }

    // MARK: events

    /// Appends with the next index, records where it happened, writes events.json. Returns nothing: `events.last` is it.
    private func append(_ e: WatchEvent) {
        guard events.count < Self.maxEvents else { return }
        var ev = e
        ev.index = events.count + 1
        if ev.t == 0 { ev.t = elapsed }
        events.append(ev)
        remember(url: ev.url, title: ev.title, app: ev.app)
        try? saveEvents()
    }

    private func remember(url: String?, title: String?, app: String?) {
        if let h = Self.host(of: url), !meta.hosts.contains(h) { meta.hosts.append(h) }
        if let t = title, !t.isEmpty, !meta.titles.contains(t), meta.titles.count < 40 { meta.titles.append(t) }
        if let a = app, !a.isEmpty, !meta.apps.contains(a) { meta.apps.append(a) }
    }

    private func noteScene(_ ctx: ScreenContext?) {
        guard let ctx else { return }
        if !meta.bundles.contains(ctx.bundleID) { meta.bundles.append(ctx.bundleID) }
        remember(url: ctx.url, title: ctx.windowTitle, app: ctx.appName)
    }

    static func host(of url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        if let u = URL(string: url), let h = u.host, !h.isEmpty {
            return u.port.map { "\(h):\($0)" } ?? h
        }
        let s = url.replacingOccurrences(of: "^[a-z]+://", with: "", options: .regularExpression)
        let h = s.split(separator: "/").first.map(String.init) ?? s
        return h.isEmpty ? nil : h
    }

    static func short(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > 120 ? String(s.prefix(120)) + "…" : s
    }

    static func prettyRole(_ ax: String) -> String {
        ax.replacingOccurrences(of: "AX", with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).lowercased()
    }

    private func saveEvents() throws {
        guard let dir else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try enc.encode(events).write(to: dir.appendingPathComponent("events.json"), options: .atomic)
    }

    private func saveMeta() throws {
        guard let dir else { return }
        try Recording(dir: dir, events: [], meta: meta).saveMeta()
    }

    private func update(_ index: Int, _ change: (inout WatchEvent) -> Void) {
        guard let i = events.firstIndex(where: { $0.index == index }) else { return }
        change(&events[i])
        try? saveEvents()
    }

    // MARK: monitors

    private func installMonitors() {
        let clicks: (NSEvent) -> Void = { [weak self] e in
            guard let self, self.isRecording else { return }
            if let w = e.window, NSApp.windows.contains(w) { return }
            self.handleClick(at: NSEvent.mouseLocation)
        }
        let keys: (NSEvent) -> Void = { [weak self] e in
            guard let self, self.isRecording else { return }
            if let w = e.window, NSApp.windows.contains(w) { return }   // typed into our own pad
            self.handleKey(e)
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: clicks) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { e in clicks(e); return e }) { monitors.append(l) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in keys(e); return e }) { monitors.append(l) }
    }

    private func isOwnWindow(_ p: NSPoint) -> Bool {
        NSApp.windows.contains { w in w.isVisible && !huds.contains { $0 === w } && w.frame.contains(p) }
    }

    private func currentContext() -> ScreenContext? {
        watcher.isRunning ? watcher.current : watcher.sample()
    }

    private func handleClick(at p: NSPoint) {
        guard isRecording, !isOwnWindow(p), events.count < Self.maxEvents else { return }
        flushTyping()
        let target = hitTester.hitTest(at: p)
        let ctx = currentContext()
        meta.clicks += 1
        let n = meta.clicks
        var e = WatchEvent(index: 0, t: elapsed, kind: "click",
                           app: target.windowOwner ?? ctx?.appName, title: target.windowTitle ?? ctx?.windowTitle, url: ctx?.url)
        if let el = target.element {
            e.role = Self.prettyRole(el.role)
            e.label = el.title?.isEmpty == false ? el.title : el.description
            e.value = Self.short(el.value)   // a text area's value can be a whole document; keep a glimpse, not the content
        }
        append(e)
        let index = events.last?.index ?? 0
        onClickCount?(n)
        updateCaption()
        let wantFull = lastFullScene.map { l in ctx.map { !$0.sameScene(as: l) } ?? false } ?? true || n % 8 == 0
        if wantFull { lastFullScene = ctx }
        enqueue { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.isRecording else { return }
            await self.captureCrop(eventIndex: index, at: p, alsoFull: wantFull)
        }
    }

    private func pollScene() {
        guard isRecording, let ctx = currentContext() else { return }
        if let last = lastScene, last.sameScene(as: ctx) { return }
        lastScene = ctx
        lastFullScene = ctx
        noteScene(ctx)
        guard events.count < Self.maxEvents else { return }
        append(WatchEvent(index: 0, t: elapsed, kind: "scene", app: ctx.appName, title: ctx.windowTitle, url: ctx.url))
        let index = events.last?.index ?? 0
        enqueue { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)   // let the page draw
            guard let self, self.isRecording else { return }
            await self.captureFull(eventIndex: index, at: NSEvent.mouseLocation)
        }
    }

    /// Captures run one after another so two screenshots never overlap.
    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = captureChain
        captureChain = Task {
            await previous?.value
            await work()
        }
    }

    // MARK: captures

    private func captureCrop(eventIndex: Int, at p: NSPoint, alsoFull: Bool = false) async {
        guard let dir else { return }
        do {
            let raw = try await ScreenCapture.captureDisplay(containing: p)
            let ip = raw.imagePoint(p)
            let size = CGSize(width: CGFloat(config.watchCropWidth) * raw.pixelsPerPoint, height: CGFloat(config.watchCropHeight) * raw.pixelsPerPoint)
            let stem = String(format: "%03d", eventIndex)
            if let c = ScreenCapture.crop(raw.image, around: ip, size: size),
               let data = ScreenCapture.jpeg(ScreenCapture.downscale(c, maxLongEdge: Self.cropMaxLongEdge), quality: 0.8) {
                try data.write(to: dir.appendingPathComponent("\(stem)-crop.jpg"))
                update(eventIndex) { $0.crop = "\(stem)-crop.jpg" }
            }
            if alsoFull { writeFull(raw.image, stem: stem, eventIndex: eventIndex) }
        } catch {
            Log.info("watch: capture failed: \(error.localizedDescription)")
        }
    }

    private func captureFull(eventIndex: Int, at p: NSPoint) async {
        do {
            let raw = try await ScreenCapture.captureDisplay(containing: p)
            writeFull(raw.image, stem: String(format: "%03d", eventIndex), eventIndex: eventIndex)
        } catch {
            Log.info("watch: capture failed: \(error.localizedDescription)")
        }
    }

    private func writeFull(_ image: CGImage, stem: String, eventIndex: Int) {
        guard let dir, let data = ScreenCapture.jpeg(ScreenCapture.downscale(image, maxLongEdge: config.maxImageLongEdge), quality: 0.8) else { return }
        do {
            try data.write(to: dir.appendingPathComponent("\(stem)-full.jpg"))
            meta.frames += 1
            update(eventIndex) { $0.full = "\(stem)-full.jpg" }
            try? saveMeta()
        } catch { Log.info("watch: write failed: \(error.localizedDescription)") }
    }

    // MARK: typing

    private func handleKey(_ e: NSEvent) {
        guard events.count < Self.maxEvents else { return }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return }   // shortcuts are not text
        switch Int(e.keyCode) {
        case 36, 76, 48: flushTyping(); return            // Return, keypad Enter, Tab
        case 53: return                                  // Esc
        case 51:                                         // Backspace
            if var t = typing, !t.secure { t.text = String(t.text.dropLast()); typing = t }
            return
        default: break
        }
        guard let chars = e.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return }
        let field = focusedField()
        if let t = typing, t.label != field.label { flushTyping() }
        if typing == nil { typing = (field.label, field.secure, "") }
        if var t = typing, !t.secure, t.text.count < Self.maxTypedChars { t.text += chars; typing = t }
    }

    private func flushTyping() {
        guard let t = typing else { return }
        typing = nil
        let ctx = currentContext()
        if t.secure {
            append(WatchEvent(index: 0, t: elapsed, kind: "typed", app: ctx?.appName, title: ctx?.windowTitle, url: ctx?.url, role: "password field", value: "not recorded"))
        } else if !t.text.trimmingCharacters(in: .whitespaces).isEmpty {
            append(WatchEvent(index: 0, t: elapsed, kind: "typed", app: ctx?.appName, title: ctx?.windowTitle, url: ctx?.url, role: "text field", label: t.label, text: String(t.text.prefix(Self.maxTypedChars))))
        }
    }

    /// The focused element system-wide, as "role “name”", and whether it is a secure (password) field. Cached briefly.
    private func focusedField() -> (label: String, secure: Bool) {
        if let c = focusedCache, Date().timeIntervalSince(c.at) < 0.8 { return (c.label, c.secure) }
        var label = "the focused field", secure = false
        if Permissions.accessibilityGranted {
            let sys = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(sys, 0.2)
            if let el = AX.element(sys, kAXFocusedUIElementAttribute) {
                let role = AX.string(el, kAXRoleAttribute) ?? ""
                let sub = AX.string(el, kAXSubroleAttribute)
                secure = sub == kAXSecureTextFieldSubrole || sub == "AXSecureTextField"
                var name = AX.string(el, kAXTitleAttribute) ?? AX.string(el, kAXDescriptionAttribute) ?? AX.string(el, kAXPlaceholderValueAttribute)
                if (name ?? "").isEmpty, let parent = AX.element(el, kAXParentAttribute) { name = AX.string(parent, kAXTitleAttribute) }
                let r = role.isEmpty ? "field" : Self.prettyRole(role)
                label = (name?.isEmpty == false) ? "\(r) “\(name!.prefix(60))”" : r
            }
        }
        focusedCache = (Date(), label, secure)
        return (label, secure)
    }

    // MARK: HUD

    private var captionText: String { "Familiar is watching · \(meta.clicks) click\(meta.clicks == 1 ? "" : "s") · \(hotkeyLabel) to stop" }

    private func updateCaption() { for c in captions { c.string = captionText } }

    private func showHUD() {
        for s in NSScreen.screens {
            let p = NSPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            let v = NSView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.wantsLayer = true
            if let layer = v.layer {
                ShimmerBorder.install(on: layer, bounds: v.bounds, dim: 0)
                let (pill, text) = ShimmerBorder.captionPill(bounds: v.bounds, scale: s.backingScaleFactor, width: 460, text: captionText)
                layer.addSublayer(pill)
                captions.append(text)
            }
            p.contentView = v
            p.orderFrontRegardless()
            huds.append(p)
        }
    }
}
