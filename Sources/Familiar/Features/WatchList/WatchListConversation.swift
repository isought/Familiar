import Foundation
import FamiliarContracts
import FamiliarRuntime

/// The watch list in general chat: tools to watch items, list the watches, check one now, change one or stop it.
/// Changes go through the same store as the Watch List window, so they show there at once. Checks the chat starts are
/// waited for (at most `waitLimit`) and their results returned, so the chat shows what each item looks like now.
@MainActor
final class WatchListConversation {
    let store: WatchListStore
    let runner: WatchListRunner
    /// The checks the tools folder offers: each pack's `watch:` script.
    var checks: () -> [WatchListCheckChoice] = { [] }
    /// Asks macOS for permission to notify; called when a watch is created.
    var askForNotifications: () -> Void = {}
    /// "on", or why notifications are off and how to turn them on.
    var notificationLine: () async -> String = { "on" }
    /// A watch was created, changed or stopped: a one-line receipt for the pad.
    var onChange: ((String) -> Void)?
    /// A check needs secrets in Settings. The chat never takes a password itself.
    var onOfferConnect: ((String) -> Void)?
    /// Checks still running after this carry on; the Watch List window shows them when they finish.
    var waitLimit: Double = 90
    var now: () -> Date = Date.init

    static let noChecks = "No tool can check items yet. Link your team's tools in Settings."

    init(store: WatchListStore, runner: WatchListRunner) {
        self.store = store
        self.runner = runner
    }

    // MARK: tools

    func routes() -> [ToolRoute] {
        let watch: [String: Any] = ["type": "string", "description": "The watch's name or id, as list_watches gives them."]
        let items: (String) -> [String: Any] = { ["type": "array", "items": ["type": "string"], "description": $0] }
        let minutes: [String: Any] = ["type": "integer", "description": "How often to check, in minutes: 5 to 240. Default 15."]
        let expect: [String: Any] = ["type": "object", "description": "What counts as right for every item, field → value, e.g. {\"price\": 12.33, \"badges\": [\"Deal\"], \"in_stock\": true}. Overrides what the first check shows."]
        return [
            route("watch_items", Self.watchItemsDescription, [
                "items": items("The items exactly as the person gave them: ids or page addresses. Up to 50."),
                "name": ["type": "string", "description": "A short name for the watch, e.g. \"Sale items\"."],
                "every_minutes": minutes,
                "fields": items("Only keep an eye on these things the check reports, e.g. [\"price\", \"badges\"]. Default: everything it reports."),
                "expect": expect,
                "args": ["type": "object", "description": "Extra details the check takes, as the person gave them, e.g. {\"zip\": \"10001\"}."],
                "check": ["type": "string", "description": "Which check to use, when there are several. Default: the only one there is."],
            ], required: ["items"]) { [unowned self] input in try await self.create(input) },
            route("list_watches", "List what is being watched: each watch's name, how often it checks and when it last did, and each item's status: as expected, not as expected (and how), or couldn't check (and why).",
                  [:], required: []) { [unowned self] _ in await self.list() },
            route("check_watch_now", "Check a watch's items now instead of waiting for its schedule, and return what each shows. Without watch, check every watch. Use it when the person asks to check now.",
                  ["watch": watch], required: []) { [unowned self] input in try await self.checkNow(input) },
            route("change_watch", "Change a watch: add or remove items, change how often it checks, change what counts as right for every item (expect, compared at once with what each item's last check showed), or pause and resume it. New items are checked now.",
                  ["watch": watch, "add_items": items("Items to add: ids or page addresses."),
                   "remove_items": items("Items to stop watching: as given, or their titles."), "every_minutes": minutes,
                   "expect": ["type": "object", "description": "What counts as right from now on, field → value, for every item."],
                   "paused": ["type": "boolean", "description": "true pauses the watch; false resumes it."]],
                  required: ["watch"]) { [unowned self] input in try await self.change(input) },
            route("stop_watch", "Stop watching: remove a watch with all its items, so it no longer checks or notifies.",
                  ["watch": watch], required: ["watch"]) { [unowned self] input in try self.stop(input) },
        ]
    }

    static let watchItemsDescription = "Watch items for the person and tell them when one is not as it should be right now. Use it when they ask to watch, keep an eye on or monitor items (product ids or page addresses); it is not Watch Me, which records them doing a task. Their team's check for the site checks each item on a schedule, and a Mac notification tells them when an item stops being as expected or changes again, when it is back, or when it can't be checked twice in a row. This creates the watch, checks every item once now, and returns per item its title, status, what it shows now and what counts as right: what its first check shows, unless expect says otherwise. Then confirm in one or two lines what you are watching, what counts as right, and how often, and that they can change what counts as right (expect here, or change_watch later). If notifications are off, say so."

    private func route(_ name: String, _ description: String, _ properties: [String: Any], required: [String],
                       action: @escaping ([String: Any]) async throws -> String) -> ToolRoute {
        ToolRoute(match: .tool(name: name), definition: ["name": name, "description": description,
            "input_schema": ["type": "object", "additionalProperties": false, "properties": properties, "required": required]]) { _, input, _ in
            do { return .text(try await action(input)) }
            catch { return .text(error.localizedDescription, isError: true) }
        }
    }

    // MARK: actions

    private func create(_ input: [String: Any]) async throws -> String {
        let keys = try Self.items(input["items"], required: true)
        guard store.watches.count < WatchListStore.watchLimit else {
            throw WatchListError("You're already watching \(WatchListStore.watchLimit) lists, the most Noteling keeps. Stop one first.")
        }
        let choice = try resolveCheck(input["check"])
        let (minutes, minutesNote) = try Self.minutes(input["every_minutes"])
        var args = try Self.values(input["args"], "args")
        args.removeValue(forKey: "item")
        try Self.checkArguments(args, for: choice)
        let name = uniqueName(Self.text(input["name"]) ?? Self.defaultName(keys))
        let watch = WatchListWatch(name: name, check: choice.id, items: keys.map(WatchListItem.init(key:)), args: args,
                                   fields: try Self.fields(input["fields"]), expect: try Self.values(input["expect"], "expect"),
                                   everyMinutes: minutes, createdAt: now())
        try store.add(watch)
        askForNotifications()
        let finished = await checkWaiting([watch.id])
        onChange?("Watching “\(Self.clip(name, 80))”: \(keys.count) item\(keys.count == 1 ? "" : "s"), \(watch.everyWords).")
        var result = store.watch(id: watch.id).map(summary) ?? [:]
        if let minutesNote { result["note"] = minutesNote }
        if !finished { result["still_checking"] = Self.stillChecking }
        if !choice.missingSecrets.isEmpty {
            result["setup"] = "The check needs \(choice.missingSecrets.joined(separator: " and ")) in Settings before it can check anything: point to the Open Settings button, and never ask for a password in chat."
            onOfferConnect?(choice.pack)
        }
        result["notifications"] = await notificationLine()
        return Self.json(result)
    }

    private func list() async -> String {
        guard !store.watches.isEmpty else { return "Nothing is being watched." + (store.notice.map { " " + $0 } ?? "") }
        var result: [String: Any] = ["watches": store.watches.map(summary)]
        if let notice = store.notice { result["notice"] = notice }
        result["notifications"] = await notificationLine()
        return Self.json(result)
    }

    private func checkNow(_ input: [String: Any]) async throws -> String {
        let chosen: [WatchListWatch]
        if Self.text(input["watch"]) == nil {
            guard !store.watches.isEmpty else { throw WatchListError("Nothing is being watched.") }
            chosen = store.watches
        } else {
            chosen = [try resolve(input["watch"])]
        }
        let finished = await checkWaiting(chosen.map(\.id))
        var result: [String: Any] = ["watches": chosen.compactMap { store.watch(id: $0.id) }.map(summary)]
        if !finished { result["still_checking"] = Self.stillChecking }
        return Self.json(result)
    }

    private func change(_ input: [String: Any]) async throws -> String {
        let watch = try resolve(input["watch"])
        let adding = try Self.items(input["add_items"], required: false)
        let removing = try Self.items(input["remove_items"], required: false)
        let minutes = try input["every_minutes"].map { try Self.minutes($0) }
        let expect = try Self.values(input["expect"], "expect")
        let paused = try input["paused"].map { value -> Bool in
            if let flag = NoteCheckResult.boolean(value) { return flag }
            if let text = value as? String, let flag = WatchListRules.flag(in: text) { return flag }
            throw WatchListError("paused must be true or false.")
        }
        guard !adding.isEmpty || !removing.isEmpty || minutes != nil || !expect.isEmpty || paused != nil else {
            throw WatchListError("Nothing to change: give items to add or remove, how often, what counts as right, or paused.")
        }
        var changes: [String] = [], added: [String] = [], notFound: [String] = []
        try store.change(watch.id) { w in
            for key in removing {
                guard let index = w.items.firstIndex(where: { Self.matches($0, key) }) else { notFound.append(key); continue }
                w.items.remove(at: index)
            }
            if removing.count > notFound.count { changes.append("removed \(Self.count(removing.count - notFound.count))") }
            for key in adding where !w.items.contains(where: { $0.key == key }) {
                w.items.append(WatchListItem(key: key))
                added.append(key)
            }
            if !added.isEmpty { changes.append("added \(Self.count(added.count))") }
            guard !w.items.isEmpty else { throw WatchListError("That would leave nothing to watch. To stop watching it, use stop_watch.") }
            if let every = minutes?.0, every != w.everyMinutes { w.everyMinutes = every; changes.append("checks \(w.everyWords)") }
            if !expect.isEmpty {
                for (field, value) in expect { w.expect[field] = value }
                for index in w.items.indices { WatchListRules.reexpect(&w.items[index], with: expect) }
                changes.append("what counts as right")
            }
            if let paused, paused != w.paused { w.paused = paused; changes.append(paused ? "paused" : "resumed") }
        }
        var finished = true
        if !added.isEmpty { finished = await checkWaiting([watch.id], items: Set(added)) }
        let name = Self.clip(watch.name, 80)
        if !changes.isEmpty { onChange?("Changed “\(name)”: \(changes.joined(separator: ", ")).") }
        var result = store.watch(id: watch.id).map(summary) ?? [:]
        result["changed"] = changes.isEmpty ? "nothing: it was already like that" : changes.joined(separator: ", ")
        if !notFound.isEmpty { result["not_in_this_watch"] = notFound }
        if let note = minutes?.1 { result["note"] = note }
        if !finished { result["still_checking"] = Self.stillChecking }
        return Self.json(result)
    }

    private func stop(_ input: [String: Any]) throws -> String {
        let watch = try resolve(input["watch"])
        runner.cancel(watch.id)
        try store.remove(watch.id)
        let receipt = "Stopped watching “\(Self.clip(watch.name, 80))”."
        onChange?(receipt)
        return receipt + " It no longer checks or notifies."
    }

    /// Checks watches (or some items of one) and waits for them, at most `waitLimit`. What comes back while the chat
    /// waits is what the chat shows, so it only becomes what the person was told; what lands later tells them as usual.
    private func checkWaiting(_ ids: [UUID], items: Set<String>? = nil) async -> Bool {
        if items != nil, let id = ids.first, let running = runner.current(id) {
            // A run in progress started before these items were added: they are checked once it ends.
            _ = await WatchListRunner.wait(for: running, atMost: waitLimit)
        }
        let quiet = WatchListQuiet()
        let runs = ids.compactMap { runner.run($0, items: items, quiet: quiet) }
        let all = Task { for run in runs { await run.value } }
        let finished = await WatchListRunner.wait(for: all, atMost: waitLimit)
        quiet.on = false
        return finished
    }

    // MARK: lookups

    private func resolveCheck(_ raw: Any?) throws -> WatchListCheckChoice {
        let available = checks()
        let names = available.map { "\($0.id) (\($0.pack))" }.joined(separator: ", ")
        if let asked = Self.text(raw) {
            let wanted = available.first { $0.id == asked }
                ?? available.first { $0.packDir.caseInsensitiveCompare(asked) == .orderedSame || $0.pack.caseInsensitiveCompare(asked) == .orderedSame }
            if let wanted { return wanted }
            throw WatchListError(available.isEmpty ? Self.noChecks : "There's no check called “\(Self.clip(asked, 80))”. Use one of: \(names).")
        }
        guard let only = available.first else { throw WatchListError(Self.noChecks) }
        guard available.count == 1 else { throw WatchListError("Several tools can check items: \(names). Say which one with check.") }
        return only
    }

    /// By id, or by name; without one, the only watch there is.
    private func resolve(_ raw: Any?) throws -> WatchListWatch {
        let names = store.watches.map { "“\(Self.clip($0.name, 60))”" }.joined(separator: ", ")
        guard let key = Self.text(raw) else {
            throw WatchListError(store.watches.isEmpty ? "Nothing is being watched." : "Say which watch: \(names).")
        }
        if let id = UUID(uuidString: key), let watch = store.watch(id: id) { return watch }
        let named = store.watches.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if named.count == 1 { return named[0] }
        if !named.isEmpty { throw WatchListError("Several watches are called “\(Self.clip(key, 80))”; use the id.") }
        throw WatchListError(store.watches.isEmpty ? "Nothing is being watched."
            : "No watch is called “\(Self.clip(key, 80))”. Watches: \(names).")
    }

    private static func matches(_ item: WatchListItem, _ key: String) -> Bool {
        item.key == key || item.key.caseInsensitiveCompare(key) == .orderedSame || item.label.caseInsensitiveCompare(key) == .orderedSame
    }

    private func uniqueName(_ base: String) -> String {
        let name = String(base.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let taken = Set(store.watches.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    // MARK: what the chat reads

    static let stillChecking = "Some items are still being checked. The Watch List window shows them when they are done, and a notification comes only if one is not as expected later."

    /// A watch as the chat reads it, compact: per item its title, status, what it shows now and what counts as right.
    private func summary(_ watch: WatchListWatch) -> [String: Any] {
        var result: [String: Any] = ["watch": watch.name, "id": watch.id.uuidString, "every_minutes": watch.everyMinutes, "check": watch.check]
        if watch.paused { result["paused"] = true }
        if let fields = watch.fields {
            result["fields"] = fields
            let reported = Set(watch.items.flatMap { $0.state.map { Array($0.keys) } ?? [] })
            let other = reported.subtracting(fields).subtracting(watch.expect.keys)
            if !other.isEmpty { result["also_reported"] = other.sorted() }
            // A name the check doesn't use would never be watched: say so, rather than stay green.
            let checked = watch.items.filter { $0.status?.isVerdict == true }
            let missing = checked.isEmpty ? [] : fields.filter { field in checked.allSatisfy { $0.state?[field] == nil } }
            if !missing.isEmpty {
                result["fields_not_reported"] = missing
                result["fields_note"] = "The check doesn't report \(missing.joined(separator: " or ")), so \(missing.count == 1 ? "it isn't" : "they aren't") watched. "
                    + (reported.isEmpty ? "" : "It reports: \(reported.sorted().joined(separator: ", ")). ")
                    + "Tell the person, and to watch the right ones, stop this watch and create it again with those names in fields."
            }
        }
        if !watch.expect.isEmpty { result["expect"] = watch.expect.mapValues(Self.brief) }
        if !watch.args.isEmpty { result["args"] = watch.args.mapValues(\.json) }
        if let last = watch.lastRunAt { result["last_checked"] = Self.time(last, now: now()) }
        let checking = runner.checking.contains(watch.id)
        result["items"] = watch.items.map { item -> [String: Any] in
            var row: [String: Any] = ["item": item.key]
            if let title = item.title { row["title"] = title }
            if let url = item.url { row["url"] = url }
            switch item.status {
            case nil: row["status"] = checking ? "checking" : "not checked yet"
            case .asExpected?: row["status"] = "as expected"
            case .notAsExpected(let differences)?:
                row["status"] = "not as expected"
                row["differences"] = differences.map(\.words)
            case .couldNotCheck(let reason)?:
                row["status"] = "couldn't check"
                row["reason"] = reason
            }
            if let expected = item.expected {
                row["counts_as_right"] = expected.mapValues(Self.brief)
                if item.status?.isVerdict == true, let state = item.state {
                    row["now"] = state.filter { expected[$0.key] != nil }.mapValues(Self.brief)
                }
            } else {
                row["counts_as_right"] = "what its first check that works shows" + (watch.expect.isEmpty ? "" : ", with expect")
            }
            let unreported = item.unreported(named: watch.fields)
            if !unreported.isEmpty { row["not_reported"] = unreported }
            if let checked = item.checkedAt { row["checked"] = Self.time(checked, now: now()) }
            return row
        }
        return result
    }

    private static func brief(_ value: WatchListValue) -> Any {
        switch value {
        case .text(let text): return clip(text, 120)
        case .list(let list): return Array(list.prefix(10)).map { clip($0, 80) } + (list.count > 10 ? ["…and \(list.count - 10) more"] : [])
        default: return value.json
        }
    }

    static func time(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: input

    static func text(_ raw: Any?) -> String? {
        let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Items as given: texts (or numbers, for ids), trimmed, each once.
    static func items(_ raw: Any?, required: Bool) throws -> [String] {
        let values: [Any]
        if raw == nil || raw is NSNull { values = [] }
        else if let list = raw as? [Any] { values = list }
        else if let one = raw as? String { values = [one] }
        else { throw WatchListError("Give the items as a list of ids or page addresses.") }
        var keys: [String] = []
        for value in values {
            var key: String
            if let text = value as? String { key = text }
            else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { key = number.stringValue }
            else { continue }
            key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !keys.contains(key) else { continue }
            guard key.count <= 1_000 else { throw WatchListError("An item is too long: give its id or page address.") }
            keys.append(key)
        }
        if required, keys.isEmpty { throw WatchListError("Give the items to watch: their ids or page addresses.") }
        guard keys.count <= WatchListStore.itemLimit else {
            throw WatchListError("A watch holds up to \(WatchListStore.itemLimit) items. Split them into two watches.")
        }
        return keys
    }

    /// How often, held to 5–240 minutes, and a note for the chat when it had to be.
    static func minutes(_ raw: Any?) throws -> (Int, String?) {
        guard let raw, !(raw is NSNull) else { return (WatchListWatch.defaultMinutes, nil) }
        var value: Double?
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.doubleValue }
        else if let text = raw as? String { value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let value, value.isFinite else { throw WatchListError("every_minutes must be a number of minutes, 5 to 240.") }
        let asked = Int(min(max(value.rounded(), -1_000_000), 1_000_000))
        let minutes = WatchListWatch.clamp(asked)
        guard minutes != asked else { return (minutes, nil) }
        return (minutes, minutes > asked ? "It checks every 5 minutes, the most often it can."
                                         : "It checks every 240 minutes (4 hours), the least often it can.")
    }

    static func fields(_ raw: Any?) throws -> [String]? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let values = (raw as? [Any]) ?? (raw as? String).map({ [$0] }) else { throw WatchListError("fields must be a list of names.") }
        var fields: [String] = []
        for case let name as String in values {
            let field = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !field.isEmpty, !fields.contains(field) { fields.append(field) }
        }
        return fields.isEmpty ? nil : fields
    }

    /// An object of field → value (some models send it as JSON text).
    static func values(_ raw: Any?, _ name: String) throws -> [String: WatchListValue] {
        guard let raw, !(raw is NSNull) else { return [:] }
        var object = raw as? [String: Any]
        if object == nil, let text = raw as? String, let data = text.data(using: .utf8) {
            object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let object else { throw WatchListError("\(name) must be an object of field → value.") }
        var values: [String: WatchListValue] = [:]
        for (key, value) in object {
            let field = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !field.isEmpty { values[field] = WatchListValue(json: value) }
        }
        guard values.count <= WatchListReading.fieldLimit else { throw WatchListError("\(name) has too many fields.") }
        return values
    }

    /// A check takes only the extra arguments it declares, and can't run without the ones it requires.
    static func checkArguments(_ args: [String: WatchListValue], for choice: WatchListCheckChoice) throws {
        func described(_ names: [String]) -> String {
            names.map { name in (choice.arguments[name] ?? "").isEmpty ? name : "\(name) (\(choice.arguments[name]!))" }.joined(separator: ", ")
        }
        let unknown = args.keys.filter { choice.arguments[$0] == nil }.sorted()
        if !unknown.isEmpty {
            throw WatchListError("The check doesn't take \(unknown.joined(separator: ", ")). "
                + (choice.arguments.isEmpty ? "It takes nothing besides the items." : "It takes: \(described(choice.arguments.keys.sorted()))."))
        }
        let missing = choice.required.filter { args[$0] == nil }
        if !missing.isEmpty {
            throw WatchListError("The check needs \(described(missing)) besides the items. Ask the person, then pass it in args.")
        }
    }

    static func defaultName(_ keys: [String]) -> String {
        guard let first = keys.first else { return "Watch" }
        var short = first
        if let url = URL(string: first), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            short = url.pathComponents.last { $0 != "/" } ?? url.host ?? first
        }
        short = String(short.prefix(40))
        return keys.count == 1 ? short : "\(short) and \(keys.count - 1) more"
    }

    private static func count(_ n: Int) -> String { "\(n) item\(n == 1 ? "" : "s")" }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
