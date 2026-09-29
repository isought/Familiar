import Darwin
import Foundation

/// Saves complete run records. A replacement must still match the record the caller read.
/// Folder locations are optional because storage need not be file based.
@MainActor
protocol SourceRunRepository: AnyObject {
    var archiveDirectory: URL? { get }
    func load() throws -> [SourceRunRecord]
    func save(_ record: SourceRunRecord, replacing previous: SourceRunRecord?) throws
    func directory(for id: UUID) -> URL?
}

/// run.json is authoritative. Per-source JSON and report.md are regenerated exports.
@MainActor
final class FileSourceRunRepository: SourceRunRepository {
    private let root: URL
    var archiveDirectory: URL? { root }
    private var locations: [UUID: URL] = [:]

    init(directory: URL) { root = directory }

    func directory(for id: UUID) -> URL? { locations[id] }

    func load() throws -> [SourceRunRecord] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        let folders = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var records: [SourceRunRecord] = []
        var loadedLocations: [UUID: URL] = [:]
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            try calendarRequire(values.isDirectory == true && values.isSymbolicLink != true, "The run archive contains an unexpected file or link: \(folder.lastPathComponent).")
            let record = try SourceRunJSON.decoder().decode(SourceRunRecord.self, from: Data(contentsOf: folder.appendingPathComponent("run.json")))
            try record.validate()
            try calendarRequire(loadedLocations[record.id] == nil, "The run archive contains duplicate identifiers.")
            loadedLocations[record.id] = folder
            records.append(record)
        }
        locations = loadedLocations
        return records
    }

    func save(_ record: SourceRunRecord, replacing previous: SourceRunRecord?) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: record.timeZoneID)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: record.startedAt)
        var destination = locations[record.id] ?? root.appendingPathComponent(stamp)
        if previous == nil && manager.fileExists(atPath: destination.path) {
            destination = root.appendingPathComponent("\(stamp)-\(record.id.uuidString.prefix(8).lowercased())")
        }
        if let previous {
            let stored = try SourceRunJSON.decoder().decode(SourceRunRecord.self, from: Data(contentsOf: destination.appendingPathComponent("run.json")))
            try calendarRequire(stored == previous, "This archived run changed on disk. Its saved files were preserved.")
        } else {
            try calendarRequire(!manager.fileExists(atPath: destination.path), "The run folder already exists. Its saved files were preserved.")
        }
        let temporary = root.appendingPathComponent(".run-\(UUID().uuidString).tmp")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        func write(_ data: Data, name: String) throws {
            let file = temporary.appendingPathComponent(name)
            try data.write(to: file, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let descriptor = open(file.path, O_RDONLY)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        try write(SourceRunJSON.encoder().encode(record), name: "run.json")
        for entry in record.entries {
            let slug = entry.sourceName.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
            try write(SourceRunJSON.encoder().encode(entry), name: "\(String((slug.isEmpty ? "source" : slug).prefix(60)))-\(entry.sourceID.uuidString.lowercased()).json")
        }
        try write(Data(SourceRunReport.render(record).utf8), name: "report.md")
        // macOS atomically exchanges two directories. There is never a missing run folder.
        let flags = previous != nil ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renamex_np(temporary.path, destination.path, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
        locations[record.id] = destination
    }
}
