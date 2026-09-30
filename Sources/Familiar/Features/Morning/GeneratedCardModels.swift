import Foundation
import CryptoKit

/// Current observed facts are separate from the continuing identity of an item.
enum ObservedItemState: String, Codable, CaseIterable { case open, resolved, unknown }

struct TrackedSourceItem: Codable, Equatable {
    var key: String
    var title: String
    var details: String
    var url: String
    var identityEvidence: String
}

struct CardObservation: Codable, Equatable, Identifiable {
    var runID: UUID
    var sourceID: UUID
    var itemKey: String
    var sourceName: String
    var kind: String
    var title: String
    var excerpt: String
    var url: String
    var identityEvidence: String
    var observedAt: Date
    var state: ObservedItemState
    var stateEvidence: String
    var id: String { Self.key(sourceID: sourceID, itemKey: itemKey) }

    static func key(sourceID: UUID, itemKey: String) -> String {
        sourceID.uuidString.lowercased() + ":" + itemKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var fingerprint: String {
        let data = (try? JSONEncoder().encode([title, excerpt, url, state.rawValue])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Generator output refers to input observations; it cannot mint unrelated item identities.
/// A card is three things: what it is (title), what it means for the person (meaning), and what they can do
/// (the best option as `action`, then up to two alternatives).
struct CardProposal: Codable, Equatable {
    var observationKey: String
    var title: String
    var meaning: String
    var action: MorningAction
    var alternatives: [MorningAction] = []
}

struct CardChange: Codable, Equatable, Identifiable {
    var id = UUID()
    var at: Date
    var runID: UUID?
    var message: String
}

struct CardTracking: Codable, Equatable {
    var sourceID: UUID
    var itemKey: String
    var sourceName: String
    var identityEvidence: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastRunID: UUID
    var contentFingerprint: String
    var resolution: ObservedItemState = .open
    var resolutionEvidence = ""
    var resolvedByUser = false
    var userEdited = false
    var changes: [CardChange] = []
    var key: String { CardObservation.key(sourceID: sourceID, itemKey: itemKey) }
}

struct CardGenerationRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var runIDs: [UUID]
    var completedAt: Date
    var created: Int
    var updated: Int
    var resolved: Int
}

/// What the card step last judged of one item, so an unchanged item isn't put to the model again (and so can't come
/// back as a card for something it passed over before).
struct CardJudgment: Codable, Equatable {
    var revision: String
    var seenAt: Date

    /// Judgments this long unseen are dropped; an item that old is read again as new.
    static let lifetime: TimeInterval = 30 * 24 * 3_600

    /// A hash of what a judgment rests on, like `CardObservation.fingerprint`.
    static func revision(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CardGenerationSummary: Equatable {
    var created = 0
    var updated = 0
    var resolved = 0
    /// Items the model read this step, and items left out because it had judged them before.
    var sent = 0
    var alreadySorted = 0
    var message: String {
        if sent == 0, alreadySorted > 0, created + updated + resolved == 0 { return "Nothing new to sort: \(alreadySorted) already sorted." }
        let counts = "\(created) new · \(updated) updated · \(resolved) resolved"
        return alreadySorted > 0 ? counts + " · \(alreadySorted) already sorted" : counts
    }
}

extension MorningCard {
    /// What the person can do, best first.
    var options: [MorningAction] { [action] + (alternatives ?? []) }
    /// What it means for the person. Hand-written notes and older cards may only have a summary.
    var meaning: String { rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary : rationale }
    var displayDisposition: MorningCardDisposition { tracking?.resolution == .resolved ? .resolved : disposition }
    var isResolved: Bool { tracking?.resolution == .resolved || disposition == .resolved }
}
