import Darwin
import Foundation

/// Reusable definitions only. Collected observations belong to SourceRunRepository.
struct SourceRulesSnapshot: Equatable {
    let sources: [LearnedCalendarSource]
    let readingSources: [LearnedReadingSource]
    let removedSources: [RemovedSource]

    init(sources: [LearnedCalendarSource] = [], readingSources: [LearnedReadingSource] = [], removedSources: [RemovedSource] = []) {
        self.sources = sources
        self.readingSources = readingSources
        self.removedSources = removedSources.map {
            RemovedSource(id: $0.id, removedAt: $0.removedAt, calendar: $0.calendar, reading: $0.reading)
        }
    }
}

/// Only older stores return observations alongside rules, for import before replacement.
struct LegacySourceCollections {
    var calendarSnapshots: [CalendarSnapshot]
    var readingSnapshots: [ReadingSnapshot]
    var removedSources: [RemovedSource]
}

struct LoadedSourceRules {
    var rules: SourceRulesSnapshot
    var legacyCollections: LegacySourceCollections? = nil
}

@MainActor
protocol SourceRulesRepository: AnyObject {
    func load() throws -> LoadedSourceRules?
    /// Replace reusable definitions; a successful return means the write completed.
    func save(_ rules: SourceRulesSnapshot) throws
}

/// Preserves the existing workspace.json format and upgrades only after legacy runs are imported.
@MainActor
final class FileSourceRulesRepository: SourceRulesRepository {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("workspace.json") }

    init(directory: URL) { self.directory = directory }

    func load() throws -> LoadedSourceRules? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        struct Header: Decodable { var version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard [1, 2, 3, 4].contains(version) else {
            throw CalendarDataError.unavailable("Source version \(version) is not supported by this Familiar version.")
        }
        let workspace = try (version >= 4 ? SourceRunJSON.decoder() : JSONDecoder()).decode(Workspace.self, from: data)
        let rules = SourceRulesSnapshot(sources: workspace.sources, readingSources: workspace.readingSources, removedSources: workspace.removedSources)
        let legacy = version < 4 ? LegacySourceCollections(calendarSnapshots: workspace.snapshots,
            readingSnapshots: workspace.readingSnapshots, removedSources: workspace.removedSources) : nil
        return LoadedSourceRules(rules: rules, legacyCollections: legacy)
    }

    func save(_ rules: SourceRulesSnapshot) throws {
        try persist(Workspace(sources: rules.sources, readingSources: rules.readingSources, removedSources: rules.removedSources))
    }

    private struct RemovedRule: Codable {
        var id: UUID
        var removedAt: Date
        var calendar: LearnedCalendarSource?
        var reading: LearnedReadingSource?
        init(_ source: RemovedSource) { id = source.id; removedAt = source.removedAt; calendar = source.calendar; reading = source.reading }
        var source: RemovedSource { RemovedSource(id: id, removedAt: removedAt, calendar: calendar, reading: reading) }
    }

    private struct Workspace: Codable {
        var version = 4
        var sources: [LearnedCalendarSource] = []
        var snapshots: [CalendarSnapshot] = []
        var readingSources: [LearnedReadingSource] = []
        var readingSnapshots: [ReadingSnapshot] = []
        var removedSources: [RemovedSource] = []

        enum CodingKeys: String, CodingKey { case version, sources, snapshots, readingSources, readingSnapshots, removedSources }
        init(sources: [LearnedCalendarSource] = [], snapshots: [CalendarSnapshot] = [],
             readingSources: [LearnedReadingSource] = [], readingSnapshots: [ReadingSnapshot] = [], removedSources: [RemovedSource] = []) {
            self.sources = sources; self.snapshots = snapshots
            self.readingSources = readingSources; self.readingSnapshots = readingSnapshots
            self.removedSources = removedSources
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            sources = try values.decode([LearnedCalendarSource].self, forKey: .sources)
            snapshots = version < 4 ? try values.decode([CalendarSnapshot].self, forKey: .snapshots) : []
            if version >= 4 {
                try calendarRequire(!values.contains(.snapshots) && !values.contains(.readingSnapshots), "Rules contain unexpected embedded results. Files were preserved.")
            }
            if version == 1 {
                readingSources = []
                readingSnapshots = []
            } else {
                readingSources = try values.decode([LearnedReadingSource].self, forKey: .readingSources)
                readingSnapshots = version < 4 ? try values.decode([ReadingSnapshot].self, forKey: .readingSnapshots) : []
            }
            if version >= 4 { removedSources = try values.decode([RemovedRule].self, forKey: .removedSources).map(\.source) }
            else { removedSources = version >= 3 ? try values.decode([RemovedSource].self, forKey: .removedSources) : [] }
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            try values.encode(sources, forKey: .sources)
            try values.encode(readingSources, forKey: .readingSources)
            try values.encode(removedSources.map(RemovedRule.init), forKey: .removedSources)
        }
    }

    private func persist(_ workspace: Workspace) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = SourceRunJSON.encoder()
        let data = try encoder.encode(workspace)
        let temporary = directory.appendingPathComponent(".workspace-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, file.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: file.path])
        }
    }
}
