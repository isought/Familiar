import Foundation

/// How thumbs, explanations and what the person already did make one item's label. A thumb always beats a guess and
/// the latest thumb wins; clearing it goes back to the guess. Pure, so the card, the rest and the numbers agree.
enum AttentionLabels {
    /// An explanation keeps at most this many characters.
    static let explanationLimit = 2_000

    enum Thumb: CaseIterable { case up, down }

    /// The label a tap gives. Up goes yes, strong yes, then clear; down mirrors it. The other thumb switches sides.
    static func next(current: AttentionLabelValue?, tapped: Thumb) -> AttentionLabelValue {
        switch (tapped, current) {
        case (.up, .yes): return .strongYes
        case (.up, .strongYes): return .clear
        case (.up, _): return .yes
        case (.down, .no): return .strongNo
        case (.down, .strongNo): return .clear
        case (.down, _): return .no
        }
    }

    static func weight(_ value: AttentionLabelValue) -> Int {
        switch value {
        case .yes: return 1
        case .strongYes: return 2
        case .no: return -1
        case .strongNo: return -2
        case .explain, .clear: return 0
        }
    }

    /// One item's label as it stands, folded from its `label` and `implicit` events in the order they were written.
    struct Effective: Equatable {
        /// The thumb in effect: yes, no, strong_yes or strong_no.
        private(set) var explicit: AttentionLabelValue?
        /// What the person did that still stands, oldest first.
        private(set) var signals: [AttentionSignal] = []
        /// Words the person added; they never change the label.
        private(set) var explanation: String?

        /// The latest thing the person did that still stands, which decides the label when no thumb does.
        var guess: AttentionSignal? { signals.last }

        /// The label as a later event records it for `prior`.
        var state: AttentionPrior {
            switch explicit {
            case .yes: return .yes
            case .strongYes: return .strongYes
            case .no: return .no
            case .strongNo: return .strongNo
            case .explain, .clear, nil:
                guard let yes = guess?.countsAsYes else { return .notSet }
                return yes ? .guessYes : .guessNo
            }
        }

        /// True for a yes, false for a no, nil when neither a thumb nor a guess says.
        var isYes: Bool? {
            switch state {
            case .yes, .strongYes, .guessYes: return true
            case .no, .strongNo, .guessNo: return false
            case .notSet: return nil
            }
        }

        var isGuessed: Bool { [.guessYes, .guessNo].contains(state) }

        mutating func add(_ value: AttentionLabelValue, text: String?) {
            switch value {
            case .yes, .no, .strongYes, .strongNo: explicit = value
            case .clear: explicit = nil
            case .explain:
                let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                explanation = text.isEmpty ? nil : text
            }
        }

        /// A retract takes back the latest signal of its kind. A card is kept or filed away, never both, so a new
        /// decision replaces the one before it: after Ignore, Undo back to "I'll do it", then Return to review
        /// folder, nothing is left to guess from.
        mutating func add(_ signal: AttentionSignal, retracts: AttentionSignal?) {
            switch signal {
            case .retract:
                if let retracts, let index = signals.lastIndex(of: retracts) { signals.remove(at: index) }
            case .mine, .ignored:
                signals.removeAll { $0 == .mine || $0 == .ignored }
                signals.append(signal)
            case .optionTapped, .contextRequested, .handled, .adjusted:
                signals.append(signal)
            }
        }
    }
}

extension AttentionSignal {
    /// Choosing an option or asking for context, keeping the card, marking it handled and adjusting it say yes;
    /// ignoring it says no. A retract says neither.
    var countsAsYes: Bool? {
        switch self {
        case .optionTapped, .contextRequested, .mine, .handled, .adjusted: return true
        case .ignored: return false
        case .retract: return nil
        }
    }
}
