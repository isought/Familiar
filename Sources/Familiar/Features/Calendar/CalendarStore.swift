import Combine
import Foundation

@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var sources: [LearnedCalendarSource] = []
    @Published private(set) var snapshots: [CalendarSnapshot] = []
    @Published private(set) var readingSources: [LearnedReadingSource] = []
    @Published private(set) var readingSnapshots: [ReadingSnapshot] = []
    @Published private(set) var removedSources: [RemovedSource] = []
    @Published private(set) var savedReadingWorkflows: [SavedReadingWorkflow] = []
    @Published private(set) var error: String?

    let runStore: SourceRunStore
    private var runObservation: AnyCancellable?

    private struct Workspace {
        var sources: [LearnedCalendarSource] = []
        var snapshots: [CalendarSnapshot] = []
        var readingSources: [LearnedReadingSource] = []
        var readingSnapshots: [ReadingSnapshot] = []
        var removedSources: [RemovedSource] = []

        var rules: SourceRulesSnapshot {
            SourceRulesSnapshot(sources: sources, readingSources: readingSources, removedSources: removedSources)
        }
    }

    private let repository: any SourceRulesRepository
    private var blockedReason: String?
    private var workflowRoot: URL?

    convenience init(directory: URL = Config.dir.appendingPathComponent("calendar"), runsDirectory: URL? = nil) {
        let defaultDirectory = Config.dir.appendingPathComponent("calendar")
        let runs = SourceRunStore(directory: runsDirectory ?? (directory.standardizedFileURL == defaultDirectory.standardizedFileURL
            ? Config.dir.appendingPathComponent("runs") : directory.appendingPathComponent("runs")))
        self.init(repository: FileSourceRulesRepository(directory: directory), runStore: runs)
    }

    init(repository: any SourceRulesRepository, runStore: SourceRunStore) {
        self.repository = repository
        self.runStore = runStore
        do {
            if let loaded = try repository.load() {
                let workspace = Workspace(sources: loaded.rules.sources,
                    snapshots: loaded.legacyCollections?.calendarSnapshots ?? [],
                    readingSources: loaded.rules.readingSources,
                    readingSnapshots: loaded.legacyCollections?.readingSnapshots ?? [],
                    removedSources: loaded.legacyCollections?.removedSources ?? loaded.rules.removedSources)
                try Self.validate(workspace)
                if loaded.legacyCollections != nil {
                    // Import first. If any write fails, the legacy workspace remains intact and retry is idempotent.
                    for snapshot in workspace.snapshots {
                        try runStore.importLegacy(calendar: snapshot, source: workspace.sources.first { $0.id == snapshot.sourceID }!)
                    }
                    for snapshot in workspace.readingSnapshots { try runStore.importLegacy(reading: snapshot) }
                    for removed in workspace.removedSources {
                        for snapshot in removed.calendarSnapshots { try runStore.importLegacy(calendar: snapshot, source: removed.calendar!) }
                        for snapshot in removed.readingSnapshots { try runStore.importLegacy(reading: snapshot) }
                    }
                    try repository.save(workspace.rules)
                }
                sources = workspace.sources; readingSources = workspace.readingSources; removedSources = workspace.removedSources
            } else {
                try repository.save(SourceRulesSnapshot())
            }
            if let archiveError = runStore.error { error = archiveError }
        } catch {
            let reason = "Sources could not be opened safely. \(error.localizedDescription) Changes are paused to protect your saved data."
            self.error = reason; blockedReason = reason
        }
        runObservation = runStore.$runs.sink { [weak self] runs in self?.refreshDerivedSnapshots(runs) }
    }

    func saveSource(_ source: LearnedCalendarSource) throws {
        try transact { next in
            try calendarRequire(!next.removedSources.contains { $0.id == source.id }, "This source was removed. Restore it before changing it.")
            var source = source
            source.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            source.meaning = source.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = next.sources.firstIndex(where: { $0.id == source.id }) { next.sources[index] = source }
            else { next.sources.append(source) }
        }
        if let workflowRoot { refreshSavedWorkflows(root: workflowRoot) }
    }

    func saveSnapshot(_ value: CalendarSnapshot) throws {
        do {
            if let blockedReason { throw CalendarDataError.unavailable(blockedReason) }
            var snapshot = value
            guard let registered = sources.first(where: { $0.id == snapshot.sourceID }) else { throw CalendarDataError.invalid("This calendar source is no longer active.") }
            if snapshot.source == nil { snapshot.source = registered }
            try snapshot.validate()
            snapshot.day = snapshot.dayInterval.start
            snapshot.events.sort { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
            let request = CalendarReadRequest(id: snapshot.id, source: snapshot.source!, day: snapshot.day, startHour: snapshot.startHour, endHour: snapshot.endHour)
            var entry = SourceRunEntry(calendar: request, state: snapshot.coverage == .complete ? .complete : .partial)
            entry.requestedAt = snapshot.collectedAt; entry.finishedAt = snapshot.collectedAt; entry.calendarSnapshot = snapshot
            try runStore.saveCompleted(entry: entry, timeZoneID: snapshot.timeZoneID)
            error = nil
        } catch { self.error = error.localizedDescription; throw error }
    }

    func saveReadingSource(_ source: LearnedReadingSource) throws {
        try transact { next in
            try calendarRequire(!next.removedSources.contains { $0.id == source.id }, "This source was removed. Restore it before changing it.")
            var source = source
            source.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            source.meaning = source.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = next.readingSources.firstIndex(where: { $0.id == source.id }) { next.readingSources[index] = source }
            else { next.readingSources.append(source) }
        }
        if let workflowRoot { refreshSavedWorkflows(root: workflowRoot) }
    }

    func saveReadingSnapshot(_ snapshot: ReadingSnapshot) throws {
        do {
            if let blockedReason { throw CalendarDataError.unavailable(blockedReason) }
            try calendarRequire(readingSources.contains { $0.id == snapshot.sourceID }, "This reading source is no longer active.")
            try snapshot.validate()
            var entry = SourceRunEntry(reading: ReadingReadRequest(id: snapshot.requestID, source: snapshot.source, requestedAt: snapshot.collectedAt), state: snapshot.coverage == .complete ? .complete : .partial)
            entry.finishedAt = snapshot.collectedAt; entry.readingSnapshot = snapshot
            try runStore.saveCompleted(entry: entry, timeZoneID: TimeZone.current.identifier)
            error = nil
        } catch { self.error = error.localizedDescription; throw error }
    }

    func latestReading(for sourceID: UUID) -> ReadingSnapshot? {
        guard let source = readingSources.first(where: { $0.id == sourceID }) else { return nil }
        return readingSnapshots.filter { $0.source.matchesIdentity(of: source) }.max { $0.collectedAt < $1.collectedAt }
    }

    func removeSource(id: UUID) throws {
        try transact { next in
            if let index = next.sources.firstIndex(where: { $0.id == id }) {
                let source = next.sources.remove(at: index)
                let snapshots = next.snapshots.filter { $0.sourceID == id }
                next.snapshots.removeAll { $0.sourceID == id }
                next.removedSources.append(RemovedSource(id: id, calendar: source, calendarSnapshots: snapshots))
            } else if let index = next.readingSources.firstIndex(where: { $0.id == id }) {
                let source = next.readingSources.remove(at: index)
                let snapshots = next.readingSnapshots.filter { $0.sourceID == id }
                next.readingSnapshots.removeAll { $0.sourceID == id }
                next.removedSources.append(RemovedSource(id: id, reading: source, readingSnapshots: snapshots))
            } else {
                throw CalendarDataError.invalid("This source is no longer in your active sources.")
            }
        }
        if let workflowRoot { refreshSavedWorkflows(root: workflowRoot) }
    }

    func restoreSource(id: UUID) throws {
        try transact { next in
            guard let index = next.removedSources.firstIndex(where: { $0.id == id }) else {
                throw CalendarDataError.invalid("This removed source could not be found.")
            }
            let record = next.removedSources[index]
            try record.validate()
            try calendarRequire(!next.sources.contains { $0.id == id } && !next.readingSources.contains { $0.id == id }, "An active source already uses this identifier. The removed source was kept unchanged.")
            if let path = record.workflowPath {
                let activePaths = next.sources.compactMap(\.workflowPath) + next.readingSources.map(\.workflowPath)
                try calendarRequire(!activePaths.contains(path), "An active source already uses this saved workflow. The removed source was kept unchanged.")
            }
            let activeSnapshotIDs = Set(next.snapshots.map(\.id) + next.readingSnapshots.map(\.id))
            let restoredSnapshotIDs = Set(record.calendarSnapshots.map(\.id) + record.readingSnapshots.map(\.id))
            try calendarRequire(activeSnapshotIDs.isDisjoint(with: restoredSnapshotIDs), "An active collection already uses one of these saved identifiers. The removed source was kept unchanged.")
            if let calendar = record.calendar { next.sources.append(calendar) }
            if let reading = record.reading { next.readingSources.append(reading) }
            next.snapshots.append(contentsOf: record.calendarSnapshots)
            next.readingSnapshots.append(contentsOf: record.readingSnapshots)
            next.removedSources.remove(at: index)
        }
        if let workflowRoot { refreshSavedWorkflows(root: workflowRoot) }
    }

    func refreshSavedWorkflows(root: URL) {
        workflowRoot = root
        let registered = Set(sources.map(\.id) + readingSources.map(\.id) + removedSources.map(\.id))
        let paths = Set(sources.compactMap(\.workflowPath) + readingSources.map(\.workflowPath) + removedSources.compactMap(\.workflowPath))
        savedReadingWorkflows = SavedReadingWorkflow.discover(root: root).filter { !registered.contains($0.draft.id) && !paths.contains($0.relativePath) }
    }

    func latest(for sourceID: UUID) -> CalendarSnapshot? {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        return snapshots.filter { $0.sourceID == sourceID && $0.matchesIdentity(of: source) }.max { $0.collectedAt < $1.collectedAt }
    }

    private func refreshDerivedSnapshots(_ runs: [SourceRunRecord]) {
        let calendars = runs.flatMap(\.entries).compactMap(\.calendarSnapshot).sorted { $0.collectedAt < $1.collectedAt }
        let readings = runs.flatMap(\.entries).compactMap(\.readingSnapshot).sorted { $0.collectedAt < $1.collectedAt }
        var latestCalendars: [String: CalendarSnapshot] = [:]
        var latestReadings: [UUID: ReadingSnapshot] = [:]
        for snapshot in calendars { latestCalendars[snapshot.sourceID.uuidString + ":" + snapshot.dateLabel] = snapshot }
        for snapshot in readings { latestReadings[snapshot.sourceID] = snapshot }
        let activeCalendars = Set(sources.map(\.id)), activeReadings = Set(readingSources.map(\.id))
        snapshots = latestCalendars.values.filter { activeCalendars.contains($0.sourceID) }.sorted { $0.collectedAt < $1.collectedAt }
        readingSnapshots = latestReadings.values.filter { activeReadings.contains($0.sourceID) }.sorted { $0.collectedAt < $1.collectedAt }
        removedSources = removedSources.map { value in
            var value = value
            value.calendarSnapshots = latestCalendars.values.filter { value.calendar != nil && $0.sourceID == value.id }.sorted { $0.collectedAt < $1.collectedAt }
            value.readingSnapshots = latestReadings.values.filter { value.reading != nil && $0.sourceID == value.id }
            return value
        }
    }

    private func transact(_ mutation: (inout Workspace) throws -> Void) throws {
        do {
            if let blockedReason { throw CalendarDataError.unavailable(blockedReason) }
            var next = Workspace(sources: sources, snapshots: snapshots, readingSources: readingSources, readingSnapshots: readingSnapshots, removedSources: removedSources)
            try mutation(&next)
            try Self.validate(next)
            try repository.save(next.rules)
            sources = next.sources
            readingSources = next.readingSources
            removedSources = next.removedSources
            refreshDerivedSnapshots(runStore.runs)
            error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private static func validate(_ workspace: Workspace) throws {
        try calendarRequire(Set(workspace.sources.map(\.id)).count == workspace.sources.count, "Saved calendar sources contain duplicate identifiers.")
        try calendarRequire(Set(workspace.snapshots.map(\.id)).count == workspace.snapshots.count, "Saved calendar collections contain duplicate identifiers.")
        for source in workspace.sources { try source.validate() }
        let sourceIDs = Set(workspace.sources.map(\.id))
        var collectedDays: Set<String> = []
        for snapshot in workspace.snapshots {
            try snapshot.validate()
            try calendarRequire(sourceIDs.contains(snapshot.sourceID), "A calendar collection refers to a missing source.")
            try calendarRequire(collectedDays.insert(snapshot.sourceID.uuidString + ":" + snapshot.dateLabel).inserted, "A source has duplicate collections for the same day.")
        }
        let allSourceIDs = workspace.sources.map(\.id) + workspace.readingSources.map(\.id)
        try calendarRequire(Set(allSourceIDs).count == allSourceIDs.count, "Saved sources contain duplicate identifiers.")
        let removedIDs = workspace.removedSources.map(\.id)
        try calendarRequire(Set(removedIDs).count == removedIDs.count && Set(allSourceIDs).isDisjoint(with: Set(removedIDs)), "Active and removed sources contain overlapping or duplicate identifiers.")
        for removed in workspace.removedSources { try removed.validate() }
        for source in workspace.readingSources { try source.validate() }
        let readingIDs = Set(workspace.readingSources.map(\.id))
        try calendarRequire(Set(workspace.readingSnapshots.map(\.sourceID)).count == workspace.readingSnapshots.count, "A reading source has duplicate latest collections.")
        for snapshot in workspace.readingSnapshots {
            try snapshot.validate()
            try calendarRequire(readingIDs.contains(snapshot.sourceID), "A reading collection refers to a missing source.")
        }
    }
}
