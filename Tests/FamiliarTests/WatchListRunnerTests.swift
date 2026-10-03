import Foundation
import Testing
@testable import Familiar

/// The schedule: due watches start on a tick, at most two checks run at once across all watches (a list check is one), a
/// watch never has two runs at once, hand edits are taken in, results are saved and alerts go out by the rules. The
/// checks are fakes: no Python, no network.
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
        await fixture.runner.run(fixture.watchID)?.value
        let paused = WatchListWatch(name: "Paused", check: "shop__watch_item", items: [WatchListItem(key: "p")], paused: true)
        try fixture.store.add(paused)

        fixture.clock.now += 10 * 60
        fixture.runner.tick()
        #expect(fixture.runner.current(fixture.watchID) == nil)

        fixture.clock.now += 5 * 60
        fixture.runner.tick()
        await fixture.runner.current(fixture.watchID)?.value
        #expect(fixture.checks.calls.sorted() == ["1", "1", "2", "2"])   // the paused watch never ran
        #expect(fixture.store.watch(id: fixture.watchID)?.lastRunAt == fixture.clock.now)
        #expect(fixture.store.watch(id: paused.id)?.lastRunAt == nil)
    }

    @Test func itemsNoCheckHasLookedAtAreCheckedAtTheNextTick() async throws {
        let fixture = try Fixture(items: 2)
        defer { fixture.remove() }
        await fixture.runner.run(fixture.watchID)?.value
        try fixture.store.change(fixture.watchID) { $0.items.append(WatchListItem(key: "3")) }   // as when Noteling quit mid-run
        fixture.runner.tick()
        await fixture.runner.current(fixture.watchID)?.value
        #expect(fixture.checks.calls.sorted() == ["1", "2", "3"])
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

        let saved = fixture.place.store().watch(id: fixture.watchID)
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
        #expect(unavailable(await checker.plan(watch)) == "It needs WATCH_LIST_TEST_TOKEN_NOT_SET in Settings.")
        var other = watch
        other.check = "shop__offers"
        #expect(unavailable(await checker.plan(other)) == "Its check, shop__offers, isn't in your tools folder any more.")
        other.check = ""   // a watch.json that names no check uses the only one there is
        #expect(unavailable(await checker.plan(other)) == "It needs WATCH_LIST_TEST_TOKEN_NOT_SET in Settings.")

        let scene = WatchListChecker.scene(for: watch.items[0])
        #expect(scene.appName == "Watch list" && scene.bundleID.isEmpty && scene.url == nil && scene.windowTitle == "123")
        #expect(WatchListChecker.scene(for: WatchListItem(key: "https://shop.example.com/item/9")).url == "https://shop.example.com/item/9")
    }

    // MARK: list checks

    @Test func aListCheckIsCalledOncePerRunWithAllItemsAndCountsAsOneOfTheTwo() async throws {
        let lists = FakeListChecks()
        let fixture = try Fixture(items: 5, prepare: { watch in .wholeList { items in await lists.check(watch, items) } })
        defer { fixture.remove() }
        let second = WatchListWatch(name: "Other list", check: "c", items: (1...3).map { WatchListItem(key: "o\($0)") })
        let third = WatchListWatch(name: "Third list", check: "c", items: [WatchListItem(key: "t1")])
        try fixture.store.add(second)
        try fixture.store.add(third)
        lists.gate = Gate()

        let runs = [fixture.watchID, second.id, third.id].compactMap { fixture.runner.run($0) }
        try await fixture.until { lists.inFlight == 2 }
        for _ in 0..<50 { await Task.yield() }
        #expect(lists.inFlight == 2)                   // the third list waits for a turn
        lists.gate?.open()
        for run in runs { await run.value }

        #expect(lists.calls.count == 3 && lists.peak == 2)
        #expect(lists.calls.first { $0.first == "1" } == ["1", "2", "3", "4", "5"])
        let watch = try #require(fixture.store.watch(id: fixture.watchID))
        #expect(watch.items.allSatisfy { $0.status == .asExpected && $0.title == "Listed \($0.key)" })
    }

    @Test func whatAListCheckLeftOutIsCouldNotCheckAndAFailedRunIsOneNotification() async throws {
        let lists = FakeListChecks()
        let fixture = try Fixture(items: 4, prepare: { watch in .wholeList { items in await lists.check(watch, items) } })
        defer { fixture.remove() }
        lists.leaveOut = ["3"]
        await fixture.runner.run(fixture.watchID)?.value
        let item = try #require(fixture.store.watch(id: fixture.watchID)?.item("3"))
        #expect(item.status == .couldNotCheck("The check returned nothing for this item."))

        lists.leaveOut = []
        await fixture.runner.run(fixture.watchID)?.value   // all fine again
        lists.failure = "Signed out of the shop"
        await fixture.runner.run(fixture.watchID)?.value
        await fixture.runner.run(fixture.watchID)?.value
        #expect(fixture.alerts.map(\.body) == ["Couldn't check 4 items: Signed out of the shop"])
        #expect(fixture.store.watch(id: fixture.watchID)?.items.allSatisfy { $0.status == .couldNotCheck("Signed out of the shop") } == true)
    }

    @Test func aCheckThatTakesOneItemAtATimeChecks50AtMost() async throws {
        let fixture = try Fixture(items: 52)
        defer { fixture.remove() }
        await fixture.runner.run(fixture.watchID)?.value
        #expect(fixture.checks.calls.count == 50)
        let watch = try #require(fixture.store.watch(id: fixture.watchID))
        #expect(watch.item("51")?.status == .couldNotCheck(WatchListRunner.overLimit))
        #expect(watch.item("50")?.status == .asExpected)
    }

    // MARK: hand edits

    @Test func anItemAddedByHandIsCheckedAtTheNextTickAndAPausedWatchStops() async throws {
        let fixture = try Fixture(items: 2)
        defer { fixture.remove() }
        await fixture.runner.run(fixture.watchID)?.value
        let ran = fixture.store.watch(id: fixture.watchID)?.lastRunAt
        try fixture.place.edit("sale-items") { $0["items"] = ["1", "2", "3"] }

        fixture.runner.tick()
        await fixture.runner.current(fixture.watchID)?.value

        #expect(fixture.checks.calls.sorted() == ["1", "2", "3"])
        #expect(fixture.store.watch(id: fixture.watchID)?.item("3")?.status == .asExpected)
        #expect(fixture.store.watch(id: fixture.watchID)?.lastRunAt == ran)   // not a run of the whole watch

        try fixture.place.edit("sale-items") { $0["paused"] = true }
        fixture.clock.now += 3_600
        fixture.runner.tick()
        #expect(fixture.runner.current(fixture.watchID) == nil)
    }

    @Test func aRunUsesWhatWatchJsonSaysRightBeforeIt() async throws {
        let fixture = try Fixture(items: 1)
        defer { fixture.remove() }
        await fixture.runner.run(fixture.watchID)?.value
        try fixture.place.edit("sale-items") { $0["expect"] = ["price": 12.33] }

        fixture.checks.next["1"] = [fixture.checks.reading(price: 10)]
        await fixture.runner.run(fixture.watchID)?.value   // "Check now", before any tick

        #expect(fixture.alerts.map(\.body) == ["Price: 10 — expected 12.33"])
    }

    @Test func aWatchWhoseFolderIsDeletedStopsAtTheNextTick() async throws {
        let fixture = try Fixture(items: 2)
        defer { fixture.remove() }
        fixture.checks.gate = Gate()
        let run = fixture.runner.run(fixture.watchID)
        try await fixture.until { fixture.checks.inFlight == 2 }
        try FileManager.default.removeItem(at: fixture.place.watches.appendingPathComponent("sale-items"))
        fixture.runner.tick()
        fixture.checks.gate?.open()
        await run?.value
        #expect(fixture.store.watches.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.place.watches.appendingPathComponent("sale-items").path))   // not brought back
    }

    // MARK: the real check

    @Test func aWatchsOwnCheckIsUsedInsteadOfThePacksAndGetsOnlyTheSecretsItsWatchJsonLists() async throws {
        let place = Place()
        defer { place.remove() }
        let registry = try await shopRegistry(in: place.root, requires: "SHOP_TOKEN")
        let store = place.store()
        let watch = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: [WatchListItem(key: "123")],
                                   args: ["zip": .number(10001)], requires: ["SHOP_TOKEN", LinkedTools.tokenKey])
        try store.add(watch)
        let scripts = FakeScripts()
        var checker = WatchListChecker(registry: registry, folder: { store.folder(for: $0) })
        checker.run = { script, args, context, secrets, timeout, toolDir in
            try await scripts.run(script, args, context, secrets, timeout, toolDir)
        }
        checker.introspect = { _ in ScriptSchema(description: "Own", inputSchema: ["type": "object", "properties": ["item": [:], "zip": ["type": "string"]]], dependencies: []) }
        checker.hasSecret = { _ in true }

        _ = try await checkEach(checker, watch)   // no check.py: the pack's
        #expect(scripts.calls.last?.script.id == "shop__watch_item")
        #expect(scripts.calls.last?.secrets == ["SHOP_TOKEN"])
        #expect(scripts.calls.last?.toolDir == nil)

        let own = try #require(store.folder(for: watch.id)).appendingPathComponent("check.py")
        try "def run(item: str, zip: str = ''):\n    return {}\n".write(to: own, atomically: true, encoding: .utf8)
        _ = try await checkEach(checker, watch)
        let call = try #require(scripts.calls.last)
        #expect(call.script.path.standardizedFileURL == own.standardizedFileURL)
        #expect(call.secrets == ["SHOP_TOKEN"])           // its own list, without Noteling's own token
        #expect(call.toolDir?.standardizedFileURL == store.folder(for: watch.id)?.standardizedFileURL)
        #expect(call.args["item"] as? String == "123" && call.args["zip"] as? String == "10001")
        #expect(call.timeout == 60)
        #expect(call.context?.appName == "Watch list")

        var bare = watch
        bare.requires = ["OTHER_TOKEN"]
        checker.hasSecret = { $0 != "OTHER_TOKEN" }
        #expect(unavailable(await checker.plan(bare)) == "It needs OTHER_TOKEN in Settings.")
    }

    @Test func aCheckThatTakesItemsGetsThemAllInOneCallWithTimeForEach() async throws {
        let place = Place()
        defer { place.remove() }
        let registry = try await shopRegistry(in: place.root, requires: nil)
        let store = place.store()
        let watch = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: ["123", "456", "789"].map { WatchListItem(key: $0) },
                                   args: ["zip": .text("10001")])
        try store.add(watch)
        try "def run(items: list, zip: str = ''):\n    return {}\n".write(to: try #require(store.folder(for: watch.id)).appendingPathComponent("check.py"),
                                                                       atomically: true, encoding: .utf8)
        let scripts = FakeScripts()
        scripts.answer = ["123": ["title": "One", "state": ["price": 1]], "456": ["error": "Gone from the shop"],
                          "999": ["title": "Not asked", "state": [:]]] as [String: Any]
        var checker = WatchListChecker(registry: registry, folder: { store.folder(for: $0) })
        checker.run = { try await scripts.run($0, $1, $2, $3, $4, $5) }
        checker.introspect = { _ in ScriptSchema(description: "Own", inputSchema: ["type": "object", "properties": ["items": ["type": "array"], "zip": [:]]], dependencies: []) }

        guard case .wholeList(let check) = await checker.plan(watch) else { Issue.record("expected a list check"); return }
        let outcomes = await check(watch.items)

        #expect(scripts.calls.count == 1)
        #expect(scripts.calls[0].args["items"] as? [String] == ["123", "456", "789"] && scripts.calls[0].args["zip"] as? String == "10001")
        #expect(scripts.calls[0].args["item"] == nil)
        #expect(scripts.calls[0].timeout == 63)   // a minute and a second per item
        #expect(scripts.calls[0].context?.windowTitle == "Sale items")
        guard case .checked(let one)? = outcomes["123"] else { Issue.record("123 wasn't checked"); return }
        #expect(one.title == "One")
        #expect(outcomes["456"] == .failed("Gone from the shop"))
        #expect(outcomes["789"] == .failed("The check returned nothing for this item. It returned results for 999."))

        scripts.failure = ScriptRunnerError(message: "check.py timed out after 63s", timedOut: true)
        let late = await check(watch.items)
        #expect(late.count == 3 && late.values.allSatisfy { $0 == .failed("It took longer than 63 seconds.") })
        #expect(WatchListChecker.choices(in: registry).first?.takesList == false)   // the pack's own check takes one at a time
    }

    // MARK: helpers

    private func unavailable(_ plan: WatchListPlan) -> String? {
        if case .unavailable(let reason) = plan { return reason }
        return nil
    }

    private func checkEach(_ checker: WatchListChecker, _ watch: WatchListWatch) async throws -> WatchListOutcome {
        guard case .eachItem(let check) = await checker.plan(watch) else { throw WatchListError("expected a check of one item at a time") }
        return await check(watch.items[0])
    }

    /// A tools folder with a shop pack whose `watch:` script takes one item and a zip code.
    private func shopRegistry(in root: URL, requires: String?) async throws -> ToolRegistry {
        let tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools.appendingPathComponent("shop"), withIntermediateDirectories: true)
        try "---\nname: Shop\nmatch:\n  urls: [shop.example.com/item/]\n\(requires.map { "requires: [\($0)]\n" } ?? "")watch: watch_item\n---\nItems."
            .write(to: tools.appendingPathComponent("shop/SKILL.md"), atomically: true, encoding: .utf8)
        let registry = ToolRegistry(root: tools, runner: ScriptRunner(config: Config()))
        await registry.reload()
        let shop = try #require(registry.packs.first)
        shop.scripts = [ScriptTool(id: "shop__watch_item", packDir: "shop", fileName: "watch_item.py", path: shop.dir.appendingPathComponent("scripts/watch_item.py"),
                                   description: "Fixture", inputSchema: ["type": "object", "properties": ["item": [:], "zip": ["type": "string"]]],
                                   dependencies: [])]
        return registry
    }
}

/// A list check that answers for the items it is given (all as expected, but for those it leaves out), or fails the
/// whole run; counts how many run at once.
@MainActor
final class FakeListChecks {
    var calls: [[String]] = []
    var inFlight = 0
    var peak = 0
    var gate: Gate?
    var leaveOut: Set<String> = []
    var failure: String?

    func check(_ watch: WatchListWatch, _ items: [WatchListItem]) async -> [String: WatchListOutcome] {
        calls.append(items.map(\.key))
        inFlight += 1
        peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        if let gate { await gate.wait() }
        if let failure { return Dictionary(uniqueKeysWithValues: items.map { ($0.key, WatchListOutcome.failed(failure)) }) }
        var answer: [String: Any] = [:]
        for item in items where !leaveOut.contains(item.key) { answer[item.key] = ["title": "Listed \(item.key)", "state": ["price": 10]] }
        return WatchListReading.parseList(answer, keys: items.map(\.key))
    }
}

/// Stands in for running a script: records what it was given and answers with `answer`, or throws `failure`.
@MainActor
final class FakeScripts {
    struct Call {
        var script: ScriptTool
        var args: [String: Any]
        var context: ScreenContext?
        var secrets: [String]
        var timeout: TimeInterval
        var toolDir: URL?
    }
    var calls: [Call] = []
    var answer: Any = ["title": "Item", "state": ["price": 10]] as [String: Any]
    var failure: Error?

    func run(_ script: ScriptTool, _ args: [String: Any], _ context: ScreenContext?, _ secrets: [String], _ timeout: TimeInterval,
             _ toolDir: URL?) async throws -> Any {
        calls.append(Call(script: script, args: args, context: context, secrets: secrets, timeout: timeout, toolDir: toolDir))
        if let failure { throw failure }
        return answer
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
    let place = Place()
    let store: WatchListStore
    let runner: WatchListRunner
    let checks = FakeWatchChecks()
    let clock = TestClock()
    var alerts: [WatchListAlert] = []
    let watchID: UUID

    /// Every watch is checked one item at a time by `checks`, unless `prepare` says how.
    init(items: Int, prepare: WatchListRunner.Prepare? = nil) throws {
        store = place.store()
        let checks = checks, clock = clock
        runner = WatchListRunner(store: store, prepare: prepare ?? { watch in .eachItem { item in await checks.check(watch, item) } },
                                 now: { clock.now })
        let watch = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: (1...items).map { WatchListItem(key: "\($0)") })
        watchID = watch.id
        try store.add(watch)
        runner.onAlert = { [unowned self] in self.alerts.append($0) }
    }

    func remove() { place.remove() }

    /// Lets the runner's tasks move until the condition holds.
    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        try #require(condition())
    }
}
