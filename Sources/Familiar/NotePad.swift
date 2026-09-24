import AppKit
import SwiftUI

// The chat card drawn as a pad of sticky notes: each exchange is one yellow note the character writes on,
// stuck to a warm desk-coloured pad. Colours, fonts, the note itself and the progressive "ink" reveal live here;
// `BubbleView` (BubblePanel.swift) composes them with the header, input and footer.

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
             : LinearGradient(colors: [Color(red: 0.925, green: 0.885, blue: 0.815), Color(red: 0.875, green: 0.82, blue: 0.73)], startPoint: .top, endPoint: .bottom)
    }
    /// The pad's glued binding strip behind the header.
    static func binding(_ dark: Bool) -> Color { dark ? Color(red: 0.11, green: 0.095, blue: 0.08) : Color(red: 0.83, green: 0.765, blue: 0.655) }
    static func bindingEdge(_ dark: Bool) -> Color { dark ? .black.opacity(0.5) : Color(red: 0.62, green: 0.53, blue: 0.40).opacity(0.55) }
    /// Text and icons drawn directly on the desk (header, footer).
    static func deskInk(_ dark: Bool) -> Color { dark ? Color(red: 0.93, green: 0.90, blue: 0.84) : Color(red: 0.24, green: 0.19, blue: 0.13) }
    static func deskInkSoft(_ dark: Bool) -> Color { deskInk(dark).opacity(0.62) }

    static let bodySize: CGFloat = 13.5
    static let body = Font.system(size: bodySize)
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

    /// Groups the flat transcript into notes: every user/pen message starts one; an answer or error joins the note
    /// above it when that note is still blank, otherwise it gets a note of its own.
    static func group(_ transcript: [ChatMessage]) -> [Note] {
        var out: [Note] = []
        for m in transcript {
            switch m.role {
            case .user, .wand:
                out.append(Note(id: m.id, heading: m, answers: []))
            case .assistant, .error:
                if let i = out.indices.last, out[i].answers.isEmpty { out[i].answers.append(m) }
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
/// and answers that were there before the card opened show up complete.
@MainActor
final class RevealLedger {
    private(set) var done = Set<UUID>()
    private var seeded = false
    func mark(_ id: UUID) { done.insert(id) }
    func isDone(_ id: UUID) -> Bool { done.contains(id) }
    /// Called while the card's body is built: whatever is on the pad when it opens was written earlier, so it shows
    /// complete; only answers that land while the pad is open get inked in. `reset()` when the card goes away.
    func seed(_ transcript: [ChatMessage]) {
        guard !seeded else { return }
        seeded = true
        for m in transcript { done.insert(m.id) }
    }
    func reset() { seeded = false }
}

// MARK: - The note

struct StickyNoteView: View {
    let note: Note
    let index: Int                  // position on the pad; drives the alternating tilt
    let isLatest: Bool
    let busy: Bool
    let status: String
    let suggestions: [String]       // paper tabs along the bottom edge (the latest note only)
    let ledger: RevealLedger
    let onSuggest: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    private var tilt: Double { index.isMultiple(of: 2) ? -1.2 : 1.3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paper.zIndex(1)
            if !suggestions.isEmpty { tabs.padding(.top, -7).zIndex(0) }
        }
        .scaleEffect(isLatest ? 1 : 0.985)
        .opacity(isLatest ? 1 : 0.94)
        .rotationEffect(.degrees(tilt))
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let h = note.heading { heading(h) }
            ForEach(note.answers) { a in answer(a) }
            if busy && note.answers.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status.isEmpty ? "Writing…" : status).font(.caption).foregroundStyle(Pad.inkSoft)
                }
                .padding(.top, 2)
                .id("busy")
            }
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 20, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoteSheetView(curl: 24, dark: scheme == .dark))
        .overlay(alignment: .topLeading) { Tape().offset(x: 22, y: -6) }
        .padding(.top, 6)   // room for the tape
        .environment(\.colorScheme, .light)   // paper is always light, whatever the desk does
    }

    private func heading(_ m: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if m.role == .wand {
                    Image(systemName: "pencil.tip").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pad.penInk)
                        .help("Picked with the pen")
                }
                Text(m.text).font(HandFont.font(size: 17)).foregroundStyle(Pad.ink).textSelection(.enabled)
            }
            InkLine(wobble: 0.6).stroke(Pad.ink.opacity(0.22), lineWidth: 1).frame(height: 3)
        }
    }

    @ViewBuilder
    private func answer(_ m: ChatMessage) -> some View {
        switch m.role {
        case .error:
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Pad.redInk).padding(.top, 2)
                    Text(m.text).font(Pad.body).foregroundStyle(Pad.redInk).textSelection(.enabled)
                }
                InkLine(wobble: 1.2).stroke(Pad.redInk.opacity(0.85), lineWidth: 1.5).frame(height: 4).padding(.leading, 18)
            }
        default:
            RevealingText(message: m, ledger: ledger)
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { onSuggest(s) }.buttonStyle(PaperTabStyle()).disabled(busy)
                }
            }
            .padding(.leading, 14).padding(.trailing, 12).padding(.bottom, 6)
        }
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
        .font(Pad.body).foregroundStyle(Pad.ink).lineSpacing(3)
        .onAppear { start() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func start() {
        guard !padStatic, !ledger.isDone(message.id) else { shown = Int.max; return }
        ledger.mark(message.id)
        let n = lines.count
        guard n > 0 else { shown = Int.max; return }
        let step = min(0.04, 1.5 / Double(n))
        shown = 1
        let t = Timer(timeInterval: step, repeats: true) { t in
            MainActor.assumeIsolated {
                shown += 1
                if shown >= n { t.invalidate(); timer = nil; shown = Int.max }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        shown = Int.max
    }

    /// Inline Markdown line by line; lines past `visible` are laid out but drawn in clear ink, so the note
    /// keeps its final height while the text appears.
    static func rendered(_ lines: [String], visible: Int) -> Text {
        let parts = lines.enumerated().map { i, line -> Text in
            let t: Text
            if let a = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { t = Text(a) } else { t = Text(line) }
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
                .overlay(NoteSheet(curl: curl).fill(RadialGradient(colors: [.white.opacity(0.22), .clear], center: UnitPoint(x: 0.2, y: 0.1), startRadius: 0, endRadius: 260)))
                .overlay(NoteSheet(curl: curl).fill(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.10), location: 0.42), .init(color: .clear, location: 0.5), .init(color: Pad.paperEdge.opacity(0.06), location: 0.78), .init(color: .clear, location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)))   // a faint sheen, like light across the fibres
                .overlay(NoteSheet(curl: curl).stroke(Pad.paperEdge.opacity(0.45), lineWidth: 0.8))
            CornerCurlView(curl: curl)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(dark ? 0.45 : 0.20), radius: 6, x: 0, y: 3)
        .shadow(color: Color(red: 0.55, green: 0.42, blue: 0.10).opacity(dark ? 0.0 : 0.16), radius: 1.5, y: 1)
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

/// A short strip of translucent tape holding the note down.
struct Tape: View {
    var body: some View {
        Rectangle()
            .fill(Color(red: 1.0, green: 0.98, blue: 0.92).opacity(0.55))
            .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 0.5))
            .overlay(LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing))
            .frame(width: 42, height: 12)
            .shadow(color: .black.opacity(0.12), radius: 0.8, y: 0.8)
            .rotationEffect(.degrees(-4))
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
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Pad.ink)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.top, 13).padding(.bottom, 6)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .fill(configuration.isPressed ? Pad.paperBottom : Pad.tabPaper)
                    .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).strokeBorder(Pad.tabEdge.opacity(0.7), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1.5)
            )
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}
