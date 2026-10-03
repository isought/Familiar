import AppKit
import Combine
import Foundation

/// While the chat waits for a check it asked for, results only become what the person was told, since the chat shows
/// them. Results that land after it stopped waiting tell the person as usual.
@MainActor
final class WatchListQuiet {
    var on = true
}

/// How one run checks a watch: one item at a time, all its items in one call (a list check), or not at all, and why.
enum WatchListPlan {
    case eachItem((WatchListItem) async -> WatchListOutcome)
    case wholeList(([WatchListItem]) async -> [String: WatchListOutcome])
    case unavailable(String)
}

/// Checks watches on their schedule: every 30 seconds it starts the watches that are due, and again just after the Mac
/// wakes. At most two checks run at a time across all watches (a list check is one), and a watch never has two runs at
/// once. Before each run, and at each tick, it takes in what people changed in the watches folder by hand.
@MainActor
final class WatchListRunner: ObservableObject {
    typealias Prepare = (WatchListWatch) async -> WatchListPlan
    typealias Check = (WatchListWatch, WatchListItem) async -> WatchListOutcome

    let store: WatchListStore
    /// Watches being checked right now.
    @Published private(set) var checking: Set<UUID> = []
    /// Something to tell the person; the app shows it as a notification.
    var onAlert: ((WatchListAlert) -> Void)?

    static let concurrentChecks = 2
    static let tickSeconds: Double = 30
    static let afterWakeSeconds: Double = 10
    static let overLimit = "Not checked: a watch whose check takes one item at a time holds up to \(WatchListStore.itemLimitEach) items."

    private let prepare: Prepare
    private let now: () -> Date
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var ticker: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var slotsInUse = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Couldn't-check alerts wait for the end of their run, so several for one reason go out as one.
    private var heldFailures: [UUID: [WatchListAlert]] = [:]

    init(store: WatchListStore, prepare: @escaping Prepare, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.prepare = prepare
        self.now = now
    }

    /// A check that takes one item at a time, for every watch.
    convenience init(store: WatchListStore, check: @escaping Check, now: @escaping () -> Date = Date.init) {
        self.init(store: store, prepare: { watch in .eachItem { item in await check(watch, item) } }, now: now)
    }

    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled, let runner = self {
                runner.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
            }
        }
        // A sleeping Mac misses its ticks: check what came due as soon as the network is likely back.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.afterWakeSeconds * 1_000_000_000))
                self?.tick()
            }
        }
        Log.info("watch list: checking \(store.watches.count) watch(es) on schedule")
    }

    /// Stops the schedule and any checks running (their scripts are stopped too), and saves what came back.
    func stop() {
        ticker?.cancel()
        ticker = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        for task in runs.values { task.cancel() }
        try? store.save()
    }

    /// Takes in what changed in the watches folder, then starts every watch that is due and not running.
    func tick() {
        takeIn()
        let time = now()
        for watch in store.watches where runs[watch.id] == nil && WatchListSchedule.isDue(watch, at: time) {
            run(watch.id)
        }
        checkUnchecked()
    }

    /// Takes in what people changed in the watches folder by hand: a watch whose folder went away stops, and items no
    /// check has looked at yet are checked right away. Before a run, and before the chat answers.
    @discardableResult
    func refresh() -> WatchListChanges {
        let changes = takeIn()
        checkUnchecked()
        return changes
    }

    private func takeIn() -> WatchListChanges {
        let changes = store.refresh()
        for id in changes.removed { runs[id]?.cancel() }
        return changes
    }

    /// Items no check has looked at yet, such as ones someone added to watch.json or ones a run left when Noteling
    /// quit, are checked now rather than at the watch's next run. Their first check says nothing: it only finds what
    /// counts as right.
    private func checkUnchecked() {
        for watch in store.watches where !watch.paused && runs[watch.id] == nil {
            let unchecked = Set(watch.items.filter { $0.checkedAt == nil }.map(\.key))
            if !unchecked.isEmpty { run(watch.id, items: unchecked) }
        }
    }

    /// Checks a watch now. While it is being checked already, that run is the answer: runs of one watch never overlap.
    /// `items` checks only those (new items), without moving the watch's schedule.
    @discardableResult
    func run(_ id: UUID, items: Set<String>? = nil, quiet: WatchListQuiet? = nil) -> Task<Void, Never>? {
        if let current = runs[id] { return current }
        guard store.watch(id: id) != nil else { return nil }
        checking.insert(id)
        let task = Task { [weak self] in
            await self?.perform(id, items: items, quiet: quiet)
            self?.runs[id] = nil
            self?.checking.remove(id)
        }
        runs[id] = task
        return task
    }

    /// The run in progress for a watch, if any.
    func current(_ id: UUID) -> Task<Void, Never>? { runs[id] }

    /// Stops a watch's run, when the watch is stopped.
    func cancel(_ id: UUID) {
        runs[id]?.cancel()
    }

    /// Waits for a run, at most `seconds`, or until the waiter is stopped; the run carries on either way. True when it
    /// finished in time. (A task group would wait for the run anyway: awaiting a task's value can't be cancelled.)
    static func wait(for task: Task<Void, Never>?, atMost seconds: Double) async -> Bool {
        guard let task else { return true }
        let race = Race()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.continuation = continuation
                race.timer = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    race.finish(false)
                }
                Task { @MainActor in
                    await task.value
                    race.finish(true)
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(false) }
        }
    }

    /// The first of a run's end, the time limit or a stop resumes the waiter; the others find nothing left to do.
    private final class Race {
        var continuation: CheckedContinuation<Bool, Never>?
        var timer: Task<Void, Never>?

        func finish(_ finished: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            continuation.resume(returning: finished)
        }
    }

    private func perform(_ id: UUID, items keys: Set<String>?, quiet: WatchListQuiet?) async {
        refresh()   // a hand edit since the last tick counts for this run
        guard let watch = store.watch(id: id) else { return }
        if keys == nil { _ = try? store.change(id, persist: false) { $0.lastRunAt = now() } }
        let items = watch.items.filter { keys?.contains($0.key) ?? true }
        if !items.isEmpty {
            switch await prepare(watch) {
            case .unavailable(let reason):
                if !Task.isCancelled { for item in items { record(.failed(reason), watchID: id, key: item.key, quiet: quiet?.on ?? false) } }
            case .eachItem(let check):
                await checkEach(id, items, allowed: Set(watch.items.prefix(WatchListStore.itemLimitEach).map(\.key)), quiet: quiet, check: check)
            case .wholeList(let check):
                await checkList(id, items, quiet: quiet, check: check)
            }
        }
        do { try store.save(id) } catch { Log.info("watch list: couldn't save: \(error.localizedDescription)") }
        let failures = heldFailures.removeValue(forKey: id) ?? []
        if !Task.isCancelled { WatchListRules.grouped(failures).forEach(tell) }
    }

    private func checkEach(_ id: UUID, _ items: [WatchListItem], allowed: Set<String>, quiet: WatchListQuiet?,
                           check: @escaping (WatchListItem) async -> WatchListOutcome) async {
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                guard allowed.contains(item.key) else {
                    if !Task.isCancelled { record(.failed(Self.overLimit), watchID: id, key: item.key, quiet: quiet?.on ?? false) }
                    continue
                }
                group.addTask { @MainActor [weak self] in
                    guard let self else { return }
                    await self.acquire()
                    defer { self.release() }
                    // The watch may have been changed or stopped while this waited for a turn.
                    guard !Task.isCancelled, let latest = self.store.watch(id: id)?.item(item.key) else { return }
                    let outcome = await check(latest)
                    guard !Task.isCancelled else { return }   // stopped, not a failed check
                    self.record(outcome, watchID: id, key: item.key, quiet: quiet?.on ?? false)
                }
            }
        }
    }

    /// One call for all the items, taking one turn of the two.
    private func checkList(_ id: UUID, _ items: [WatchListItem], quiet: WatchListQuiet?,
                           check: ([WatchListItem]) async -> [String: WatchListOutcome]) async {
        await acquire()
        defer { release() }
        guard !Task.isCancelled, let watch = store.watch(id: id) else { return }
        let latest = items.compactMap { watch.item($0.key) }
        guard !latest.isEmpty else { return }
        let outcomes = await check(latest)
        guard !Task.isCancelled else { return }
        for item in latest {
            record(outcomes[item.key] ?? .failed("The check returned nothing for this item."), watchID: id, key: item.key, quiet: quiet?.on ?? false)
        }
    }

    private func record(_ outcome: WatchListOutcome, watchID: UUID, key: String, quiet: Bool) {
        var alert: WatchListAlert?
        let time = now()
        _ = try? store.change(watchID, persist: false) { watch in
            guard let index = watch.items.firstIndex(where: { $0.key == key }) else { return }
            var item = watch.items[index]
            let kind = WatchListRules.apply(outcome, to: &item, fields: watch.fields, expect: watch.expect, at: time, quiet: quiet)
            watch.items[index] = item
            alert = kind.map { WatchListAlert(watchID: watch.id, watchName: watch.name, itemKey: key, title: item.label, kind: $0, why: item.whyNow) }
        }
        guard let alert else { return }
        if case .couldNotCheck = alert.kind { heldFailures[watchID, default: []].append(alert) } else { tell(alert) }
    }

    private func tell(_ alert: WatchListAlert) {
        Log.info("watch list: \(alert.watchName) · \(alert.title): \(alert.body.replacingOccurrences(of: "\n", with: "; "))")
        onAlert?(alert)
    }

    private func acquire() async {
        if slotsInUse < Self.concurrentChecks { slotsInUse += 1; return }
        await withCheckedContinuation { waiting.append($0) }   // the slot is handed over by release
    }

    private func release() {
        if waiting.isEmpty { slotsInUse -= 1 } else { waiting.removeFirst().resume() }
    }
}

/// A check the tools folder offers: a pack's `watch:` script, with what it takes and what it still needs from Settings.
struct WatchListCheckChoice: Equatable {
    let id: String              // the script's tool name, e.g. shop__watch_item
    let pack: String            // the pack's display name
    let packDir: String
    /// Extra arguments the script takes besides the items, with their descriptions.
    var arguments: [String: String] = [:]
    /// Arguments the script can't run without, besides the items.
    var required: [String] = []
    var missingSecrets: [String] = []
    /// Its `run()` takes `items`: all of a watch's items in one call, so a watch can hold more of them.
    var takesList = false

    var itemLimit: Int { takesList ? WatchListStore.itemLimit : WatchListStore.itemLimitEach }
}

/// A watch's check, found: its own check.py, or the pack's `watch:` script, with the secrets it gets.
struct WatchListResolvedCheck {
    var script: ScriptTool
    var secrets: [String]
    var missing: [String]
    /// Its own folder, for a watch's own check.py: where it runs and what NOTELING_TOOL_DIR says.
    var toolDir: URL?

    var own: Bool { toolDir != nil }
    var takesList: Bool { WatchListChecker.takesList(script) }
}

/// What a watch's own check.py takes, read once per version of the file.
@MainActor
final class WatchListSchemaCache {
    private var cache: [String: (date: Date?, schema: ScriptSchema)] = [:]

    func schema(for file: URL, introspect: (URL) async throws -> ScriptSchema) async throws -> ScriptSchema {
        let date = WatchListFiles.modified(file)
        if let hit = cache[file.path], hit.date == date { return hit.schema }
        let schema = try await introspect(file)
        cache[file.path] = (date, schema)
        return schema
    }
}

/// Runs a watch's check as the person: the watch's own check.py when its folder has one, else the pack's `watch:`
/// script. Each is given the items exactly as written and only the extra arguments it declares, gets only its own
/// secrets (a check.py, those its watch.json lists under `requires`; a pack's script, the pack's), and is stopped at its
/// time limit. A check whose `run()` takes `items` gets them all in one call.
@MainActor
struct WatchListChecker {
    let registry: ToolRegistry
    /// The watch's folder, for its own check.py.
    var folder: (UUID) -> URL? = { _ in nil }
    var timeout: TimeInterval = 60
    /// Runs a script and returns what its `run()` returned. Tests put a fake here: no Python, no network.
    var run: (_ script: ScriptTool, _ args: [String: Any], _ context: ScreenContext?, _ secrets: [String], _ timeout: TimeInterval,
              _ toolDir: URL?) async throws -> Any
    /// Reads what a script's `run()` takes.
    var introspect: (URL) async throws -> ScriptSchema
    var hasSecret: (String) -> Bool = { Secrets.has($0) || ProcessInfo.processInfo.environment[$0] != nil }
    let schemas = WatchListSchemaCache()

    init(registry: ToolRegistry, folder: @escaping (UUID) -> URL? = { _ in nil }) {
        self.registry = registry
        self.folder = folder
        let runner = registry.runner
        run = { script, args, context, secrets, timeout, toolDir in
            try await runner.result(script, args: args, context: context, secrets: secrets, timeout: timeout, toolDir: toolDir)
        }
        introspect = { try await runner.introspect($0) }
    }

    static func choices(in registry: ToolRegistry) -> [WatchListCheckChoice] {
        registry.packs.compactMap { pack in
            guard let script = registry.script(pack.watch, in: pack) else { return nil }
            return WatchListCheckChoice(id: script.id, pack: pack.name, packDir: pack.dirName, arguments: arguments(of: script),
                                        required: (script.inputSchema["required"] as? [String] ?? []).filter { $0 != "item" && $0 != "items" },
                                        missingSecrets: registry.missingRequirements(for: [pack]).first?.keys ?? [], takesList: takesList(script))
        }
    }

    /// The extra arguments a script takes besides the items, with their descriptions.
    nonisolated static func arguments(of script: ScriptTool) -> [String: String] {
        var arguments: [String: String] = [:]
        for (name, schema) in script.inputSchema["properties"] as? [String: Any] ?? [:] where name != "item" && name != "items" {
            arguments[name] = (schema as? [String: Any])?["description"] as? String ?? ""
        }
        return arguments
    }

    nonisolated static func takesList(_ script: ScriptTool) -> Bool {
        (script.inputSchema["properties"] as? [String: Any])?["items"] != nil
    }

    /// The check a watch uses: its folder's check.py, else the pack check it names, else the only one there is.
    func resolve(_ watch: WatchListWatch) async throws -> WatchListResolvedCheck {
        if let folder = folder(watch.id) {
            let file = folder.appendingPathComponent(WatchListFiles.ownCheck)
            if FileManager.default.fileExists(atPath: file.path) {
                let schema: ScriptSchema
                do { schema = try await schemas.schema(for: file, introspect: introspect) }
                catch { throw WatchListError("Its check.py can't be read: \(WatchListRules.reason(error.localizedDescription))") }
                let script = ScriptTool(id: ToolRegistry.toolName("watch__\(folder.lastPathComponent)"), packDir: folder.lastPathComponent,
                                        fileName: WatchListFiles.ownCheck, path: file, description: schema.description,
                                        inputSchema: schema.inputSchema, dependencies: schema.dependencies)
                // Noteling's own token for the team's tools is never a script's, whatever a watch.json asks for.
                let secrets = watch.requires.filter { $0 != LinkedTools.tokenKey }
                return WatchListResolvedCheck(script: script, secrets: secrets, missing: secrets.filter { !hasSecret($0) }, toolDir: folder)
            }
        }
        // Only a script a pack names as its watch check runs, so a watch.json can't run some other script.
        let checks = registry.packs.compactMap { pack in registry.script(pack.watch, in: pack).map { (pack, $0) } }
        let chosen = watch.check.isEmpty ? (checks.count == 1 ? checks.first : nil) : checks.first { $0.1.id == watch.check }
        guard let (pack, script) = chosen else {
            if !watch.check.isEmpty { throw WatchListError("Its check, \(watch.check), isn't in your tools folder any more.") }
            if checks.isEmpty { throw WatchListError(WatchListConversation.noChecks) }
            throw WatchListError("Its watch.json doesn't say which check to use. Put one of these under check: "
                + checks.map(\.1.id).joined(separator: ", ") + ".")
        }
        return WatchListResolvedCheck(script: script, secrets: pack.requires, missing: pack.requires.filter { !hasSecret($0) }, toolDir: nil)
    }

    func plan(_ watch: WatchListWatch) async -> WatchListPlan {
        let check: WatchListResolvedCheck
        do { check = try await resolve(watch) } catch { return .unavailable(WatchListStore.reason(error)) }
        if !check.missing.isEmpty { return .unavailable("It needs \(check.missing.joined(separator: ", ")) in Settings.") }
        if check.takesList { return .wholeList { items in await self.checkList(watch, items, check) } }
        return .eachItem { item in await self.checkItem(watch, item, check) }
    }

    func checkItem(_ watch: WatchListWatch, _ item: WatchListItem, _ check: WatchListResolvedCheck) async -> WatchListOutcome {
        do {
            let result = try await run(check.script, Self.arguments(for: check.script, item: item.key, extra: watch.args),
                                       Self.scene(for: item), check.secrets, timeout, check.toolDir)
            return WatchListReading.parse(result)
        } catch {
            return .failed(Self.failure(error, limit: timeout))
        }
    }

    func checkList(_ watch: WatchListWatch, _ items: [WatchListItem], _ check: WatchListResolvedCheck) async -> [String: WatchListOutcome] {
        let keys = items.map(\.key)
        let limit = WatchListRules.listTimeLimit(items: keys.count)
        do {
            let result = try await run(check.script, Self.arguments(for: check.script, items: keys, extra: watch.args),
                                       Self.scene(for: watch), check.secrets, limit, check.toolDir)
            return WatchListReading.parseList(result, keys: keys)
        } catch {
            let reason = Self.failure(error, limit: limit)
            return Dictionary(keys.map { ($0, WatchListOutcome.failed(reason)) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private static func failure(_ error: Error, limit: TimeInterval) -> String {
        if let error = error as? ScriptRunnerError, error.timedOut { return "It took longer than \(Int(limit)) seconds." }
        if error is CancellationError { return "Stopped." }
        return WatchListRules.reason(error.localizedDescription)
    }

    /// The item exactly as given, plus the watch's extra arguments the script declares; never anything else. Each goes
    /// as the type the script declares, so a zip code given as a number still arrives as text.
    nonisolated static func arguments(for script: ScriptTool, item: String, extra: [String: WatchListValue]) -> [String: Any] {
        var args = declared(script, extra)
        args["item"] = item
        return args
    }

    /// All the items for a list check, as written, in the watch's order, plus the extra arguments it declares.
    nonisolated static func arguments(for script: ScriptTool, items: [String], extra: [String: WatchListValue]) -> [String: Any] {
        var args = declared(script, extra)
        args["items"] = items
        return args
    }

    nonisolated private static func declared(_ script: ScriptTool, _ extra: [String: WatchListValue]) -> [String: Any] {
        let declared = script.inputSchema["properties"] as? [String: Any] ?? [:]
        var args: [String: Any] = [:]
        for (name, value) in extra where name != "item" && name != "items" {
            guard let schema = declared[name] else { continue }
            args[name] = typed(value, as: (schema as? [String: Any])?["type"] as? String)
        }
        return args
    }

    nonisolated static func typed(_ value: WatchListValue, as type: String?) -> Any {
        switch (type, value) {
        case ("string", .number), ("string", .flag): return "\(value.json)"
        case ("integer", .text(let text)):
            return WatchListRules.number(in: text).flatMap { $0.rounded() == $0 && abs($0) < 1e15 ? Int($0) : nil } ?? text
        case ("number", .text(let text)): return WatchListRules.number(in: text) ?? text
        case ("boolean", .text(let text)): return WatchListRules.flag(in: text) ?? text
        default: return value.json
        }
    }

    /// What the script sees as the page: the item's own, when it is known.
    nonisolated static func scene(for item: WatchListItem, at time: Date = Date()) -> ScreenContext {
        ScreenContext(appName: "Watch list", bundleID: "", windowTitle: item.label, url: item.pageURL, focused: nil, timestamp: time)
    }

    /// A list check sees the watch: there is no one page.
    nonisolated static func scene(for watch: WatchListWatch, at time: Date = Date()) -> ScreenContext {
        ScreenContext(appName: "Watch list", bundleID: "", windowTitle: watch.name, url: nil, focused: nil, timestamp: time)
    }
}
