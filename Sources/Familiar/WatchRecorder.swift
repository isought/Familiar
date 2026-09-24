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
    var role: String?        // the clicked element's role (e.g. "button"); for a typed event whose text was withheld, why
    var label: String?       // the element's name as shown on screen, or the field typed into
    var value: String?
    var crop: String?        // NNN-crop.jpg, around the click
    var full: String?        // NNN-full.jpg, the whole display
    var text: String?        // typed text, or a note

    static let notRecorded = "not recorded"

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
        try PrivateFiles.write(enc.encode(meta), to: dir.appendingPathComponent("meta.json"))
    }
}

/// Recordings hold screenshots and typed text, so they get the same file modes as config.json and secrets.json:
/// folders 0700, files 0600, whatever the umask says.
enum PrivateFiles {
    static func makeDir(_ url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// "Watch me": a passive recorder. Global click and key monitors (never intercepting), a screenshot crop around
/// every click outside Familiar's own windows, a full frame whenever the scene changes, typed text per form field
/// (never for password fields, terminals, or fields it cannot identify), all written to
/// `~/.familiar/recordings/<stamp>/` as it happens.
@MainActor
final class WatchRecorder {
    static let maxEvents = 400
    static let maxTypedChars = 200
    static let cropMaxLongEdge = 1200
    static let retentionDays = 7             // unfinished recordings older than this are swept at the next start

    /// Anything typed here may be a sudo / ssh / gpg password: text is never recorded in these apps.
    static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp", "co.zeit.hyper", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty",
    ]
    /// Form fields whose typed text is recorded. A text area counts only in a browser (a web form's multi-line field);
    /// in editors, chat apps and the like typing is noted but the text withheld.
    static let recordedRoles: Set<String> = ["AXTextField", "AXComboBox", "AXSearchField"]
    /// Field names that mean the value is a secret, whatever the subrole says.
    static let secretPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(pass(word|code|phrase)?|pwd|pin|otp|mfa|2fa|secret|token|api[ _-]?key|key|cvv|cvc|ssn|credential)s?\b"#)

    static func looksSecret(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        return secretPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// What the keystrokes are going into: a named form field, or something whose text must not be written down.
    enum Field: Equatable {
        case text(label: String)
        case hidden(why: String)      // "password field", "terminal", "unknown field", "text area" …
    }

    var config: Config
    let watcher: ContextWatcher
    var hotkeyLabel = "⌃⌥Space"
    var onClickCount: ((Int) -> Void)?

    private(set) var isRecording = false
    private(set) var dir: URL?
    private var session = 0                  // bumped per session; queued captures check it before writing
    private var events: [WatchEvent] = []
    private var meta = WatchMeta(startedAt: "")
    private var startedAt = Date()
    private var lastFullScene: ScreenContext?
    private var lastScene: ScreenContext?
    private var sampled: (at: Date, ctx: ScreenContext?)?
    private var restoreWatcherInterval = false
    private var monitors: [Any] = []
    private var huds: [NSPanel] = []
    private var captions: [CATextLayer] = []
    private var pollTimer: Timer?
    private var captureChain: Task<Void, Never>?
    private var typing: (field: Field, text: String)?
    private var focusedCache: (at: Date, field: Field)?
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
        sweepOldRecordings()
        try beginSession(dir: config.resolvedRecordingsDir.appendingPathComponent(Self.stamp.string(from: Date())))
        isRecording = true
        if watcher.isRunning, config.watcherIntervalSeconds > 1 {   // notice a navigation within a second, not two
            watcher.start(interval: 1)
            restoreWatcherInterval = true
        }
        installMonitors()
        showHUD()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollScene() } }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        pollScene()   // the starting screen
        Log.info("watch: recording into \(dir!.path)")
    }

    /// Stops and returns what was recorded. Waits briefly for a capture still queued for the last click, so the
    /// Submit/Save crop is in the recording. The folder stays on disk until the recording is kept or discarded.
    func stop(purpose: String?) async -> Recording {
        flushTyping()
        tearDown()
        if let chain = captureChain {
            captureChain = nil
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await chain.value }
                g.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                await g.next()
                g.cancelAll()
            }
        }
        if let purpose, !purpose.isEmpty { append(WatchEvent(index: 0, t: 0, kind: "note", text: purpose)) }
        return endSession(purpose: purpose)
    }

    /// Stops without keeping anything (quit mid-recording): monitors off, queued captures dropped, folder removed.
    func abandon() {
        guard isRecording else { return }
        tearDown()
        captureChain?.cancel(); captureChain = nil
        session += 1
        if let dir { try? FileManager.default.removeItem(at: dir) }
        Log.info("watch: abandoned")
    }

    private func tearDown() {
        isRecording = false
        pollTimer?.invalidate(); pollTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for p in huds { p.orderOut(nil) }
        huds.removeAll(); captions.removeAll()
        if restoreWatcherInterval {
            restoreWatcherInterval = false
            if watcher.isRunning { watcher.start(interval: config.watcherIntervalSeconds) }
        }
    }

    /// For testing without a person: 3 full frames a second apart and 3 crops around the mouse, from the current screen.
    func recordSynthetic(into target: URL) async throws -> Recording {
        guard !isRecording else { throw ClaudeError(message: "already recording") }
        try beginSession(dir: target)
        isRecording = true
        defer { isRecording = false }
        let s = session
        let mouse = NSEvent.mouseLocation
        let ctx = watcher.sample() ?? watcher.current
        let hit = hitTester.hitTest(at: mouse)
        let fakes = [("button", "Synthetic click 1"), ("text field", "Synthetic field"), ("link", "Synthetic link")]
        for i in 0..<3 {
            noteScene(ctx)
            let sceneIndex = append(WatchEvent(index: 0, t: elapsed, kind: "scene", app: ctx?.appName, title: ctx?.windowTitle, url: ctx?.url)) ?? 0
            await captureFull(session: s, eventIndex: sceneIndex, at: mouse)
            var click = WatchEvent(index: 0, t: elapsed, kind: "click", app: hit.windowOwner ?? ctx?.appName, title: hit.windowTitle ?? ctx?.windowTitle, url: ctx?.url)
            if i == 0, let e = hit.element {
                click.role = Self.prettyRole(e.role); click.label = e.title?.isEmpty == false ? e.title : e.description
                click.value = Self.safeValue(e, bundle: hit.ownerBundleID ?? ctx?.bundleID)
            } else {
                click.role = fakes[i].0; click.label = fakes[i].1
            }
            meta.clicks += 1
            let clickIndex = append(click) ?? 0
            await captureCrop(session: s, eventIndex: clickIndex, at: mouse)
            if i == 1 { append(WatchEvent(index: 0, t: elapsed, kind: "typed", app: ctx?.appName, title: ctx?.windowTitle, url: ctx?.url, role: "text field", label: "Synthetic field", text: "hello from the synthetic recorder")) }
            if i < 2 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        return endSession(purpose: nil)
    }

    private func beginSession(dir: URL) throws {
        try PrivateFiles.makeDir(dir)
        self.dir = dir
        session += 1
        events.removeAll()
        startedAt = Date()
        meta = WatchMeta(startedAt: Self.iso.string(from: startedAt))
        lastFullScene = nil; lastScene = nil; sampled = nil; typing = nil; focusedCache = nil
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

    /// Recordings left behind by a crash (no endedAt, or never kept/discarded) do not pile up forever.
    private func sweepOldRecordings() {
        let fm = FileManager.default
        let root = config.resolvedRecordingsDir
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        for n in names {
            let u = root.appendingPathComponent(n)
            guard let attrs = try? fm.attributesOfItem(atPath: u.path), let m = attrs[.modificationDate] as? Date, m < cutoff else { continue }
            try? fm.removeItem(at: u)
            Log.info("watch: swept old recording \(n)")
        }
    }

    private var elapsed: Double { (Date().timeIntervalSince(startedAt) * 10).rounded() / 10 }

    // MARK: events

    /// Appends with the next index, records where it happened, writes events.json. Returns the index, or nil when the
    /// recording is full and the event was dropped.
    @discardableResult
    private func append(_ e: WatchEvent) -> Int? {
        guard events.count < Self.maxEvents else { return nil }
        var ev = e
        ev.index = events.count + 1
        if ev.t == 0 { ev.t = elapsed }
        events.append(ev)
        remember(url: ev.url, title: ev.title, app: ev.app)
        try? saveEvents()
        return ev.index
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

    nonisolated static func host(of url: String?) -> String? {
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

    /// A glimpse of a clicked control's value, or nothing when it could be a secret or a document: secure fields,
    /// anything named like a password/token, text areas and web areas (their value is the content), and terminals.
    static func safeValue(_ el: AXElementInfo, bundle: String?) -> String? {
        if el.subrole == "AXSecureTextField" { return nil }
        if el.role == "AXTextArea" || el.role == "AXWebArea" || el.role == "AXScrollArea" { return nil }
        if looksSecret(el.title) || looksSecret(el.description) || looksSecret(el.placeholder) { return nil }
        if let bundle, terminalBundles.contains(bundle) { return nil }
        return short(el.value)
    }

    private func saveEvents() throws {
        guard let dir else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try PrivateFiles.write(enc.encode(events), to: dir.appendingPathComponent("events.json"))
    }

    private func saveMeta() throws {
        guard let dir else { return }
        try Recording(dir: dir, events: [], meta: meta).saveMeta()
    }

    private func update(session s: Int, _ index: Int, _ change: (inout WatchEvent) -> Void) {
        guard s == session, let i = events.firstIndex(where: { $0.index == index }) else { return }
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
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: clicks) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { e in clicks(e); return e }) { monitors.append(l) }
        // Without Accessibility the focused field cannot be identified, so no keystroke would ever be written down:
        // do not listen for them at all.
        guard Permissions.accessibilityGranted else { Log.info("watch: no Accessibility, typed text is not recorded"); return }
        let keys: (NSEvent) -> Void = { [weak self] e in
            guard let self, self.isRecording else { return }
            if let w = e.window, NSApp.windows.contains(w) { return }   // typed into our own pad
            self.handleKey(e)
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in keys(e); return e }) { monitors.append(l) }
    }

    private func isOwnWindow(_ p: NSPoint) -> Bool {
        NSApp.windows.contains { w in w.isVisible && !huds.contains { $0 === w } && w.frame.contains(p) }
    }

    /// The watcher's view when it runs (at 1 s while recording); otherwise our own sample, at most once a second.
    private func currentContext() -> ScreenContext? {
        if watcher.isRunning { return watcher.current }
        if let s = sampled, Date().timeIntervalSince(s.at) < 1 { return s.ctx }
        let c = watcher.sample()
        sampled = (Date(), c)
        return c
    }

    private func handleClick(at p: NSPoint) {
        guard isRecording, !isOwnWindow(p) else { return }
        focusedCache = nil          // focus moves with a click: the next keystroke re-samples the field
        flushTyping()
        guard events.count < Self.maxEvents else { return }
        let target = hitTester.hitTest(at: p)
        let ctx = currentContext()
        var e = WatchEvent(index: 0, t: elapsed, kind: "click",
                           app: target.windowOwner ?? ctx?.appName, title: target.windowTitle ?? ctx?.windowTitle, url: ctx?.url)
        if let el = target.element {
            e.role = Self.prettyRole(el.role)
            e.label = el.title?.isEmpty == false ? el.title : el.description
            e.value = Self.safeValue(el, bundle: target.ownerBundleID ?? ctx?.bundleID)
        }
        guard let index = append(e) else { return }
        meta.clicks += 1
        let n = meta.clicks
        onClickCount?(n)
        updateCaption()
        let wantFull = lastFullScene.map { l in ctx.map { !$0.sameScene(as: l) } ?? false } ?? true || n % 8 == 0
        if wantFull { lastFullScene = ctx }
        let s = session
        enqueue { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.session == s else { return }
            await self.captureCrop(session: s, eventIndex: index, at: p, alsoFull: wantFull)
        }
    }

    private func pollScene() {
        guard isRecording, let ctx = currentContext() else { return }
        if let last = lastScene, last.sameScene(as: ctx) { return }
        lastScene = ctx
        lastFullScene = ctx
        noteScene(ctx)
        guard let index = append(WatchEvent(index: 0, t: elapsed, kind: "scene", app: ctx.appName, title: ctx.windowTitle, url: ctx.url)) else { return }
        let s = session
        enqueue { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)   // let the page draw
            guard let self, self.session == s else { return }
            await self.captureFull(session: s, eventIndex: index, at: NSEvent.mouseLocation)
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

    private func captureCrop(session s: Int, eventIndex: Int, at p: NSPoint, alsoFull: Bool = false) async {
        guard let dir else { return }
        do {
            let raw = try await ScreenCapture.captureDisplay(containing: p)
            guard s == session else { return }
            let ip = raw.imagePoint(p)
            let size = CGSize(width: CGFloat(config.watchCropWidth) * raw.pixelsPerPoint, height: CGFloat(config.watchCropHeight) * raw.pixelsPerPoint)
            let stem = String(format: "%03d", eventIndex)
            if let c = ScreenCapture.crop(raw.image, around: ip, size: size),
               let data = ScreenCapture.jpeg(ScreenCapture.downscale(c, maxLongEdge: Self.cropMaxLongEdge), quality: 0.8) {
                try PrivateFiles.write(data, to: dir.appendingPathComponent("\(stem)-crop.jpg"))
                update(session: s, eventIndex) { $0.crop = "\(stem)-crop.jpg" }
            }
            if alsoFull { writeFull(session: s, raw.image, stem: stem, eventIndex: eventIndex) }
        } catch {
            Log.info("watch: capture failed: \(error.localizedDescription)")
        }
    }

    private func captureFull(session s: Int, eventIndex: Int, at p: NSPoint) async {
        do {
            let raw = try await ScreenCapture.captureDisplay(containing: p)
            writeFull(session: s, raw.image, stem: String(format: "%03d", eventIndex), eventIndex: eventIndex)
        } catch {
            Log.info("watch: capture failed: \(error.localizedDescription)")
        }
    }

    private func writeFull(session s: Int, _ image: CGImage, stem: String, eventIndex: Int) {
        guard s == session, let dir,
              let data = ScreenCapture.jpeg(ScreenCapture.downscale(image, maxLongEdge: config.maxImageLongEdge), quality: 0.8) else { return }
        do {
            try PrivateFiles.write(data, to: dir.appendingPathComponent("\(stem)-full.jpg"))
            meta.frames += 1
            update(session: s, eventIndex) { $0.full = "\(stem)-full.jpg" }
            try? saveMeta()
        } catch { Log.info("watch: write failed: \(error.localizedDescription)") }
    }

    // MARK: typing

    private func handleKey(_ e: NSEvent) {
        guard events.count < Self.maxEvents else { return }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return }   // shortcuts are not text
        switch Int(e.keyCode) {
        case 36, 76, 48: flushTyping(); return            // Return, keypad Enter, Tab: focus may move
        case 53: return                                  // Esc
        case 51:                                         // Backspace
            if var t = typing { t.text = String(t.text.dropLast()); typing = t }
            return
        default: break
        }
        guard let chars = e.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return }
        // The first keystroke of a run always asks Accessibility which field has focus; only the following keystrokes
        // of the same run reuse that answer, and only briefly.
        let field: Field
        if typing != nil, let c = focusedCache, Date().timeIntervalSince(c.at) < 0.8 { field = c.field }
        else { field = focusedField() }
        if let t = typing, t.field != field { flushTyping() }
        focusedCache = (Date(), field)
        if typing == nil { typing = (field, "") }
        if var t = typing, case .text = t.field, t.text.count < Self.maxTypedChars { t.text += chars; typing = t }
    }

    private func flushTyping() {
        focusedCache = nil
        guard let t = typing else { return }
        typing = nil
        let ctx = currentContext()
        switch t.field {
        case .hidden(let why):
            append(WatchEvent(index: 0, t: elapsed, kind: "typed", app: ctx?.appName, title: ctx?.windowTitle, url: ctx?.url, role: why, value: WatchEvent.notRecorded))
        case .text(let label):
            if !t.text.trimmingCharacters(in: .whitespaces).isEmpty {
                append(WatchEvent(index: 0, t: elapsed, kind: "typed", app: ctx?.appName, title: ctx?.windowTitle, url: ctx?.url, role: "text field", label: label, text: String(t.text.prefix(Self.maxTypedChars))))
            }
        }
    }

    /// The element with keyboard focus system-wide, as "role “name”" when its text may be recorded. Fails closed: a
    /// terminal, a secure or secret-looking field, anything that is not a form field, or an element Accessibility
    /// cannot resolve all come back hidden.
    private func focusedField() -> Field {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if Self.terminalBundles.contains(bundle) { return .hidden(why: "terminal") }
        guard Permissions.accessibilityGranted else { return .hidden(why: "unknown field") }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.2)
        guard let el = AX.element(sys, kAXFocusedUIElementAttribute) else { return .hidden(why: "unknown field") }
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        let sub = AX.string(el, kAXSubroleAttribute)
        if sub == kAXSecureTextFieldSubrole || sub == "AXSecureTextField" { return .hidden(why: "password field") }
        let title = AX.string(el, kAXTitleAttribute), desc = AX.string(el, kAXDescriptionAttribute), placeholder = AX.string(el, kAXPlaceholderValueAttribute)
        var name = [title, desc, placeholder].compactMap { $0 }.first { !$0.isEmpty }
        if name == nil, let parent = AX.element(el, kAXParentAttribute) { name = AX.string(parent, kAXTitleAttribute) }
        if Self.looksSecret(title) || Self.looksSecret(desc) || Self.looksSecret(placeholder) || Self.looksSecret(name) {
            return .hidden(why: "password field")
        }
        let formField = Self.recordedRoles.contains(role) || (role == "AXTextArea" && ContextWatcher.browserBundles.contains(bundle))
        guard formField else { return .hidden(why: role.isEmpty ? "unknown field" : Self.prettyRole(role)) }
        let r = Self.prettyRole(role)
        return .text(label: (name?.isEmpty == false) ? "\(r) “\(name!.prefix(60))”" : r)
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
