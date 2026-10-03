import AppKit
import Combine
import Foundation

/// While the chat waits for a check it asked for, results only become what the person was told, since the chat shows
/// them. Results that land after it stopped waiting tell the person as usual.
@MainActor
final class WatchListQuiet {
    var on = true
}

/// Checks watches on their schedule: every 30 seconds it starts the watches that are due, and again just after the Mac
/// wakes. At most two item checks run at a time across all watches, and a watch never has two runs at once.
@MainActor
final class WatchListRunner: ObservableObject {
    typealias Check = (WatchListWatch, WatchListItem) async -> WatchListOutcome

    let store: WatchListStore
    /// Watches being checked right now.
    @Published private(set) var checking: Set<UUID> = []
    /// Something to tell the person; the app shows it as a notification.
    var onAlert: ((WatchListAlert) -> Void)?

    static let concurrentChecks = 2
    static let tickSeconds: Double = 30
    static let afterWakeSeconds: Double = 10

    private let check: Check
    private let now: () -> Date
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var ticker: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var slotsInUse = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Couldn't-check alerts wait for the end of their run, so several for one reason go out as one.
    private var heldFailures: [UUID: [WatchListAlert]] = [:]

    init(store: WatchListStore, check: @escaping Check, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.check = check
        self.now = now
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

    /// Starts every watch that is due and not running.
    func tick() {
        let time = now()
        for watch in store.watches where runs[watch.id] == nil && WatchListSchedule.isDue(watch, at: time) {
            run(watch.id)
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
        guard let watch = store.watch(id: id) else { return }
        if keys == nil { _ = try? store.change(id, persist: false) { $0.lastRunAt = now() } }
        let items = watch.items.filter { keys?.contains($0.key) ?? true }
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask { @MainActor [weak self] in
                    guard let self else { return }
                    await self.acquire()
                    defer { self.release() }
                    // The watch may have been changed or stopped while this waited for a turn.
                    guard !Task.isCancelled, let current = self.store.watch(id: id), let latest = current.item(item.key) else { return }
                    let outcome = await self.check(current, latest)
                    guard !Task.isCancelled else { return }   // stopped, not a failed check
                    self.record(outcome, watchID: id, key: item.key, quiet: quiet?.on ?? false)
                }
            }
        }
        do { try store.save() } catch { Log.info("watch list: couldn't save: \(error.localizedDescription)") }
        let failures = heldFailures.removeValue(forKey: id) ?? []
        if !Task.isCancelled { WatchListRules.grouped(failures).forEach(tell) }
    }

    private func record(_ outcome: WatchListOutcome, watchID: UUID, key: String, quiet: Bool) {
        var alert: WatchListAlert?
        let time = now()
        _ = try? store.change(watchID, persist: false) { watch in
            guard let index = watch.items.firstIndex(where: { $0.key == key }) else { return }
            var item = watch.items[index]
            let kind = WatchListRules.apply(outcome, to: &item, fields: watch.fields, expect: watch.expect, at: time, quiet: quiet)
            watch.items[index] = item
            alert = kind.map { WatchListAlert(watchID: watch.id, watchName: watch.name, itemKey: key, title: item.label, kind: $0) }
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
    /// Extra arguments the script takes besides `item`, with their descriptions.
    var arguments: [String: String] = [:]
    /// Arguments the script can't run without, besides `item`.
    var required: [String] = []
    var missingSecrets: [String] = []
}

/// Runs a watch's check for one item: the pack's `watch:` script, as the person (with the pack's secrets), stopped at its
/// time limit, given the item as they wrote it and only the extra arguments the script declares.
@MainActor
struct WatchListChecker {
    let registry: ToolRegistry
    var timeout: TimeInterval = 60

    static func choices(in registry: ToolRegistry) -> [WatchListCheckChoice] {
        registry.packs.compactMap { pack in
            guard let script = registry.script(pack.watch, in: pack) else { return nil }
            let properties = script.inputSchema["properties"] as? [String: Any] ?? [:]
            var arguments: [String: String] = [:]
            for (name, schema) in properties where name != "item" {
                arguments[name] = (schema as? [String: Any])?["description"] as? String ?? ""
            }
            let required = (script.inputSchema["required"] as? [String] ?? []).filter { $0 != "item" }
            return WatchListCheckChoice(id: script.id, pack: pack.name, packDir: pack.dirName, arguments: arguments, required: required,
                                        missingSecrets: registry.missingRequirements(for: [pack]).first?.keys ?? [])
        }
    }

    /// The item exactly as given, plus the watch's extra arguments the script declares; never anything else. Each goes
    /// as the type the script declares, so a zip code given as a number still arrives as text.
    nonisolated static func arguments(for script: ScriptTool, item: String, extra: [String: WatchListValue]) -> [String: Any] {
        let declared = script.inputSchema["properties"] as? [String: Any] ?? [:]
        var args: [String: Any] = [:]
        for (name, value) in extra where name != "item" {
            guard let schema = declared[name] else { continue }
            args[name] = typed(value, as: (schema as? [String: Any])?["type"] as? String)
        }
        args["item"] = item
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

    func check(_ watch: WatchListWatch, _ item: WatchListItem) async -> WatchListOutcome {
        // Only a script a pack names as its watch check runs, so a stored watch can't run some other script.
        guard let pack = registry.packs.first(where: { registry.script($0.watch, in: $0)?.id == watch.check }),
              let script = registry.script(pack.watch, in: pack) else {
            return .failed("Its check, \(watch.check), isn't in your tools folder any more.")
        }
        if let missing = registry.missingRequirements(for: [pack]).first?.keys, !missing.isEmpty {
            return .failed("It needs \(missing.joined(separator: ", ")) in Settings.")
        }
        do {
            let result = try await registry.runner.result(script, args: Self.arguments(for: script, item: item.key, extra: watch.args),
                                                          context: Self.scene(for: item), secrets: pack.requires, timeout: timeout)
            return WatchListReading.parse(result)
        } catch let error as ScriptRunnerError where error.timedOut {
            return .failed("It took longer than \(Int(timeout)) seconds.")
        } catch is CancellationError {
            return .failed("Stopped.")
        } catch {
            return .failed(WatchListRules.reason(error.localizedDescription))
        }
    }
}
