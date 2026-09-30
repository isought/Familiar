import SwiftUI

/// Two small thumbs on a card's header line: was this worth the person's notice? Tapping the same thumb again means
/// very, then clears it; the other thumb switches sides. A guess from what the person did shows pale, and its hover
/// names the action it came from. Thumbs only label the item: they never change the card, its folder or its work.
/// Only cards from a source the test reads have them.
struct AttentionThumbs: View {
    /// How far the hit areas reach above and below the header line.
    static let overhang: CGFloat = 2
    @ObservedObject var ledger: AttentionLedger
    let card: MorningCard
    var via: AttentionVia = .card

    /// Nil for a card the test does not label.
    var key: String? { ledger.labelKey(for: card) }

    var body: some View {
        if let key {
            let label = ledger.effective(for: key)
            HStack(spacing: 0) {
                thumb(.up, label)
                thumb(.down, label)
                if let explanation = label.explanation {
                    Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(Pad.penInk)
                        .frame(width: 16, height: 18).help(explanation).accessibilityLabel("Your explanation: \(explanation)")
                }
            }
            // The hit areas are a little taller than the header line; they overhang it rather than push the card down.
            .padding(.vertical, -Self.overhang)
        }
    }

    func tap(_ thumb: AttentionLabels.Thumb) {
        guard let key else { return }
        ledger.tapThumb(key: key, card: card, thumb: thumb, via: via)
    }

    private enum Mark { case off, guessed, on, strong }

    private func thumb(_ thumb: AttentionLabels.Thumb, _ label: AttentionLabels.Effective) -> some View {
        let mark = Self.mark(thumb, label.state)
        let symbol = thumb == .up ? "hand.thumbsup" : "hand.thumbsdown"
        return Button { tap(thumb) } label: {
            ZStack {
                if mark == .strong {
                    // Two overlapped thumbs; a sliver of paper keeps the front one apart from the one behind.
                    Image(systemName: symbol + ".fill").opacity(0.55).offset(x: -2.5)
                    Image(systemName: symbol + ".fill").shadow(color: Pad.fieldPaper, radius: 0, x: -1).offset(x: 2.5)
                } else {
                    Image(systemName: mark == .off ? symbol : symbol + ".fill")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(mark == .off ? Pad.inkSoft.opacity(0.45) : Pad.penInk.opacity(mark == .guessed ? 0.35 : 1))
            .frame(width: 22, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint(thumb, mark: mark, guess: label.guess))
        .accessibilityLabel(thumb == .up ? "Worth my notice" : "Not worth my notice")
        .accessibilityValue(Self.value(thumb, mark))
    }

    private static func mark(_ thumb: AttentionLabels.Thumb, _ state: AttentionPrior) -> Mark {
        switch (thumb, state) {
        case (.up, .yes), (.down, .no): return .on
        case (.up, .strongYes), (.down, .strongNo): return .strong
        case (.up, .guessYes), (.down, .guessNo): return .guessed
        default: return .off
        }
    }

    private func hint(_ thumb: AttentionLabels.Thumb, mark: Mark, guess: AttentionSignal?) -> String {
        switch (thumb, mark) {
        case (_, .guessed):
            return "Counted as \(thumb == .up ? "yes" : "no") because \(guess.map { Self.reason($0, card: card) } ?? "of what you did"). Tap to confirm."
        case (.up, .strong): return "Very worth my notice. Tap again to clear."
        case (.down, .strong): return "Not at all worth my notice. Tap again to clear."
        case (.up, _): return "Worth my notice. Tap again for very."
        case (.down, _): return "Not worth my notice. Tap again for not at all."
        }
    }

    /// What the person did that the guess came from, in the card's own words where it has them.
    static func reason(_ signal: AttentionSignal, card: MorningCard) -> String {
        switch signal {
        case .optionTapped: return "you chose one of its options"
        case .contextRequested: return card.contextAction.map { "you chose “\($0.title)”" } ?? "you asked for more context"
        case .mine: return "you chose “I’ll do it”"
        case .ignored: return "you chose “Ignore”"
        case .handled: return "you chose “I’ve handled this”"
        case .adjusted: return "you adjusted it"
        case .retract: return "of what you did"
        }
    }

    private static func value(_ thumb: AttentionLabels.Thumb, _ mark: Mark) -> String {
        switch mark {
        case .on: return "yes"
        case .strong: return "strongly"
        case .guessed: return thumb == .up ? "guessed yes" : "guessed"
        case .off: return "not set"
        }
    }
}

/// "Let me explain…" in a card's ⋯ menu, or "Edit your explanation…" once there are words to edit.
struct AttentionExplainMenuItem: View {
    @ObservedObject var ledger: AttentionLedger
    let card: MorningCard

    var body: some View {
        if let key = ledger.labelKey(for: card) {
            Button(ledger.explanation(for: key) == nil ? "Let me explain…" : "Edit your explanation…") { ledger.beginExplaining(key) }
        }
    }
}

/// One line under a card's meaning, only while the person explains why it was worth their notice, or not. It never
/// changes the thumbs. It is inline rather than a popover so it can be rendered and checked.
struct AttentionExplainSlot: View {
    @ObservedObject var ledger: AttentionLedger
    let card: MorningCard
    @State private var text = ""
    @FocusState private var focused: Bool

    var isOpen: Bool { ledger.labelKey(for: card).map { $0 == ledger.explaining } ?? false }

    var body: some View {
        if isOpen {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Let me explain").foregroundStyle(Pad.inkSoft)
                    TextField("Why is this worth your notice, or not?", text: $text)
                        .textFieldStyle(.roundedBorder).focused($focused).onSubmit { save(text) }
                    Button("Save") { save(text) }.foregroundStyle(Pad.penInk)
                    Button("Cancel") { ledger.cancelExplaining() }.foregroundStyle(Pad.penInk)
                }
                // A save that could not be written keeps the field open with the words in it.
                if let error = ledger.error { Text(error).foregroundStyle(Pad.redInk).textSelection(.enabled) }
            }
            .buttonStyle(.plain).font(.system(size: 12))
            .onAppear {
                text = card.tracking.flatMap { ledger.explanation(for: $0.key) } ?? ""
                focused = true
            }
            .onExitCommand { ledger.cancelExplaining() }
            // Leaving the card puts the field away; its words were either saved or meant to be dropped.
            .onDisappear { if isOpen { ledger.cancelExplaining() } }
        }
    }

    /// Saves up to 2000 characters and closes the field once they are written.
    func save(_ text: String) {
        guard isOpen, let key = card.tracking?.key else { return }
        ledger.explain(key: key, card: card, text: text, via: .card)
    }
}
