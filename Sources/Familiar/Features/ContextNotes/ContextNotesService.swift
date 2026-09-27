import Foundation

/// Keeps contextual notes in their existing tool-pack storage without owning chat
/// presentation or the pen's native interaction.
@MainActor
final class ContextNotesService {
    private let registry: ToolRegistry

    init(registry: ToolRegistry) {
        self.registry = registry
    }

    /// Editing an existing note preserves its original pack, even if its scene
    /// would currently select a different pack.
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
        try registry.removeNote(id: id)
    }
}
