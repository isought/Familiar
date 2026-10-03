import CryptoKit
import Foundation

/// Your notes, one small file each in `~/.noteling/notes`, kept apart from tool packs. Saving one never rewrites
/// another, nothing reloads the packs, and a folder of one-note files is what a shared team folder can be later.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [StickyNote] = []
    let directory: URL
    /// Ids of notes removed here, so a pack's notes.json that comes back (a sync, a checkout) can't bring them back.
    private var removed: Set<String> = []
    private var removedFile: URL { directory.appendingPathComponent(".removed") }

    init(directory: URL = Config.dir.appendingPathComponent("notes")) {
        self.directory = directory
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        notes = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            do { return try JSONDecoder().decode(StickyNote.self, from: Data(contentsOf: url)) }
            catch { Log.info("notes: cannot read \(url.lastPathComponent): \(error.localizedDescription)"); return nil }
        }
        removed = Set(((try? String(contentsOf: removedFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    }

    /// The notes on the scene: a page's by its key, an app's by its window.
    func notes(for ctx: ScreenContext?) -> [StickyNote] {
        guard let ctx else { return [] }
        let page = ctx.url.flatMap(PageKey.of)
        return notes.filter { $0.anchor.matchesScene(ctx, page: page) }
    }

    /// Whether a copy of this note kept in a pack is out of date: the store has its own, or removed it.
    func supersedes(_ id: String) -> Bool { removed.contains(id) || notes.contains { $0.id == id } }

    func save(_ note: StickyNote) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(note).write(to: Self.file(for: note.id, in: directory), options: .atomic)
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note } else { notes.append(note) }
    }

    func remove(_ id: String) throws {
        let url = Self.file(for: id, in: directory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        notes.removeAll { $0.id == id }
        if removed.insert(id).inserted {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? removed.sorted().joined(separator: "\n").write(to: removedFile, atomically: true, encoding: .utf8)
        }
    }

    /// Takes in the notes that tool packs keep in `notes.json`, from earlier versions or a shared folder. A note
    /// already here is replaced only by a copy confirmed later; one removed here is never taken in again; and a file
    /// that can't be read is left alone, to be read once it is fixed. With `rename`, each file read in full is renamed
    /// `notes.json.moved-<time>`; without it (a tools folder shared with others) it stays for them, and taking it in
    /// again changes nothing. Returns how many notes came in or were updated.
    @discardableResult
    func moveNotes(fromPacksIn root: URL, rename: Bool = true) -> Int {
        let packs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var moved = 0
        for pack in packs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = pack.appendingPathComponent(NoteStore.fileName)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                let kept = try NoteStore.read(packDir: pack)
                for note in kept where !removed.contains(note.id) {
                    if let current = notes.first(where: { $0.id == note.id }) {
                        guard note.confirmed > current.confirmed else {
                            if note != current { Log.info("notes: kept the newer copy of \(note.id) over the one in \(pack.lastPathComponent)") }
                            continue
                        }
                    }
                    try save(note)
                    moved += 1
                }
                if rename {
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                    try FileManager.default.moveItem(at: file, to: pack.appendingPathComponent(NoteStore.fileName + ".moved-" + stamp))
                }
            } catch {
                Log.info("notes: left \(pack.lastPathComponent)/\(NoteStore.fileName) where it is: \(error.localizedDescription)")
            }
        }
        if moved > 0 { Log.info("notes: took in \(moved) note(s) from tool packs into \(directory.path)") }
        return moved
    }

    /// A note's file: its id when that is already a plain lowercase id, as Noteling makes them; any other id gets a
    /// hash of itself added, so two ids never share a file.
    static func file(for id: String, in directory: URL) -> URL {
        let safe = String(id.lowercased().unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) })
        guard safe != id || safe.isEmpty else { return directory.appendingPathComponent(safe + ".json") }
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent((safe.isEmpty ? "note" : String(safe.prefix(40))) + "-" + hash + ".json")
    }
}
