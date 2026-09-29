import Combine
import CryptoKit
import Foundation

/// Owns run lifecycle and published state; repositories own storage and exports.
@MainActor
final class SourceRunStore: ObservableObject {
    @Published private(set) var runs: [SourceRunRecord] = []
    @Published private(set) var error: String?
    var archiveDirectory: URL? { repository.archiveDirectory }
    private let repository: any SourceRunRepository
    private var blockedReason: String?

    convenience init(directory: URL = Config.dir.appendingPathComponent("runs")) {
        self.init(repository: FileSourceRunRepository(directory: directory))
    }

    init(repository: any SourceRunRepository) {
        self.repository = repository
        do {
            let loaded = try repository.load()
            try calendarRequire(Set(loaded.map(\.id)).count == loaded.count, "The run archive contains duplicate identifiers.")
            for record in loaded { try record.validate() }
            runs = loaded.sorted { $0.startedAt > $1.startedAt }
            // A process exit must never leave a prior collection appearing live.
            for record in runs where record.status == .running {
                _ = try finish(runID: record.id, status: .interrupted)
            }
        } catch {
            let reason = "Run history could not be opened safely. \(error.localizedDescription) Saved files were preserved."
            self.error = reason; blockedReason = reason
        }
    }

    func run(id: UUID) -> SourceRunRecord? { runs.first { $0.id == id } }
    func directory(for id: UUID) -> URL? { repository.directory(for: id) }
    func report(for id: UUID) -> String? { run(id: id).map(SourceRunReport.render) }

    @discardableResult
    func begin(entries: [SourceRunEntry], origin: SourceRunOrigin, startedAt: Date = Date(), timeZoneID: String = TimeZone.current.identifier) throws -> SourceRunRecord {
        let record = SourceRunRecord(origin: origin, startedAt: startedAt, timeZoneID: timeZoneID, entries: entries)
        try commit(record, replacing: false)
        return record
    }

    @discardableResult
    func updateEntry(runID: UUID, entry: SourceRunEntry) throws -> SourceRunRecord {
        guard var record = run(id: runID), let index = record.entries.firstIndex(where: { $0.id == entry.id }) else {
            throw CalendarDataError.invalid("The requested run entry could not be found.")
        }
        let old = record.entries[index]
        try calendarRequire(record.status == .running, "This collection run has already finished.")
        try calendarRequire(old.calendarRequest == entry.calendarRequest && old.readingSource == entry.readingSource && old.requestedAt == entry.requestedAt, "A running collection cannot change its captured source or request.")
        record.entries[index] = entry
        try commit(record, replacing: true)
        return record
    }

    @discardableResult
    func finish(runID: UUID, status: SourceRunStatus, finishedAt: Date = Date()) throws -> SourceRunRecord {
        guard var record = run(id: runID) else { throw CalendarDataError.invalid("This collection run could not be found.") }
        try calendarRequire(record.status == .running && status != .running, "This collection run cannot be finished again.")
        record.status = status; record.finishedAt = finishedAt
        for index in record.entries.indices where [.waiting, .reading].contains(record.entries[index].state) {
            let wasWaiting = record.entries[index].state == .waiting
            record.entries[index].state = wasWaiting ? .notRun : (status == .interrupted ? .interrupted : status == .failed ? .failed : .stopped)
            record.entries[index].finishedAt = finishedAt
            record.entries[index].message = status == .interrupted
                ? (wasWaiting ? "Not run: Familiar closed before this source started." : "Interrupted: Familiar closed before this source completed.")
                : (wasWaiting ? "This source was not run." : "This source did not complete during this run.")
        }
        try commit(record, replacing: true)
        return record
    }

    /// Import one retained observation, without pretending that legacy snapshots describe a whole batch.
    func importLegacy(calendar snapshot: CalendarSnapshot, source: LearnedCalendarSource) throws {
        var captured = snapshot.source ?? source
        if snapshot.source == nil { captured.timeZoneID = snapshot.timeZoneID }
        let request = CalendarReadRequest(id: snapshot.id, source: captured, day: snapshot.day, startHour: snapshot.startHour, endHour: snapshot.endHour)
        var entry = SourceRunEntry(calendar: request, state: snapshot.coverage == .complete ? .complete : .partial,
            message: "Recovered from a saved collection. Earlier batch membership is unknown.")
        if snapshot.source == nil {
            entry.message += " This older collection did not retain its source profile; the saved profile is included only for reference."
        }
        entry.requestedAt = snapshot.collectedAt; entry.finishedAt = snapshot.collectedAt; entry.calendarSnapshot = snapshot
        try importLegacy(entry: entry, timeZoneID: snapshot.timeZoneID)
    }
    func importLegacy(reading snapshot: ReadingSnapshot) throws {
        var entry = SourceRunEntry(reading: ReadingReadRequest(id: snapshot.requestID, source: snapshot.source, requestedAt: snapshot.collectedAt),
            state: snapshot.coverage == .complete ? .complete : .partial, message: "Recovered from a saved collection. Earlier batch membership is unknown.")
        entry.finishedAt = snapshot.collectedAt; entry.readingSnapshot = snapshot
        try importLegacy(entry: entry, timeZoneID: TimeZone.current.identifier)
    }
    private func importLegacy(entry: SourceRunEntry, timeZoneID: String) throws {
        let bytes = Array(SHA256.hash(data: try SourceRunJSON.encoder().encode(entry)).prefix(16))
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let record = SourceRunRecord(id: id, origin: .migration, startedAt: entry.requestedAt, finishedAt: entry.finishedAt, timeZoneID: timeZoneID, status: .completed, entries: [entry])
        if let existing = run(id: id) {
            // A retry may occur after the computer's display time zone changes.
            // Preserve the original folder/time-zone choice when its observation matches.
            try calendarRequire(existing.origin == .migration && existing.status == .completed
                && existing.startedAt == record.startedAt && existing.finishedAt == record.finishedAt
                && existing.entries == record.entries, "An imported collection conflicts with an existing archived run.")
            return
        }
        try commit(record, replacing: false)
    }

    /// Used by older direct snapshot callers; still creates one durable run per read.
    func saveCompleted(entry: SourceRunEntry, timeZoneID: String) throws {
        let record = SourceRunRecord(origin: .single, startedAt: entry.requestedAt, finishedAt: entry.finishedAt ?? entry.requestedAt,
            timeZoneID: timeZoneID, status: .completed, entries: [entry])
        try commit(record, replacing: false)
    }

    private func commit(_ record: SourceRunRecord, replacing: Bool) throws {
        do {
            if let blockedReason { throw CalendarDataError.unavailable(blockedReason) }
            try record.validate()
            try repository.save(record, replacing: replacing ? run(id: record.id) : nil)
            var next = runs.filter { $0.id != record.id }; next.append(record)
            runs = next.sorted { $0.startedAt > $1.startedAt }
            error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
}

enum SourceRunReport {
    static func render(_ record: SourceRunRecord) -> String {
        var lines = ["# Collected results", "", "\(SourceRunJSON.timestamp(record.startedAt)) · \(record.timeZoneID) · \(record.status.rawValue)"]
        if record.origin == .migration { lines.append("Recovered saved observation; original run grouping is unknown.") }
        for entry in record.entries {
            lines += ["", "## \(entry.sourceName)", "", "Status: \(entry.state.rawValue)"]
            if !entry.message.isEmpty { lines += ["", entry.message] }
            if let snapshot = entry.readingSnapshot {
                if snapshot.items.isEmpty { lines += ["", snapshot.coverage == .complete ? "No items were found in the saved scope." : "No items were collected; coverage is incomplete."] }
                for item in snapshot.items {
                    lines += ["", "### \(item.title)", "", item.text]
                    if !item.url.isEmpty { lines += ["", "Source: \(item.url)"] }
                }
                if !snapshot.coverageNotes.isEmpty { lines += ["", "Collection notes: " + snapshot.coverageNotes.joined(separator: " ")] }
            }
            if let snapshot = entry.calendarSnapshot { lines += ["", CalendarBriefing.render(snapshot)] }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
