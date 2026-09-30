import Foundation

struct MorningFolder: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
}

struct MorningPerson: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var role: String = ""
    var relationship: String = ""
    var context: String = ""
    var identities: [String] = []
    var isMe: Bool = false
}

struct MorningSource: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var kind: String = "Personal note"
    var excerpt: String
    var url: String = ""
    var capturedAt: Date = Date()
}

enum MorningActionMode: String, Codable, CaseIterable {
    case prepare, desktop
    var label: String { self == .prepare ? "Prepare a local result" : "Work in an app" }
}

struct MorningAction: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var instruction: String
    var mode: MorningActionMode = .prepare
}

enum MorningCardDisposition: String, Codable, CaseIterable {
    case unreviewed, ignored, mine, delegated, completed, resolved
    var label: String {
        switch self {
        case .unreviewed: return "To review"
        case .ignored: return "Filed away"
        case .mine: return "I’ll handle it"
        case .delegated: return "With Noteling"
        case .completed: return "Result ready"
        case .resolved: return "Resolved"
        }
    }
}

struct MorningCard: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var folderID: UUID
    var title: String
    var summary: String = ""
    var personIDs: [UUID] = []
    var sources: [MorningSource] = []
    var rationale: String = ""
    var action: MorningAction
    var contextAction: MorningAction? = nil
    var unknowns: String = ""
    var timing: String = ""
    var isSample: Bool = false
    var disposition: MorningCardDisposition = .unreviewed
    var updatedAt: Date = Date()
    var tracking: CardTracking? = nil
    var personalContext: String? = nil
    /// Options after the first (the first is `action`), best first. Optional so cards saved before it still load.
    var alternatives: [MorningAction]? = nil
}

enum MorningWorkKind: String, Codable { case action, context }

enum MorningWorkStatus: String, Codable, CaseIterable {
    case queued, running, needsAttention, completed, failed, cancelled, interrupted
    var isPending: Bool { self == .queued || self == .running || self == .needsAttention }
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Working"
        case .needsAttention: return "Needs you"
        case .completed: return "Result ready"
        case .failed: return "Couldn’t finish"
        case .cancelled: return "Stopped"
        case .interrupted: return "Interrupted · check before retrying"
        }
    }
}

/// The accepted action and evidence are snapshots; editing a card cannot silently change queued work.
struct MorningWorkItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var cardID: UUID
    var card: MorningCard
    var people: [MorningPerson]
    var action: MorningAction
    var kind: MorningWorkKind = .action
    var status: MorningWorkStatus = .queued
    var result: String = ""
    var progress: String = ""
    var createdAt: Date = Date()
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
}

struct MorningWorkspace: Codable, Equatable {
    var version: Int = 1
    var folders: [MorningFolder] = [
        MorningFolder(name: "Replies"), MorningFolder(name: "Unfinished"), MorningFolder(name: "Housekeeping")
    ]
    var people: [MorningPerson] = []
    var cards: [MorningCard] = []
    var workItems: [MorningWorkItem] = []
    var samplesLoaded = false
    var cardGenerations: [CardGenerationRecord]? = nil
}
