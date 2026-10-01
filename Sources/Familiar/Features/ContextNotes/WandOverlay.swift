import AppKit
import QuartzCore

struct WandTarget {
    var screenPoint: NSPoint
    var element: AXElementInfo?
    var windowOwner: String?
    var windowTitle: String?
    var ownerBundleID: String? = nil
    var windowFrame: NSRect? = nil            // the window under the point, AppKit global coordinates
    var stroke: [NSPoint]? = nil              // an inked region: the stroke as drawn, global points
    var region: NSRect? = nil                 // its bounding box
    var regionElements: [AXScan.Item] = []    // labelled controls inside the region, top to bottom
    var notes: [StickyNote] = []              // notes stuck on the element, or inside the region
    var notOnScreen: [StickyNote] = []        // the scene's notes for controls that aren't on screen, such as a missing button

    var isRegion: Bool { region != nil }

    var shortLabel: String {
        if isRegion {
            let names = regionElements.compactMap(\.label).prefix(2).map { "“\($0.prefix(28))”" }
            if names.isEmpty { return "what you circled" }
            return "circled " + names.joined(separator: ", ") + (regionElements.count > 2 ? "…" : "")
        }
        if let e = element {
            let name = e.title?.isEmpty == false ? e.title! : (e.description?.isEmpty == false ? e.description! : e.role.replacingOccurrences(of: "AX", with: ""))
            return String(name.prefix(60))
        }
        return windowTitle.map { "somewhere in “\($0.prefix(50))”" } ?? "that spot"
    }
}

/// Wand mode: full-screen overlays with a shimmering border, element highlight under the wand, click to pick,
/// drag to circle, right-click to stick a note. The notes already on the scene show as stickers while the pen is up.
@MainActor
final class WandController {
    var onPick: ((WandTarget) -> Void)?
    var onCancel: (() -> Void)?
    /// The scene (for anchors) and the notes on it, asked when the pen is picked up.
    var sceneProvider: (() -> ScreenContext?)?
    var notesProvider: ((ScreenContext?) -> [StickyNote])?
    var author: () -> String = { NSFullUserName() }
    var onNoteSave: ((StickyNote) -> Void)?
    var onNoteDelete: ((String) -> Void)?
    /// The scripts that could check a note on this scene: the tools folder's, for the packs that match it.
    var checksProvider: ((ScreenContext?) -> [NoteEditor.CheckChoice]) = { _ in [] }
    /// Told how many of the scene's notes were placed and how many have nothing on screen, and whether they are shown
    /// without the pen, for the usage log.
    var onPlaced: ((_ placed: Int, _ notOnScreen: Int, _ shown: Bool) -> Void)?

    struct PlacedNote { let note: StickyNote; let frame: NSRect }

    private var panels: [WandPanel] = []
    private var lastHit: (Date, NSPoint, WandTarget)?
    private(set) var scene: ScreenContext?
    private(set) var sceneNotes: [StickyNote] = []
    private(set) var placed: [PlacedNote] = []
    private var scan: AXScan.Result?
    /// Panels showing notes only, after the badge was clicked, and what puts them away.
    private var shown: [WandPanel] = []
    private var dismissal: Any?
    private var localDismissal: Any?
    /// Kept out of screenshots and screen sharing, like the rest of Noteling, when the setting says so.
    var hideFromScreenShare = false
    /// Notes that are on this page but whose control isn't on it now, and where they show instead: at the window's edge.
    private(set) var unplaced: [StickyNote] = []
    private(set) var edges: [PlacedNote] = []

    var isActive: Bool { !panels.isEmpty }
    var isShowingNotes: Bool { !shown.isEmpty }

    func activate() {
        guard !isActive else { return }
        hideNotes()
        scene = sceneProvider?()
        sceneNotes = notesProvider?(scene) ?? []
        scan = nil
        placed = []
        edges = []
        unplaced = []
        for screen in NSScreen.screens {
            let p = WandPanel(screen: screen, controller: self)
            if hideFromScreenShare { p.sharingType = .none }
            p.orderFrontRegardless()
            panels.append(p)
        }
        panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.makeKey()
        WandCursor.cursor.push()
        placeStickers()
        Log.info("wand: active, \(sceneNotes.count) note(s) on this scene")
    }

    func deactivate() {
        guard isActive else { return }
        NSCursor.pop()
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
    }

    /// The notes on the page in front, shown where they are stuck without the pen: open, over the page, letting every
    /// click through to it. The next click, key or change of page puts them away.
    func showNotes() {
        guard !isActive, !isShowingNotes else { return }
        scene = sceneProvider?()
        sceneNotes = notesProvider?(scene) ?? []
        scan = nil
        placed = []
        edges = []
        unplaced = []
        for screen in NSScreen.screens {
            let p = WandPanel(screen: screen, controller: self, passive: true)
            p.sharingType = .none   // notes, colleagues' names and checks: never in a screen share, whatever the bubble's setting
            p.orderFrontRegardless()
            shown.append(p)
        }
        guard !sceneNotes.isEmpty else {
            // Nothing to show: say so briefly where the pointer is, then go.
            shown.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.wandView?.showNotice(Self.noNotes)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.hideNotes() }
            return
        }
        // A click, a key or a scroll anywhere puts them away: stickers can't follow a page that moves.
        dismissal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideNotes() }
        }
        localDismissal = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.hideNotes() }
            return event
        }
        placeStickers()
        Log.info("notes: showing \(sceneNotes.count) note(s) on the page")
    }

    func hideNotes() {
        guard isShowingNotes else { return }
        if let dismissal { NSEvent.removeMonitor(dismissal) }
        if let localDismissal { NSEvent.removeMonitor(localDismissal) }
        dismissal = nil
        localDismissal = nil
        for p in shown { p.orderOut(nil) }
        shown.removeAll()
    }

    /// Puts the scene's notes on their controls: on a web page from the page reader, off the main thread, by the
    /// page's own id for a control first; in other apps from the window's Accessibility tree.
    private func placeStickers() {
        let notes = sceneNotes
        guard !notes.isEmpty else { return }
        if let bundle = scene?.bundleID, ContextWatcher.browserBundles.contains(bundle) {
            let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
            Task { [weak self] in
                let page = await Task.detached(priority: .userInitiated) { PageReader.read(bundleID: bundle) }.value
                guard let self, self.isActive || self.isShowingNotes else { return }
                let result: (placed: [PlacedNote], missing: [StickyNote]) = page.map { Self.place(notes, page: $0, primaryMaxY: primaryMaxY) } ?? ([], notes)
                // Notes saved while the page was read keep where they were put; ones removed meanwhile stay gone.
                let current = Set(self.sceneNotes.map(\.id)), savedMeanwhile = Set(self.placed.map(\.note.id))
                self.placed = result.placed.filter { current.contains($0.note.id) && !savedMeanwhile.contains($0.note.id) }
                    + self.placed.filter { current.contains($0.note.id) }
                self.unplaced = result.missing.filter { current.contains($0.id) }
                let window = page.flatMap(\.windowFrame).map { NSRect(x: $0.minX, y: primaryMaxY - $0.maxY, width: $0.width, height: $0.height) }
                self.edges = window.map { Self.atEdge(self.unplaced, of: $0) } ?? []
                self.refreshStickers()
                if self.isShowingNotes, let notice = Self.notice(unplaced: self.unplaced.count - self.edges.count) {
                    self.shown.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.wandView?.showNotice(notice)
                }
                Log.info("notes: placed \(result.placed.count) of \(notes.count) on the page")
                self.onPlaced?(self.placed.count, self.unplaced.count, self.isShowingNotes)
            }
        } else {
            let scan = ensureScan()
            placed = Self.place(notes, scan: scan)
            unplaced = notes.filter { note in !placed.contains { $0.note.id == note.id } }
            edges = scan.windowFrame.map { Self.atEdge(unplaced, of: $0) } ?? []
            refreshStickers()
            onPlaced?(placed.count, unplaced.count, isShowingNotes)
        }
    }

    static let noNotes = "No notes here yet. Pick up the pen and right-click a button to leave one."

    /// Notes for controls that aren't on screen (a button this person doesn't have, a field further down), shown down
    /// the window's right edge instead of nowhere, at most three, each saying what it is for.
    static let edgeLimit = 3
    static func atEdge(_ notes: [StickyNote], of window: NSRect) -> [PlacedNote] {
        notes.prefix(edgeLimit).enumerated().map { index, note in
            var shown = note
            shown.text = "Not on your screen: \(note.anchor.controlSummary). " + note.text
            let spot = NSRect(x: window.maxX - 30, y: window.maxY - 120 - CGFloat(index) * 130, width: 1, height: 1)
            return PlacedNote(note: shown, frame: spot)
        }
    }

    /// What the overlay says when some notes have nothing on screen to stick to.
    static func notice(unplaced count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 more note here is for something not on screen. Point the pen at the page to hear it."
            : "\(count) more notes here are for things not on screen. Point the pen at the page to hear them."
    }

    /// Notes placed on a page's controls: by the page's own id, then by role and label, then by the spot kept for
    /// controls without a name. A note whose control isn't on the page is left out rather than stuck somewhere wrong.
    static func place(_ notes: [StickyNote], page: PageSnapshot, primaryMaxY: CGFloat) -> (placed: [PlacedNote], missing: [StickyNote]) {
        func appKit(_ frame: CGRect) -> NSRect { NSRect(x: frame.minX, y: primaryMaxY - frame.maxY, width: frame.width, height: frame.height) }
        var placed: [PlacedNote] = [], missing: [StickyNote] = []
        for note in notes {
            let anchor = note.anchor
            var found: CGRect?
            // By the page's own id only when it is steady, names one control, and that control has the note's role.
            if let id = anchor.domID, NoteAnchor.isSteadyID(id) {
                let named = page.elements.filter { $0.domID == id }
                if named.count == 1, anchor.role == nil || named[0].role == anchor.role, named[0].visible { found = named[0].frame }
            }
            if found == nil, anchor.label != nil {
                found = page.elements.first { $0.visible && anchor.matchesElement(role: $0.role, label: $0.label) }?.frame
            }
            if found == nil, let window = page.windowFrame, let rect = anchor.rect, rect.count == 4 {
                found = CGRect(x: window.minX + window.width * rect[0], y: window.minY + window.height * rect[1],
                               width: window.width * rect[2], height: window.height * rect[3])
            }
            if let found, found.width > 0 || found.height > 0 { placed.append(PlacedNote(note: note, frame: appKit(found))) }
            else { missing.append(note) }
        }
        return (placed, missing)
    }

    func cancel() {
        deactivate()
        onCancel?()
    }

    func pick(at point: NSPoint) {
        var target = hitTest(at: point)
        target.notes = notes(on: target)
        target.notOnScreen = unplaced.filter { !target.notes.contains($0) }
        deactivate()
        Log.info("wand: picked \(target.shortLabel) [\(target.element?.label ?? "no element")] in \(target.windowOwner ?? "?"), \(target.notes.count) note(s)")
        onPick?(target)
    }

    /// A drawn stroke: the region is its bounding box, and the labelled controls mostly inside it are named for the model.
    func pickRegion(stroke: [NSPoint]) {
        guard var target = regionTarget(stroke) else { return }
        target.regionElements = elements(in: target.region!)
        target.notes = notes(on: target)
        target.notOnScreen = unplaced.filter { !target.notes.contains($0) }
        deactivate()
        Log.info("wand: circled \(Int(target.region!.width))x\(Int(target.region!.height)) with \(target.regionElements.count) control(s), \(target.notes.count) note(s)")
        onPick?(target)
    }

    func regionTarget(_ stroke: [NSPoint]) -> WandTarget? {
        guard let region = Self.bounds(of: stroke) else { return nil }
        var target = hitTest(at: NSPoint(x: region.midX, y: region.midY))
        target.element = nil
        target.stroke = stroke
        target.region = region
        return target
    }

    static func bounds(of pts: [NSPoint]) -> NSRect? {
        guard let f = pts.first else { return nil }
        var r = NSRect(origin: f, size: .zero)
        for p in pts.dropFirst() { r = r.union(NSRect(origin: p, size: .zero)) }
        return r.width < 4 && r.height < 4 ? nil : r
    }

    private func elements(in region: NSRect) -> [AXScan.Item] {
        let items = ensureScan().items.filter { item in
            let i = item.frame.intersection(region)
            guard !i.isNull else { return false }
            return i.width * i.height >= item.frame.width * item.frame.height * 0.5
        }
        return Array(items.sorted { $0.frame.maxY != $1.frame.maxY ? $0.frame.maxY > $1.frame.maxY : $0.frame.minX < $1.frame.minX }.prefix(25))
    }

    @discardableResult
    private func ensureScan() -> AXScan.Result {
        if let scan { return scan }
        let s = AXScan.frontmostWindow()
        scan = s
        return s
    }

    static func place(_ notes: [StickyNote], scan: AXScan.Result) -> [PlacedNote] {
        var out: [PlacedNote] = []
        for n in notes {
            if n.anchor.label != nil {
                if let item = scan.items.first(where: { n.anchor.matchesElement(role: $0.role, label: $0.label) }) {
                    out.append(PlacedNote(note: n, frame: item.frame))
                }
            } else if let wf = scan.windowFrame, let r = n.anchor.screenRect(in: wf) {
                out.append(PlacedNote(note: n, frame: r))
            }
        }
        return out
    }

    /// Notes stuck on this target, by the same rule that places them on the page: the page's own id first, then role
    /// and label, and for circled spots and regions, by overlap.
    func notes(on target: WandTarget) -> [StickyNote] {
        if let region = target.region { return placed.filter { $0.frame.intersects(region) }.map(\.note) }
        guard let e = target.element else { return [] }
        var out = sceneNotes.filter { Self.belongs($0, to: e) }
        if let f = e.frame {
            for p in placed where !out.contains(p.note) && (p.note.anchor.isRegion ? p.frame.intersects(f) : Self.sameControl(p.frame, f)) {
                out.append(p.note)
            }
        }
        return out
    }

    /// A note is this control's when the page's own steady id names it (and the role agrees), else by role and label.
    static func belongs(_ note: StickyNote, to element: AXElementInfo) -> Bool {
        let anchor = note.anchor
        if let id = anchor.domID, NoteAnchor.isSteadyID(id), let mine = element.domID {
            return id == mine && (anchor.role == nil || anchor.role == element.role)
        }
        return anchor.matchesElement(role: element.role, label: element.anchorLabel)
    }

    /// Two frames are one control when they overlap almost entirely.
    static func sameControl(_ a: NSRect, _ b: NSRect) -> Bool {
        let overlap = a.intersection(b)
        guard !overlap.isNull, a.width * a.height > 0, b.width * b.height > 0 else { return false }
        return overlap.width * overlap.height >= 0.8 * min(a.width * a.height, b.width * b.height)
    }

    /// Where a note on this target would be anchored, or nil when there is nothing to stick it to.
    func anchor(for target: WandTarget) -> NoteAnchor? {
        let bundle = target.ownerBundleID ?? scene?.bundleID
        let url = scene?.bundleID == bundle ? scene?.url : nil
        var a = NoteStore.sceneAnchor(bundleID: bundle, windowTitle: target.windowTitle ?? scene?.windowTitle, url: url)
        guard a.host != nil || a.bundle != nil else { return nil }
        if let region = target.region {
            guard let wf = target.windowFrame else { return nil }
            a.rect = NoteAnchor.fractions(of: region, in: wf)
            return a
        }
        guard let e = target.element, !e.isSecure else { return nil }
        a.role = e.role
        if a.page != nil, NoteAnchor.isSteadyID(e.domID) { a.domID = e.domID }
        if let label = e.anchorLabel { a.label = String(label.prefix(120)); return a }
        guard let f = e.frame, let wf = target.windowFrame else { return nil }
        a.rect = NoteAnchor.fractions(of: f, in: wf)
        return a
    }

    /// Keeps a note: on the scene, on screen as a sticker, and through `onNoteSave` into its pack.
    @discardableResult
    func save(_ draft: NoteDraft) -> StickyNote {
        var note = NoteStore.make(draft, by: author())
        if let old = sceneNotes.first(where: { $0.id == note.id }) { note.at = old.at }
        sceneNotes.removeAll { $0.id == note.id }
        sceneNotes.append(note)
        placed.removeAll { $0.note.id == note.id }
        placed.append(PlacedNote(note: note, frame: draft.frame))
        refreshStickers()
        onNoteSave?(note)
        return note
    }

    func delete(_ id: String) {
        sceneNotes.removeAll { $0.id == id }
        placed.removeAll { $0.note.id == id }
        refreshStickers()
        onNoteDelete?(id)
    }

    private func refreshStickers() {
        for p in panels + shown { p.wandView?.showStickers((placed + edges).filter { $0.frame.intersects(p.frame) }) }
    }

    /// Throttled hit test for hover highlighting.
    func hover(at point: NSPoint) -> WandTarget {
        if let (t, p, target) = lastHit, Date().timeIntervalSince(t) < 0.04, abs(p.x - point.x) < 2, abs(p.y - point.y) < 2 { return target }
        let target = hitTest(at: point)
        lastHit = (Date(), point, target)
        return target
    }

    func hitTest(at point: NSPoint) -> WandTarget {
        let hit = ScreenHitTester.hitTest(at: point)
        return WandTarget(screenPoint: hit.screenPoint, element: hit.element,
                          windowOwner: hit.windowOwner, windowTitle: hit.windowTitle,
                          ownerBundleID: hit.ownerBundleID, windowFrame: hit.windowFrame)
    }
}

final class WandPanel: NSPanel {
    init(screen: NSScreen, controller: WandController, passive: Bool = false) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = passive ? .floating : .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = passive
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = WandView(frame: NSRect(origin: .zero, size: screen.frame.size), controller: controller, screen: screen, passive: passive)
        self.passive = passive
    }
    private var passive = false
    override var canBecomeKey: Bool { !passive }
    override var canBecomeMain: Bool { false }
    var wandView: WandView? { contentView as? WandView }
}

/// Paper colours shared by the stickers on screen and the editor.
enum StickerPaper {
    static let tip = CGColor(red: 1.0, green: 0.94, blue: 0.58, alpha: 1)
    static let warning = CGColor(red: 1.0, green: 0.85, blue: 0.50, alpha: 1)
    static let edge = CGColor(red: 0.80, green: 0.66, blue: 0.28, alpha: 0.9)
    static let ink = NSColor(red: 0.12, green: 0.165, blue: 0.267, alpha: 1)
    static let inkSoft = NSColor(red: 0.12, green: 0.165, blue: 0.267, alpha: 0.6)

    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        if let family = HandFont.family,
           let f = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size) ?? NSFont(name: family, size: size) {
            return f
        }
        return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// The text as CATextLayer should draw it, and the height it needs (measured with the same attributes, plus slack
    /// for the layer's own leading), capped at `maxLines`.
    static func measure(_ text: String, font: NSFont, color: NSColor, width: CGFloat, maxLines: Int) -> (NSAttributedString, CGFloat) {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: para, .foregroundColor: color])
        let r = attr.boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let line = ceil(font.ascender - font.descender + font.leading) + 2
        let lines = max(1, min(CGFloat(maxLines), ceil(r.height / max(1, line - 2))))
        return (attr, lines * line + 4)
    }

    /// Stuck to the control's top-right corner; when there is no room above, hung under its bottom-right corner instead.
    static func origin(for size: NSSize, control: NSRect, in bounds: NSRect) -> NSPoint {
        var x = control.maxX - 26
        var y = control.maxY - 10
        if y + size.height > bounds.height - 6 { y = control.minY + 10 - size.height }
        x = min(max(6, x), bounds.width - size.width - 6)
        y = min(max(6, y), bounds.height - size.height - 6)
        return NSPoint(x: x, y: y)
    }
}

final class WandView: NSView {
    private unowned let controller: WandController
    private let screen: NSScreen
    private let highlight = CAShapeLayer()
    private let labelPill = CALayer()
    private let labelText = CATextLayer()
    private let inkHalo = CAShapeLayer()
    private let ink = CAShapeLayer()
    private var captionText: CATextLayer?
    private var captionRestore: DispatchWorkItem?
    private var stickers: [Sticker] = []
    private var editor: NoteEditor?
    private var editing: (anchor: NoteAnchor, frame: NSRect, existing: StickyNote?)?
    private var stroke: [NSPoint] = []        // the stroke in progress, global points
    private var strokeIsNote = false          // drawn with the right button: it ends in a note, not a question

    static let dragThreshold: CGFloat = 6
    static let caption = "Click to ask  ·  drag to circle  ·  right-click to leave a note  ·  Esc to cancel"

    /// One note already on the scene, stuck to its control.
    final class Sticker {
        let note: StickyNote
        let frame: NSRect          // the control, global coordinates
        let layer = CALayer()
        let text = CATextLayer()
        let byline = CATextLayer()
        var expanded = false
        init(note: StickyNote, frame: NSRect) { self.note = note; self.frame = frame }
    }

    /// Showing notes only: no border, no caption, every sticker open, and the mouse goes to the apps underneath.
    let passive: Bool

    init(frame: NSRect, controller: WandController, screen: NSScreen, passive: Bool = false) {
        self.controller = controller
        self.screen = screen
        self.passive = passive
        super.init(frame: frame)
        wantsLayer = true
        buildLayers()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard !passive else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .cursorUpdate, .mouseEnteredAndExited], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { if editor == nil { WandCursor.cursor.set() } }
    override func mouseEntered(with event: NSEvent) { if editor == nil { WandCursor.cursor.set() } }

    override func mouseMoved(with event: NSEvent) {
        guard editor == nil else { return }   // the highlight stays on the control being annotated
        WandCursor.cursor.set()
        let global = screenPoint(event)
        let target = controller.hover(at: global)
        updateHighlight(target)
        expandStickers(for: target, at: local(global))
    }

    // MARK: gestures

    override func mouseDown(with event: NSEvent) {
        if editor != nil { editor?.commit(); return }
        beginStroke(at: screenPoint(event), note: false)
    }
    override func mouseDragged(with event: NSEvent) { extendStroke(to: screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { endStroke() }

    override func rightMouseDown(with event: NSEvent) {
        if editor != nil { editor?.commit(); return }
        beginStroke(at: screenPoint(event), note: true)
    }
    override func rightMouseDragged(with event: NSEvent) { extendStroke(to: screenPoint(event)) }
    override func rightMouseUp(with event: NSEvent) { endStroke() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller.cancel() } // Esc
    }

    private func beginStroke(at p: NSPoint, note: Bool) {
        stroke = [p]
        strokeIsNote = note
        clearInk()
    }

    private func extendStroke(to p: NSPoint) {
        guard !stroke.isEmpty else { return }
        stroke.append(p)
        guard Self.span(stroke) > Self.dragThreshold else { return }
        let path = CGMutablePath()
        for (i, g) in stroke.enumerated() { i == 0 ? path.move(to: local(g)) : path.addLine(to: local(g)) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ink.path = path; inkHalo.path = path
        ink.isHidden = false; inkHalo.isHidden = false
        highlight.isHidden = true; labelPill.isHidden = true
        CATransaction.commit()
    }

    private func endStroke() {
        guard let start = stroke.first else { return }
        let pts = stroke
        stroke = []
        let dragged = Self.span(pts) > Self.dragThreshold
        if strokeIsNote {
            if dragged { openEditor(region: pts) } else { openEditor(at: start) }
        } else {
            if dragged { controller.pickRegion(stroke: pts) } else { clearInk(); controller.pick(at: start) }
        }
    }

    static func span(_ pts: [NSPoint]) -> CGFloat {
        guard let f = pts.first else { return 0 }
        return pts.reduce(0) { max($0, hypot($1.x - f.x, $1.y - f.y)) }
    }

    private func clearInk() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ink.path = nil; inkHalo.path = nil; ink.isHidden = true; inkHalo.isHidden = true
        CATransaction.commit()
    }

    // MARK: stickers

    /// Showing notes only: says, in a pill at the top, that some notes are for something not on screen now.
    func showNotice(_ text: String) {
        guard passive, let root = layer else { return }
        let (pill, _) = ShimmerBorder.captionPill(bounds: bounds, scale: screen.backingScaleFactor, width: 620, text: text)
        root.addSublayer(pill)
    }

    func showStickers(_ placed: [WandController.PlacedNote]) {
        stickers.forEach { $0.layer.removeFromSuperlayer() }
        stickers = placed.map { makeSticker($0.note, at: $0.frame) }
        if passive { for s in stickers { s.expanded = true; layout(s) } }
    }

    private func makeSticker(_ note: StickyNote, at frame: NSRect) -> Sticker {
        let s = Sticker(note: note, frame: frame)
        let scale = screen.backingScaleFactor
        s.layer.backgroundColor = note.isWarning ? StickerPaper.warning : StickerPaper.tip
        s.layer.cornerRadius = 2
        s.layer.borderWidth = 0.5
        s.layer.borderColor = StickerPaper.edge
        s.layer.shadowOpacity = 0.3; s.layer.shadowRadius = 3; s.layer.shadowOffset = CGSize(width: 0, height: -2)
        for t in [s.text, s.byline] { t.contentsScale = scale; t.isWrapped = true; t.truncationMode = .end }
        s.text.foregroundColor = StickerPaper.ink.cgColor      // the truncation token takes the layer's colour, not the string's
        s.byline.foregroundColor = StickerPaper.inkSoft.cgColor
        s.byline.font = NSFont.systemFont(ofSize: 10); s.byline.fontSize = 10
        s.layer.addSublayer(s.text); s.layer.addSublayer(s.byline)
        layer?.addSublayer(s.layer)
        layout(s)
        return s
    }

    /// Stuck to the control's top-right corner, overlapping it a little, kept on screen. Collapsed: two lines. Expanded: the whole note and who left it.
    private func layout(_ s: Sticker) {
        let control = local(s.frame)
        let width: CGFloat = s.expanded ? 280 : 190
        let body = (s.note.isWarning ? "⚠︎ " : "") + (s.expanded ? s.note.text : String(s.note.text.prefix(100)))
        let font = StickerPaper.font(s.expanded ? 13.5 : 12.5, bold: true)
        let (attr, textH) = StickerPaper.measure(body, font: font, color: StickerPaper.ink, width: width - 20, maxLines: s.expanded ? 14 : 2)
        let height = textH + (s.expanded ? 34 : 14)
        let o = StickerPaper.origin(for: NSSize(width: width, height: height), control: control, in: bounds)
        let seed = CGFloat(abs(s.note.id.hashValue % 100)) / 100
        CATransaction.begin(); CATransaction.setDisableActions(true)
        s.layer.transform = CATransform3DIdentity
        s.layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        s.layer.position = CGPoint(x: o.x + width / 2, y: o.y + height / 2)
        s.layer.transform = s.expanded ? CATransform3DIdentity : CATransform3DMakeRotation((seed - 0.5) * 0.06, 0, 0, 1)
        s.layer.zPosition = s.expanded ? 10 : 1
        s.text.string = attr
        s.text.frame = CGRect(x: 10, y: s.expanded ? 24 : 7, width: width - 20, height: textH)
        s.byline.string = "— " + s.note.byline
        s.byline.frame = CGRect(x: 10, y: 7, width: width - 20, height: 13)
        s.byline.isHidden = !s.expanded
        CATransaction.commit()
    }

    private func expandStickers(for target: WandTarget, at p: NSPoint) {
        for s in stickers {
            let onControl = target.element.map { s.note.anchor.matchesElement(role: $0.role, label: $0.anchorLabel) } ?? false
            let onRegion = s.note.anchor.isRegion && (s.frame.contains(target.screenPoint) || (target.element?.frame.map { s.frame.intersects($0) } ?? false))
            let overSticker = s.layer.frame.contains(p)
            let want = onControl || onRegion || overSticker
            if want != s.expanded { s.expanded = want; layout(s) }
        }
    }

    // MARK: note editor

    private func openEditor(at point: NSPoint) {
        clearInk()
        let target = controller.hitTest(at: point)
        guard let anchor = controller.anchor(for: target) else {
            flash(target.element?.isSecure == true ? "No notes on password fields" : "Nothing here to stick a note on"); return
        }
        let existing = controller.notes(on: target).first
        let frame = target.element?.frame ?? NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        updateHighlight(target)
        present(anchor: anchor, at: frame, existing: existing)
    }

    private func openEditor(region pts: [NSPoint]) {
        guard let target = controller.regionTarget(pts), let region = target.region else { clearInk(); return }
        guard let anchor = controller.anchor(for: target) else { clearInk(); flash("Nothing here to stick a note on"); return }
        present(anchor: anchor, at: region, existing: nil)
    }

    /// Render mode: open or close a sticker by note id.
    func setExpanded(_ id: String, _ on: Bool) {
        for s in stickers where s.note.id == id && s.expanded != on { s.expanded = on; layout(s) }
    }

    func present(anchor: NoteAnchor, at frame: NSRect, existing: StickyNote?) {
        editor?.removeFromSuperview()
        let ed = NoteEditor(existing: existing, place: anchor.controlSummary, checks: controller.checksProvider(controller.scene))
        let o = StickerPaper.origin(for: ed.frame.size, control: local(frame), in: bounds)
        ed.frame = NSRect(origin: o, size: ed.frame.size)
        ed.onCommit = { [weak self] text, kind, check in self?.finishEditor(text: text, kind: kind, check: check) }
        ed.onCancel = { [weak self] in self?.closeEditor() }
        ed.onDelete = { [weak self] in
            guard let self, let ex = self.editing?.existing else { return }
            self.controller.delete(ex.id)
            self.closeEditor()
            self.flash("Note removed")
        }
        addSubview(ed)
        editor = ed
        editing = (anchor, frame, existing)
        NSCursor.arrow.set()
        window?.makeKey()
        window?.makeFirstResponder(ed.textView)
    }

    private func finishEditor(text: String, kind: String, check: NoteCheck?) {
        guard let e = editing else { closeEditor(); return }
        var anchor = e.anchor
        if let existing = e.existing?.anchor {
            // Editing a note keeps the page or site it was stuck to, so a note for a whole site doesn't shrink to one page.
            anchor.page = existing.page; anchor.host = existing.host; anchor.path = existing.path
            anchor.bundle = existing.bundle; anchor.window = existing.window
        }
        let draft = NoteDraft(existingID: e.existing?.id, anchor: anchor, kind: kind, text: text, frame: e.frame, check: check)
        let note = controller.save(draft)
        closeEditor()
        flash("Note kept on \(note.anchor.summary)")
    }

    private func closeEditor() {
        editor?.removeFromSuperview()
        editor = nil
        editing = nil
        clearInk()
        window?.makeFirstResponder(self)
        WandCursor.cursor.set()
    }

    /// Replaces the caption for a moment.
    private func flash(_ text: String, seconds: Double = 2.2) {
        captionRestore?.cancel()
        captionText?.string = text
        let w = DispatchWorkItem { [weak self] in self?.captionText?.string = Self.caption }
        captionRestore = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    // MARK: geometry and chrome

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        guard let w = window else { return .zero }
        let p = event.locationInWindow
        return NSPoint(x: w.frame.minX + p.x, y: w.frame.minY + p.y)
    }

    private func local(_ global: NSPoint) -> NSPoint {
        guard let w = window else { return global }
        return NSPoint(x: global.x - w.frame.minX, y: global.y - w.frame.minY)
    }

    private func local(_ global: NSRect) -> NSRect {
        guard let w = window else { return global }
        return NSRect(x: global.minX - w.frame.minX, y: global.minY - w.frame.minY, width: global.width, height: global.height)
    }

    private func updateHighlight(_ target: WandTarget) {
        guard let frame = target.element?.frame else {
            highlight.isHidden = true; labelPill.isHidden = true; return
        }
        let local = local(frame).insetBy(dx: -3, dy: -3)
        guard local.width < bounds.width * 0.95 || local.height < bounds.height * 0.95 else {
            highlight.isHidden = true; labelPill.isHidden = true; return   // whole-window hits are noise
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.path = CGPath(roundedRect: local, cornerWidth: 6, cornerHeight: 6, transform: nil)
        highlight.isHidden = false
        let text = target.shortLabel
        labelText.string = text
        let width = min(CGFloat(text.count) * 7.5 + 24, 420)
        var px = local.minX, py = local.maxY + 8
        if py + 26 > bounds.height { py = local.minY - 34 }
        px = min(max(8, px), bounds.width - width - 8)
        labelPill.frame = CGRect(x: px, y: py, width: width, height: 26)
        labelText.frame = CGRect(x: 12, y: 5, width: width - 24, height: 18)
        labelPill.isHidden = false
        CATransaction.commit()
    }

    private func buildLayers() {
        guard let root = layer else { return }
        let scale = screen.backingScaleFactor
        if passive { return }
        ShimmerBorder.install(on: root, bounds: bounds, dim: 0.10)

        highlight.fillColor = CGColor(gray: 1, alpha: 0.06)
        highlight.strokeColor = NSColor.systemPurple.cgColor
        highlight.lineWidth = 2
        highlight.isHidden = true
        root.addSublayer(highlight)

        for (l, width, color) in [(inkHalo, CGFloat(9), CGColor(gray: 1, alpha: 0.85)), (ink, CGFloat(4.5), CGColor(red: 0.55, green: 0.3, blue: 0.95, alpha: 1))] {
            l.fillColor = nil
            l.strokeColor = color
            l.lineWidth = width
            l.lineCap = .round
            l.lineJoin = .round
            l.isHidden = true
            root.addSublayer(l)
        }

        labelPill.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.92).cgColor
        labelPill.cornerRadius = 13
        labelPill.isHidden = true
        labelText.fontSize = 12
        labelText.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        labelText.foregroundColor = NSColor.white.cgColor
        labelText.contentsScale = scale
        labelText.truncationMode = .end
        labelPill.addSublayer(labelText)
        root.addSublayer(labelPill)

        let (hint, text) = ShimmerBorder.captionPill(bounds: bounds, scale: scale, width: 620, text: Self.caption)
        captionText = text
        root.addSublayer(hint)
    }
}

/// A sticky note being written, right where it will be stuck: lined paper, a Tip/Warning switch, Return keeps it.
final class NoteEditor: NSView, NSTextViewDelegate {
    static let size = NSSize(width: 276, height: 138)
    let textView = NoteTextView()
    private let scroll = NSScrollView()
    private let warning = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let placeLabel = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "What should the next person know?")
    private let hint = NSTextField(labelWithString: "⏎ keep · ⇧⏎ line · esc drop")
    private let checkMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private var checks: [CheckChoice] = []
    private var keptArgs: [String: String]?
    var onCommit: ((String, String, NoteCheck?) -> Void)?

    /// A script that can check a note: its tool id and how the menu names it.
    struct CheckChoice: Equatable {
        var script: String
        var title: String
    }

    /// The editor's height: one more row when there are scripts to check the note with.
    static func height(withChecks: Bool) -> CGFloat { size.height + (withChecks ? 26 : 0) }

    /// Chooses a check by its place in the list, as the menu does.
    func selectCheck(at index: Int) { checkMenu.selectItem(at: index + 1) }

    /// What the check menu chose; nil for none.
    var chosenCheck: NoteCheck? {
        let index = checkMenu.indexOfSelectedItem - 1
        guard checks.indices.contains(index) else { return nil }
        return NoteCheck(script: checks[index].script, args: keptArgs)
    }
    var onCancel: (() -> Void)?
    var onDelete: (() -> Void)?

    init(existing: StickyNote?, place: String, checks: [CheckChoice] = []) {
        // A note linked to a script that isn't offered here keeps it as a choice, so editing the text never drops it.
        var choices = checks
        if let current = existing?.check, !choices.contains(where: { $0.script == current.script }) {
            choices.append(CheckChoice(script: current.script, title: current.script.replacingOccurrences(of: "__", with: " · ")))
        }
        self.checks = choices
        self.keptArgs = existing?.check?.args
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.size.width, height: Self.height(withChecks: !choices.isEmpty))))
        wantsLayer = true
        layer?.backgroundColor = existing?.isWarning == true ? StickerPaper.warning : StickerPaper.tip
        layer?.cornerRadius = 3
        layer?.borderWidth = 0.5
        layer?.borderColor = StickerPaper.edge
        layer?.shadowOpacity = 0.35; layer?.shadowRadius = 5; layer?.shadowOffset = CGSize(width: 0, height: -3)
        let w = Self.size.width, h = frame.height, bottom: CGFloat = self.checks.isEmpty ? 0 : 26

        placeLabel.stringValue = (existing == nil ? "Note on " : "Your note on ") + place
        placeLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        placeLabel.textColor = StickerPaper.inkSoft
        placeLabel.lineBreakMode = .byTruncatingTail
        placeLabel.frame = NSRect(x: 10, y: h - 22, width: w - (existing == nil ? 20 : 44), height: 14)
        addSubview(placeLabel)

        if existing != nil {
            let b = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove note") ?? NSImage(), target: self, action: #selector(deleteTapped))
            b.isBordered = false
            b.contentTintColor = StickerPaper.inkSoft
            b.frame = NSRect(x: w - 30, y: h - 26, width: 22, height: 22)
            b.toolTip = "Remove this note"
            addSubview(b)
        }

        scroll.frame = NSRect(x: 10, y: 36 + bottom, width: w - 20, height: h - 62 - bottom)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = StickerPaper.font(14.5, bold: true)
        textView.textColor = StickerPaper.ink
        textView.insertionPointColor = StickerPaper.ink
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.string = existing?.text ?? ""
        textView.delegate = self
        textView.onReturn = { [weak self] in self?.commit() }
        textView.onEscape = { [weak self] in self?.onCancel?() }
        scroll.documentView = textView
        addSubview(scroll)

        placeholder.font = StickerPaper.font(14.5, bold: true)
        placeholder.textColor = StickerPaper.inkSoft.withAlphaComponent(0.45)
        placeholder.frame = NSRect(x: 15, y: h - 46, width: w - 30, height: 20)
        placeholder.isHidden = !(existing?.text ?? "").isEmpty
        addSubview(placeholder)

        if !self.checks.isEmpty {
            // Link the note to a script that tests it, run as whoever reads the note.
            checkMenu.addItem(withTitle: "No check")
            for choice in self.checks { checkMenu.addItem(withTitle: "Check with " + choice.title) }
            if let current = existing?.check, let index = self.checks.firstIndex(where: { $0.script == current.script }) {
                checkMenu.selectItem(at: index + 1)
            }
            checkMenu.controlSize = .small
            checkMenu.font = NSFont.systemFont(ofSize: 11)
            checkMenu.frame = NSRect(x: 8, y: 32, width: w - 16, height: 22)
            checkMenu.toolTip = "When someone points at this with the pen, the script runs as them and its answer shows beside the note"
            addSubview(checkMenu)
        }

        warning.attributedTitle = NSAttributedString(string: "⚠︎ Warning", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: StickerPaper.ink])
        warning.state = existing?.isWarning == true ? .on : .off
        warning.controlSize = .small
        warning.target = self
        warning.action = #selector(kindChanged)
        warning.sizeToFit()
        warning.frame.origin = NSPoint(x: 10, y: 9)
        addSubview(warning)

        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = StickerPaper.inkSoft
        hint.alignment = .right
        hint.frame = NSRect(x: w - 170, y: 11, width: 160, height: 14)
        addSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A click on the paper itself is not a click on the screen behind it.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(textView) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(textView) }

    func commit() {
        let t = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { onCancel?() } else { onCommit?(String(t.prefix(600)), warning.state == .on ? "warning" : "tip", chosenCheck) }
    }

    @objc private func kindChanged() {
        layer?.backgroundColor = warning.state == .on ? StickerPaper.warning : StickerPaper.tip
        window?.makeFirstResponder(textView)
    }

    @objc private func deleteTapped() { onDelete?() }

    func textDidChange(_ notification: Notification) { placeholder.isHidden = !textView.string.isEmpty }
}

final class NoteTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()
        case 36, 76:
            if event.modifierFlags.contains(.shift) { insertNewline(nil) } else { onReturn?() }
        default: super.keyDown(with: event)
        }
    }
}

/// Shared overlay chrome: the rotating rainbow border and a caption pill at the top.
enum ShimmerBorder {
    static func install(on root: CALayer, bounds: CGRect, dim: CGFloat) {
        root.backgroundColor = CGColor(gray: 0, alpha: dim)
        for (width, opacity) in [(CGFloat(28), Float(0.28)), (CGFloat(8), Float(0.95))] {
            let container = CALayer()
            container.frame = bounds
            let mask = CAShapeLayer()
            mask.frame = bounds
            mask.path = CGPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), cornerWidth: 18, cornerHeight: 18, transform: nil)
            mask.fillColor = nil
            mask.strokeColor = CGColor(gray: 0, alpha: 1)
            mask.lineWidth = width
            container.mask = mask
            let g = CAGradientLayer()
            g.type = .conic
            g.colors = [NSColor.systemBlue, NSColor.systemPurple, NSColor.systemPink, NSColor.systemOrange, NSColor.systemTeal, NSColor.systemBlue].map(\.cgColor)
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 0.5)
            let side = hypot(bounds.width, bounds.height) * 1.1
            g.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            g.opacity = opacity
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = 2 * Double.pi; spin.duration = 5; spin.repeatCount = .infinity
            g.add(spin, forKey: "spin")
            container.addSublayer(g)
            root.addSublayer(container)
        }
    }

    static func captionPill(bounds: CGRect, scale: CGFloat, width: CGFloat, text: String) -> (CALayer, CATextLayer) {
        let pill = CALayer()
        let t = CATextLayer()
        pill.frame = CGRect(x: bounds.midX - width / 2, y: bounds.height - 64, width: width, height: 34)
        pill.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.88).cgColor
        pill.cornerRadius = 17
        t.string = text
        t.fontSize = 13
        t.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        t.foregroundColor = NSColor.white.cgColor
        t.alignmentMode = .center
        t.truncationMode = .end
        t.contentsScale = scale
        t.frame = CGRect(x: 8, y: 8, width: width - 16, height: 20)
        pill.addSublayer(t)
        return (pill, t)
    }
}

enum WandCursor {
    /// Size of the cursor image in points; the hotspot is the nib tip, bottom-left.
    static let size = NSSize(width: 40, height: 40)
    static let hotSpot = NSPoint(x: 4, y: 36)

    static let cursor: NSCursor = {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx)
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }()

    /// A quill pen: metal nib at the bottom-left (the hotspot), feather sweeping up to the top-right, a purple ink drop at the tip.
    /// Draws into a flipped (top-left origin) context of `size` points; scale the context to draw it larger.
    static func draw(in ctx: CGContext) {
        let tip = CGPoint(x: hotSpot.x, y: hotSpot.y)
        // axis from the nib tip to the feather end, with a unit normal (n points down-right)
        let end = CGPoint(x: 36.5, y: 3.5)
        let dx = end.x - tip.x, dy = end.y - tip.y
        let len = hypot(dx, dy)
        let d = CGPoint(x: dx / len, y: dy / len), n = CGPoint(x: -d.y, y: d.x)
        func at(_ t: CGFloat, _ w: CGFloat) -> CGPoint { CGPoint(x: tip.x + d.x * len * t + n.x * w, y: tip.y + d.y * len * t + n.y * w) }
        let space = CGColorSpaceCreateDeviceRGB()

        // vane: a feather leaf, fuller on the upper side, narrower below, ending in a point
        let vane = CGMutablePath()
        vane.move(to: at(0.34, 0))
        vane.addCurve(to: at(1.0, -0.4), control1: at(0.50, -8.6), control2: at(0.86, -7.0))
        vane.addCurve(to: at(0.34, 0), control1: at(0.82, 4.2), control2: at(0.50, 5.0))
        vane.closeSubpath()
        // shaft: a thin tapered strip from just above the nib to the feather end
        let shaft = CGMutablePath()
        shaft.move(to: at(0.14, -1.6)); shaft.addLine(to: at(1.0, -0.6)); shaft.addLine(to: at(1.0, 0.6)); shaft.addLine(to: at(0.14, 1.6)); shaft.closeSubpath()
        // nib: a pointed blade
        let nib = CGMutablePath()
        nib.move(to: tip); nib.addLine(to: at(0.16, -3.2)); nib.addLine(to: at(0.28, -1.9)); nib.addLine(to: at(0.28, 1.9)); nib.addLine(to: at(0.16, 3.2)); nib.closeSubpath()

        // silhouette: one soft shadow under the whole pen plus a pale rim, so it reads on dark and light alike
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1, height: 1.5), blur: 3.5, color: CGColor(gray: 0, alpha: 0.55))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineJoin(.round)
        ctx.addPath(vane); ctx.addPath(shaft); ctx.addPath(nib)
        ctx.setLineWidth(2.4); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.strokePath()
        ctx.addPath(vane); ctx.addPath(shaft); ctx.addPath(nib)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // vane: warm white shading to a cool lavender at the shaft, a few barbs on the upper side, a sheen along the edge
        ctx.saveGState()
        ctx.addPath(vane); ctx.clip()
        if let g = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 1, blue: 0.99, alpha: 1), CGColor(red: 0.87, green: 0.84, blue: 0.94, alpha: 1)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: at(0.7, -8.5), end: at(0.7, 4.5), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.setLineCap(.round)
        ctx.setLineWidth(0.75); ctx.setStrokeColor(CGColor(red: 0.50, green: 0.45, blue: 0.64, alpha: 0.55))
        for i in 0..<6 {
            let t = 0.44 + 0.085 * CGFloat(i)
            ctx.move(to: at(t, -0.8)); ctx.addLine(to: at(t + 0.11, -7.2 + CGFloat(i) * 0.5))
        }
        ctx.strokePath()
        ctx.setLineWidth(1.2); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.move(to: at(0.48, -6.2)); ctx.addQuadCurve(to: at(0.92, -3.6), control: at(0.72, -7.6)); ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(vane); ctx.setLineWidth(1.0); ctx.setStrokeColor(CGColor(red: 0.30, green: 0.26, blue: 0.42, alpha: 0.95)); ctx.strokePath()

        // shaft: cream with a dark edge
        ctx.addPath(shaft); ctx.setFillColor(CGColor(red: 0.93, green: 0.88, blue: 0.72, alpha: 1)); ctx.fillPath()
        ctx.addPath(shaft); ctx.setLineWidth(0.8); ctx.setStrokeColor(CGColor(red: 0.42, green: 0.35, blue: 0.25, alpha: 0.9)); ctx.strokePath()

        // nib: dark metal with a highlight along one edge, a slit down the middle and a breather hole
        ctx.saveGState()
        ctx.addPath(nib); ctx.clip()
        if let g = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0.62, alpha: 1), CGColor(gray: 0.20, alpha: 1), CGColor(gray: 0.08, alpha: 1)] as CFArray, locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(g, start: at(0.2, -3.5), end: at(0.2, 3.5), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.setLineWidth(0.8); ctx.setStrokeColor(CGColor(gray: 0.85, alpha: 0.9))
        ctx.move(to: at(0.03, 0)); ctx.addLine(to: at(0.20, 0)); ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(nib); ctx.setLineWidth(0.8); ctx.setStrokeColor(CGColor(gray: 0.05, alpha: 1)); ctx.strokePath()
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fillEllipse(in: CGRect(x: at(0.16, 0).x - 0.9, y: at(0.16, 0).y - 0.9, width: 1.8, height: 1.8))

        // ink drop at the tip, in the brand purple
        let ink = CGPoint(x: tip.x + 1.6, y: tip.y - 0.4)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5, color: CGColor(red: 0.55, green: 0.3, blue: 0.95, alpha: 0.6))
        ctx.setFillColor(CGColor(red: 0.55, green: 0.3, blue: 0.95, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: ink.x - 2.6, y: ink.y - 2.6, width: 5.2, height: 5.2))
        ctx.restoreGState()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: ink.x - 1.7, y: ink.y - 1.9, width: 1.6, height: 1.3))
    }
}
