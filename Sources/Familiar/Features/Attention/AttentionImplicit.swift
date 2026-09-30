import Foundation

/// What the person did to cards between two saved workspaces that says whether a card was worth showing. Only the
/// person's own actions count: work moving a card into and out of With Noteling, evidence resolving it, new or
/// updated generated cards, samples and hand-written notes never do. Pure, so the card and chat paths count the same.
enum AttentionImplicit {
    struct Change: Equatable {
        var cardID: UUID
        var key: String
        var signal: AttentionSignal
        var retracts: AttentionSignal? = nil
        var optionIndex: Int? = nil
        var optionMode: MorningActionMode? = nil
    }

    /// Each change once, card by card in the new workspace's order.
    static func signals(from old: MorningWorkspace, to new: MorningWorkspace) -> [Change] {
        let before = Dictionary(old.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldWork = Set(old.workItems.map(\.id))
        var changes: [Change] = []
        for card in new.cards {
            guard let previous = before[card.id], !previous.isSample, !card.isSample,
                  let was = previous.tracking, let tracking = card.tracking else { continue }
            func add(_ signal: AttentionSignal, retracts: AttentionSignal? = nil, optionIndex: Int? = nil, optionMode: MorningActionMode? = nil) {
                changes.append(Change(cardID: card.id, key: tracking.key, signal: signal, retracts: retracts,
                                      optionIndex: optionIndex, optionMode: optionMode))
            }
            // Handing work over and its end move a card through With Noteling on their own.
            if previous.disposition != card.disposition, previous.disposition != .delegated, card.disposition != .delegated {
                switch (previous.disposition, card.disposition) {
                case (_, .mine): add(.mine)
                case (_, .ignored): add(.ignored)
                case (.mine, .unreviewed): add(.retract, retracts: .mine)
                case (.ignored, .unreviewed): add(.retract, retracts: .ignored)
                default: break
                }
            }
            // Evidence resolves a card without the person, and leaves resolvedByUser false.
            if !was.resolvedByUser && tracking.resolvedByUser { add(.handled) }
            if was.resolvedByUser && !tracking.resolvedByUser { add(.retract, retracts: .handled) }
            if trimmed(previous.personalContext) != trimmed(card.personalContext) || (!was.userEdited && tracking.userEdited) {
                add(.adjusted)
            }
            // Choosing an option swaps it to the front, so its place is read from the card before the tap.
            for item in new.workItems where item.cardID == card.id && !oldWork.contains(item.id) {
                switch item.kind {
                case .action: add(.optionTapped, optionIndex: previous.options.firstIndex { $0.id == item.action.id }, optionMode: item.action.mode)
                case .context: add(.contextRequested)
                }
            }
        }
        return changes
    }

    private static func trimmed(_ text: String?) -> String { text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

extension AttentionCardContext {
    /// The card as it stands at `at`. Its age counts from when a card step made it.
    init(_ card: MorningCard, at: Date) {
        let made = card.tracking.map { $0.changes.first?.at ?? $0.firstSeenAt } ?? card.updatedAt
        self.init(cardID: card.id, disposition: card.disposition, displayDisposition: card.displayDisposition,
            optionCount: card.options.count, optionModes: card.options.map(\.mode),
            cardAgeHours: max(0, at.timeIntervalSince(made) / 3_600), userEdited: card.tracking?.userEdited ?? false,
            hasPersonalContext: !(card.personalContext ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            createdByRun: card.tracking?.changes.first { $0.runID != nil }?.runID)
    }
}
