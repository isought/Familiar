import AppKit
import SwiftUI

/// Floating, non-activating panel that stays above everything and follows across Spaces.
final class BubblePanel: NSPanel {
    static let collapsedSize = NSSize(width: 84, height: 84)
    static let expandedSize = NSSize(width: 400, height: 540)

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
    @State private var reaction: MascotMood?      // brief happy/sad after an answer
    @State private var stuck: CGFloat = 1         // 1 = peeled away; animates to 0 as the note sticks on at launch
    @StateObject private var sense = BubbleSense()

    private var mood: MascotMood {
        if charging { return .charging }
        if sense.controlActive { return .onIt }
        if state.busy { return .thinking }
        if let r = reaction { return r }
        return sense.pointerNear ? .curious : .idle
    }

    private var orb: some View {
        MascotView(mood: mood, lookAt: sense.gaze, charge: charge, size: 64, peel: stuck, animated: sense.visible)
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
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in state.onDragBubble?(.moved) }
                .onEnded { _ in state.onDragBubble?(.ended) }
        )
        .onTapGesture { state.expanded = true }
        .onLongPressGesture(minimumDuration: state.config.wandHoldSeconds, maximumDistance: 8) {
            // charged: cast
            charging = false
            withAnimation(.easeOut(duration: 0.2)) { charge = 0 }
            if state.busy { state.expanded = true } else { state.startWand() }
        } onPressingChanged: { pressing in
            charging = pressing
            if pressing {
                charge = 0
                withAnimation(.linear(duration: state.config.wandHoldSeconds)) { charge = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { charge = 0 }
            }
        }
        .contextMenu {
            Button("Open chat") { state.expanded = true }
            Button("Point the wand") { state.startWand() }
            Divider()
            Button("Settings…") { state.onOpenSettings?() }
            Button("Hide bubble") { state.onHideBubble?() }
            Button("Quit Familiar") { NSApp.terminate(nil) }
        }
        .help("Click: chat  ·  Hold: charge the wand  ·  ⌃⌥Space: wand")
    }

    private func react(_ m: MascotMood) {
        reaction = m
        DispatchQueue.main.asyncAfter(deadline: .now() + (m == .sad ? 2.2 : 1.5)) { if reaction == m { reaction = nil } }
    }

    // MARK: expanded card

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            if !state.suggestions.isEmpty { suggestionRow }
            inputRow
            footer
        }
        .frame(width: BubblePanel.expandedSize.width - 16, height: BubblePanel.expandedSize.height - 16)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .padding(8)
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            MascotView(mood: state.busy ? .thinking : .idle, lookAt: sense.gaze, size: 28, animated: sense.visible, decorations: false).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Familiar").font(.headline)
                Text(state.contextLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { state.clearConversation() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Clear conversation").disabled(state.transcript.isEmpty)
            Button { state.expanded = false } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).help("Collapse")
            Menu {
                Button("Settings…") { state.onOpenSettings?() }
                Button("Hide bubble") { state.onHideBubble?() }
                Button("Quit Familiar") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in state.onDragBubble?(.moved) }
                .onEnded { _ in state.onDragBubble?(.ended) }
        )
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Point the wand at anything on screen and I'll tell you what it is and what you can do about it.")
                            Text("Or just type a question below.").foregroundStyle(.secondary)
                        }.font(.callout).padding(.top, 8)
                    }
                    ForEach(state.transcript) { m in messageRow(m).id(m.id) }
                    if state.busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(state.status).font(.caption).foregroundStyle(.secondary)
                        }.id("busy")
                    }
                }
                .padding(12)
            }
            .onChange(of: state.transcript.count) { _, _ in withAnimation { proxy.scrollTo(state.transcript.last?.id, anchor: .bottom) } }
            .onChange(of: state.busy) { _, busy in if busy { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
        }
    }

    @ViewBuilder
    private func messageRow(_ m: ChatMessage) -> some View {
        switch m.role {
        case .user:
            HStack { Spacer(minLength: 40)
                Text(m.text).textSelection(.enabled)
                    .padding(10).background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        case .wand:
            HStack { Spacer(minLength: 40)
                Label(m.text, systemImage: "wand.and.stars")
                    .padding(10).background(Color.purple.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        case .assistant:
            HStack(alignment: .top) {
                rendered(m.text).textSelection(.enabled)
                    .padding(10).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 20)
            }
        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(m.text).font(.callout).textSelection(.enabled)
            }
        }
    }

    private func rendered(_ text: String) -> Text {
        let lines = text.components(separatedBy: "\n").map { line -> Text in
            if let a = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
            return Text(line)
        }
        return lines.dropFirst().reduce(lines.first ?? Text("")) { $0 + Text("\n") + $1 }
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.suggestions, id: \.self) { s in
                    Button(s) { state.askSuggestion(s) }
                        .buttonStyle(.bordered).controlSize(.small).disabled(state.busy)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Ask about your screen…", text: $state.question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { state.ask() }
            Button { state.startWand() } label: { Image(systemName: "wand.and.stars").font(.title3) }
                .buttonStyle(.borderless).disabled(state.busy).help("Point the wand (⌃⌥Space)")
            Button { state.ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .disabled(state.busy || state.question.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
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
            Text("⌃⌥Space wand")
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.bottom, 8)
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
    }
}
