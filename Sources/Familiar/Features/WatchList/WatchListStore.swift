import Combine
import Foundation

/// The watches, kept in `watch-list.json` in Noteling's folder: written whole to a temporary file that only your account
/// can read, then moved into place, so a crash never leaves half a file.
@MainActor
final class WatchListStore: ObservableObject {
    @Published private(set) var watches: [WatchListWatch] = []
    /// An earlier watch list that couldn't be read was set aside: the window and the chat say so.
    @Published private(set) var notice: String?
    let file: URL

    static let watchLimit = 20
    static let itemLimit = 50

    private struct Saved: Codable {
        var version = 1
        var watches: [WatchListWatch]
    }

    init(file: URL = Config.dir.appendingPathComponent("watch-list.json")) {
        self.file = file
        load()
    }

    func watch(id: UUID) -> WatchListWatch? { watches.first { $0.id == id } }

    func add(_ watch: WatchListWatch) throws {
        guard watches.count < Self.watchLimit else {
            throw WatchListError("You're already watching \(Self.watchLimit) lists, the most Noteling keeps. Stop one first.")
        }
        try Self.validate(watch)
        watches.append(watch)
        do { try save() } catch { watches.removeAll { $0.id == watch.id }; throw error }
    }

    /// Changes one watch in place. A run keeps its results in memory as each item comes back (`persist: false`) and
    /// saves once at its end; anything the person changes is saved at once, and put back if saving fails.
    @discardableResult
    func change(_ id: UUID, persist: Bool = true, _ body: (inout WatchListWatch) throws -> Void) throws -> WatchListWatch {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { throw WatchListError("That watch was stopped.") }
        let before = watches[index]
        var watch = before
        try body(&watch)
        try Self.validate(watch)
        watches[index] = watch
        if persist {
            do { try save() } catch { watches[index] = before; throw error }
        }
        return watch
    }

    func remove(_ id: UUID) throws {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        let removed = watches.remove(at: index)
        do { try save() } catch { watches.insert(removed, at: index); throw error }
    }

    func save() throws {
        let manager = FileManager.default
        let directory = file.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try SourceRunJSON.encoder().encode(Saved(watches: watches))
        let temporary = directory.appendingPathComponent(".watch-list-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WatchListError("Couldn't save the watch list in \(directory.path).")
        }
        guard rename(temporary.path, file.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: file.path])
        }
    }

    private static func validate(_ watch: WatchListWatch) throws {
        guard watch.items.count <= itemLimit else {
            throw WatchListError("A watch holds up to \(itemLimit) items. Split them into two watches.")
        }
    }

    /// Nothing there yet is an empty list. A file that can't be read is set aside, never overwritten, and the list starts
    /// again empty, so watching keeps working.
    private func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return }
        do {
            let saved = try SourceRunJSON.decoder().decode(Saved.self, from: Data(contentsOf: file))
            watches = saved.watches
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let aside = file.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? manager.moveItem(at: file, to: aside)
            notice = "An earlier watch list couldn't be read, so it was set aside as \(aside.lastPathComponent)."
            Log.info("watch list: can't read \(file.lastPathComponent) (\(error.localizedDescription)); set aside as \(aside.lastPathComponent)")
        }
    }
}
