import AppKit
import Foundation
import Testing
@testable import Familiar

/// Notes that find you: kept one file each in the notes store, stuck to a page by its key and to a control by the
/// page's own id first, counted for the bubble's badge on every page, and placed on the page from the page reader.
@Suite @MainActor
struct NotesStoreTests {
    // MARK: - The store

    @Test func eachNoteIsItsOwnFile() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = NotesStore(directory: fixture.notes)
        let first = fixture.note("a1", page: "https://portal.example.test/onboarding", text: "Request role Y first")
        let second = fixture.note("b2", page: "https://portal.example.test/onboarding", text: "Approval takes 2 days")
        try store.save(first)
        try store.save(second)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.notes.path)) == ["a1.json", "b2.json"])
        var edited = first
        edited.text = "Request role Y first, from your manager"
        try store.save(edited)
        try store.remove("b2")
        try store.remove("never-there")
        let reloaded = NotesStore(directory: fixture.notes)
        #expect(reloaded.notes == [edited])
        // A file that can't be read is skipped, not fatal.
        try "{not json".write(to: fixture.notes.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        #expect(NotesStore(directory: fixture.notes).notes == [edited])
    }

    @Test func notesKeptInToolPacksMoveOnce() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let pack = fixture.tools.appendingPathComponent("portal")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let old = StickyNote(id: "old-1", anchor: NoteAnchor(host: "portal.example.test", role: "AXButton", label: "Submit"),
                             kind: "warning", text: "Check the total", by: "Fixture", at: "2026-09-01", confirmed: "2026-09-01")
        try NoteStore.save([old], packDir: pack)
        let store = NotesStore(directory: fixture.notes)
        #expect(store.moveNotes(fromPacksIn: fixture.tools) == 1)
        #expect(store.notes == [old])
        #expect(!FileManager.default.fileExists(atPath: pack.appendingPathComponent("notes.json").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: pack.path).contains { $0.hasPrefix("notes.json.moved-") })
        #expect(store.moveNotes(fromPacksIn: fixture.tools) == 0)   // never twice

        // The file comes back, from a sync or a checkout: a note removed since stays removed, and is never read twice.
        try store.remove(old.id)
        try NoteStore.save([old], packDir: pack)
        #expect(store.moveNotes(fromPacksIn: fixture.tools) == 0 && NotesStore(directory: fixture.notes).notes.isEmpty)
    }

    @Test func aPackFileThatCantBeReadIsLeftForLater() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let pack = fixture.tools.appendingPathComponent("portal")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try "{\"notes\": [{\"id\": \"x\"}]}".write(to: pack.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
        let store = NotesStore(directory: fixture.notes)
        #expect(store.moveNotes(fromPacksIn: fixture.tools) == 0)
        #expect(FileManager.default.fileExists(atPath: pack.appendingPathComponent("notes.json").path))   // still there to fix
    }

    @Test func theNewerCopyWinsAndASharedFolderKeepsItsFile() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = NotesStore(directory: fixture.notes)
        var mine = fixture.note("same", page: "https://portal.example.test/a", text: "Mine")
        mine.confirmed = "2026-09-20"
        try store.save(mine)
        var older = mine; older.text = "Older"; older.confirmed = "2026-09-01"
        var newer = mine; newer.text = "Newer"; newer.confirmed = "2026-09-30"
        for (name, note) in [("a", older), ("b", newer)] {
            let pack = fixture.tools.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
            try NoteStore.save([note], packDir: pack)
        }
        #expect(store.moveNotes(fromPacksIn: fixture.tools, rename: false) == 1)
        #expect(store.notes.map(\.text) == ["Newer"])
        #expect(FileManager.default.fileExists(atPath: fixture.tools.appendingPathComponent("b/notes.json").path))   // left for the others
        #expect(store.moveNotes(fromPacksIn: fixture.tools, rename: false) == 0)   // and taking it in again changes nothing
    }

    @Test func noTwoIdsShareAFile() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = NotesStore(directory: fixture.notes)
        for id in ["备注", "提示", "A.b", "ab", "0e9f-uuid"] { try store.save(fixture.note(id, page: "https://portal.example.test/", text: id)) }
        #expect(Set(NotesStore(directory: fixture.notes).notes.map(\.id)) == ["备注", "提示", "A.b", "ab", "0e9f-uuid"])
        try store.remove("备注")
        #expect(Set(NotesStore(directory: fixture.notes).notes.map(\.id)) == ["提示", "A.b", "ab", "0e9f-uuid"])
        #expect(NotesStore.file(for: "0e9f-uuid", in: fixture.notes).lastPathComponent == "0e9f-uuid.json")
    }

    @Test func thePenKeepsNotesInTheStoreAndTakesThemOutOfPacks() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let pack = fixture.tools.appendingPathComponent("portal")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try "---\nname: portal\nmatch:\n  urls: [portal.example.test]\n---\n".write(to: pack.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        var old = fixture.note("old-1", page: "https://portal.example.test/onboarding", text: "Old")
        try NoteStore.save([old], packDir: pack)
        let registry = ToolRegistry(root: fixture.tools, runner: ScriptRunner(config: Config()))
        await registry.reload()
        registry.notesStore = NotesStore(directory: fixture.notes)
        let service = ContextNotesService(registry: registry)
        old.text = "Edited with the pen"
        #expect(try await service.keep(old, appName: "Browser") == "notes")
        #expect(registry.pack(holding: old.id) == nil && NoteStore.load(packDir: pack).isEmpty)
        #expect(registry.notes(for: fixture.scene("https://portal.example.test/onboarding")) == [old])
        try service.remove(old.id)
        #expect(registry.notes(for: fixture.scene("https://portal.example.test/onboarding")).isEmpty)
    }

    // MARK: - Which page

    @Test func aNoteIsOnItsPageOnly() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = NotesStore(directory: fixture.notes)
        try store.save(fixture.note("lib", page: "http://127.0.0.1:4310/?page=library", text: "Library note"))
        try store.save(fixture.note("form", page: "https://example.service-now.com/nav_to.do?uri=sc_cat_item.do%3Fsys_id%3Dabc", text: "Request role Y first"))
        #expect(store.notes(for: fixture.scene("http://127.0.0.1:4310/?page=library&q=tax")).map(\.id) == ["lib"])
        #expect(store.notes(for: fixture.scene("http://127.0.0.1:4310/?page=attention")).isEmpty)   // once every page showed every note
        // However the record was reached.
        #expect(store.notes(for: fixture.scene("https://example.service-now.com/sc_cat_item.do?sys_id=abc&sysparm_view=x")).map(\.id) == ["form"])
        #expect(store.notes(for: fixture.scene("https://example.service-now.com/sc_cat_item.do?sys_id=zzz")).isEmpty)
        #expect(store.notes(for: nil).isEmpty)
    }

    @Test func notesFromBeforePageKeysStillMatchTheirSite() {
        let legacy = NoteAnchor(host: "portal.example.test", path: "/catalog", role: "AXButton", label: "Submit")
        let fixture = Fixture()
        #expect(legacy.matchesScene(fixture.scene("https://portal.example.test/catalog?x=1")))
        #expect(!legacy.matchesScene(fixture.scene("https://portal.example.test/other")))
    }

    @Test func aNoteMadeInABrowserNamesItsPage() {
        let anchor = NoteStore.sceneAnchor(bundleID: "com.google.Chrome", windowTitle: "Item", url: "http://127.0.0.1:4310/?page=library")
        #expect(anchor.page?.description == "127.0.0.1:4310/?page=library" && anchor.host == "127.0.0.1:4310")
        let native = NoteStore.sceneAnchor(bundleID: "com.apple.TextEdit", windowTitle: "Untitled", url: nil)
        #expect(native.page == nil && native.bundle == "com.apple.TextEdit")
    }

    // MARK: - On the page

    @Test func notesAreFoundByThePagesOwnIdFirst() {
        let page = PageSnapshot(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "Onboarding",
            documents: [PageDocument(url: "https://portal.example.test/onboarding", frame: nil)],
            elements: [
                PageElement(kind: "button", role: "AXButton", label: "Ask for access", domID: "request-btn",
                            frame: CGRect(x: 100, y: 200, width: 150, height: 30), visible: true, enabled: true, document: 0),
                PageElement(kind: "button", role: "AXButton", label: "Cancel", frame: CGRect(x: 300, y: 200, width: 80, height: 30),
                            visible: true, enabled: true, document: 0),
            ], selectedText: nil, windowFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), truncated: false, elapsed: 0)
        var renamed = NoteAnchor(role: "AXButton", label: "Request onboarding")   // the button was renamed since
        renamed.domID = "request-btn"
        let byLabel = NoteAnchor(role: "AXButton", label: "cancel")
        let spot = NoteAnchor(rect: [0.5, 0.5, 0.1, 0.05])
        let gone = NoteAnchor(role: "AXButton", label: "Delete everything")
        let notes = [renamed, byLabel, spot, gone].enumerated().map { index, anchor in
            StickyNote(id: "n\(index)", anchor: anchor, kind: "tip", text: "Note \(index)", by: "Fixture", at: "2026-10-01", confirmed: "2026-10-01")
        }
        let result = WandController.place(notes, page: page, primaryMaxY: 1_000)
        #expect(result.placed.map(\.note.id) == ["n0", "n1", "n2"] && result.missing.map(\.id) == ["n3"])
        // AppKit's bottom-left coordinates: a control 200 points from the top of a 1000-point screen.
        #expect(result.placed[0].frame == NSRect(x: 100, y: 770, width: 150, height: 30))
        #expect(result.placed[2].frame == NSRect(x: 500, y: 560, width: 100, height: 40))
    }

    @Test func anIdThePageMadeUpNeverPlacesANote() {
        #expect(NoteAnchor.isSteadyID("request-btn") && NoteAnchor.isSteadyID("submit"))
        for generated in ["ember412", ":r5:", "ext-gen12", "mat-input-3", "ui-id-4", "a1b2c3d4e5f6", "123abc"] {
            #expect(!NoteAnchor.isSteadyID(generated), "\(generated) looks made up")
        }
        func element(_ label: String, id: String, role: String = "AXButton", y: CGFloat, visible: Bool = true) -> PageElement {
            PageElement(kind: "button", role: role, label: label, domID: id, frame: CGRect(x: 10, y: y, width: 80, height: 20),
                        visible: visible, enabled: true, document: 0)
        }
        let page = PageSnapshot(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "", documents: [],
            elements: [element("Delete", id: "ember412", role: "AXLink", y: 100), element("Save", id: "save", y: 200),
                       element("Save", id: "save", y: 300), element("Archive", id: "archive", y: 2_000, visible: false)],
            selectedText: nil, truncated: false, elapsed: 0)
        func note(_ id: String, label: String, domID: String) -> StickyNote {
            var anchor = NoteAnchor(role: "AXButton", label: label)
            anchor.domID = domID
            return StickyNote(id: id, anchor: anchor, kind: "tip", text: id, by: "F", at: "", confirmed: "")
        }
        let result = WandController.place([note("generated", label: "Save changes", domID: "ember412"),
                                           note("twice", label: "Save changes", domID: "save"),
                                           note("below", label: "Archive", domID: "archive")], page: page, primaryMaxY: 1_000)
        // A made-up id and an id two controls share place nothing, and neither does a control below the fold.
        #expect(result.placed.isEmpty && result.missing.map(\.id) == ["generated", "twice", "below"])
        #expect(WandController.notice(unplaced: 3)?.hasPrefix("3 more notes here are for things not on screen") == true)
        #expect(WandController.notice(unplaced: 0) == nil)
    }

    @Test func theBadgeSaysWhatIsHereWarningsFirst() {
        let notes = [
            StickyNote(id: "t", anchor: NoteAnchor(), kind: "tip", text: "Approval takes 2 days", by: "A", at: "", confirmed: ""),
            StickyNote(id: "w", anchor: NoteAnchor(), kind: "warning", text: "Don't pick Premium", by: "B", at: "", confirmed: ""),
        ]
        #expect(NotesBadge.summary(notes) == "2 notes here:\n⚠︎ Don't pick Premium\n• Approval takes 2 days\nPress ⌥ Option twice, or click here, to show them on the page.")
    }

    @Test func optionPressedTwiceIsTheShortcut() {
        /// Feeds a run of Option downs ("d"), ups ("u"), other keys ("k") and Option with ⌘ ("c") at the given times,
        /// and says when the shortcut fired.
        func fired(_ steps: [(String, TimeInterval)]) -> [TimeInterval] {
            var tap = DoubleOptionTap(), out: [TimeInterval] = []
            for (step, time) in steps {
                switch step {
                case "d": if tap.flags(.option, at: time) { out.append(time) }
                case "u": if tap.flags([], at: time) { out.append(time) }
                case "c": if tap.flags([.option, .command], at: time) { out.append(time) }
                default: tap.key()
                }
            }
            return out
        }
        #expect(fired([("d", 0), ("u", 0.08), ("d", 0.2), ("u", 0.27)]) == [0.27])            // down, up, twice, quickly
        #expect(fired([("d", 0), ("u", 0.05), ("d", 0.6), ("u", 0.65)]).isEmpty)              // too slow between taps
        #expect(fired([("d", 0), ("u", 0.6), ("d", 0.7), ("u", 0.75)]).isEmpty)               // held, not tapped
        #expect(fired([("d", 0), ("u", 0.05), ("k", 0.07), ("d", 0.1), ("u", 0.15)]).isEmpty) // typing between
        #expect(fired([("d", 0), ("c", 0.05), ("u", 0.1), ("d", 0.2), ("u", 0.25)]).isEmpty)  // ⌥⌘, not Option alone
        // A third quick tap starts over rather than firing again.
        #expect(fired([("d", 0), ("u", 0.05), ("d", 0.1), ("u", 0.15), ("d", 0.2), ("u", 0.25)]) == [0.15])
        #expect(WandController.noNotes.hasPrefix("No notes here yet"))
    }

    // MARK: - Fixtures

    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-store-\(UUID())")
        var notes: URL { root.appendingPathComponent("notes") }
        var tools: URL { root.appendingPathComponent("tools") }

        func note(_ id: String, page url: String, text: String) -> StickyNote {
            var anchor = NoteStore.sceneAnchor(bundleID: "com.google.Chrome", windowTitle: "Page", url: url)
            anchor.role = "AXButton"
            anchor.label = "Submit"
            return StickyNote(id: id, anchor: anchor, kind: "tip", text: text, by: "Fixture", at: "2026-10-01", confirmed: "2026-10-01")
        }

        func scene(_ url: String) -> ScreenContext {
            ScreenContext(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "Page", url: url, focused: nil, timestamp: Date())
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
