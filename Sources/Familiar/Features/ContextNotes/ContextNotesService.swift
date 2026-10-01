import Foundation

/// Keeps contextual notes: in the notes store when there is one, one file per note, else (and for notes from before
/// the store, until they move) in their tool pack, without owning chat presentation or the pen's native interaction.
@MainActor
final class ContextNotesService {
    private let registry: ToolRegistry

    init(registry: ToolRegistry) {
        self.registry = registry
    }

    /// Keeps a note where notes live: in the store when there is one, taking out a copy still kept in a pack; else
    /// in a pack, as `save` does. Says where it went.
    @discardableResult
    func keep(_ note: StickyNote, appName: String?) async throws -> String {
        guard let store = registry.notesStore else { return try await save(note, appName: appName).dirName }
        try store.save(note)
        if registry.pack(holding: note.id) != nil { try registry.removeNote(id: note.id) }
        return store.directory.lastPathComponent
    }

    /// Keeps a note in a tool pack. Editing an existing note preserves its original pack, even if its scene would
    /// currently select a different pack.
    func save(_ note: StickyNote, appName: String?) async throws -> ToolPack {
        let pack: ToolPack
        if let existing = registry.pack(holding: note.id) {
            pack = existing
        } else {
            pack = try await registry.packForNote(anchor: note.anchor, appName: appName)
        }
        try registry.put(note, in: pack)
        return pack
    }

    func remove(_ id: String) throws {
        try registry.notesStore?.remove(id)
        try registry.removeNote(id: id)
    }
}
