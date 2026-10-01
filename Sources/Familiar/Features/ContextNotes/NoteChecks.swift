import Foundation

/// What a note's check said: that the claim holds for this person, that it doesn't, something to know, or that it
/// couldn't run. Shown beside the note as CHECKED, in the script's own words, never rewritten by the model.
struct NoteCheckResult: Equatable {
    enum Verdict: String, Equatable { case holds, fails, info, unavailable }
    var script: String
    var verdict: Verdict
    var detail: String
    var milliseconds: Int = 0
    /// What the script returned when it didn't say in words, for the model only: the pad never shows raw data.
    var raw: String? = nil

    /// What a check script returned: a JSON object with `holds` (true or false) and `detail` (or `summary` or
    /// `message`), or plain words. Anything else ran, but didn't say whether the note holds.
    static func parse(_ output: String, script: String) -> NoteCheckResult {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var value: Any? = (text.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        // The script runner hands back {"result": …, "stdout": …}: the check's own answer is the result.
        if let wrapper = value as? [String: Any], wrapper.keys.contains("result") { value = wrapper["result"] }
        if let flag = boolean(value) { return NoteCheckResult(script: script, verdict: flag ? .holds : .fails, detail: flag ? "Holds." : "Doesn't hold.") }
        if let words = value as? String, !words.isEmpty { return NoteCheckResult(script: script, verdict: .info, detail: clip(words)) }
        if let object = value as? [String: Any] {
            if let error = object["error"] as? String { return NoteCheckResult(script: script, verdict: .unavailable, detail: clip(firstLine(error))) }
            let detail = (object["detail"] ?? object["summary"] ?? object["message"]) as? String
            if let holds = boolean(object["holds"]) {
                return NoteCheckResult(script: script, verdict: holds ? .holds : .fails, detail: clip(detail ?? (holds ? "Holds." : "Doesn't hold.")))
            }
            if let detail { return NoteCheckResult(script: script, verdict: .info, detail: clip(detail)) }
        }
        if value == nil, !text.isEmpty, (text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }) == nil {
            return NoteCheckResult(script: script, verdict: .info, detail: clip(text))
        }
        let data = value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
        return NoteCheckResult(script: script, verdict: .info, detail: "Ran, but didn't say whether this holds.",
                               raw: data.map { String(String(decoding: $0, as: UTF8.self).prefix(1_500)) })
    }

    /// The pad's line: "CHECKED · roles · as you: You don't have role Y."
    var line: String {
        let name = script.components(separatedBy: "__").last ?? script
        switch verdict {
        case .unavailable: return "Couldn't check (\(name)): \(detail)"
        default: return "CHECKED · \(name) · as you: \(detail)"
        }
    }

    /// A real JSON true or false; never the number 0 or 1.
    static func boolean(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "")
    }

    static func clip(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }
}

/// Runs the checks notes are linked to, with the person's own secrets, each stopped at its time limit, so a slow or
/// broken script never holds up the notes. A check runs only a script from a pack for the page in front, with only
/// the arguments the script declares, so a note can't make the pen run some other script.
@MainActor
struct NoteChecker {
    let registry: ToolRegistry
    var timeout: TimeInterval = 10

    func run(_ check: NoteCheck, context: ScreenContext?) async -> NoteCheckResult {
        let started = Date()
        var result = await outcome(check, context: context)
        result.milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        return result
    }

    private func outcome(_ check: NoteCheck, context: ScreenContext?) async -> NoteCheckResult {
        func unavailable(_ why: String) -> NoteCheckResult { NoteCheckResult(script: check.script, verdict: .unavailable, detail: why) }
        guard let (pack, script) = registry.packs.lazy.flatMap({ pack in pack.scripts.map { (pack, $0) } }).first(where: { $0.1.id == check.script }) else {
            return unavailable("This check isn't in your tools folder.")
        }
        if let context, !registry.select(for: context).active.contains(where: { $0.dir == pack.dir }) {
            return unavailable("This check isn't for this page.")
        }
        if let missing = registry.missingRequirements(for: [pack]).first?.keys, !missing.isEmpty {
            return unavailable("It needs \(missing.joined(separator: ", ")) in Settings.")
        }
        let declared = Set((script.inputSchema["properties"] as? [String: Any] ?? [:]).keys)
        let args: [String: Any] = (check.args ?? [:]).filter { declared.contains($0.key) }.mapValues { $0 }
        do {
            let output = try await registry.runner.run(script, args: args, context: context, secrets: pack.requires,
                                                       timeout: timeout, stopsWithCaller: true)
            return NoteCheckResult.parse(output, script: check.script)
        } catch let error as ScriptRunnerError where error.timedOut {
            return unavailable("It took longer than \(Int(timeout)) seconds.")
        } catch is CancellationError {
            return unavailable("Stopped.")
        } catch {
            return unavailable(NoteCheckResult.clip(NoteCheckResult.firstLine(error.localizedDescription)))
        }
    }
}

/// How notes get used, kept on this Mac to settle later which ways of meeting a note people reach for: arriving on a
/// page with notes, showing them, pointing at things with the pen, checks run, notes kept or removed. Counts, kinds and
/// note ids only: never a note's text, a page's address, or anything on screen. One JSON line per event.
@MainActor
final class NotesUsageLog {
    let file: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private var failed = false
    static let limit = 2 * 1024 * 1024

    init(file: URL = Config.dir.appendingPathComponent("usage/notes.jsonl")) { self.file = file }

    struct Event: Codable, Equatable {
        var v = 1
        var at: Date
        var event: String
        var counts: [String: Int] = [:]
        var tags: [String: String] = [:]
        var notes: [String]? = nil
    }

    func record(_ event: String, counts: [String: Int] = [:], tags: [String: String] = [:], notes: [String]? = nil, at: Date = Date()) {
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let size = try? manager.attributesOfItem(atPath: file.path)[.size] as? Int, size > Self.limit {
                let previous = file.deletingPathExtension().appendingPathExtension("previous.jsonl")
                try? manager.removeItem(at: previous)
                try manager.moveItem(at: file, to: previous)
            }
            if !manager.fileExists(atPath: file.path) {
                manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            var line = try encoder.encode(Event(at: at, event: event, counts: counts, tags: tags, notes: notes))
            line.append(0x0A)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            if !failed { Log.info("notes usage: can't write \(file.lastPathComponent): \(error.localizedDescription)") }
            failed = true
        }
    }

    func read() -> [Event] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? decoder.decode(Event.self, from: Data($0.utf8)) }
    }
}
