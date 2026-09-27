import Foundation
import Testing
@testable import Familiar

@Suite
@MainActor
struct PackContextProviderTests {
    @Test
    func sceneSelectionIncludesMatchingNotesFromEveryPack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let registry = await fixture.registry()
        var checkedPacks: [String] = []
        let context = PackContextProvider.context(for: fixture.scene, registry: registry, docsLimit: 100,
                                                 missingRequirements: { packs in
            checkedPacks = packs.map(\.dirName)
            return packs.filter { !$0.requires.isEmpty }.map { ($0, $0.requires) }
        })

        #expect(context.active.map(\.dirName) == ["active"])
        #expect(context.global.map(\.dirName) == ["shared"])
        #expect(context.others.map(\.dirName) == ["other"])
        #expect(checkedPacks == ["active", "shared"])
        #expect(context.sceneNotes.map(\.id) == ["on-scene"])
        #expect(context.promptSection.contains("Active tool pack: Expenses"))
        #expect(context.promptSection.contains("Shared tool pack: Shared"))
        #expect(context.promptSection.contains("On button “Submit” on expenses.example.test: [warning] Check the total"))
        #expect(!context.promptSection.contains("Unrelated note"))
        #expect(!context.promptSection.contains("Other private instructions"))
        #expect(context.promptSection.contains("Expenses needs FIXTURE_EXPENSE_KEY"))
        #expect(!context.promptSection.contains("FIXTURE_OTHER_KEY"))
    }

    @Test
    func penAndHeadlessOptionsKeepSelectionWithoutDuplicatingNotesOrSetupNotices() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let registry = await fixture.registry()
        var lookupCalls = 0
        let context = PackContextProvider.context(for: fixture.scene, registry: registry, docsLimit: 100,
                                                 includeNotes: false, includeMissingRequirements: false,
                                                 missingRequirements: { _ in lookupCalls += 1; return [] })

        #expect(context.sceneNotes.map(\.id) == ["on-scene"])
        #expect(context.active.map(\.dirName) == ["active"])
        #expect(!context.promptSection.contains("Notes left"))
        #expect(!context.promptSection.contains("Check the total"))
        #expect(!context.promptSection.contains("Not configured yet"))
        #expect(context.missingRequirements.isEmpty)
        #expect(lookupCalls == 0)
    }

    @Test
    func absentSceneUsesOnlyGlobalPacksAndKeepsDocumentBudget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let registry = await fixture.registry()
        let absent = PackContextProvider.context(for: nil, registry: registry, docsLimit: 0,
                                                missingRequirements: { _ in [] })
        #expect(absent.active.isEmpty)
        #expect(absent.global.map(\.dirName) == ["shared"])
        #expect(absent.others.map(\.dirName) == ["active", "other"])
        #expect(absent.sceneNotes.isEmpty)
        #expect(absent.promptSection.contains("No tool pack matched the current app/URL."))
        #expect(absent.promptSection.contains("shared/docs/guide.md (5 chars, use read_file)"))
        #expect(!absent.promptSection.contains("<file path="))

        let limited = PackContextProvider.context(for: fixture.scene, registry: registry, docsLimit: 6,
                                                 missingRequirements: { _ in [] })
        #expect(limited.promptSection.contains("<file path=\"active/docs/guide.md\">\nABCD\n</file>"))
        #expect(limited.promptSection.contains("shared/docs/guide.md (5 chars, use read_file)"))
        #expect(!limited.promptSection.contains("<file path=\"shared/docs/guide.md\">"))
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let scene = ScreenContext(appName: "Browser", bundleID: "test.browser", windowTitle: "Expenses",
                                  url: "https://expenses.example.test/reports", focused: nil,
                                  timestamp: Date(timeIntervalSince1970: 0))

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-pack-context-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                try writePack("active", skill: """
                ---
                name: Expenses
                requires: [FIXTURE_EXPENSE_KEY]
                match:
                  urls: [expenses.example.test]
                ---
                Expense instructions
                """, doc: "ABCD")
                try writePack("shared", skill: """
                ---
                name: Shared
                ---
                Shared instructions
                """, doc: "EFGHI")
                try writePack("other", skill: """
                ---
                name: Other
                requires: [FIXTURE_OTHER_KEY]
                match:
                  urls: [other.example.test]
                ---
                Other private instructions
                """, doc: "Other private document")
                // A note belongs to its anchored scene, even when its containing pack is not active there.
                try NoteStore.save([note(id: "on-scene", host: "expenses.example.test", text: "Check the total")],
                                   packDir: root.appendingPathComponent("other"))
                try NoteStore.save([note(id: "off-scene", host: "other.example.test", text: "Unrelated note")],
                                   packDir: root.appendingPathComponent("active"))
            } catch {
                remove()
                throw error
            }
        }

        func writePack(_ name: String, skill: String, doc: String) throws {
            let dir = root.appendingPathComponent(name)
            let docs = dir.appendingPathComponent("docs")
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            try skill.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try doc.write(to: docs.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        }

        func note(id: String, host: String, text: String) -> StickyNote {
            StickyNote(id: id, anchor: NoteAnchor(host: host, role: "AXButton", label: "Submit"), kind: "warning",
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
