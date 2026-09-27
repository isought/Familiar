import Foundation
import Testing
@testable import Familiar

@Suite @MainActor
struct ContextNotesServiceTests {
    @Test
    func editingANotePreservesItsOriginalPackInsteadOfMovingItToTheMatchingPack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalDirectory = try fixture.pack("original", host: "old.example.test")
        let matchingDirectory = try fixture.pack("matching", host: "new.example.test")
        var note = fixture.note(id: "kept-note", host: "new.example.test", text: "Original text")
        try NoteStore.save([note], packDir: originalDirectory)
        let registry = await fixture.registry()
        let service = ContextNotesService(registry: registry)

        note.text = "Updated text"
        let savedPack = try await service.save(note, appName: "Browser")

        #expect(savedPack.dirName == "original")
        #expect(NoteStore.load(packDir: originalDirectory) == [note])
        #expect(NoteStore.load(packDir: matchingDirectory).isEmpty)
        await registry.reload()
        #expect(registry.pack(holding: note.id)?.dirName == "original")
        #expect(registry.pack(holding: note.id)?.notes == [note])
    }

    @Test
    func newSceneCreatesAndReusesAMatchingPackWithPersistedNotes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let registry = await fixture.registry()
        let service = ContextNotesService(registry: registry)
        let first = fixture.note(id: "first", host: "new.example.test", text: "Check the total")
        let second = fixture.note(id: "second", host: "new.example.test", text: "Review the date")

        let created = try await service.save(first, appName: "Browser")
        let reused = try await service.save(second, appName: "Browser")

        #expect(created.dir == reused.dir)
        #expect(created.match.matches(first.anchor.sceneContext))
        #expect(FileManager.default.fileExists(atPath: created.dir.appendingPathComponent("SKILL.md").path))
        #expect(NoteStore.load(packDir: created.dir) == [first, second])
        await registry.reload()
        #expect(registry.packs.count == 1)
        #expect(registry.notes(for: first.anchor.sceneContext) == [first, second])
    }

    @Test
    func deletingOneNotePersistsWithoutRemovingItsNeighbors() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = try fixture.pack("notes", host: "notes.example.test")
        let first = fixture.note(id: "remove-me", host: "notes.example.test", text: "Obsolete")
        let second = fixture.note(id: "keep-me", host: "notes.example.test", text: "Still useful")
        try NoteStore.save([first, second], packDir: directory)
        let registry = await fixture.registry()
        let service = ContextNotesService(registry: registry)

        try service.remove(first.id)
        try service.remove("already-absent")

        #expect(NoteStore.load(packDir: directory) == [second])
        await registry.reload()
        #expect(registry.pack(holding: first.id) == nil)
        #expect(registry.pack(holding: second.id)?.notes == [second])
    }

    @Test
    func failedWritesAndDeletesSurfaceErrorsAndLeaveLoadedNotesIntact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = try fixture.pack("notes", host: "notes.example.test")
        let note = fixture.note(id: "existing", host: "notes.example.test", text: "Saved text")
        try NoteStore.save([note], packDir: directory)
        let registry = await fixture.registry()
        let service = ContextNotesService(registry: registry)

        // A directory at the destination makes writes fail consistently without
        // depending on process privileges or filesystem permission handling.
        let destination = directory.appendingPathComponent(NoteStore.fileName)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var changed = note
        changed.text = "Must not enter the in-memory registry"
        var saveFailed = false
        do { _ = try await service.save(changed, appName: nil) }
        catch { saveFailed = true }
        #expect(saveFailed)
        #expect(registry.pack(holding: note.id)?.notes == [note])

        var deleteFailed = false
        do { try service.remove(note.id) }
        catch { deleteFailed = true }
        #expect(deleteFailed)
        #expect(registry.pack(holding: note.id)?.notes == [note])
    }

    @MainActor
    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-context-notes-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func pack(_ name: String, host: String) throws -> URL {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: \(name)\nmatch:\n  urls: [\(host)]\n---\nFixture notes.\n"
                .write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            return directory
        }

        func note(id: String, host: String, text: String) -> StickyNote {
            StickyNote(id: id, anchor: NoteAnchor(host: host, role: "AXButton", label: "Submit"), kind: "tip",
                       text: text, by: "Fixture", at: "2026-01-01", confirmed: "2026-01-01")
        }

        func registry() async -> ToolRegistry {
            let registry = ToolRegistry(root: root, runner: ScriptRunner(config: Config()))
            await registry.reload()
            return registry
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
