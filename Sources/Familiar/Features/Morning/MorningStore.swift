import Combine
import Darwin
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

/// A local, versioned workspace. A published handoff always has a committed disk record first.
@MainActor
final class MorningStore: ObservableObject {
    @Published private(set) var workspace = MorningWorkspace()
    @Published private(set) var error: String?
    @Published var queueMessage: String?

    var folders: [MorningFolder] { workspace.folders }
    var people: [MorningPerson] { workspace.people }
    var cards: [MorningCard] { workspace.cards }
    var workItems: [MorningWorkItem] { workspace.workItems }

    private let directory: URL
    private var file: URL { directory.appendingPathComponent("workspace.json") }
    private var blockedReason: String?

    init(directory: URL = Config.dir.appendingPathComponent("morning")) {
        self.directory = directory
        do {
            guard FileManager.default.fileExists(atPath: file.path) else {
                try persist(workspace)
                return
            }
            let data = try Data(contentsOf: file)
            struct Header: Decodable { var version: Int }
            let version = try JSONDecoder().decode(Header.self, from: data).version
            guard version == 1 else {
                throw MorningStoreError.unavailable("These morning files use version \(version), which this version of Familiar cannot read. Your saved files have been left untouched.")
            }
            var loaded = try JSONDecoder().decode(MorningWorkspace.self, from: data)
            try Self.validate(loaded)
            workspace = loaded
            var recovered = false
            for index in loaded.workItems.indices {
                guard loaded.workItems[index].status == .running || loaded.workItems[index].status == .needsAttention else { continue }
                loaded.workItems[index].status = .interrupted
                loaded.workItems[index].finishedAt = Date()
                loaded.workItems[index].progress = "Familiar closed while this was in progress. Check what happened before trying again."
                Self.restoreCard(after: loaded.workItems[index], in: &loaded)
                recovered = true
            }
            if recovered {
                try persist(loaded)
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
                throw MorningStoreError.invalid("Hand the file to Familiar to start work; its result will update the file automatically.")
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
                next.cards[cardIndex].disposition = .completed
                next.cards[cardIndex].updatedAt = Date()
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

    private func transact(_ change: (inout MorningWorkspace) throws -> Void) throws {
        do {
            if let blockedReason { throw MorningStoreError.unavailable(blockedReason) }
            var next = workspace
            try change(&next)
            try Self.validate(next)
            try persist(next)
            workspace = next
            error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private func persist(_ next: MorningWorkspace) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        let temporary = directory.appendingPathComponent(".workspace-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // Rename commits one complete document. The private directory also protects the temporary file.
        guard rename(temporary.path, file.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: file.path])
        }
    }

    private static func restoreCard(after item: MorningWorkItem, in workspace: inout MorningWorkspace) {
        guard item.kind == .action, let index = workspace.cards.firstIndex(where: { $0.id == item.cardID }) else { return }
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
            try require(hasText(action.instruction), "Describe what Familiar should do.")
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
                if item.kind == .action { try require(card.disposition == .delegated, "Waiting work must remain attached to its delegated file.") }
            }
        }
    }
}
