import Foundation
import Testing
@testable import Familiar

/// Each time the pack comes into view, the ledger records what opened it, the screen it opened on and how many cards
/// were waiting, on the local day. The launcher, the menu and the task panel count as the person opening it; chat,
/// Who's Who and a run are recorded but do not count. Moving between screens of an open pack is not an open, except
/// the first open that counts on a day the pack stayed open from the day before.
@Suite @MainActor
struct AttentionOpenedTests {
    @Test func anOpenIsLoggedWhenItShowsThePanelOrIsTheDaysFirstThatCounts() {
        for trigger in AttentionOpenTrigger.allCases {
            #expect(AttentionOpen.records(trigger, wasOpen: false, countedToday: false))
            #expect(AttentionOpen.records(trigger, wasOpen: false, countedToday: true))
            #expect(!AttentionOpen.records(trigger, wasOpen: true, countedToday: true))
            #expect(AttentionOpen.records(trigger, wasOpen: true, countedToday: false) == trigger.counts)
        }
    }

    @Test func aPackLeftOpenOvernightCountsTheNextDaysFirstOpenThatCounts() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let tuesday = Self.date("2026-09-29T13:00:00.000Z")          // Tue 09:00 in New York
        let tuesdayLate = Self.date("2026-09-30T03:59:00.000Z")      // Tue 23:59, already Wednesday in UTC
        let midnight = Self.date("2026-09-30T04:01:00.000Z")         // Wed 00:01
        let wednesday = Self.date("2026-09-30T12:30:00.000Z")        // Wed 08:30
        let thursdayChat = Self.date("2026-10-01T12:00:00.000Z")     // Thu 08:00
        let thursday = Self.date("2026-10-01T13:00:00.000Z")
        let ledger = fixture.ledger(clock: tuesday)
        ledger.recordOpened(.launcher, route: .folders, desk: 3, wasOpen: false)
        ledger.recordOpened(.menu, route: .folders, desk: 3, wasOpen: true)          // the same visit
        ledger.clock = { tuesdayLate }
        ledger.recordOpened(.taskPanel, route: .card(UUID()), desk: 3, wasOpen: true)
        #expect(fixture.opens.map(\.trigger) == [.launcher])

        // Still on screen after local midnight: opens that do not count stay unrecorded, the first that counts is kept.
        ledger.clock = { midnight }
        ledger.recordOpened(.chat, route: .sources, desk: 3, wasOpen: true)
        ledger.recordOpened(.people, route: .people, desk: 3, wasOpen: true)
        ledger.recordOpened(.run, route: .sourceRun(runID: UUID(), sourceID: nil), desk: 3, wasOpen: true)
        ledger.clock = { wednesday }
        ledger.recordOpened(.menu, route: .folders, desk: 2, wasOpen: true)
        ledger.recordOpened(.taskPanel, route: .card(UUID()), desk: 2, wasOpen: true)
        // A new visit is always recorded, whatever opened it; the day keeps the time of its first open that counts.
        ledger.recordOpened(.chat, route: .sources, desk: 2, wasOpen: false)
        ledger.clock = { wednesday.addingTimeInterval(3_600) }
        ledger.recordOpened(.launcher, route: .folders, desk: 2, wasOpen: false)
        #expect(fixture.opens.map(\.trigger) == [.launcher, .menu, .chat, .launcher])
        #expect(fixture.events.filter { $0.type == .opened }.map(\.day) == ["2026-09-29", "2026-09-30", "2026-09-30", "2026-09-30"])

        // After a relaunch the file says Wednesday already counts. On Thursday, chat opening the pack does not count,
        // so the first open that counts while it is open is still recorded.
        let relaunched = fixture.ledger(clock: wednesday.addingTimeInterval(7_200))
        #expect(relaunched.index.firstOpened == ["2026-09-29": tuesday, "2026-09-30": wednesday])
        relaunched.recordOpened(.menu, route: .folders, desk: 2, wasOpen: true)
        relaunched.clock = { thursdayChat }
        relaunched.recordOpened(.chat, route: .sources, desk: 1, wasOpen: false)
        relaunched.clock = { thursday }
        relaunched.recordOpened(.taskPanel, route: .card(UUID()), desk: 1, wasOpen: true)
        relaunched.recordOpened(.launcher, route: .folders, desk: 1, wasOpen: true)
        #expect(fixture.opens.map(\.trigger) == [.launcher, .menu, .chat, .launcher, .chat, .taskPanel])
        #expect(relaunched.index.firstOpened["2026-10-01"] == thursday)
    }

    @Test func anOpenAskedForDuringADesktopGrantIsHeldUntilThePackShows() {
        // The first request says whether the pack was open before the grant; a later open wins unless only the held
        // one counts.
        #expect(AttentionOpen.hold(.taskPanel, wasOpen: false, over: nil) == .init(trigger: .taskPanel, wasOpen: false))
        #expect(AttentionOpen.hold(.taskPanel, wasOpen: true, over: nil) == .init(trigger: .taskPanel, wasOpen: true))
        #expect(AttentionOpen.hold(.chat, wasOpen: true, over: .init(trigger: .menu, wasOpen: false))
                == .init(trigger: .menu, wasOpen: false))
        #expect(AttentionOpen.hold(.taskPanel, wasOpen: true, over: .init(trigger: .chat, wasOpen: false))
                == .init(trigger: .taskPanel, wasOpen: false))
        #expect(AttentionOpen.hold(.people, wasOpen: true, over: .init(trigger: .chat, wasOpen: false))
                == .init(trigger: .people, wasOpen: false))

        // Recorded when the grant ends: the pack came into view, or it was open already and today is not counted yet.
        let fixture = Fixture()
        defer { fixture.remove() }
        let ledger = fixture.ledger(clock: Self.date("2026-09-30T13:00:00.000Z"))
        let broughtIntoView = AttentionOpen.hold(.taskPanel, wasOpen: true, over: AttentionOpen.hold(.chat, wasOpen: false, over: nil))
        ledger.recordOpened(broughtIntoView.trigger, route: .card(UUID()), desk: 1, wasOpen: broughtIntoView.wasOpen)
        let openBefore = AttentionOpen.hold(.menu, wasOpen: true, over: nil)
        ledger.recordOpened(openBefore.trigger, route: .folders, desk: 1, wasOpen: openBefore.wasOpen)
        #expect(fixture.opens.map(\.trigger) == [.taskPanel])
    }

    @Test func recordOpenedKeepsTriggerRouteDeskAndLocalDay() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        // Late evening in New York is already the next day in UTC; the open belongs to the local day.
        let at = Self.date("2026-10-01T02:30:00.250Z")
        let ledger = fixture.ledger(clock: at)
        ledger.recordOpened(.taskPanel, route: .card(UUID()), desk: 4, wasOpen: false)

        let event = try #require(fixture.events.last)
        #expect(event.payload == .opened(.init(trigger: .taskPanel, route: "card", desk: 4)))
        #expect(event.at == at && event.day == "2026-09-30" && event.timeZone.identifier == "America/New_York")
        #expect(ledger.revision == 2 && ledger.error == nil)   // one write for `started`, one for the open
        let line = try #require(String(decoding: try Data(contentsOf: fixture.file), as: UTF8.self).split(separator: "\n").last)
        #expect(line.contains("\"type\":\"opened\"") && line.contains("\"trigger\":\"task_panel\"") && line.contains("\"desk\":4"))
        #expect(line.contains("\"at\":\"2026-09-30T22:30:00.250-04:00\""))

        // The screen is kept by a short name, never by the card, person or run it showed.
        let routes: [MorningNavigation.Route] = [.folders, .people, .sources, .sourceRun(runID: UUID(), sourceID: UUID()),
                                                 .folder(UUID()), .person(UUID()), .editCard(nil), .sourceRuns]
        for route in routes { ledger.recordOpened(.menu, route: route, desk: 0, wasOpen: false) }
        #expect(fixture.opens.map(\.route) == ["card", "folders", "people", "sources", "sourceRun", "other", "other", "other", "other"])
    }

    @Test func triggersThatCount() {
        let fixture = Fixture()
        defer { fixture.remove() }
        #expect(AttentionOpenTrigger.allCases.filter(\.counts) == [.launcher, .menu, .taskPanel])
        #expect(AttentionOpenTrigger.allCases.filter { !$0.counts } == [.chat, .people, .run])

        // Every trigger is still written down, so the rule can be changed later from the ledger alone.
        let ledger = fixture.ledger()
        for trigger in AttentionOpenTrigger.allCases { ledger.recordOpened(trigger, route: .folders, desk: 2, wasOpen: false) }
        #expect(fixture.opens.map(\.trigger) == AttentionOpenTrigger.allCases)
        #expect(fixture.events.map(\.type) == [.started] + Array(repeating: .opened, count: AttentionOpenTrigger.allCases.count))
    }

    // MARK: - Fixtures

    private static func date(_ text: String) -> Date { AttentionTime.date(text)! }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-opened-\(UUID())")
        var file: URL { root.appendingPathComponent("attention/signals.jsonl") }
        var events: [AttentionEvent] { AttentionLogFile.read(file).events }
        var opens: [AttentionEvent.Opened] { events.compactMap { if case .opened(let value) = $0.payload { return value }; return nil } }

        @MainActor func ledger(clock: Date = Date()) -> AttentionLedger {
            AttentionLedger(directory: root.appendingPathComponent("attention"), clock: { clock },
                            timeZone: TimeZone(identifier: "America/New_York")!)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
