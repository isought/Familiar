import AppKit
import SwiftUI

struct BubbleView: View {
    @ObservedObject var state: Assistant
    @ObservedObject var shell: ShellState
    var onOrigami: (() -> Void)? = nil
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group { if shell.expanded { card } else { orb } }
            .animation(.easeOut(duration: 0.15), value: shell.expanded)
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
                    if moving { shell.onDragBubble?(.moved) }
                }
                .onEnded { _ in
                    let wasMoving = moving, wasCast = cast
                    endPress()
                    if wasMoving { shell.onDragBubble?(.ended) }
                    else if !wasCast { click() }                       // released before the ring filled: a click
                }
        )
        .contextMenu {
            Button("Open chat") { shell.expanded = true }
            Button("Point the pen") { state.startWand() }
            Button(state.watching ? "Stop watching" : "Watch me") { state.toggleWatching() }
            Divider()
            Button("Fold into a crane") { onOrigami?() }
                .disabled(onOrigami == nil || state.busy || state.watching || sense.controlActive)
            Divider()
            Button("Settings…") { shell.onOpenSettings?() }
            Button("Hide bubble") { shell.onHideBubble?() }
            Button("Quit Noteling") { NSApp.terminate(nil) }
        }
        .help("Double-click: chat  ·  Hold: pick up the pen  ·  ⌃⌥Space: pen")
        .overlay(alignment: .topTrailing) {
            if !state.notesHere.isEmpty {
                NotesBadge(notes: state.notesHere) { state.onShowNotes?() }.padding(.top, 2).padding(.trailing, 2)
            }
        }
    }

    @State private var lastClick: Date?

    /// Single click can reopen the task screen; double click always opens chat for a new instruction.
    private func click() {
        let now = Date()
        if let last = lastClick, now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
            lastClick = nil
            reaction = nil
            shell.expanded = true
            return
        }
        lastClick = now
        if state.backgroundTaskRunning { state.showBackgroundTasks(); return }
        react(.happy, for: 0.9)
        shell.onPoke?()
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
            MainActor.assumeIsolated {   // the pad says why the pen is off while busy or watching
                if state.busy || state.watching { shell.expanded = true } else { state.startWand() }
            }
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
        if state.chatPresentationBusy { return .thinking }
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
        .frame(width: shell.cardSize.width - 16, height: shell.cardSize.height - 16)
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
                Text("Noteling").font(HandFont.font(size: 17)).foregroundStyle(Pad.deskInk(dark))
                Text(state.contextLine).font(.caption).foregroundStyle(Pad.deskInkSoft(dark)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { state.toggleBackgroundControl() } label: {
                Image(systemName: state.backgroundOn ? "rectangle.and.hand.point.up.left.filled" : "rectangle.and.hand.point.up.left")
                    .symbolEffect(.pulse, isActive: sense.controlActive && state.backgroundOn)
            }
                .buttonStyle(.borderless)
                .foregroundStyle(state.backgroundOn ? Pad.penInk : Pad.deskInk(dark).opacity(0.8))
                .opacity(state.config.allowControl ? 1 : 0.45)
                .disabled(sense.controlActive)
                .help(handHelp)
            Button { state.toggleWatching() } label: { Image(systemName: state.watching ? "eye.fill" : "eye") }
                .buttonStyle(.borderless).help(state.watching ? "Stop watching" : "Watch me do something, then write it up as a tool pack").disabled(state.busy)
            Button { state.clearConversation() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Clear the pad").disabled(state.transcript.isEmpty)
            Button { shell.onToggleLarge?() } label: { Image(systemName: shell.cardSize.height >= BubblePanel.largeExpandedSize.height - 1 ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless).help("Large / normal size")
            Button { shell.expanded = false } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).help("Collapse")
            Menu {
                Button("Background tasks…") { state.showBackgroundTasks() }
                Button("Fold into a crane") { onOrigami?() }
                    .disabled(onOrigami == nil || state.busy || state.watching || sense.controlActive)
                Button("Settings…") { shell.onOpenSettings?() }
                Button("Hide bubble") { shell.onHideBubble?() }
                Button("Quit Noteling") { NSApp.terminate(nil) }
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
                .onChanged { _ in shell.onDragBubble?(.moved) }
                .onEnded { _ in shell.onDragBubble?(.ended) }
        )
    }

    /// The hand's tooltip describes the effective state: a fresh install (control off) never shows a purple hand that does nothing.
    private var handHelp: String {
        if sense.controlActive && state.backgroundOn { return "Working in the background task screen — Stop is there, or ⌃⌥Space." }
        if !state.config.allowControl { return "Control is off. Click to let Noteling do things for you — it works in the window while you carry on." }
        if state.backgroundOn { return "Works in the window you asked about while you carry on — your mouse and keyboard stay yours. Click to have it take the mouse instead." }
        return "Takes the mouse when it does things for you. Click to have it work in the window while you carry on instead."
    }

    /// The notes, oldest at the top, newest at the bottom and on top of the pile.
    private var transcript: some View {
        let notes = Note.group(state.transcript)
        let tabsOn = state.busy ? nil : notes.last { $0.hasAnswer }?.id   // follow-ups stick to the last real answer
        return ScrollViewReader { proxy in
            ScrollView {
                // Notes change height as tabs and the busy row move between turns.
                // Lazy height estimates can loop with bottom-anchored scrolling;
                // measure the current transcript before asking it to scroll.
                VStack(alignment: .leading, spacing: 14) {
                    if notes.isEmpty { welcomeNote }
                    ForEach(Array(notes.enumerated()), id: \.element.id) { i, n in
                        let latest = i == notes.count - 1
                        StickyNoteView(note: n, index: i, isLatest: latest, busy: state.chatPresentationBusy && latest, status: state.status,
                                       suggestions: n.id == tabsOn ? state.suggestions : [], ledger: ledger,
                                       peek: latest ? peekMood : nil, animated: padAnimated,
                                       onSuggest: { state.askSuggestion($0) })
                            .id(n.id)
                    }
                    if state.chatPresentationBusy, notes.last?.hasAnswer == true || notes.isEmpty {
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
                MainThreadDiagnostics.shared.mark(.chatScrollRequested, itemCount: notes.count)
                withAnimation { proxy.scrollTo(Note.id(containing: state.transcript.last?.id, in: Note.group(state.transcript)), anchor: .bottom) }
            }
            .onChange(of: state.busy) { _, busy in
                if busy {
                    MainThreadDiagnostics.shared.mark(.chatScrollRequested, itemCount: notes.count)
                    withAnimation { proxy.scrollTo("busy", anchor: .bottom) }
                }
            }
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
                (Text(state.config.allowControl
                      ? "Ask me to do something and I'll do it in that window while you carry on — the "
                      : "Ask me to do something and I'll do it for you once you click the ")
                 + Text(Image(systemName: "rectangle.and.hand.point.up.left"))
                 + Text(state.config.allowControl ? " up top turns that off." : " up top."))
                    .foregroundStyle(Pad.inkSoft)
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
                        if gripStart == nil { gripStart = CGSize(width: shell.cardSize.width, height: shell.cardSize.height) }
                        let w = max(340, min(1400, gripStart!.width + v.translation.width))
                        let h = max(400, min(1400, gripStart!.height + v.translation.height))
                        shell.onResizeCard?(NSSize(width: w, height: h), false)
                    }
                    .onEnded { _ in gripStart = nil; shell.onResizeCard?(shell.cardSize, true) }
            )
            .help("Drag to resize")
    }

    private var footer: some View {
        HStack {
            if !state.hasConnection {
                Button { shell.onOpenSettings?() } label: { Label("Connect to Claude — open Settings", systemImage: "key") }
                    .buttonStyle(.plain).foregroundStyle(.orange)
            } else if !state.busy, !state.status.isEmpty {
                Text(state.status)
            }
            Spacer()
            Text(state.watching ? "⌃⌥Space stop watching" : state.peek.isWorking ? "⌃⌥Space stop" : "⌃⌥Space pen")
            resizeGrip
        }
        .font(.caption2).foregroundStyle(Pad.deskInkSoft(dark))
        .padding(.leading, 14).padding(.trailing, 6).padding(.bottom, 6)
    }
}

/// Notes on the page in front: a small sticky held by the bubble, with how many. Hovering lists them; clicking shows
/// them on the page. It never covers the page by itself.
struct NotesBadge: View {
    let notes: [StickyNote]
    let show: () -> Void

    var body: some View {
        let warning = notes.contains(where: \.isWarning)
        Text("\(notes.count)")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(Color(nsColor: StickerPaper.ink))
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 2.5).fill(Color(cgColor: warning ? StickerPaper.warning : StickerPaper.tip)))
            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color(cgColor: StickerPaper.edge), lineWidth: 0.7))
            .rotationEffect(.degrees(7))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: show)
            .help(Self.summary(notes))
            .accessibilityElement()
            .accessibilityLabel("\(notes.count) \(notes.count == 1 ? "note" : "notes") on this page")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { show() }
    }

    /// What hovering says: the first few notes, warnings first, and what a click does.
    static func summary(_ notes: [StickyNote]) -> String {
        let shown = notes.sorted { $0.isWarning && !$1.isWarning }.prefix(4).map { ($0.isWarning ? "⚠︎ " : "• ") + String($0.text.prefix(90)) }
        return (["\(notes.count) \(notes.count == 1 ? "note" : "notes") here:"] + shown + (notes.count > 4 ? ["…"] : [])
            + ["Click to show them on the page."]).joined(separator: "\n")
    }
}
