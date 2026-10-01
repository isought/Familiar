import AppKit
import Foundation
import Testing
@testable import Familiar

/// Notes in read mode: told by the pen with who said them and how long ago, linked to scripts that check what they
/// claim (run as the reader), found by the same rule the page uses, shown at the window's edge when their control is
/// missing, and counted in a local usage log that never holds a note's words.
@Suite @MainActor
struct NoteChecksTests {
    static let now = NoteStore.day.date(from: "2026-10-01")!

    func note(_ id: String, text: String = "Request role Y first", confirmed: String = "2026-09-28", kind: String = "tip",
              anchor: NoteAnchor = NoteAnchor(role: "AXButton", label: "Request onboarding"), check: NoteCheck? = nil) -> StickyNote {
        StickyNote(id: id, anchor: anchor, kind: kind, text: text, by: "Ana", at: "2026-09-01", confirmed: confirmed, check: check)
    }

    // MARK: - Who said it, and when

    @Test func aNoteSaysWhoSaidItAndHowLongAgo() {
        #expect(note("a", confirmed: "2026-10-01").confirmedWords(at: Self.now) == "confirmed today")
        #expect(note("a", confirmed: "2026-09-28").confirmedWords(at: Self.now) == "confirmed 3 days ago")
        #expect(note("a", confirmed: "2026-09-10").confirmedWords(at: Self.now) == "confirmed 3 wk ago")
        let old = note("a", confirmed: "2026-02-01")
        #expect(old.confirmedWords(at: Self.now) == "confirmed 8 mo ago" && old.isOld(at: Self.now))
        #expect(old.peopleSay(at: Self.now) == "PEOPLE SAY · Ana · confirmed 8 mo ago · may be out of date")
        #expect(note("a", confirmed: "someday").confirmedWords(at: Self.now) == "confirmed someday")
    }

    @Test func notesFromBeforeChecksStillLoad() throws {
        let json = #"{"id":"x","anchor":{"host":"portal.example.test"},"kind":"tip","text":"Old","by":"Ana","at":"2026-09-01","confirmed":"2026-09-01"}"#
        let decoded = try JSONDecoder().decode(StickyNote.self, from: Data(json.utf8))
        #expect(decoded.check == nil && decoded.text == "Old")
        let draft = NoteDraft(existingID: nil, anchor: NoteAnchor(), kind: "tip", text: " Hi ", frame: .zero, check: NoteCheck(script: "sn__roles"))
        #expect(NoteStore.make(draft, by: "Ana").check == NoteCheck(script: "sn__roles"))
    }

    // MARK: - Checks

    @Test func aChecksAnswerIsReadInItsOwnWords() {
        func parse(_ result: Any) -> NoteCheckResult {
            let data = try! JSONSerialization.data(withJSONObject: ["result": result, "stdout": ""])
            return NoteCheckResult.parse(String(decoding: data, as: UTF8.self), script: "servicenow__my_roles")
        }
        #expect(parse(["holds": false, "detail": "You don't have role Y."]) == .init(script: "servicenow__my_roles", verdict: .fails, detail: "You don't have role Y."))
        #expect(parse(["holds": true, "summary": "You have role Y."]).verdict == .holds)
        #expect(parse(["message": "Role requests take about 2 days."]).verdict == .info)
        #expect(parse(["error": "Not signed in."]).verdict == .unavailable)
        #expect(parse("Plain words").detail == "Plain words" && parse(true).verdict == .holds)
        // A number is not a verdict, and data without words never reaches the pad, only the model.
        let number = parse(1)
        #expect(number.verdict == .info && number.detail == "Ran, but didn't say whether this holds." && number.raw == "1")
        #expect(parse(["holds": 1]).verdict == .info && parse(["roles": ["admin"]]).raw == #"{"roles":["admin"]}"#)
        #expect(NoteCheckResult.parse("Traceback: boom", script: "x__y").detail == "Traceback: boom")
        #expect(parse(String(repeating: "a", count: 500)).detail.count == 301)
        #expect(parse(["holds": false, "detail": "You don't have role Y."]).line == "CHECKED · my_roles · as you: You don't have role Y.")
        #expect(NoteCheckResult(script: "x__roles", verdict: .unavailable, detail: "It needs TOKEN in Settings.").line
                == "Couldn't check (roles): It needs TOKEN in Settings.")
    }

    @Test func aCheckRunsFromTheToolsFolderAsTheReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("note-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = root.appendingPathComponent("servicenow")
        try FileManager.default.createDirectory(at: pack.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "---\nname: ServiceNow\nmatch:\n  urls: [example.service-now.com]\n---\nFixture.".write(to: pack.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try """
        def run() -> dict:
            \"\"\"Says whether you have role Y.\"\"\"
            return {"holds": False, "detail": "You don't have role Y."}
        """.write(to: pack.appendingPathComponent("scripts/my_roles.py"), atomically: true, encoding: .utf8)
        try """
        import time
        def run() -> dict:
            \"\"\"Never answers in time.\"\"\"
            time.sleep(5)
            return {"holds": True}
        """.write(to: pack.appendingPathComponent("scripts/slow.py"), atomically: true, encoding: .utf8)
        let registry = ToolRegistry(root: root, runner: ScriptRunner(config: Config()))
        await registry.reload()
        try #require(registry.script(named: "servicenow__my_roles") != nil)

        let checker = NoteChecker(registry: registry, timeout: 1.5)
        // Arguments the script doesn't declare are dropped, not passed on.
        let roles = await checker.run(NoteCheck(script: "servicenow__my_roles", args: ["url": "https://elsewhere.example.test"]), context: nil)
        #expect(roles.verdict == .fails && roles.detail == "You don't have role Y.")
        // The limit stops the script itself: the answer comes at the limit, not when the script would have finished.
        let started = Date()
        let slow = await checker.run(NoteCheck(script: "servicenow__slow"), context: nil)
        #expect(slow.verdict == .unavailable && slow.detail == "It took longer than 1 seconds.")
        #expect(Date().timeIntervalSince(started) < 4.5)
        // A check from a pack that isn't for this page doesn't run there.
        let elsewhere = ScreenContext(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "Mail", url: "https://mail.example.test/",
                                      focused: nil, timestamp: Date())
        let wrongPage = await checker.run(NoteCheck(script: "servicenow__my_roles"), context: elsewhere)
        #expect(wrongPage.verdict == .unavailable && wrongPage.detail == "This check isn't for this page.")
        let page = ScreenContext(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "Item",
                                 url: "https://example.service-now.com/sc_cat_item.do?sys_id=abc", focused: nil, timestamp: Date())
        #expect(await checker.run(NoteCheck(script: "servicenow__my_roles"), context: page).verdict == .fails)
        let missing = await checker.run(NoteCheck(script: "nowhere__check"), context: nil)
        #expect(missing.verdict == .unavailable && missing.detail == "This check isn't in your tools folder.")
    }

    // MARK: - Which notes are this control's

    @Test func thePenAndThePageFindTheSameNotes() {
        var renamed = NoteAnchor(role: "AXButton", label: "Request onboarding")
        renamed.domID = "request-btn"
        let element = AXElementInfo(role: "AXButton", title: "Ask for access", frame: NSRect(x: 0, y: 0, width: 80, height: 20), domID: "request-btn")
        #expect(WandController.belongs(note("a", anchor: renamed), to: element))   // by the page's own id, though renamed
        var otherRole = renamed
        otherRole.role = "AXLink"
        #expect(!WandController.belongs(note("b", anchor: otherRole), to: element))
        var generated = NoteAnchor(role: "AXButton", label: "Ask for access")
        generated.domID = "ember412"
        #expect(WandController.belongs(note("c", anchor: generated), to: element))   // a made-up id falls back to the label
        // What was pointed at must sit inside the noted control: its text yes, a container around it no.
        let button = NSRect(x: 100, y: 100, width: 120, height: 30)
        #expect(WandController.inside(NSRect(x: 110, y: 105, width: 80, height: 20), noted: button))
        #expect(!WandController.inside(NSRect(x: 0, y: 0, width: 1_000, height: 800), noted: button))
        #expect(!WandController.inside(NSRect(x: 0, y: 30, width: 100, height: 20), noted: button))
        #expect(!WandController.inside(NSRect(x: 101, y: 101, width: 2, height: 2), noted: button))   // too small: a pixel
    }

    @Test func notesForMissingControlsShowAtTheWindowsEdge() {
        let window = NSRect(x: 100, y: 100, width: 1_200, height: 800)
        let missing = (0..<5).map { note("m\($0)") }
        let edges = WandController.atEdge(missing, of: window, below: ["m1"])
        #expect(edges.count == WandController.edgeLimit)
        #expect(edges[0].note.text == "Not on your screen: button “Request onboarding”. Request role Y first")
        #expect(edges[1].note.text.hasPrefix("Further down the page: "))
        // Each sticker sits inside the window, one under the other, never overlapping.
        let tops = edges.map(\.frame.maxY)
        #expect(edges.allSatisfy { window.contains($0.frame.origin) } && tops == tops.sorted(by: >))
        #expect(zip(tops, tops.dropFirst()).allSatisfy { $0 - $1 >= 40 })
        // A short window holds fewer, and the notice counts the rest.
        #expect(WandController.atEdge(missing, of: NSRect(x: 0, y: 0, width: 800, height: 220)).count == 1)
        #expect(WandController.notice(unplaced: 2)?.hasPrefix("2 more notes here are for things not on screen") == true)
    }

    // MARK: - What the model is told

    @Test func theModelGetsClaimsWithTheirAgeAndChecks() {
        let current = note("a", confirmed: "2026-09-28", check: NoteCheck(script: "servicenow__my_roles"))
        let old = note("b", text: "Use item Z", confirmed: "2026-01-15", kind: "warning")
        let text = Prompt.notes(onTarget: [current], notOnScreen: [old], elsewhere: [],
                                checks: ["a": NoteCheckResult(script: "servicenow__my_roles", verdict: .fails, detail: "You don't have role Y.")], now: Self.now)
        #expect(text.contains("## Notes left on this control\n- Ana's note: \"Request role Y first\" (confirmed 3 days ago)\n  CHECKED · my_roles · as you: You don't have role Y.\n"))
        #expect(text.contains("## Notes on this page for controls not on the user's screen\n- For button “Request onboarding”: [warning] Ana's note: \"Use item Z\" (confirmed 8 mo ago, may be out of date)\n"))
        let below = Prompt.notes(onTarget: [], notOnScreen: [old], furtherDown: ["b"], elsewhere: [],
                                 checks: ["b": NoteCheckResult(script: "x__y", verdict: .info, detail: "Ran, but didn't say whether this holds.", raw: "{\"n\":1}")], now: Self.now)
        #expect(below.contains("For button “Request onboarding” (further down the page): ") && below.contains("(the check returned: {\"n\":1})"))
        #expect(!Prompt.system.contains("usually right") && Prompt.system.contains("Attribute them"))
    }

    // MARK: - The note editor

    @Test func aNoteCanBeLinkedToACheck() {
        let choices = [NoteEditor.CheckChoice(script: "servicenow__my_roles", title: "my_roles (ServiceNow)")]
        let editor = NoteEditor(existing: nil, place: "button “Request onboarding”", checks: choices)
        #expect(editor.frame.height == NoteEditor.height(withChecks: true) && editor.chosenCheck == nil)
        var committed: NoteCheck?
        editor.onCommit = { _, _, check in committed = check }
        editor.textView.string = "You need role Y"
        editor.selectCheck(at: 0)
        editor.commit()
        #expect(committed == NoteCheck(script: "servicenow__my_roles"))
        // A note linked to a check that isn't offered here keeps it, arguments and all.
        let kept = note("k", check: NoteCheck(script: "other__check", args: ["role": "Y"]))
        let reopened = NoteEditor(existing: kept, place: "x", checks: [])
        #expect(reopened.chosenCheck == NoteCheck(script: "other__check", args: ["role": "Y"]))
        // Switching to another script leaves the old arguments behind.
        let switched = NoteEditor(existing: kept, place: "x", checks: choices)
        switched.selectCheck(at: 0)
        #expect(switched.chosenCheck == NoteCheck(script: "servicenow__my_roles"))
        #expect(NoteEditor(existing: nil, place: "x").frame.height == NoteEditor.size.height)
    }

    // MARK: - Usage, on this Mac

    @Test func usageIsCountedWithoutWords() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID())/notes.jsonl")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = NotesUsageLog(file: file)
        log.record("arrive", counts: ["notes": 2, "warnings": 1], notes: ["a", "b"], at: Self.now)
        log.record("show", counts: ["notes": 2], tags: ["via": "shortcut"], at: Self.now)
        let events = log.read()
        #expect(events.map(\.event) == ["arrive", "show"] && events[0].counts == ["notes": 2, "warnings": 1] && events[1].tags == ["via": "shortcut"])
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("Request") && raw.split(separator: "\n").count == 2)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
