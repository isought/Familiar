import Foundation

/// What a note's check said: that the claim holds for this person, that it doesn't, something to know, or that it
/// couldn't run. Shown beside the note as CHECKED, in the script's own words, never rewritten by the model.
struct NoteCheckResult: Equatable {
    enum Verdict: String, Equatable { case holds, fails, info, unavailable }
    var script: String
    var verdict: Verdict
    var detail: String
    var milliseconds: Int = 0

    /// What a check script returned: a JSON object with `holds` (true or false) and `detail` (or `summary` or
    /// `message`), or any other text, kept as information. Long text is clipped.
    static func parse(_ output: String, script: String) -> NoteCheckResult {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8), var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // The script runner hands back {"result": …, "stdout": …}: the check's own answer is the result.
            if let result = object["result"] {
                if let inner = result as? [String: Any] { object = inner }
                else if let words = result as? String { return NoteCheckResult(script: script, verdict: .info, detail: clip(words)) }
                else if let holds = result as? Bool { return NoteCheckResult(script: script, verdict: holds ? .holds : .fails, detail: holds ? "Holds." : "Doesn't hold.") }
            }
            if let error = object["error"] as? String { return NoteCheckResult(script: script, verdict: .unavailable, detail: clip(error)) }
            let detail = (object["detail"] ?? object["summary"] ?? object["message"]) as? String
            if let holds = object["holds"] as? Bool {
                return NoteCheckResult(script: script, verdict: holds ? .holds : .fails, detail: clip(detail ?? (holds ? "Holds." : "Doesn't hold.")))
            }
            if let detail { return NoteCheckResult(script: script, verdict: .info, detail: clip(detail)) }
        }
        return NoteCheckResult(script: script, verdict: .info, detail: text.isEmpty ? "The check returned nothing." : clip(text))
    }

    /// The pad's line: "CHECKED · roles · as you: You don't have role Y."
    var line: String {
        let name = script.components(separatedBy: "__").last ?? script
        switch verdict {
        case .unavailable: return "Couldn't check (\(name)): \(detail)"
        default: return "CHECKED · \(name) · as you: \(detail)"
        }
    }

    private static func clip(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }
}

/// Runs the checks notes are linked to, with the person's own secrets, each within a time limit, so a slow or broken
/// script never holds up the notes.
@MainActor
struct NoteChecker {
    let registry: ToolRegistry
    var timeout: TimeInterval = 10

    func run(_ check: NoteCheck, context: ScreenContext?) async -> NoteCheckResult {
        guard let (pack, script) = registry.packs.lazy.flatMap({ pack in pack.scripts.map { (pack, $0) } }).first(where: { $0.1.id == check.script }) else {
            return NoteCheckResult(script: check.script, verdict: .unavailable, detail: "This check isn't in your tools folder.")
        }
        if let missing = registry.missingRequirements(for: [pack]).first?.keys, !missing.isEmpty {
            return NoteCheckResult(script: check.script, verdict: .unavailable, detail: "It needs \(missing.joined(separator: ", ")) in Settings.")
        }
        let runner = registry.runner, started = Date(), limit = timeout
        let args: [String: Any] = (check.args ?? [:]).mapValues { $0 }
        let outcome: Result<String, Error> = await withTaskGroup(of: Result<String, Error>?.self) { group in
            group.addTask { @MainActor in
                do { return .success(try await runner.run(script, args: args, context: context, secrets: pack.requires)) }
                catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(CheckTimedOut())
        }
        var result: NoteCheckResult
        switch outcome {
        case .success(let output): result = NoteCheckResult.parse(output, script: check.script)
        case .failure(let error as CheckTimedOut): result = NoteCheckResult(script: check.script, verdict: .unavailable, detail: error.message(limit))
        case .failure(let error): result = NoteCheckResult(script: check.script, verdict: .unavailable, detail: error.localizedDescription)
        }
        result.milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        return result
    }

    private struct CheckTimedOut: Error {
        func message(_ limit: TimeInterval) -> String { "It took longer than \(Int(limit)) seconds." }
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
