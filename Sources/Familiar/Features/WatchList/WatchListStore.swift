import Combine
import Foundation

/// What a look at the watches folder found changed by hand since the last one.
struct WatchListChanges: Equatable {
    /// Watches that turned up: a folder someone put there, or one that can be read now.
    var added: [UUID] = []
    /// Watches whose folder went away (deleted, or moved to the Trash in the Finder): they stop.
    var removed: [UUID] = []
    /// Items someone added to a watch.json, by watch: checked right away.
    var newItems: [UUID: Set<String>] = [:]
}

/// The watches, one folder each in `watches/` in Noteling's folder (see `WatchListFiles`), so people can read them, edit
/// them and hand one to a teammate the way they do a tool pack. A watch.json changed by hand is read again at the next
/// look; one that can't be read is never written over or deleted, and the watch keeps its last good definition until
/// it's fixed. Stopping a watch moves its folder to the Trash, where it can be put back.
@MainActor
final class WatchListStore: ObservableObject {
    @Published private(set) var watches: [WatchListWatch] = []
    /// Watches whose watch.json can't be read right now: "Can't read watch.json: <reason>".
    @Published private(set) var problems: [UUID: String] = [:]
    /// Folders in `watches/` that hold no watch Noteling could read or take, by folder name, with why.
    @Published private(set) var unreadable: [String: String] = [:]
    /// Something to say about the list as a whole: that an earlier watch list couldn't be moved into folders.
    @Published private(set) var notice: String?
    let directory: URL
    /// Moves a stopped watch's folder to the Trash. Tests put their own here, so nothing reaches the real Trash.
    var trash: (URL) throws -> Void

    nonisolated static let watchLimit = 20
    /// Items in one watch: a list check takes them all at once; a check that takes one item at a time, 50.
    nonisolated static let itemLimit = 200
    nonisolated static let itemLimitEach = 50

    private struct Record {
        var folder: String
        /// watch.json's modification date when Noteling last read or wrote it: any other date means a hand edit.
        var seen: Date?
        /// Keys a person added that Noteling doesn't use, written back as they were.
        var other: String?
    }
    private var records: [UUID: Record] = [:]
    /// The watch.json date of each folder that couldn't be read, so it is read (and logged) again only once it changes.
    private var unreadableSeen: [String: Date?] = [:]

    init(directory: URL = Config.dir.appendingPathComponent("watches"),
         legacyFile: URL? = Config.dir.appendingPathComponent("watch-list.json"),
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.directory = directory
        self.trash = trash
        if let legacyFile { migrate(from: legacyFile) }
        refresh()
    }

    func watch(id: UUID) -> WatchListWatch? { watches.first { $0.id == id } }

    func folder(for id: UUID) -> URL? { records[id].map { directory.appendingPathComponent($0.folder) } }

    /// The watch's own check, when its folder has one.
    func ownCheck(for id: UUID) -> URL? {
        guard let file = folder(for: id)?.appendingPathComponent(WatchListFiles.ownCheck),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    func add(_ watch: WatchListWatch) throws {
        guard watches.count < Self.watchLimit else {
            throw WatchListError("You're already watching \(Self.watchLimit) lists, the most Noteling keeps. Stop one first.")
        }
        try Self.validate(watch)
        var watch = watch
        watch.createdAt = Date(timeIntervalSince1970: watch.createdAt.timeIntervalSince1970.rounded(.down))   // as watch.json writes it
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let taken = Set((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
        let name = WatchListFiles.slug(watch.name, taken: taken)
        let folder = directory.appendingPathComponent(name)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        records[watch.id] = Record(folder: name)
        do {
            try writeDefinition(watch)
            try writeResults(watch)
        } catch {
            records[watch.id] = nil
            try? manager.removeItem(at: folder)
            throw error
        }
        watches.append(watch)
    }

    /// Changes one watch. A run keeps what its checks find in memory (`persist: false`) and saves at its end; anything
    /// the person changes is saved at once, and put back if saving fails. A hand edit made since the last look is taken
    /// in first, so a change never writes over it, and a watch.json that can't be read is never written over.
    @discardableResult
    func change(_ id: UUID, persist: Bool = true, _ body: (inout WatchListWatch) throws -> Void) throws -> WatchListWatch {
        if persist { refresh(id) }
        guard let index = watches.firstIndex(where: { $0.id == id }) else { throw WatchListError("That watch was stopped.") }
        let before = watches[index]
        var watch = before
        try body(&watch)
        try Self.validate(watch)
        let redefined = watch.definition != before.definition
        if redefined, let problem = problems[id] {
            throw WatchListError("\(problem) Fix the file, or put back the one it had, first: Noteling doesn't write over a watch.json it can't read.")
        }
        watches[index] = watch
        guard persist || redefined else { return watch }
        do {
            if redefined { try writeDefinition(watch) }
            try writeResults(watch)
        } catch {
            watches[index] = before
            throw error
        }
        return watch
    }

    /// Stops a watch: its folder goes to the Trash, so it can be put back.
    func remove(_ id: UUID) throws {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        if let folder = folder(for: id), FileManager.default.fileExists(atPath: folder.path) {
            do { try trash(folder) }
            catch { throw WatchListError("Couldn't move its folder to the Trash: \(error.localizedDescription)") }
        }
        watches.remove(at: index)
        records[id] = nil
        problems[id] = nil
    }

    /// Writes what a watch's checks found to its latest.json.
    func save(_ id: UUID) throws {
        guard let watch = watch(id: id) else { return }
        try writeResults(watch)
    }

    func save() throws {
        var failure: Error?
        for watch in watches {
            do { try writeResults(watch) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    // MARK: looking at the folder

    /// Looks at the watches folder for what people changed by hand: a watch.json with a new modification date is read
    /// again, a new folder becomes a watch, and a folder that went away takes its watch with it. Cheap enough for every
    /// tick: it reads only files that changed.
    @discardableResult
    func refresh() -> WatchListChanges {
        var changes = WatchListChanges()
        let folders = WatchListFiles.folders(in: directory)
        let names = Set(folders.map(\.lastPathComponent))
        var gone = records.filter { !names.contains($0.value.folder) }
        let known = Dictionary(records.map { ($0.value.folder, $0.key) }, uniquingKeysWith: { first, _ in first })
        var found: [Found] = []
        for folder in folders {
            if let id = known[folder.lastPathComponent] { reread(id, changes: &changes) }
            else if let new = read(folder) { found.append(new) }
        }
        // Oldest first, so a copy of a folder comes after the one it copies, and past the limit the newest wait.
        for new in found.sorted(by: { ($0.definition.createdAt, $0.name) < ($1.definition.createdAt, $1.name) }) {
            take(new, gone: &gone, changes: &changes)
        }
        for (id, record) in gone {
            watches.removeAll { $0.id == id }
            records[id] = nil
            problems[id] = nil
            changes.removed.append(id)
            Log.info("watch list: the \(record.folder) folder is gone, so it is no longer watched")
        }
        for name in unreadable.keys where !names.contains(name) {
            unreadable[name] = nil
            unreadableSeen[name] = nil
        }
        if !changes.added.isEmpty { sort() }
        return changes
    }

    /// Looks again at one watch's watch.json, right before a run or a change.
    @discardableResult
    func refresh(_ id: UUID) -> WatchListChanges {
        var changes = WatchListChanges()
        reread(id, changes: &changes)
        return changes
    }

    private func reread(_ id: UUID, changes: inout WatchListChanges) {
        guard var record = records[id] else { return }
        let file = directory.appendingPathComponent(record.folder).appendingPathComponent(WatchListFiles.definition)
        let date = WatchListFiles.modified(file)   // before reading, so a write that ends after the read is seen next time
        guard date != record.seen else { return }
        record.seen = date
        records[id] = record
        do {
            guard date != nil else { throw WatchListError("it isn't in the folder.") }
            let parsed = try WatchListFiles.parseDefinition(Data(contentsOf: file), folder: record.folder, created: created(file))
            if problems[id] != nil { Log.info("watch list: \(record.folder)/watch.json can be read again") }
            problems[id] = nil
            record.other = parsed.definition.other
            records[id] = record
            guard let index = watches.firstIndex(where: { $0.id == id }),
                  !parsed.definition.sameSettings(as: watches[index].definition) else { return }
            let before = watches[index]
            watches[index].adopt(parsed.definition, quiet: false)
            let added = Set(watches[index].items.map(\.key)).subtracting(before.items.map(\.key))
            if !added.isEmpty { changes.newItems[id] = added }
            Log.info("watch list: took in the changes to \(record.folder)/watch.json")
        } catch {
            let problem = "Can't read watch.json: " + Self.reason(error)
            if problems[id] != problem { Log.info("watch list: \(record.folder): \(problem) Its last good definition is used until it's fixed.") }
            problems[id] = problem
        }
    }

    /// A folder not seen before, read: what its watch.json says.
    private struct Found {
        var folder: URL
        var date: Date?
        var definition: WatchListDefinition
        var hadID: Bool
        var name: String { folder.lastPathComponent }
    }

    /// Reads a folder not seen before. One whose watch.json can't be read is reported, once until the file changes.
    private func read(_ folder: URL) -> Found? {
        let name = folder.lastPathComponent
        let file = folder.appendingPathComponent(WatchListFiles.definition)
        let date = WatchListFiles.modified(file)
        if let seen = unreadableSeen[name], seen == date { return nil }
        do {
            guard date != nil else { throw WatchListError("it isn't in the folder.") }
            let parsed = try WatchListFiles.parseDefinition(Data(contentsOf: file), folder: name, created: created(file))
            return Found(folder: folder, date: date, definition: parsed.definition, hadID: parsed.hadID)
        } catch {
            cannot(name, date: date, "Can't read watch.json: " + Self.reason(error))
            return nil
        }
    }

    /// A folder not watched, and why. A watch.json that can't be read is read again only once it changes; a folder
    /// past the limit is looked at again each time, so it is watched as soon as another watch stops.
    private func cannot(_ name: String, date: Date?, _ why: String, untilChanged: Bool = true) {
        if unreadable[name] != why { Log.info("watch list: not watching the \(name) folder: \(why)") }
        unreadable[name] = why
        if untilChanged { unreadableSeen[name] = .some(date) } else { unreadableSeen.removeValue(forKey: name) }
    }

    /// Takes a folder not seen before: a watch someone put there or copied, one that changed its folder name, or one
    /// whose watch.json couldn't be read until now.
    private func take(_ found: Found, gone: inout [UUID: Record], changes: inout WatchListChanges) {
        let name = found.name, folder = found.folder, date = found.date
        let parsed = (definition: found.definition, hadID: found.hadID)
        unreadable[name] = nil
        unreadableSeen[name] = nil
        var definition = parsed.definition
        if let renamed = gone.removeValue(forKey: definition.id) {   // the same watch, in a folder with a new name
            records[definition.id] = Record(folder: name, seen: date, other: definition.other)
            Log.info("watch list: \(renamed.folder) is now \(name)")
            guard let index = watches.firstIndex(where: { $0.id == definition.id }),
                  !definition.sameSettings(as: watches[index].definition) else { return }
            let before = watches[index]
            watches[index].adopt(definition, quiet: false)
            let added = Set(watches[index].items.map(\.key)).subtracting(before.items.map(\.key))
            if !added.isEmpty { changes.newItems[definition.id] = added }
            return
        }
        guard watches.count < Self.watchLimit else {
            cannot(name, date: date, "Not watched: Noteling watches up to \(Self.watchLimit) lists. Stop one to watch this one.", untilChanged: false)
            return
        }
        let copy = records[definition.id] != nil   // a copy of another watch's folder is a watch of its own
        if copy { definition.id = WatchListFiles.derivedID(folder: name) }
        var watch = WatchListWatch(id: definition.id, name: definition.name, check: definition.check, items: [])
        watch.adopt(definition, quiet: false)
        if let data = try? Data(contentsOf: folder.appendingPathComponent(WatchListFiles.results)) {
            do { try WatchListFiles.readResults(data, into: &watch) }
            catch { Log.info("watch list: \(name)/latest.json can't be read (\(Self.reason(error))); its items are checked afresh") }
        }
        // watch.json may have changed while Noteling wasn't looking: what counts as right is worked out again.
        for index in watch.items.indices {
            WatchListRules.refresh(&watch.items[index], fields: watch.fields, expect: watch.expect, quiet: false)
        }
        records[watch.id] = Record(folder: name, seen: date, other: definition.other)
        watches.append(watch)
        changes.added.append(watch.id)
        // An id of its own, written down, so it stays the same if the folder is renamed or copied again.
        if copy || !parsed.hadID { try? writeDefinition(watch) }
    }

    private func sort() {
        watches.sort { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    private func created(_ file: URL) -> Date {
        let folder = file.deletingLastPathComponent()
        return (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.creationDate] as? Date ?? Date()
    }

    // MARK: writing

    private func writeDefinition(_ watch: WatchListWatch) throws {
        guard var record = records[watch.id] else { return }
        var definition = watch.definition
        definition.other = record.other
        let file = directory.appendingPathComponent(record.folder).appendingPathComponent(WatchListFiles.definition)
        try WatchListFiles.write(WatchListFiles.definitionText(definition), to: file)
        record.seen = WatchListFiles.modified(file)
        records[watch.id] = record
    }

    /// Never makes the folder: a watch whose folder went away is not brought back by a run that ends after it.
    private func writeResults(_ watch: WatchListWatch) throws {
        guard let folder = folder(for: watch.id), FileManager.default.fileExists(atPath: folder.path) else { return }
        try WatchListFiles.write(WatchListFiles.resultsText(watch), to: folder.appendingPathComponent(WatchListFiles.results))
    }

    private static func validate(_ watch: WatchListWatch) throws {
        guard watch.items.count <= itemLimit else {
            throw WatchListError("A watch holds up to \(itemLimit) items. Split them into two watches.")
        }
    }

    static func reason(_ error: Error) -> String {
        (error as? WatchListError)?.message ?? error.localizedDescription
    }

    // MARK: the earlier single file

    /// Moves the watches of an earlier `watch-list.json` into folders, once: only while there is no watches folder
    /// yet. The folders are made beside it and moved into place whole, and only then is the old file renamed
    /// `watch-list.json.moved-<time>`; if anything fails, the old file stays as it is and the move is tried again at
    /// the next launch.
    private func migrate(from legacy: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path), !manager.fileExists(atPath: directory.path) else { return }
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".watches-moving-\(UUID().uuidString)")
        do {
            let old = try SourceRunJSON.decoder().decode(LegacyWatchList.self, from: Data(contentsOf: legacy))
            try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var taken = Set<String>()
            for var watch in old.watches.prefix(Self.watchLimit) {
                // What counted as right is where it starts from now, so a value taken out of expect later goes back to it.
                for index in watch.items.indices { watch.items[index].captured = watch.items[index].expected }
                let name = WatchListFiles.slug(watch.name, taken: taken)
                taken.insert(name)
                let folder = staging.appendingPathComponent(name)
                try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try WatchListFiles.write(WatchListFiles.definitionText(watch.definition), to: folder.appendingPathComponent(WatchListFiles.definition))
                try WatchListFiles.write(WatchListFiles.resultsText(watch), to: folder.appendingPathComponent(WatchListFiles.results))
            }
            try manager.moveItem(at: staging, to: directory)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let moved = legacy.deletingLastPathComponent().appendingPathComponent(legacy.lastPathComponent + ".moved-" + stamp)
            do { try manager.moveItem(at: legacy, to: moved) }
            catch { Log.info("watch list: moved the watches, but couldn't rename \(legacy.lastPathComponent): \(error.localizedDescription)") }
            Log.info("watch list: moved \(min(old.watches.count, Self.watchLimit)) watch(es) from \(legacy.lastPathComponent) into \(directory.lastPathComponent)/")
        } catch {
            try? manager.removeItem(at: staging)
            notice = "Your earlier watch list couldn't be moved into the watches folder, so it was left as \(legacy.lastPathComponent): "
                + Self.reason(error)
            Log.info("watch list: couldn't move \(legacy.lastPathComponent) into folders: \(Self.reason(error))")
        }
    }
}

/// The earlier single `watch-list.json`: every watch with its results, in one file.
struct LegacyWatchList: Codable {
    var version = 1
    var watches: [WatchListWatch]
}
