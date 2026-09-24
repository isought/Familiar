import AppKit
import SwiftUI

// The chat card drawn as a pad of sticky notes: each exchange is one yellow note the character writes on,
// stuck to a warm desk-coloured pad, with the character itself peeking over the newest one. Colours, fonts,
// the note, the tabs and the progressive "ink" reveal live here; `BubbleView` (BubblePanel.swift) composes
// them with the header, input and footer.

/// Palette and type of the pad. Paper stays yellow in both appearances; only the desk around it darkens.
enum Pad {
    static let ink = Color(red: 0.12, green: 0.165, blue: 0.267)                 // #1F2A44, body text
    static let inkSoft = ink.opacity(0.62)
    static let redInk = Color(red: 0.70, green: 0.14, blue: 0.12)
    static let penInk = Color(red: 0.45, green: 0.26, blue: 0.80)                // the quill's purple ink drop

    static let paperTop = Color(red: 1.0, green: 0.965, blue: 0.70)
    static let paperBottom = Color(red: 0.99, green: 0.905, blue: 0.53)
    static let paperEdge = Color(red: 0.84, green: 0.70, blue: 0.30)
    static let paperDeep = Color(red: 0.93, green: 0.80, blue: 0.40)             // a sheet tucked behind, or the crease

    static let tabPaper = Color(red: 1.0, green: 0.985, blue: 0.92)
    static let tabEdge = Color(red: 0.80, green: 0.70, blue: 0.45)
    static let fieldPaper = Color(red: 1.0, green: 0.99, blue: 0.955)

    static func desk(_ dark: Bool) -> LinearGradient {
        dark ? LinearGradient(colors: [Color(red: 0.21, green: 0.19, blue: 0.165), Color(red: 0.145, green: 0.13, blue: 0.11)], startPoint: .top, endPoint: .bottom)
             : LinearGradient(colors: [Color(red: 0.935, green: 0.90, blue: 0.84), Color(red: 0.89, green: 0.84, blue: 0.76)], startPoint: .top, endPoint: .bottom)
    }
    /// The pad's glued binding strip behind the header.
    static func binding(_ dark: Bool) -> Color { dark ? Color(red: 0.11, green: 0.095, blue: 0.08) : Color(red: 0.84, green: 0.78, blue: 0.675) }
    static func bindingEdge(_ dark: Bool) -> Color { dark ? .black.opacity(0.5) : Color(red: 0.62, green: 0.53, blue: 0.40).opacity(0.55) }
    /// Text and icons drawn directly on the desk (header, footer).
    static func deskInk(_ dark: Bool) -> Color { dark ? Color(red: 0.93, green: 0.90, blue: 0.84) : Color(red: 0.24, green: 0.19, blue: 0.13) }
    static func deskInkSoft(_ dark: Bool) -> Color { deskInk(dark).opacity(0.62) }

    /// Body type is sized for someone reading instructions off the note across a desk, not for density.
    static let bodySize: CGFloat = 15
    static let body = Font.system(size: bodySize)
    static let lineSpacing: CGFloat = 4
    /// Notes alternate this much either way down the pad; small enough that wrapped text still reads true.
    static let tilt: Double = 0.9
}

/// The handwriting used for note headings only. Picks the first installed family from a short list of the
/// handwriting faces macOS ships with; otherwise a rounded system font, which is the same spirit without the risk.
enum HandFont {
    static let family: String? = {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return ["Noteworthy", "Bradley Hand", "Chalkboard SE", "Marker Felt"].first { installed.contains($0) }
    }()

    static func font(size: CGFloat) -> Font {
        if let family, let f = NSFontManager.shared.font(withFamily: family, traits: .boldFontMask, weight: 9, size: size) ?? NSFont(name: family, size: size) {
            return Font(f)
        }
        return .system(size: size, weight: .semibold, design: .rounded)
    }
}

/// Set on a static render (`--render-card`) so every answer is fully inked and nothing animates.
private struct PadStaticKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var padStatic: Bool { get { self[PadStaticKey.self] } set { self[PadStaticKey.self] = newValue } }
}

/// One note on the pad: the question (typed, or the pen-pick label) as its heading and whatever came back as its body.
struct Note: Identifiable {
    let id: UUID
    var heading: ChatMessage?
    var answers: [ChatMessage]

    var hasAnswer: Bool { answers.contains { $0.role == .assistant } }

    /// Groups the flat transcript into notes: every user/pen message starts one. An answer joins the note above it
    /// while that note has no answer yet (an earlier error on it, say a failed capture, does not push the answer onto
    /// a sheet of its own); an error always stays on the note it belongs to. Only an answer with nothing above it
    /// gets a headless note.
    static func group(_ transcript: [ChatMessage]) -> [Note] {
        var out: [Note] = []
        for m in transcript {
            switch m.role {
            case .user, .wand, .draft, .learned:
                out.append(Note(id: m.id, heading: m, answers: []))
            case .assistant:
                if let i = out.indices.last, !out[i].hasAnswer { out[i].answers.append(m) }
                else { out.append(Note(id: m.id, heading: nil, answers: [m])) }
            case .error:
                if let i = out.indices.last { out[i].answers.append(m) }
                else { out.append(Note(id: m.id, heading: nil, answers: [m])) }
            }
        }
        return out
    }

    static func id(containing messageID: UUID?, in notes: [Note]) -> UUID? {
        guard let messageID else { return nil }
        return notes.first { $0.id == messageID || $0.answers.contains { $0.id == messageID } }?.id
    }
}

/// Which answers have already been (or are being) written out, so a note scrolled off and back does not re-ink
/// and answers that were there before the card opened show up complete. `revealing` is published so the character
/// can look busy while ink is going down.
@MainActor
final class RevealLedger: ObservableObject {
    @Published private(set) var revealing = Set<UUID>()
    private var done = Set<UUID>()
    private var seeded = false

    var isRevealing: Bool { !revealing.isEmpty }
    func isDone(_ id: UUID) -> Bool { done.contains(id) }
    func begin(_ id: UUID) { done.insert(id); revealing.insert(id) }
    func end(_ id: UUID) { revealing.remove(id) }
    /// Called while the card's body is built: whatever is on the pad when it opens was written earlier, so it shows
    /// complete; only answers that land while the pad is open get inked in. `reset()` when the card goes away.
    func seed(_ transcript: [ChatMessage]) {
        guard !seeded else { return }
        seeded = true
        for m in transcript { done.insert(m.id) }
    }
    func reset() { seeded = false; if !revealing.isEmpty { revealing.removeAll() } }
}

// MARK: - The note

struct StickyNoteView: View {
    let note: Note
    let index: Int                  // position on the pad; drives the alternating tilt
    let isLatest: Bool
    let busy: Bool
    let status: String
    let suggestions: [String]       // paper tabs along the bottom edge (the latest answered note only)
    let ledger: RevealLedger
    var peek: MascotMood? = nil     // the character looking over the top edge (the newest note only)
    var animated = true
    let onSuggest: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    private var tilt: Double { index.isMultiple(of: 2) ? -Pad.tilt : Pad.tilt }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let peek { Peeker(mood: peek, busy: busy, animated: animated) }
            VStack(alignment: .leading, spacing: 0) {
                paper.zIndex(1)
                if !suggestions.isEmpty { tabs.padding(.top, -7).zIndex(0) }
            }
            .rotationEffect(.degrees(tilt), anchor: .top)
            .padding(.top, peek != nil ? Peeker.headroom : 0)
            .scaleEffect(isLatest ? 1 : 0.985, anchor: .top)
            .opacity(isLatest ? 1 : 0.94)
        }
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let h = note.heading { heading(h) }
            ForEach(note.answers) { a in answer(a) }
            if busy && !note.hasAnswer {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(status.isEmpty ? "Writing…" : status).font(.callout).foregroundStyle(Pad.inkSoft)
                }
                .padding(.top, 2)
                .id("busy")
            }
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 20, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoteSheetView(curl: 24, dark: scheme == .dark))
        .environment(\.colorScheme, .light)   // paper is always light, whatever the desk does
    }

    private func heading(_ m: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if m.role == .wand {
                Label("You pointed at", systemImage: "pencil.tip")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Pad.penInk)
            } else if m.role == .draft || m.role == .learned {
                Label(m.role == .draft ? "Learned by watching · draft" : "Learned by watching", systemImage: "eye")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Pad.penInk)
            }
            Text(m.text).font(HandFont.font(size: 18)).foregroundStyle(Pad.ink).textSelection(.enabled)
                .padding(.trailing, peek != nil ? 34 : 0)   // room for the character's chin
            InkLine(wobble: 0.6).stroke(Pad.ink.opacity(0.22), lineWidth: 1).frame(height: 3)
        }
    }

    @ViewBuilder
    private func answer(_ m: ChatMessage) -> some View {
        switch m.role {
        case .error:
            // red ink with a red rule down the margin: it stays on the note it belongs to, and cannot pass for an answer
            // (an overlay, not a stack sibling: a flexible rule would take whatever height the lazy stack proposes)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Pad.redInk).padding(.top, 4)
                Text(m.text).font(Pad.body).lineSpacing(Pad.lineSpacing).foregroundStyle(Pad.redInk).textSelection(.enabled)
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(Pad.redInk).frame(width: 2.5).padding(.vertical, 2) }
            .padding(.top, 2)
        default:
            RevealingText(message: m, ledger: ledger)
        }
    }

    /// Follow-ups as cream paper tabs whose top is tucked under the note's bottom edge; long ones wrap onto a second
    /// row that tucks under the first.
    private var tabs: some View {
        TabRow(spacing: 6, rowSpacing: -5) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                Button(s) { onSuggest(s) }.buttonStyle(PaperTabStyle()).disabled(busy).zIndex(Double(-i))
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The character behind the top-right corner of the newest note, looking down at what it is writing.
struct Peeker: View {
    var mood: MascotMood
    var busy: Bool
    var animated: Bool
    static let size: CGFloat = 50
    static let headroom: CGFloat = 30   // how far the note is pushed down to leave the character's face showing

    var body: some View {
        MascotView(mood: mood, lookAt: busy ? nil : CGPoint(x: -0.55, y: 0.8), size: Self.size, animated: animated, decorations: false)
            .frame(width: Self.size, height: Self.size)
            .offset(x: -24, y: -4)
    }
}

/// An assistant answer inked line by line (≈40 ms per line, 1.5 s at most) the first time it lands on the pad.
/// A click on the note finishes it at once; text selection is on once the ink is dry.
struct RevealingText: View {
    let message: ChatMessage
    let ledger: RevealLedger
    @Environment(\.padStatic) private var padStatic
    @State private var shown: Int
    @State private var timer: Timer?

    private let lines: [String]

    init(message: ChatMessage, ledger: RevealLedger) {
        self.message = message
        self.ledger = ledger
        lines = message.text.components(separatedBy: "\n")
        _shown = State(initialValue: ledger.isDone(message.id) ? Int.max : 0)
    }

    private var revealing: Bool { !padStatic && shown < lines.count }

    var body: some View {
        let visible = padStatic ? Int.max : shown
        Group {
            if revealing {
                Self.rendered(lines, visible: visible).contentShape(Rectangle()).onTapGesture { finish() }
            } else {
                Self.rendered(lines, visible: visible).textSelection(.enabled)
            }
        }
        .font(Pad.body).foregroundStyle(Pad.ink).lineSpacing(Pad.lineSpacing)
        .onAppear { start() }
        .onDisappear { finish() }
    }

    private func start() {
        guard !padStatic, !ledger.isDone(message.id) else { shown = Int.max; return }
        let n = lines.count
        guard n > 1 else { ledger.begin(message.id); ledger.end(message.id); shown = Int.max; return }
        ledger.begin(message.id)
        let step = min(0.04, 1.5 / Double(n))
        shown = 1
        let t = Timer(timeInterval: step, repeats: true) { t in
            MainActor.assumeIsolated {
                shown += 1
                if shown >= n { t.invalidate(); timer = nil; shown = Int.max; ledger.end(message.id) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func finish() {
        guard timer != nil else { return }
        timer?.invalidate(); timer = nil
        shown = Int.max
        ledger.end(message.id)
    }

    /// Inline Markdown line by line; a leading "- " / "* " becomes a bullet. Lines past `visible` are laid out but
    /// drawn in clear ink, so the note keeps its final height while the text appears; the line being written
    /// carries the nib at its end.
    static func rendered(_ lines: [String], visible: Int) -> Text {
        let inking = visible < lines.count
        let parts = lines.enumerated().map { i, raw -> Text in
            var line = raw
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "•  " + line.dropFirst(2) }
            var t: Text
            if let a = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { t = Text(a) } else { t = Text(line) }
            if inking, i == visible - 1 { t = t + Text(" ") + Text(Image(systemName: "pencil.tip")).foregroundColor(Pad.inkSoft) }
            return i < visible ? t : t.foregroundColor(.clear)
        }
        return parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + Text("\n") + $1 }
    }
}

// MARK: - Paper

/// The yellow sheet: a warm gradient lit from the top, the adhesive strip along the top edge, a darker sheet from the
/// pad peeking out behind, and a curl at the bottom-right corner with the shadow it throws.
struct NoteSheetView: View {
    var curl: CGFloat
    var dark: Bool
    var ruled = false

    var body: some View {
        ZStack {
            NoteSheet(curl: curl * 0.7)
                .fill(Pad.paperDeep)
                .offset(x: 1.5, y: 2)
            NoteSheet(curl: curl)
                .fill(LinearGradient(colors: [Pad.paperTop, Pad.paperBottom], startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)))
                .overlay {
                    // the glue strip: a hair paler and flatter, like the real thing
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.white.opacity(0.22)).frame(height: 15)
                        Rectangle().fill(Pad.paperEdge.opacity(0.10)).frame(height: 1)
                        Spacer(minLength: 0)
                    }
                    .clipShape(NoteSheet(curl: curl))
                }
                .overlay(NoteSheet(curl: curl).fill(RadialGradient(colors: [.white.opacity(0.14), .clear], center: UnitPoint(x: 0.2, y: 0.1), startRadius: 0, endRadius: 260)))
                .overlay { if ruled { RuledLines().clipShape(NoteSheet(curl: curl)) } }
                .overlay(NoteSheet(curl: curl).stroke(Pad.paperEdge.opacity(0.45), lineWidth: 0.8))
            CornerCurlView(curl: curl)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(dark ? 0.45 : 0.20), radius: 2, y: 2)
        .shadow(color: .black.opacity(dark ? 0.30 : 0.10), radius: 10, y: 8)
    }
}

/// Faint ruled lines, for the blank note.
struct RuledLines: View {
    var spacing: CGFloat = 23
    var top: CGFloat = 52
    var body: some View {
        GeometryReader { g in
            Path { p in
                var y = top
                while y < g.size.height - 12 { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y)); y += spacing }
            }
            .stroke(Pad.paperEdge.opacity(0.30), lineWidth: 0.8)
        }
    }
}

/// A rectangle with its bottom-right corner turned up (the curl area is cut away and drawn by `CornerCurlView`).
struct NoteSheet: Shape {
    var curl: CGFloat
    var animatableData: CGFloat { get { curl } set { curl = newValue } }
    func path(in r: CGRect) -> Path {
        let c = min(curl, r.width / 3, r.height / 3)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.maxX - c * 0.45, y: r.maxY - c * 0.45))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The turned-up corner: the flap's underside, bright at the crest and shading into the fold, over the shadow it casts.
struct CornerCurlView: View {
    var curl: CGFloat
    var body: some View {
        ZStack {
            CornerFlap(curl: curl).fill(Color.black.opacity(0.28)).blur(radius: 2.5).offset(x: -2, y: -1.5)
            CornerFlap(curl: curl)
                .fill(LinearGradient(stops: [.init(color: Color(red: 1.0, green: 0.99, blue: 0.90), location: 0),
                                             .init(color: Color(red: 1.0, green: 0.94, blue: 0.66), location: 0.55),
                                             .init(color: Color(red: 0.88, green: 0.72, blue: 0.32), location: 1)],
                                     startPoint: .bottomTrailing, endPoint: .topLeading))
            CornerFlap(curl: curl).stroke(Color.white.opacity(0.6), lineWidth: 0.6)
        }
    }
}

struct CornerFlap: Shape {
    var curl: CGFloat
    func path(in r: CGRect) -> Path {
        let c = min(curl, r.width / 3, r.height / 3)
        let a = CGPoint(x: r.maxX, y: r.maxY - c)          // where the fold meets the right edge
        let b = CGPoint(x: r.maxX - c, y: r.maxY)          // …and the bottom edge
        let tip = CGPoint(x: r.maxX - c * 0.92, y: r.maxY - c * 0.92)
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: CGPoint(x: r.maxX - c * 0.45, y: r.maxY - c * 0.45))
        p.addQuadCurve(to: tip, control: CGPoint(x: r.maxX - c * 1.05, y: r.maxY - c * 0.35))
        p.addQuadCurve(to: a, control: CGPoint(x: r.maxX - c * 0.35, y: r.maxY - c * 1.05))
        p.closeSubpath()
        return p
    }
}

/// A pen stroke across the width: a hair wobbly so it reads as drawn rather than ruled.
struct InkLine: Shape {
    var wobble: CGFloat = 1
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.midY
        p.move(to: CGPoint(x: r.minX, y: y + wobble * 0.4))
        p.addCurve(to: CGPoint(x: r.midX, y: y - wobble * 0.3),
                   control1: CGPoint(x: r.minX + r.width * 0.2, y: y - wobble), control2: CGPoint(x: r.midX - r.width * 0.15, y: y + wobble * 0.6))
        p.addCurve(to: CGPoint(x: r.maxX, y: y + wobble * 0.2),
                   control1: CGPoint(x: r.midX + r.width * 0.2, y: y - wobble * 0.9), control2: CGPoint(x: r.maxX - r.width * 0.15, y: y + wobble * 0.8))
        return p
    }
}

/// A suggestion as a small paper tab stuck to the note's bottom edge: its top is tucked under the sheet.
struct PaperTabStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Pad.ink)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.top, 13).padding(.bottom, 7)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .fill(configuration.isPressed ? Pad.paperBottom : Pad.tabPaper)
                    .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).strokeBorder(Pad.tabEdge.opacity(0.9), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.22), radius: 2.5, y: 2)
            )
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}

/// Lays tabs out left to right and wraps onto another row when they do not fit, so a long suggestion never
/// truncates or scrolls; with a negative `rowSpacing` and descending zIndex the next row tucks under the one above.
struct TabRow: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + rowSpacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + rowSpacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
