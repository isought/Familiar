import Combine
import Foundation

enum MorningStoreError: LocalizedError {
    case invalid(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let explanation), .unavailable(let explanation): return explanation
        }
    }
}

/// Domain transactions publish only after the repository commits the complete workspace.
@MainActor
final class MorningStore: ObservableObject {
    @Published private(set) var workspace = MorningWorkspace()
    @Published private(set) var error: String?
    @Published var queueMessage: String?

    var folders: [MorningFolder] { workspace.folders }
    var people: [MorningPerson] { workspace.people }
    var cards: [MorningCard] { workspace.cards }
    var workItems: [MorningWorkItem] { workspace.workItems }

    private let repository: any MorningRepository
    private var blockedReason: String?

    convenience init(directory: URL = Config.dir.appendingPathComponent("morning")) {
        self.init(repository: SQLiteMorningRepository(directory: directory))
    }

    init(repository: any MorningRepository) {
        self.repository = repository
        do {
            guard let stored = try repository.load() else {
                try repository.save(workspace)
                return
            }
            var loaded = stored.workspace
            try Self.validate(loaded)
            workspace = loaded
            var recovered = false
            for index in loaded.workItems.indices {
                guard loaded.workItems[index].status == .running || loaded.workItems[index].status == .needsAttention else { continue }
                loaded.workItems[index].status = .interrupted
                loaded.workItems[index].finishedAt = Date()
                loaded.workItems[index].progress = "Noteling closed while this was in progress. Check what happened before trying again."
                Self.restoreCard(after: loaded.workItems[index], in: &loaded)
                recovered = true
            }
            if recovered || stored.requiresSave {
                try repository.save(loaded)
                workspace = loaded
            }
        } catch {
            let reason = "Morning files could not be opened safely. \(error.localizedDescription) Changes are paused to protect your saved data."
            blockedReason = reason
            self.error = reason
        }
    }

    func savePerson(_ person: MorningPerson) throws {
        try transact { next in
            var person = person
            person.name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !person.name.isEmpty else { throw MorningStoreError.invalid("Give this person a name.") }
            if person.isMe {
                for index in next.people.indices { next.people[index].isMe = false }
            }
            Self.upsert(person, in: &next.people)
        }
    }

    func saveFolder(_ folder: MorningFolder) throws {
        try transact { next in
            var folder = folder
            folder.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folder.name.isEmpty else { throw MorningStoreError.invalid("Give this folder a name.") }
            Self.upsert(folder, in: &next.folders)
        }
    }

    func saveCard(_ card: MorningCard) throws {
        try transact { next in
            var card = card
            card.title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous = next.cards.first(where: { $0.id == card.id }) {
                // Decisions and sample provenance are not editable form fields.
                card.disposition = previous.disposition
                card.isSample = previous.isSample
                if var tracking = previous.tracking {
                    tracking.userEdited = true
                    tracking.changes.append(CardChange(at: Date(), message: "You adjusted this card."))
                    card.tracking = tracking
                    card.personalContext = previous.personalContext
                    card.sources = previous.sources
                }
            } else {
                card.disposition = .unreviewed
            }
            card.updatedAt = Date()
            Self.upsert(card, in: &next.cards)
        }
    }

    func setDisposition(cardID: UUID, to disposition: MorningCardDisposition) throws {
        try transact { next in
            guard [.unreviewed, .ignored, .mine].contains(disposition) else {
                throw MorningStoreError.invalid("Hand the file to Noteling to start work; its result will update the file automatically.")
            }
            guard let index = next.cards.firstIndex(where: { $0.id == cardID }) else {
                throw MorningStoreError.invalid("This file could not be found.")
            }
            guard !next.workItems.contains(where: { $0.cardID == cardID && $0.status.isPending }) else {
                throw MorningStoreError.invalid("This file already has work waiting or in progress. Stop that work before changing its decision.")
            }
            next.cards[index].disposition = disposition
            next.cards[index].updatedAt = Date()
        }
    }

    @discardableResult
    func enqueue(cardID: UUID, kind: MorningWorkKind = .action) throws -> MorningWorkItem {
        var accepted: MorningWorkItem?
        try transact { next in
            guard let index = next.cards.firstIndex(where: { $0.id == cardID }) else {
                throw MorningStoreError.invalid("This file could not be found.")
            }
            guard !next.workItems.contains(where: { $0.cardID == cardID && $0.status.isPending }) else {
                throw MorningStoreError.invalid("This file already has work waiting or in progress.")
            }
            let card = next.cards[index]
            guard !card.isResolved else { throw MorningStoreError.invalid("This matter is resolved. Reopen it before handing over more work.") }
            let action: MorningAction
            switch kind {
            case .action: action = card.action
            case .context:
                guard let contextAction = card.contextAction else {
                    throw MorningStoreError.invalid("This file does not have a context-gathering action yet.")
                }
                action = contextAction
            }
            var people = card.personIDs.compactMap { id in next.people.first(where: { $0.id == id }) }
            if let me = next.people.first(where: \.isMe), !people.contains(where: { $0.id == me.id }) {
                people.append(me)
            }
            let item = MorningWorkItem(cardID: card.id, card: card, people: people, action: action, kind: kind)
            next.workItems.append(item)
            if kind == .action { next.cards[index].disposition = .delegated }
            next.cards[index].updatedAt = Date()
            accepted = item
        }
        // The transaction either assigned this value and committed it or threw.
        return accepted!
    }

    func updateWork(id: UUID, status: MorningWorkStatus, result: String? = nil, progress: String? = nil) throws {
        try transact { next in
            guard let index = next.workItems.firstIndex(where: { $0.id == id }) else {
                throw MorningStoreError.invalid("This work item could not be found.")
            }
            let previous = next.workItems[index].status
            guard previous.isPending || previous == status else {
                throw MorningStoreError.invalid("This work has finished. Review its result before handing over a new action.")
            }
            guard status != .queued || previous == .queued else {
                throw MorningStoreError.invalid("Work that has already started cannot be queued again automatically.")
            }
            next.workItems[index].status = status
            if let result { next.workItems[index].result = result }
            if let progress { next.workItems[index].progress = progress }
            if (status == .running || status == .needsAttention), next.workItems[index].startedAt == nil {
                next.workItems[index].startedAt = Date()
            }
            if !status.isPending, next.workItems[index].finishedAt == nil {
                next.workItems[index].finishedAt = Date()
            }
            // A late progress/result update on an old run must not re-file a newer decision.
            guard previous.isPending else { return }
            let item = next.workItems[index]
            guard item.kind == .action, let cardIndex = next.cards.firstIndex(where: { $0.id == item.cardID }) else { return }
            if status == .completed {
                if next.cards[cardIndex].tracking != nil {
                    // A prepared result is not evidence that the external matter is resolved.
                    Self.restoreCard(after: item, in: &next)
                } else if next.cards[cardIndex].disposition == .delegated {
                    next.cards[cardIndex].disposition = .completed
                    next.cards[cardIndex].updatedAt = Date()
                }
            } else if !status.isPending {
                Self.restoreCard(after: item, in: &next)
            }
        }
    }

    func cancelQueued(id: UUID) throws {
        guard let item = workspace.workItems.first(where: { $0.id == id }), item.status == .queued else {
            let failure = MorningStoreError.invalid("Only waiting work can be removed from the queue. Use Stop for work already in progress.")
            error = failure.localizedDescription
            throw failure
        }
        try updateWork(id: id, status: .cancelled, progress: "Removed from the queue.")
    }

    func returnToFolder(cardID: UUID) throws {
        try setDisposition(cardID: cardID, to: .unreviewed)
    }

    func loadSamples() throws {
        guard !workspace.samplesLoaded else { return }
        try transact { next in MorningSamples.append(to: &next) }
    }

    @discardableResult
    func applyCardGeneration(observations: [CardObservation], proposals: [CardProposal], runIDs: [UUID], at: Date = Date()) throws -> CardGenerationSummary {
        let previous = Set((workspace.cardGenerations ?? []).flatMap(\.runIDs))
        guard runIDs.contains(where: { !previous.contains($0) }) else { return CardGenerationSummary() }
        var result = CardGenerationSummary()
        try transact { next in
            result = try MorningCardReconciliation.apply(observations: observations, proposals: proposals, runIDs: runIDs, at: at, to: &next)
        }
        return result
    }

    func setCardResolution(cardID: UUID, resolved: Bool) throws {
        try transact { next in
            try MorningCardReconciliation.setResolution(cardID: cardID, resolved: resolved, at: Date(), in: &next)
        }
    }

    func updateCardContext(cardID: UUID, context: String, actionInstruction: String? = nil) throws {
        try transact { next in
            guard let index = next.cards.firstIndex(where: { $0.id == cardID }) else {
                throw MorningStoreError.invalid("This file could not be found.")
            }
            if let actionInstruction {
                let instruction = actionInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instruction.isEmpty else { throw MorningStoreError.invalid("Describe what Noteling should do.") }
                next.cards[index].action.instruction = instruction
            }
            next.cards[index].personalContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
            next.cards[index].tracking?.userEdited = true
            next.cards[index].tracking?.changes.append(CardChange(at: Date(), message: "You added context or adjusted the action."))
            next.cards[index].updatedAt = Date()
        }
    }

    func trackedItems(sourceID: UUID) -> [TrackedSourceItem] {
        cards.compactMap { card in
            guard let tracking = card.tracking, tracking.sourceID == sourceID,
                  !card.isResolved, card.disposition != .ignored else { return nil }
            let source = card.sources.first
            return TrackedSourceItem(key: tracking.itemKey, title: source?.title ?? card.title,
                details: source?.excerpt ?? card.summary, url: source?.url ?? "", identityEvidence: tracking.identityEvidence)
        }
    }

    private func transact(_ change: (inout MorningWorkspace) throws -> Void) throws {
        do {
            if let blockedReason { throw MorningStoreError.unavailable(blockedReason) }
            var next = workspace
            try change(&next)
            try Self.validate(next)
            try repository.save(next)
            workspace = next
            error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private static func restoreCard(after item: MorningWorkItem, in workspace: inout MorningWorkspace) {
        guard item.kind == .action, let index = workspace.cards.firstIndex(where: { $0.id == item.cardID }) else { return }
        guard workspace.cards[index].disposition == .delegated else { return }
        workspace.cards[index].disposition = item.card.disposition == .mine ? .mine : .unreviewed
        workspace.cards[index].updatedAt = Date()
    }

    private static func upsert<T: Identifiable>(_ value: T, in values: inout [T]) where T.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
        else { values.append(value) }
    }

    private static func validate(_ value: MorningWorkspace) throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw MorningStoreError.invalid(message) }
        }
        func hasText(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func unique(_ ids: [UUID]) -> Bool { Set(ids).count == ids.count }
        func validateAction(_ action: MorningAction, sample: Bool) throws {
            try require(hasText(action.title), "Give the proposed action a title.")
            try require(hasText(action.instruction), "Describe what Noteling should do.")
            try require(!sample || action.mode == .prepare, "Sample files can only prepare local results; they cannot perform actions in your apps.")
        }
        let folderIDs = Set(value.folders.map(\.id)), personIDs = Set(value.people.map(\.id))
        try require(value.version == 1, "This morning workspace version is not supported.")
        try require(unique(value.folders.map(\.id)) && unique(value.people.map(\.id)) && unique(value.cards.map(\.id)) && unique(value.workItems.map(\.id)), "The morning workspace contains duplicate identifiers.")
        try require(value.folders.allSatisfy { hasText($0.name) }, "Every folder needs a name.")
        try require(value.people.allSatisfy { hasText($0.name) }, "Every person needs a name.")
        try require(value.people.filter(\.isMe).count <= 1, "Only one person can be marked as you.")
        for card in value.cards {
            try require(hasText(card.title), "Give this file a title.")
            try require(folderIDs.contains(card.folderID), "Choose an existing folder for this file.")
            try require(unique(card.personIDs) && Set(card.personIDs).isSubset(of: personIDs), "One of this file’s people could not be found.")
            try require(unique(card.sources.map(\.id)), "This file contains duplicate source identifiers.")
            try validateAction(card.action, sample: card.isSample)
            if let contextAction = card.contextAction { try validateAction(contextAction, sample: card.isSample) }
        }
        let tracked = value.cards.compactMap(\.tracking)
        try require(Set(tracked.map(\.key)).count == tracked.count, "Two generated cards refer to the same tracked source item.")
        for tracking in tracked {
            try require(hasText(tracking.itemKey) && hasText(tracking.identityEvidence), "A generated card needs its item identity and matching evidence.")
            try require(tracking.firstSeenAt.timeIntervalSince1970.isFinite && tracking.lastSeenAt.timeIntervalSince1970.isFinite && tracking.firstSeenAt <= tracking.lastSeenAt, "A generated card has invalid observation times.")
            try require(!tracking.resolvedByUser || tracking.resolution == .resolved, "A user-resolved card has inconsistent state.")
            try require(tracking.resolution != .resolved || hasText(tracking.resolutionEvidence), "A resolved card needs supporting evidence.")
        }
        let generations = value.cardGenerations ?? []
        try require(unique(generations.map(\.id)), "Card generation contains duplicate receipts.")
        try require(generations.allSatisfy { !$0.runIDs.isEmpty && unique($0.runIDs) && $0.completedAt.timeIntervalSince1970.isFinite }, "Card generation contains an invalid run receipt.")
        var pendingCards: Set<UUID> = []
        for item in value.workItems {
            guard let card = value.cards.first(where: { $0.id == item.cardID }) else {
                throw MorningStoreError.invalid("A work item refers to a missing file.")
            }
            try require(item.card.id == item.cardID, "A work item contains a mismatched file snapshot.")
            let linkedPeople = Set(item.card.personIDs), snapshotPeople = Set(item.people.map(\.id))
            try require(unique(item.people.map(\.id)) && unique(item.card.personIDs) && linkedPeople.isSubset(of: snapshotPeople), "A work item’s people do not match its accepted file.")
            try require(item.people.filter(\.isMe).count <= 1 && item.people.filter { !linkedPeople.contains($0.id) }.allSatisfy(\.isMe), "Only your own profile can accompany a file’s linked people.")
            try require(item.people.allSatisfy { hasText($0.name) }, "A work item contains an unnamed person.")
            try require(item.action == (item.kind == .action ? item.card.action : item.card.contextAction), "A work item’s action does not match its accepted file.")
            try validateAction(item.action, sample: item.card.isSample || card.isSample)
            if item.status.isPending {
                try require(pendingCards.insert(item.cardID).inserted, "This file already has work waiting or in progress.")
                if item.kind == .action { try require(card.disposition == .delegated || card.isResolved, "Waiting work must remain attached to its delegated file.") }
            }
        }
    }
}
