import Foundation
import Testing
@testable import Familiar

/// The schedule: due watches start on a tick, at most two item checks run at once across all watches, a watch never has
/// two runs at once, results are saved and alerts go out by the rules. The check is a fake: no Python, no network.
@Suite @MainActor
struct WatchListRunnerTests {
    @Test func atMostTwoChecksRunAtOnceAcrossWatches() async throws {
        let fixture = try Fixture(items: 5)
        defer { fixture.remove() }
        let other = WatchListWatch(name: "Other", check: "shop__watch_item", items: (1...3).map { WatchListItem(key: "o\($0)") })
        try fixture.store.add(other)
        fixture.checks.delay = 20_000_000

        let first = fixture.runner.run(fixture.watchID)
        let second = fixture.runner.run(other.id)
        await first?.value
        await second?.value

        #expect(fixture.checks.calls.count == 8)
        #expect(fixture.checks.peak == 2)
        #expect(fixture.runner.checking.isEmpty)
    }

    @Test func aWatchNeverHasTwoRunsAtOnce() async throws {
        let fixture = try Fixture(items: 3)
        defer { fixture.remove() }
        fixture.checks.gate = Gate()

        let first = try #require(fixture.runner.run(fixture.watchID))
        try await fixture.until { fixture.checks.inFlight == 2 }
        let again = fixture.runner.run(fixture.watchID)          // Check now while it runs: the same run
        fixture.clock.now += 3_600
        fixture.runner.tick()                                     // due again, but running: nothing new
        #expect(again == first)
        #expect(fixture.runner.checking == [fixture.watchID])

        fixture.checks.gate?.open()
        await first.value
        #expect(fixture.checks.calls.sorted() == ["1", "2", "3"])
    }

    @Test func aTickStartsOnlyTheWatchesThatAreDue() async throws {
        let fixture = try Fixture(items: 2)
        defer { fixture.remove() }
        try fixture.store.change(fixture.watchID) { $0.lastRunAt = fixture.clock.now }
        let paused = WatchListWatch(name: "Paused", check: "shop__watch_item", items: [WatchListItem(key: "p")], paused: true)
        try fixture.store.add(paused)

        fixture.clock.now += 10 * 60
        fixture.runner.tick()
        #expect(fixture.runner.current(fixture.watchID) == nil)

        fixture.clock.now += 5 * 60
        fixture.runner.tick()
        await fixture.runner.current(fixture.watchID)?.value
        #expect(fixture.checks.calls.sorted() == ["1", "2"])      // the paused watch never ran
        #expect(fixture.store.watch(id: fixture.watchID)?.lastRunAt == fixture.clock.now)
        #expect(fixture.store.watch(id: paused.id)?.lastRunAt == nil)
    }

    @Test func resultsAreSavedAndAlertsFollowTheRules() async throws {
        let fixture = try Fixture(items: 2)
        defer { fixture.remove() }

        await fixture.runner.run(fixture.watchID)?.value          // the first check: what counts as right, no alert
        #expect(fixture.alerts.isEmpty)
        #expect(fixture.store.watch(id: fixture.watchID)?.items.allSatisfy { $0.status == .asExpected } == true)

        fixture.checks.next["1"] = [fixture.checks.reading(price: 13.95)]
        fixture.checks.next["2"] = [.failed("Signed out")]
        await fixture.runner.run(fixture.watchID)?.value
        #expect(fixture.alerts.map(\.title) == ["Item 1"])
        #expect(fixture.alerts.first?.body == "Price: 13.95 — expected 10")
        #expect(fixture.alerts.first?.watchName == "Sale items")

        fixture.checks.next["1"] = [fixture.checks.reading(price: 13.95)]
        fixture.checks.next["2"] = [.failed("Signed out")]
        await fixture.runner.run(fixture.watchID)?.value          // same differences again; second failure in a row
        #expect(fixture.alerts.map(\.body) == ["Price: 13.95 — expected 10", "Couldn't check: Signed out"])

        await fixture.runner.run(fixture.watchID)?.value          // both fine again: only the one told it was wrong hears it
        #expect(fixture.alerts.count == 3)
        #expect(fixture.alerts.last?.title == "Item 1" && fixture.alerts.last?.body == "Back to what you expected")

        let saved = WatchListStore(file: fixture.store.file).watch(id: fixture.watchID)
        #expect(saved?.items.map(\.status) == [.asExpected, .asExpected])
        #expect(saved?.items.map(\.title) == ["Item 1", "Item 2"])
    }

    @Test func aSiteThatIsDownForEveryItemIsOneNotification() async throws {
        let fixture = try Fixture(items: 5)
        defer { fixture.remove() }
        await fixture.runner.run(fixture.watchID)?.value
        for _ in 0..<2 {
            for key in ["1", "2", "3", "4"] { fixture.checks.next[key] = [.failed("Signed out of the shop")] }
            fixture.checks.next["5"] = [.failed("Item 5 isn't on the shop")]
            await fixture.runner.run(fixture.watchID)?.value
        }
        #expect(fixture.alerts.map(\.title) == ["Sale items", "Item 5"])
        #expect(fixture.alerts.map(\.body) == ["Couldn't check 4 items: Signed out of the shop", "Couldn't check: Item 5 isn't on the shop"])
        #expect(fixture.alerts.first?.itemKey == "")
    }

    @Test func whatTheChatWaitsForIsQuietAndWhatLandsLaterIsNot() async throws {
        let fixture = try Fixture(items: 1)
        defer { fixture.remove() }
        await fixture.runner.run(fixture.watchID)?.value

        let quiet = WatchListQuiet()
        fixture.checks.next["1"] = [fixture.checks.reading(price: 13.95)]
        await fixture.runner.run(fixture.watchID, quiet: quiet)?.value
        #expect(fixture.alerts.isEmpty)                            // the chat shows it

        fixture.checks.gate = Gate()
        fixture.checks.next["1"] = [fixture.checks.reading(price: 14.5)]
        let late = WatchListQuiet()
        let run = fixture.runner.run(fixture.watchID, quiet: late)
        #expect(await WatchListRunner.wait(for: run, atMost: 0.05) == false)   // the chat stops waiting
        late.on = false
        fixture.checks.gate?.open()
        await run?.value
        #expect(fixture.alerts.map(\.body) == ["Price: 14.50 — expected 10"])
    }

    @Test func checkingOnlyNewItemsLeavesTheScheduleAlone() async throws {
        let fixture = try Fixture(items: 2)
        defer { fixture.remove() }
        await fixture.runner.run(fixture.watchID)?.value
        let ran = fixture.store.watch(id: fixture.watchID)?.lastRunAt
        try fixture.store.change(fixture.watchID) { $0.items.append(WatchListItem(key: "3")) }
        fixture.clock.now += 60

        await fixture.runner.run(fixture.watchID, items: ["3"])?.value

        #expect(fixture.checks.calls.sorted() == ["1", "2", "3"])
        #expect(fixture.store.watch(id: fixture.watchID)?.lastRunAt == ran)
        #expect(fixture.store.watch(id: fixture.watchID)?.item("3")?.status == .asExpected)
    }

    @Test func stoppingAWatchMidRunDropsWhatWasStillToCome() async throws {
        let fixture = try Fixture(items: 4)
        defer { fixture.remove() }
        fixture.checks.gate = Gate()
        let run = fixture.runner.run(fixture.watchID)
        try await fixture.until { fixture.checks.inFlight == 2 }

        fixture.runner.cancel(fixture.watchID)
        try fixture.store.remove(fixture.watchID)
        fixture.checks.gate?.open()
        await run?.value

        #expect(fixture.checks.calls.count == 2)                   // the two waiting for a turn never ran
        #expect(fixture.alerts.isEmpty && fixture.store.watches.isEmpty)
    }

    @Test func waitingGivesUpAtItsLimitAndTheRunCarriesOn() async throws {
        let fixture = try Fixture(items: 1)
        defer { fixture.remove() }
        fixture.checks.gate = Gate()
        let run = fixture.runner.run(fixture.watchID)
        let started = Date()
        #expect(await WatchListRunner.wait(for: run, atMost: 0.05) == false)
        #expect(Date().timeIntervalSince(started) < 5)
        fixture.checks.gate?.open()
        #expect(await WatchListRunner.wait(for: run, atMost: 5) == true)
        #expect(fixture.store.watch(id: fixture.watchID)?.items.first?.status == .asExpected)
    }

    @Test func theRealCheckPassesOnlyTheArgumentsItsScriptDeclares() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-packs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shop"), withIntermediateDirectories: true)
        try "---\nname: Shop\nmatch:\n  urls: [shop.example.com/item/]\nrequires: [WATCH_LIST_TEST_TOKEN_NOT_SET]\nwatch: watch_item\n---\nItems."
            .write(to: root.appendingPathComponent("shop/SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plain"), withIntermediateDirectories: true)
        try "---\nname: Plain\n---\nNo watch."
            .write(to: root.appendingPathComponent("plain/SKILL.md"), atomically: true, encoding: .utf8)
        let registry = ToolRegistry(root: root, runner: ScriptRunner(config: Config()))
        await registry.reload()
        let shop = try #require(registry.packs.first { $0.dirName == "shop" })
        let schema: [String: Any] = ["type": "object", "required": ["item", "zip"], "properties": [
            "item": ["type": "string"], "zip": ["type": "string", "description": "Delivery zip code"], "color": ["type": "string"]]]
        shop.scripts = ["watch_item", "offers"].map { stem in
            ScriptTool(id: "shop__\(stem)", packDir: "shop", fileName: "\(stem).py", path: shop.dir.appendingPathComponent("scripts/\(stem).py"),
                       description: "Fixture", inputSchema: schema, dependencies: [])
        }

        let choices = WatchListChecker.choices(in: registry)
        #expect(choices == [WatchListCheckChoice(id: "shop__watch_item", pack: "Shop", packDir: "shop",
                                                 arguments: ["zip": "Delivery zip code", "color": ""], required: ["zip"],
                                                 missingSecrets: ["WATCH_LIST_TEST_TOKEN_NOT_SET"])])
        let args = WatchListChecker.arguments(for: shop.scripts[0], item: "https://shop.example.com/item/123",
                                              extra: ["zip": .number(10001), "size": .text("L"), "item": .text("other")])
        #expect(args.count == 2)
        #expect(args["item"] as? String == "https://shop.example.com/item/123")
        #expect(args["zip"] as? String == "10001")                // as the type the script declares
        #expect(WatchListChecker.typed(.text("3"), as: "integer") as? Int == 3)
        #expect(WatchListChecker.typed(.text("12.5"), as: "number") as? Double == 12.5)
        #expect(WatchListChecker.typed(.text("yes"), as: "boolean") as? Bool == true)
        #expect(WatchListChecker.typed(.flag(true), as: "string") as? String == "true")
        #expect(WatchListChecker.typed(.text("ten"), as: "integer") as? String == "ten")

        // Missing secrets, or a script that is no longer the pack's watch check, never run.
        let checker = WatchListChecker(registry: registry)
        let watch = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: [WatchListItem(key: "123")])
        #expect(await checker.check(watch, watch.items[0]) == .failed("It needs WATCH_LIST_TEST_TOKEN_NOT_SET in Settings."))
        var other = watch
        other.check = "shop__offers"
        #expect(await checker.check(other, watch.items[0]) == .failed("Its check, shop__offers, isn't in your tools folder any more."))

        let scene = WatchListChecker.scene(for: watch.items[0])
        #expect(scene.appName == "Watch list" && scene.bundleID.isEmpty && scene.url == nil && scene.windowTitle == "123")
        #expect(WatchListChecker.scene(for: WatchListItem(key: "https://shop.example.com/item/9")).url == "https://shop.example.com/item/9")
    }
}

/// A check that answers from a script of outcomes per item (a price of 10 when there is none left), and counts how many
/// run at once. A gate holds every check until it opens.
@MainActor
final class FakeWatchChecks {
    var calls: [String] = []
    var inFlight = 0
    var peak = 0
    var delay: UInt64 = 0
    var gate: Gate?
    var next: [String: [WatchListOutcome]] = [:]

    func check(_ watch: WatchListWatch, _ item: WatchListItem) async -> WatchListOutcome {
        calls.append(item.key)
        inFlight += 1
        peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        if let gate { await gate.wait() }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if var queued = next[item.key], !queued.isEmpty {
            let outcome = queued.removeFirst()
            next[item.key] = queued
            return outcome
        }
        return reading(price: 10, key: item.key)
    }

    func reading(price: Double, key: String = "1") -> WatchListOutcome {
        .checked(WatchListReading(title: "Item \(key)", url: "https://shop.example.com/item/\(key)", state: ["price": .number(price)],
                                  facts: #"{"seller":"Acme"}"#))
    }
}

@MainActor
final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
}

@MainActor
private final class Fixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("watch-runner-\(UUID().uuidString)")
    let store: WatchListStore
    let runner: WatchListRunner
    let checks = FakeWatchChecks()
    let clock = TestClock()
    var alerts: [WatchListAlert] = []
    let watchID: UUID

    init(items: Int) throws {
        store = WatchListStore(file: folder.appendingPathComponent("watch-list.json"))
        let checks = checks, clock = clock
        runner = WatchListRunner(store: store, check: { await checks.check($0, $1) }, now: { clock.now })
        let watch = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: (1...items).map { WatchListItem(key: "\($0)") })
        watchID = watch.id
        try store.add(watch)
        runner.onAlert = { [unowned self] in self.alerts.append($0) }
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    /// Lets the runner's tasks move until the condition holds.
    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        try #require(condition())
    }
}
