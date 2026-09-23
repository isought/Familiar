import AppKit
import SwiftUI

/// Floating, non-activating panel that stays above everything and follows across Spaces.
final class BubblePanel: NSPanel {
    static let collapsedSize = NSSize(width: 64, height: 64)
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
    }

    // MARK: collapsed orb = the wand

    @State private var charge: CGFloat = 0        // 0…1 ring fill while holding
    @State private var charging = false

    private var orb: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 1.0), Color(red: 0.55, green: 0.25, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Color(red: 0.55, green: 0.3, blue: 0.95).opacity(charging ? 0.7 : 0.25), radius: charging ? 10 : 6, y: charging ? 0 : 3)
            Circle()   // charge ring
                .trim(from: 0, to: charge)
                .stroke(AngularGradient(colors: [.white, Color(red: 1, green: 0.85, blue: 0.4), .white], center: .center),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1)
            Image(systemName: state.busy ? "hourglass" : "wand.and.stars")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(charging ? -12 : 0))
        }
        .frame(width: 48, height: 48)
        .scaleEffect(charging ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: charging)
        .padding(8)
        .contentShape(Rectangle())
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
            Image(systemName: "wand.and.stars").foregroundStyle(.tint)
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
