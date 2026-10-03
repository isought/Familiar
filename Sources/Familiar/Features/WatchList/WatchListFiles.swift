import CryptoKit
import Foundation

/// A watch's folder, `watches/<name>/`: `watch.json` says what to watch (Noteling writes it, and people may edit it),
/// `latest.json` says what the last run found (only Noteling writes it), and an optional `check.py` is the watch's own
/// check. Keeping the two files apart means a person editing one never collides with Noteling writing the other.
enum WatchListFiles {
    static let definition = "watch.json"
    static let results = "latest.json"
    static let ownCheck = "check.py"

    // MARK: watch.json

    /// The keys Noteling reads in watch.json; any other key a person adds is kept when Noteling writes the file.
    static let known: Set<String> = ["id", "name", "check", "items", "args", "fields", "expect", "every_minutes", "paused",
                                     "created_at", "requires"]

    /// watch.json, its keys in the order people read them: an item is its key alone, or an object when it has its own
    /// `expect`.
    static func definitionText(_ d: WatchListDefinition) -> String {
        var pairs: [(String, Any)] = [("id", d.id.uuidString), ("name", d.name), ("check", d.check),
            ("items", d.items.map { item -> Any in item.expect.isEmpty ? item.key : ["key": item.key, "expect": item.expect.mapValues(\.json)] })]
        if let fields = d.fields { pairs.append(("fields", fields)) }
        pairs.append(("expect", d.expect.mapValues(\.json)))
        if !d.args.isEmpty { pairs.append(("args", d.args.mapValues(\.json))) }
        pairs += [("every_minutes", d.everyMinutes), ("paused", d.paused), ("created_at", seconds(d.createdAt))]
        if !d.requires.isEmpty { pairs.append(("requires", d.requires)) }
        if let other = d.other, let extra = (try? JSONSerialization.jsonObject(with: Data(other.utf8))) as? [String: Any] {
            for key in extra.keys.sorted() where !known.contains(key) { pairs.append((key, extra[key]!)) }
        }
        return "{\n" + pairs.map { "  " + WatchListJSON.text($0.0) + ": " + WatchListJSON.pretty($0.1, indent: "  ") }.joined(separator: ",\n") + "\n}\n"
    }

    /// Reads watch.json as a person may have left it, saying what is wrong in plain words. Only `items` is required:
    /// a missing name is the folder's, a missing id one made from the folder's name (so a copy of a folder is a watch
    /// of its own), how often defaults to every 15 minutes, and a missing date is the folder's own.
    static func parseDefinition(_ data: Data, folder: String, created: Date) throws -> (definition: WatchListDefinition, hadID: Bool) {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch {
            let detail = ((error as NSError).userInfo["NSDebugDescription"] as? String).map {
                ($0.prefix(1).lowercased() + $0.dropFirst()).replacingOccurrences(of: ". around line", with: " around line")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            }
            throw WatchListError("it isn't valid JSON" + (detail.map { " (\($0))" } ?? "") + ".")
        }
        guard let object = value as? [String: Any] else { throw WatchListError("it must be one JSON object: { … }.") }

        func text(_ key: String) throws -> String? {
            guard let raw = object[key], !(raw is NSNull) else { return nil }
            guard let text = raw as? String else { throw WatchListError("\(key) must be text in quotes.") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func names(_ key: String, _ what: String) throws -> [String]? {
            guard let raw = object[key], !(raw is NSNull) else { return nil }
            guard let list = raw as? [Any], list.allSatisfy({ $0 is String }) else { throw WatchListError("\(key) must be a list of \(what) in quotes.") }
            var seen = Set<String>()
            return list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        func values(_ raw: Any?, _ what: String) throws -> [String: WatchListValue] {
            guard let raw, !(raw is NSNull) else { return [:] }
            guard let object = raw as? [String: Any] else { throw WatchListError("\(what) must be an object of field → value, { … }.") }
            var values: [String: WatchListValue] = [:]
            for (key, value) in object {
                let field = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !field.isEmpty { values[field] = WatchListValue(json: value) }
            }
            return values
        }

        guard let rawItems = object["items"] else { throw WatchListError("it needs items: a list of item ids or page addresses.") }
        guard let list = rawItems as? [Any] else { throw WatchListError("items must be a list of item ids or page addresses, [ … ].") }
        var items: [WatchListDefinition.Item] = []
        for (index, entry) in list.enumerated() {
            let item: WatchListDefinition.Item
            if let key = entry as? String { item = .init(key: key) }
            else if let number = entry as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { item = .init(key: number.stringValue) }
            else if let entry = entry as? [String: Any], let key = entry["key"] as? String {
                item = .init(key: key, expect: try values(entry["expect"], "The expect of item \(index + 1)"))
            } else {
                throw WatchListError("item \(index + 1) must be an id or page address in quotes, or an object with a key: { \"key\": … }.")
            }
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !items.contains(where: { $0.key == key }) else { continue }
            items.append(.init(key: key, expect: item.expect))
        }
        guard items.count <= WatchListStore.itemLimit else {
            throw WatchListError("it lists \(items.count) items, and a watch holds up to \(WatchListStore.itemLimit).")
        }

        var everyMinutes = WatchListWatch.defaultMinutes
        if let raw = object["every_minutes"], !(raw is NSNull) {
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                everyMinutes = WatchListWatch.clamp(Int(min(max(number.doubleValue.rounded(), -1_000_000), 1_000_000)))
            } else if let text = raw as? String, let minutes = Int(text.trimmingCharacters(in: .whitespaces)) {
                everyMinutes = WatchListWatch.clamp(minutes)
            } else {
                throw WatchListError("every_minutes must be a number of minutes, 5 to 240.")
            }
        }
        var paused = false
        if let raw = object["paused"], !(raw is NSNull) {
            guard let flag = NoteCheckResult.boolean(raw) else { throw WatchListError("paused must be true or false.") }
            paused = flag
        }
        let id = (object["id"] as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
        let createdAt = (object["created_at"] as? String).flatMap { try? CalendarSubmission.timestamp($0.trimmingCharacters(in: .whitespaces)) }
        let otherKeys = object.filter { !known.contains($0.key) }
        let other = otherKeys.isEmpty ? nil : WatchListJSON.compact(otherKeys)
        let definition = WatchListDefinition(
            id: id ?? derivedID(folder: folder), name: try text("name") ?? folder, check: try text("check") ?? "", items: items,
            args: try values(object["args"], "args").filter { $0.key != "item" && $0.key != "items" },
            fields: try names("fields", "field names").flatMap { $0.isEmpty ? nil : $0 },
            expect: try values(object["expect"], "expect"), everyMinutes: everyMinutes, paused: paused, createdAt: createdAt ?? created,
            requires: try names("requires", "secret names") ?? [], other: other)
        return (definition, id != nil)
    }

    /// An id made from the folder's name, the same every time, for a watch.json that has none or shares another's.
    static func derivedID(folder: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("noteling-watch-folder:\(folder)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // a name-based UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A folder name from a watch's name: lowercase letters, digits and dashes, and not one of `taken` (compared without
    /// case, as the Mac's disks do).
    static func slug(_ name: String, taken: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) { slug.unicodeScalars.append(scalar) }
            else if !slug.isEmpty, !slug.hasSuffix("-") { slug += "-" }
        }
        slug = String(slug.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "watch" }
        let used = Set(taken.map { $0.lowercased() })
        var candidate = slug, number = 2
        while used.contains(candidate) { candidate = "\(slug)-\(number)"; number += 1 }
        return candidate
    }

    static func seconds(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: latest.json

    /// latest.json: when the watch last ran and, per item by its key, what its checks found and what the person was
    /// last told. Nothing in it is history: each run replaces it.
    static func resultsText(_ watch: WatchListWatch) -> String {
        var items: [String: Any] = [:]
        for item in watch.items {
            var entry: [String: Any] = ["failures": item.failures, "told_couldnt_check": item.notifiedCouldNotCheck]
            entry["title"] = item.title
            entry["url"] = item.url
            entry["captured"] = item.captured?.mapValues(\.json)
            entry["expected"] = item.expected?.mapValues(\.json)
            entry["state"] = item.state?.mapValues(\.json)
            if let facts = item.facts {   // an object or list as it is, so people can read it; anything else as its text
                let parsed = try? JSONSerialization.jsonObject(with: Data(facts.utf8))
                entry["facts"] = parsed is [String: Any] || parsed is [Any] ? parsed! : facts
            }
            entry["why"] = item.why
            entry["checked_at"] = item.checkedAt.map(SourceRunJSON.timestamp)
            if let status = item.status { entry.merge(statusObject(status)) { _, new in new } }
            entry["last_told"] = item.notified.map(statusObject)
            items[item.key] = entry
        }
        var file: [String: Any] = ["version": 1, "items": items]
        file["last_run_at"] = watch.lastRunAt.map(SourceRunJSON.timestamp)
        return WatchListJSON.pretty(file, indent: "") + "\n"
    }

    /// Takes in what latest.json says about each of the watch's items, by key. Anything it can't read is left out:
    /// the next check finds it again.
    static func readResults(_ data: Data, into watch: inout WatchListWatch) throws {
        guard let file = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WatchListError("it isn't a JSON object.") }
        func date(_ value: Any?) -> Date? { (value as? String).flatMap { try? CalendarSubmission.timestamp($0) } }
        func values(_ value: Any?) -> [String: WatchListValue]? { (value as? [String: Any])?.mapValues { WatchListValue(json: $0) } }
        watch.lastRunAt = date(file["last_run_at"])
        let saved = file["items"] as? [String: Any] ?? [:]
        for index in watch.items.indices {
            guard let entry = saved[watch.items[index].key] as? [String: Any] else { continue }
            var item = watch.items[index]
            item.title = entry["title"] as? String
            item.url = entry["url"] as? String
            item.captured = values(entry["captured"])
            item.expected = values(entry["expected"])
            item.state = values(entry["state"])
            if let facts = entry["facts"], !(facts is NSNull) { item.facts = facts as? String ?? WatchListValue.jsonText(facts, limit: WatchListReading.factsLimit) }
            item.why = WatchListReading.whyLines(entry["why"])
            item.checkedAt = date(entry["checked_at"])
            item.status = status(from: entry)
            item.failures = (entry["failures"] as? NSNumber)?.intValue ?? 0
            item.notified = (entry["last_told"] as? [String: Any]).flatMap(status(from:))
            item.notifiedCouldNotCheck = NoteCheckResult.boolean(entry["told_couldnt_check"]) ?? false
            watch.items[index] = item
        }
    }

    static func statusObject(_ status: WatchListStatus) -> [String: Any] {
        switch status {
        case .asExpected: return ["status": "as expected"]
        case .notAsExpected(let differences):
            return ["status": "not as expected",
                    "differences": differences.map { ["field": $0.field, "now": $0.now.json, "expected": $0.expected.json] }]
        case .couldNotCheck(let reason): return ["status": "couldn't check", "reason": reason]
        }
    }

    static func status(from object: [String: Any]) -> WatchListStatus? {
        switch object["status"] as? String {
        case "as expected": return .asExpected
        case "not as expected":
            let differences = (object["differences"] as? [[String: Any]] ?? []).compactMap { entry -> WatchListDifference? in
                guard let field = entry["field"] as? String else { return nil }
                return WatchListDifference(field: field, now: WatchListValue(json: entry["now"]), expected: WatchListValue(json: entry["expected"]))
            }
            return .notAsExpected(differences)
        case "couldn't check": return .couldNotCheck(object["reason"] as? String ?? "")
        default: return nil
        }
    }

    // MARK: files

    /// Writes the whole file under a hidden name beside it, readable only by this account, then moves it into place.
    static func write(_ text: String, to file: URL) throws {
        let manager = FileManager.default
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw WatchListError("Couldn't write \(file.lastPathComponent) in \(file.deletingLastPathComponent().path).")
        }
        guard rename(temporary.path, file.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: file.path])
        }
    }

    static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// The folders in `directory`, by name: no hidden ones, no files.
    static func folders(in directory: URL) -> [URL] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { entry in
            var isDirectory: ObjCBool = false
            return !entry.lastPathComponent.hasPrefix(".") && manager.fileExists(atPath: entry.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// JSON as people read it: two spaces in, `"key": value`, keys in order, a short list of plain values on one line, and
/// numbers as written (12.33, not 12.329999999999998).
enum WatchListJSON {
    static func pretty(_ value: Any, indent: String) -> String {
        let inner = indent + "  "
        switch value {
        case let object as [String: Any]:
            guard !object.isEmpty else { return "{}" }
            return "{\n" + object.keys.sorted().map { inner + text($0) + ": " + pretty(object[$0]!, indent: inner) }.joined(separator: ",\n")
                + "\n" + indent + "}"
        case let list as [Any]:
            guard !list.isEmpty else { return "[]" }
            let plain = list.allSatisfy { !($0 is [Any]) && !($0 is [String: Any]) }
            let line = "[" + list.map { pretty($0, indent: inner) }.joined(separator: ", ") + "]"
            if plain, line.count <= 80 { return line }
            return "[\n" + list.map { inner + pretty($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        default:
            return scalar(value)
        }
    }

    /// One line, no spaces, keys in order: how facts and values that aren't flat are kept and compared.
    static func compact(_ value: Any) -> String {
        switch value {
        case let object as [String: Any]: return "{" + object.keys.sorted().map { text($0) + ":" + compact(object[$0]!) }.joined(separator: ",") + "}"
        case let list as [Any]: return "[" + list.map(compact).joined(separator: ",") + "]"
        default: return scalar(value)
        }
    }

    static func scalar(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let text = value as? String { return self.text(text) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            if !CFNumberIsFloatType(number as CFNumber) { return String(number.int64Value) }
            let double = number.doubleValue
            guard double.isFinite else { return "null" }
            return double.rounded() == double && abs(double) < 1e15 ? String(Int64(double)) : String(double)
        }
        return text("\(value)")
    }

    static func text(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
