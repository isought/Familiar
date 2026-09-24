import AppKit
import SwiftUI

/// Floating, non-activating panel that stays above everything and follows across Spaces.
final class BubblePanel: NSPanel {
    static let collapsedSize = NSSize(width: 84, height: 84)
    static let defaultExpandedSize = NSSize(width: 400, height: 540)
    static let largeExpandedSize = NSSize(width: 560, height: 760)
    nonisolated(unsafe) static var expandedSize = NSSize(width: 400, height: 540)   // current card size (remembered)

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

struct BubbleView: View {
    @ObservedObject var state: Assistant
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group { if state.expanded { card } else { orb } }
            .animation(.easeOut(duration: 0.15), value: state.expanded)
            .onAppear {
                sense.isControlActive = { [weak state] in state?.control?.active ?? false }
                sense.begin()
            }
            .onDisappear { sense.end() }
    }

    // MARK: collapsed orb = the mascot

    @State private var charge: CGFloat = 0        // 0…1 ring fill while holding
    @State private var charging = false
    @State private var pressOrigin: CGPoint?      // where the current press started (global coords)
    @State private var moving = false             // the press turned into a drag
    @State private var cast = false               // the ring filled and the pen fired during this press
    @State private var chargeTimer: Timer?
    @State private var reaction: MascotMood?      // brief happy/sad after an answer
    @State private var stuck: CGFloat = 1         // 1 = peeled away; animates to 0 as the note sticks on at launch
    @StateObject private var sense = BubbleSense()

    private var mood: MascotMood {
        if charging { return .charging }
        if sense.controlActive { return .onIt }
        if state.watching { return .curious }
        if state.busy { return .thinking }
        if let r = reaction { return r }
        return sense.pointerNear ? .curious : .idle
    }

    private var orb: some View {
        MascotView(mood: mood, lookAt: sense.gaze, proximity: sense.proximity, charge: charge, size: 64, peel: stuck, animated: sense.visible)
        .frame(width: 64, height: 64)
        .padding(8)
        .contentShape(Rectangle())
        .onAppear {   // stick-on: the note lands on the screen when the bubble first appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { stuck = 0 } }
        }
        .onChange(of: state.busy) { was, now in
            guard was, !now else { return }
            react(state.transcript.last?.role == .error ? .sad : .happy)
        }
        // One press handler for click / hold-to-pick-up-the-pen / drag, so the ring and the trigger share a single timer:
        // when the ring is full the pen fires, whether or not the mouse has been released yet.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { v in
                    if pressOrigin == nil { beginPress(at: v.location) }
                    guard !cast, let o = pressOrigin else { return }
                    if !moving, hypot(v.location.x - o.x, v.location.y - o.y) > 10 { moving = true; cancelCharge() }
                    if moving { state.onDragBubble?(.moved) }
                }
                .onEnded { _ in
                    let wasMoving = moving, wasCast = cast
                    endPress()
                    if wasMoving { state.onDragBubble?(.ended) }
                    else if !wasCast { click() }                       // released before the ring filled: a click
                }
        )
        .contextMenu {
            Button("Open chat") { state.expanded = true }
            Button("Point the pen") { state.startWand() }
            Button(state.watching ? "Stop watching" : "Watch me") { state.toggleWatching() }
            Divider()
            Button("Settings…") { state.onOpenSettings?() }
            Button("Hide bubble") { state.onHideBubble?() }
            Button("Quit Familiar") { NSApp.terminate(nil) }
        }
        .help("Double-click: chat  ·  Hold: pick up the pen  ·  ⌃⌥Space: pen")
    }

    @State private var lastClick: Date?

    /// Single click = a poke (the note reacts, nothing opens). Double click = chat.
    private func click() {
        let now = Date()
        if let last = lastClick, now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
            lastClick = nil
            reaction = nil
            state.expanded = true
            return
        }
        lastClick = now
        react(.happy, for: 0.9)
        state.onPoke?()
    }

    private func beginPress(at p: CGPoint) {
        pressOrigin = p
        moving = false
        cast = false
        charging = true
        charge = 0
        let hold = state.config.wandHoldSeconds
        withAnimation(.linear(duration: hold)) { charge = 1 }
        chargeTimer?.invalidate()
        let t = Timer(timeInterval: hold, repeats: false) { _ in
            guard pressOrigin != nil, !moving, !cast else { return }
            cast = true
            charging = false
            withAnimation(.easeOut(duration: 0.2)) { charge = 0 }
            if state.busy { state.expanded = true } else { state.startWand() }
        }
        RunLoop.main.add(t, forMode: .common)
        chargeTimer = t
    }

    private func cancelCharge() {
        chargeTimer?.invalidate()
        chargeTimer = nil
        charging = false
        withAnimation(.easeOut(duration: 0.15)) { charge = 0 }
    }

    private func endPress() {
        chargeTimer?.invalidate()
        chargeTimer = nil
        pressOrigin = nil
        moving = false
        if charging { charging = false; withAnimation(.easeOut(duration: 0.15)) { charge = 0 } }
        cast = false
    }

    private func react(_ m: MascotMood, for seconds: Double? = nil) {
        reaction = m
        let d = seconds ?? (m == .sad ? 2.2 : 1.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { if reaction == m { reaction = nil } }
    }

    // MARK: expanded card = the pad

    @Environment(\.colorScheme) private var scheme
    @Environment(\.padStatic) private var padStatic
    @StateObject private var ledger = RevealLedger()
    private var dark: Bool { scheme == .dark }
    private var padAnimated: Bool { sense.visible && !padStatic }

    /// The character looking over the newest note: reading while busy, on it while the ink goes down, then the same
    /// brief happy/sad the orb shows; curious over the empty pad; sad while the last word on the pad is an error.
    private var peekMood: MascotMood {
        if state.watching { return .curious }
        if state.busy { return .thinking }
        if ledger.isRevealing { return .onIt }
        if let r = reaction { return r }
        if state.transcript.isEmpty { return .curious }
        return state.transcript.last?.role == .error ? .sad : .idle
    }

    private var card: some View {
        ledger.seed(state.transcript)
        return VStack(spacing: 0) {
            header
            transcript
            inputRow
            footer
        }
        .frame(width: state.cardSize.width - 16, height: state.cardSize.height - 16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Pad.desk(dark))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RadialGradient(colors: [.clear, .black.opacity(dark ? 0.35 : 0.10)], center: UnitPoint(x: 0.5, y: 0.35), startRadius: 120, endRadius: 620)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(dark ? Color.white.opacity(0.10) : Color(red: 0.45, green: 0.36, blue: 0.24).opacity(0.35)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .padding(8)
        .onAppear { inputFocused = true }
        .onDisappear { ledger.reset() }
        .onChange(of: state.busy) { was, now in   // the orb is not on screen while the pad is open, so the pad reacts
            guard was, !now else { return }
            react(state.transcript.last?.role == .error ? .sad : .happy)
        }
    }

    /// The pad's binding strip: the title in the character's own hand, and the controls.
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Familiar").font(HandFont.font(size: 17)).foregroundStyle(Pad.deskInk(dark))
                Text(state.contextLine).font(.caption).foregroundStyle(Pad.deskInkSoft(dark)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { state.toggleWatching() } label: { Image(systemName: state.watching ? "eye.fill" : "eye") }
                .buttonStyle(.borderless).help(state.watching ? "Stop watching" : "Watch me do something, then write it up as a tool pack").disabled(state.busy)
            Button { state.clearConversation() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Clear the pad").disabled(state.transcript.isEmpty)
            Button { state.onToggleLarge?() } label: { Image(systemName: state.cardSize.height >= BubblePanel.largeExpandedSize.height - 1 ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless).help("Large / normal size")
            Button { state.expanded = false } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).help("Collapse")
            Menu {
                Button("Settings…") { state.onOpenSettings?() }
                Button("Hide bubble") { state.onHideBubble?() }
                Button("Quit Familiar") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
        }
        .foregroundStyle(Pad.deskInk(dark).opacity(0.8))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                Pad.binding(dark)
                Rectangle().fill(Pad.bindingEdge(dark)).frame(height: 1)
                Rectangle().fill(Color.white.opacity(dark ? 0.04 : 0.35)).frame(height: 1).padding(.bottom, 1)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in state.onDragBubble?(.moved) }
                .onEnded { _ in state.onDragBubble?(.ended) }
        )
    }

    /// The notes, oldest at the top, newest at the bottom and on top of the pile.
    private var transcript: some View {
        let notes = Note.group(state.transcript)
        let tabsOn = state.busy ? nil : notes.last { $0.hasAnswer }?.id   // follow-ups stick to the last real answer
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if notes.isEmpty { welcomeNote }
                    ForEach(Array(notes.enumerated()), id: \.element.id) { i, n in
                        let latest = i == notes.count - 1
                        StickyNoteView(note: n, index: i, isLatest: latest, busy: state.busy && latest, status: state.status,
                                       suggestions: n.id == tabsOn ? state.suggestions : [], ledger: ledger,
                                       peek: latest ? peekMood : nil, animated: padAnimated,
                                       onSuggest: { state.askSuggestion($0) })
                            .id(n.id)
                    }
                    if state.busy, notes.last?.hasAnswer == true || notes.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(state.status).font(.caption).foregroundStyle(Pad.deskInkSoft(dark))
                        }.padding(.horizontal, 8).id("busy")
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: state.transcript.count) { _, _ in
                withAnimation { proxy.scrollTo(Note.id(containing: state.transcript.last?.id, in: Note.group(state.transcript)), anchor: .bottom) }
            }
            .onChange(of: state.busy) { _, busy in if busy { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
            .onAppear { proxy.scrollTo(notes.last?.id, anchor: .bottom) }   // the pad opens on the newest note
        }
    }

    /// The empty pad: a blank ruled sheet with the character looking over it, waiting.
    private var welcomeNote: some View {
        ZStack(alignment: .topTrailing) {
            Peeker(mood: peekMood, busy: false, animated: padAnimated)
            VStack(alignment: .leading, spacing: 8) {
                Text("What are we looking at?").font(HandFont.font(size: 18)).foregroundStyle(Pad.ink).padding(.trailing, 34)
                InkLine(wobble: 0.6).stroke(Pad.ink.opacity(0.22), lineWidth: 1).frame(height: 3)
                Text("Hold me to pick up the pen, then point it at anything on screen and I'll tell you what it is and what you can do about it.")
                Text("Or just write to me below.").foregroundStyle(Pad.inkSoft)
            }
            .font(Pad.body).foregroundStyle(Pad.ink).lineSpacing(Pad.lineSpacing)
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 20, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoteSheetView(curl: 24, dark: dark, ruled: true))
            .rotationEffect(.degrees(-Pad.tilt), anchor: .top)
            .padding(.top, Peeker.headroom)
            .environment(\.colorScheme, .light)
        }
    }

    /// A lined strip of paper to write on, the pen to pick up, and a nib to send.
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("", text: $state.question, prompt: Text("Write to me…").foregroundStyle(Pad.ink.opacity(0.42)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Pad.body).foregroundStyle(Pad.ink)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit { state.ask() }
                InkLine(wobble: 0.5).stroke(Pad.ink.opacity(0.30), lineWidth: 1).frame(height: 3)
            }
            .padding(.bottom, 1)
            Button { state.startWand() } label: { Image(systemName: "pencil.and.outline").font(.system(size: 17, weight: .medium)).foregroundStyle(Pad.penInk) }
                .buttonStyle(.plain).disabled(state.busy).help("Pick up the pen (⌃⌥Space)")
                .opacity(state.busy ? 0.4 : 1)
            Button { state.ask() } label: {   // the nib: ink on paper by day, a paper disc on the dark desk by night
                ZStack {
                    Circle().fill(dark ? Pad.paperBottom : Pad.ink).frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(dark ? 0.35 : 0), radius: 2, y: 1)
                    Image(systemName: "pencil.tip").font(.system(size: 14, weight: .semibold)).foregroundStyle(dark ? Pad.ink : Pad.paperTop)
                }
            }
            .buttonStyle(.plain)
            .disabled(state.busy || state.question.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(state.busy || state.question.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Pad.fieldPaper)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Pad.tabEdge.opacity(0.5), lineWidth: 0.7))
                .shadow(color: .black.opacity(dark ? 0.4 : 0.14), radius: 3, y: 1.5)
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
        .environment(\.colorScheme, .light)   // the strip is paper: light controls on it in both appearances
    }

    @State private var gripStart: CGSize?

    private var resizeGrip: some View {
        Image(systemName: "line.3.horizontal.decrease").rotationEffect(.degrees(-45))
            .font(.system(size: 10, weight: .bold)).foregroundStyle(Pad.deskInk(dark).opacity(0.4))
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if gripStart == nil { gripStart = CGSize(width: state.cardSize.width, height: state.cardSize.height) }
                        let w = max(340, min(1400, gripStart!.width + v.translation.width))
                        let h = max(400, min(1400, gripStart!.height + v.translation.height))
                        state.onResizeCard?(NSSize(width: w, height: h), false)
                    }
                    .onEnded { _ in gripStart = nil; state.onResizeCard?(state.cardSize, true) }
            )
            .help("Drag to resize")
    }

    private var footer: some View {
        HStack {
            if !state.hasApiKey {
                Button { state.onOpenSettings?() } label: { Label("No API key — open Settings", systemImage: "key") }
                    .buttonStyle(.plain).foregroundStyle(.orange)
            } else if !state.busy, !state.status.isEmpty {
                Text(state.status)
            }
            Spacer()
            Text(state.watching ? "⌃⌥Space stop watching" : "⌃⌥Space pen")
            resizeGrip
        }
        .font(.caption2).foregroundStyle(Pad.deskInkSoft(dark))
        .padding(.leading, 14).padding(.trailing, 6).padding(.bottom, 6)
    }
}

/// What the collapsed bubble senses about the world, polled at 30 Hz: where the pointer is relative to the panel
/// (so the eyes can follow it), whether it is hovering close, and whether the computer controller is driving the mouse.
/// While the panel is ordered out (hidden, or during control) it only tracks visibility, so the mascot can pause its clock.
@MainActor
final class BubbleSense: ObservableObject {
    @Published var visible = true
    @Published var gaze: CGPoint? = nil
    @Published var pointerNear = false
    @Published var proximity: CGFloat = 0      // 0 far away … 1 at the note; drives a gentle brow lift
    @Published var controlActive = false
    var isControlActive: () -> Bool = { false }
    private var timer: Timer?

    func begin() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func end() { timer?.invalidate(); timer = nil }

    private func sample() {
        guard let panel = NSApp.windows.first(where: { $0 is BubblePanel }) else { return }
        let active = isControlActive()
        if active != controlActive { controlActive = active }
        if panel.isVisible != visible { visible = panel.isVisible }
        guard visible else { return }
        let c = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let m = NSEvent.mouseLocation
        let dx = m.x - c.x, dy = c.y - m.y            // screen y is up; the mascot's y is down
        let dist = hypot(dx, dy)
        // full deflection from ~180pt away, eased in so nearby motion is gentle
        let k = min(1, dist / 180)
        let g = dist < 1 ? CGPoint.zero : CGPoint(x: dx / dist * k, y: dy / dist * k)
        if let old = gaze, abs(old.x - g.x) < 0.02, abs(old.y - g.y) < 0.02 {} else { gaze = g }
        let near = dist < 30            // curious only when the pointer is actually over the note; nearby motion just gets the eyes
        if near != pointerNear { pointerNear = near }
        let prox = max(0, 1 - dist / 240)
        if abs(prox - proximity) > 0.02 { proximity = prox }
    }
}
