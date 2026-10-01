import Foundation

/// Your notes, one small file each in `~/.noteling/notes`, kept apart from tool packs. Saving one never rewrites
/// another, nothing reloads the packs, and a folder of one-note files is what a shared team folder can be later.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [StickyNote] = []
    let directory: URL

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
    }

    /// The notes on the scene: a page's by its key, an app's by its window.
    func notes(for ctx: ScreenContext?) -> [StickyNote] {
        guard let ctx else { return [] }
        let page = ctx.url.flatMap(PageKey.of)
        return notes.filter { $0.anchor.matchesScene(ctx, page: page) }
    }

    func save(_ note: StickyNote) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(note).write(to: file(for: note.id), options: .atomic)
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note } else { notes.append(note) }
    }

    func remove(_ id: String) throws {
        let url = file(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        notes.removeAll { $0.id == id }
    }

    /// Moves the notes kept in tool packs' `notes.json` here, once: each pack's file is renamed `notes.json.moved`
    /// after its notes are saved, so a pack is never read twice and nothing is lost if a save fails. Returns how many
    /// moved.
    @discardableResult
    func moveNotes(fromPacksIn root: URL) -> Int {
        let packs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var moved = 0
        for pack in packs {
            let file = pack.appendingPathComponent(NoteStore.fileName)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let kept = NoteStore.load(packDir: pack)
            do {
                for note in kept where !notes.contains(where: { $0.id == note.id }) { try save(note); moved += 1 }
                try FileManager.default.moveItem(at: file, to: pack.appendingPathComponent(NoteStore.fileName + ".moved"))
            } catch {
                Log.info("notes: could not move the notes in \(pack.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if moved > 0 { Log.info("notes: moved \(moved) note(s) out of tool packs into \(directory.path)") }
        return moved
    }

    /// A note's file: its id, which Noteling makes as a lowercase UUID; any other id is reduced to safe characters.
    private func file(for id: String) -> URL {
        let safe = String(id.lowercased().unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) })
        return directory.appendingPathComponent((safe.isEmpty ? "note" : safe) + ".json")
    }
}
