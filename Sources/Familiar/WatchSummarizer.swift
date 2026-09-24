import Foundation

/// What Claude proposes after watching: enough to write a tool-pack entry. `parsed == false` means the reply was
/// not the JSON we asked for; `raw` then carries the whole text so the user can still read it.
struct PackDraft {
    var packDir = ""
    var packName = ""
    var packDescription = ""
    var matchURLs: [String] = []
    var matchTitles: [String] = []
    var matchBundles: [String] = []
    var workflowSlug = ""
    var workflowTitle = ""
    var workflowMarkdown = ""
    var screensMarkdown = ""
    var glossaryMarkdown = ""
    var caveats: [String] = []
    var confidence = 0.0
    var raw = ""
    var parsed = false
    var json: [String: Any] = [:]

    var prettyJSON: String {
        guard parsed, let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return raw }
        return String(data: d, encoding: .utf8) ?? raw
    }
}

/// Builds one request from a recording (instructions, the event log, then captioned images), asks Claude, parses the draft.
enum WatchSummarizer {
    static func summarize(_ rec: Recording, purpose: String?, config: Config, apiKey: String,
                          onStatus: @escaping (String) -> Void) async throws -> PackDraft {
        let client = ClaudeClient(config: config, apiKey: apiKey)
        client.effort = "high"
        client.maxTokens = max(config.maxTokens, 8192)
        client.maxToolRounds = 0
        let content = buildContent(rec, purpose: purpose, maxImages: config.watchMaxImages)
        var messages: [[String: Any]] = [["role": "user", "content": content]]
        let reply = try await client.converse(system: Prompt.watchSystem, tools: [], messages: &messages,
                                              executor: { _, _, _ in .text("No tools in this mode.", isError: true) }, onStatus: onStatus)
        Log.info("watch: summary \(reply.inputTokens) in, \(reply.outputTokens) out")
        return parse(reply.text, recording: rec)
    }

    // MARK: request

    static func buildContent(_ rec: Recording, purpose: String?, maxImages: Int) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "text", "text": eventLog(rec, purpose: purpose)]]
        for pick in selectImages(rec, max: maxImages) {
            guard let data = try? Data(contentsOf: rec.dir.appendingPathComponent(pick.file)) else { continue }
            content.append(["type": "text", "text": pick.caption])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]])
        }
        return content
    }

    static func eventLog(_ rec: Recording, purpose: String?) -> String {
        let m = rec.meta
        var s = "## What the user says they were doing\n\(purpose?.isEmpty == false ? purpose! : (m.purpose ?? "(no description given)"))\n\n"
        s += "## Recording\nStarted \(m.startedAt)\(m.endedAt.map { ", ended \($0)" } ?? ""); \(m.clicks) clicks, \(m.frames) full frames, \(rec.events.count) events.\n"
        if !m.hosts.isEmpty { s += "Hosts: \(m.hosts.joined(separator: ", "))\n" }
        if !m.apps.isEmpty { s += "Apps: \(m.apps.joined(separator: ", "))\n" }
        if !m.bundles.isEmpty { s += "Bundles: \(m.bundles.joined(separator: ", "))\n" }
        if !m.titles.isEmpty { s += "Window titles: \(m.titles.map { "“\($0)”" }.joined(separator: ", "))\n" }
        s += "\n## Event log\nEach line: [index] time, what happened — app · window title · URL. Images below refer to the [index].\n"
        for e in rec.events { s += line(e) + "\n" }
        s += "\nNow write the JSON described in your instructions.\n"
        return s
    }

    static func line(_ e: WatchEvent) -> String {
        let place = [e.app, e.title.map { "“\($0)”" }, e.url.map(shortURL)].compactMap { $0 }.joined(separator: " · ")
        var what: String
        switch e.kind {
        case "click": what = "click on \(e.elementLabel)"
        case "scene": what = "screen changed"
        case "typed":
            if e.role == "password field" { what = "typed into a password field (not recorded)" }
            else { what = "typed into \(e.label ?? e.role ?? "a field"): “\(e.text ?? "")”" }
        case "note": what = "note from the user: \(e.text ?? "")"
        default: what = e.kind
        }
        return "[\(e.index)] \(mmss(e.t)) \(what)" + (place.isEmpty ? "" : " — \(place)")
    }

    static func mmss(_ t: Double) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }

    static func shortURL(_ u: String) -> String {
        let s = u.replacingOccurrences(of: "^[a-z]+://", with: "", options: .regularExpression)
        return String(s.prefix(120))
    }

    struct ImagePick { let file: String; let caption: String; let order: (Int, Int) }

    /// Oldest first, at most `max`: scene-change frames first, then click crops (dropping repeats of the same label in a
    /// row), then the periodic full frames; each tier thinned evenly when it does not fit.
    static func selectImages(_ rec: Recording, max: Int) -> [ImagePick] {
        struct C { let pick: ImagePick; let tier: Int }
        var cands: [C] = []
        var prevKey: String?
        var firstFull = true
        for e in rec.events {
            let place = e.url.map(shortURL) ?? e.title.map { "“\($0)”" } ?? e.app ?? ""
            if let f = e.full {
                let cap = e.kind == "scene" ? "[\(e.index)] the screen at \(mmss(e.t)) — \(place)" : "[\(e.index)] the whole screen after that click at \(mmss(e.t)) — \(place)"
                cands.append(C(pick: ImagePick(file: f, caption: cap, order: (e.index, 1)), tier: (e.kind == "scene" || firstFull) ? 0 : 2))
                firstFull = false
            }
            if let c = e.crop {
                let key = e.elementLabel
                if e.kind == "click", let p = prevKey, p == key, e.label?.isEmpty == false {
                    // same control clicked again in a row: one crop is enough
                } else {
                    cands.append(C(pick: ImagePick(file: c, caption: "[\(e.index)] click on \(e.elementLabel) at \(mmss(e.t)) — \(place)", order: (e.index, 0)), tier: 1))
                }
            }
            if e.kind == "click" { prevKey = e.elementLabel }
        }
        var chosen: [ImagePick] = []
        var budget = Swift.max(0, max)
        for tier in 0...2 {
            let t = cands.filter { $0.tier == tier }.map(\.pick)
            if t.count <= budget { chosen += t; budget -= t.count }
            else { chosen += thin(t, to: budget); budget = 0; break }
        }
        return chosen.sorted { $0.order.0 != $1.order.0 ? $0.order.0 < $1.order.0 : $0.order.1 < $1.order.1 }
    }

    static func thin<T>(_ items: [T], to n: Int) -> [T] {
        guard n > 0, items.count > n else { return Array(items.prefix(n)) }
        return (0..<n).map { items[Int(Double($0) * Double(items.count) / Double(n))] }
    }

    // MARK: reply

    static func parse(_ text: String, recording: Recording) -> PackDraft {
        var d = PackDraft()
        d.raw = text
        guard let obj = extractJSON(text) else { return d }
        func str(_ k: String) -> String { (obj[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func list(_ k: String) -> [String] {
            if let a = obj[k] as? [Any] { return a.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            let s = str(k); return s.isEmpty ? [] : [s]
        }
        d.workflowTitle = str("workflow_title")
        d.workflowMarkdown = str("workflow_markdown")
        guard !d.workflowTitle.isEmpty, !d.workflowMarkdown.isEmpty else { return d }
        d.json = obj
        d.parsed = true
        d.packDir = PackWriter.slug(str("pack_dir"))
        if d.packDir.isEmpty { d.packDir = PackWriter.slug(recording.meta.hosts.first ?? str("pack_name")) }
        if d.packDir.isEmpty { d.packDir = "watched" }
        d.packName = str("pack_name").isEmpty ? d.packDir : str("pack_name")
        d.packDescription = str("pack_description")
        d.matchURLs = list("match_urls").isEmpty ? recording.meta.hosts : list("match_urls")
        d.matchTitles = list("match_titles")
        d.matchBundles = list("match_bundles").filter { !ContextWatcher.browserBundles.contains($0) }
        d.workflowSlug = PackWriter.slug(str("workflow_slug"))
        if d.workflowSlug.isEmpty { d.workflowSlug = PackWriter.slug(d.workflowTitle) }
        if d.workflowSlug.isEmpty { d.workflowSlug = "workflow" }
        d.screensMarkdown = str("screens_markdown")
        d.glossaryMarkdown = str("glossary_markdown")
        d.caveats = list("caveats")
        d.confidence = (obj["confidence"] as? NSNumber)?.doubleValue ?? 0
        return d
    }

    static func extractJSON(_ text: String) -> [String: Any]? {
        var body: Substring?
        if let open = text.range(of: "```json"), let close = text.range(of: "```", range: open.upperBound..<text.endIndex) {
            body = text[open.upperBound..<close.lowerBound]
        } else if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b {
            body = text[a...b]
        }
        guard let body, let data = String(body).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Writes a draft into the tools folder without ever deleting or rewriting what is there.
enum PackWriter {
    static func slug(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var out = ""
        var dash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch); dash = false }
            else if !dash, !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(48))
    }

    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    /// Returns the files written or changed.
    @discardableResult
    static func write(_ d: PackDraft, root: URL, date: Date = Date()) throws -> [URL] {
        guard d.parsed else { throw ClaudeError(message: "The draft could not be parsed, so there is nothing to save.") }
        let fm = FileManager.default
        let when = day.string(from: date)
        let packDir = root.appendingPathComponent(d.packDir)
        let docs = packDir.appendingPathComponent("docs")
        let workflows = docs.appendingPathComponent("workflows")
        try fm.createDirectory(at: workflows, withIntermediateDirectories: true)
        var written: [URL] = []

        let skill = packDir.appendingPathComponent("SKILL.md")
        let screens = docs.appendingPathComponent("screens.md")
        if !fm.fileExists(atPath: skill.path) {
            try skillFile(d).write(to: skill, atomically: true, encoding: .utf8)
            written.append(skill)
            let body = "# Screens in \(d.packName)\n\n_Learned by watching on \(when)._\n\n" + d.screensMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try body.write(to: screens, atomically: true, encoding: .utf8)
            written.append(screens)
        } else {
            if let text = try? String(contentsOf: skill, encoding: .utf8), let bumped = bumpRecordings(text) {
                try bumped.write(to: skill, atomically: true, encoding: .utf8)
                written.append(skill)
            }
            let existing = (try? String(contentsOf: screens, encoding: .utf8)) ?? ""
            let known = Set(headings(existing).map { $0.lowercased() })
            let fresh = sections(d.screensMarkdown).filter { !known.contains($0.title.lowercased()) }
            if !fresh.isEmpty {
                var add = (existing.isEmpty ? "# Screens in \(d.packName)\n" : existing.hasSuffix("\n") ? existing : existing + "\n") + "\n## \(when)\n\n"
                for sec in fresh { add += "### \(sec.title)\n\(sec.body)\n\n" }
                try add.write(to: screens, atomically: true, encoding: .utf8)
                written.append(screens)
            }
        }

        var wf = workflows.appendingPathComponent("\(d.workflowSlug).md")
        var n = 2
        while fm.fileExists(atPath: wf.path) { wf = workflows.appendingPathComponent("\(d.workflowSlug)-\(n).md"); n += 1 }
        var caveats = d.caveats.joined(separator: "; ")
        if caveats.isEmpty { caveats = "recorded once; steps may vary" }
        let body = "_Recorded by watching on \(when); \(caveats)_\n\n# \(d.workflowTitle)\n\n" + d.workflowMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try body.write(to: wf, atomically: true, encoding: .utf8)
        written.append(wf)

        let glossary = d.glossaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !glossary.isEmpty {
            let g = docs.appendingPathComponent("glossary.md")
            if let existing = try? String(contentsOf: g, encoding: .utf8) {
                let add = (existing.hasSuffix("\n") ? existing : existing + "\n") + "\n## \(when)\n\n" + glossary + "\n"
                try add.write(to: g, atomically: true, encoding: .utf8)
            } else {
                try "# \(d.packName) glossary\n\n_In the app's own words._\n\n\(glossary)\n".write(to: g, atomically: true, encoding: .utf8)
            }
            written.append(g)
        }
        Log.info("watch: wrote \(written.map(\.lastPathComponent).joined(separator: ", ")) into \(packDir.path)")
        return written
    }

    static func skillFile(_ d: PackDraft) -> String {
        func yamlList(_ a: [String]) -> String { "[" + a.map { $0.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "]", with: "") }.joined(separator: ", ") + "]" }
        var s = "---\nname: \(d.packName.replacingOccurrences(of: "\n", with: " "))\n"
        s += "description: \(d.packDescription.replacingOccurrences(of: "\n", with: " "))\n"
        s += "match:\n"
        s += "  urls: \(yamlList(d.matchURLs))\n"
        if !d.matchBundles.isEmpty { s += "  bundles: \(yamlList(d.matchBundles))\n" }
        s += "  titles: \(yamlList(d.matchTitles))\n"
        s += "---\nLearned by watching. Recordings: 1.\n\nHow to help someone here: follow docs/workflows/*.md for the tasks that were recorded (real labels, in order), and docs/screens.md for what each screen is for. Say when a step was only seen once.\n"
        return s
    }

    /// "Recordings: 3." -> "Recordings: 4." if such a line exists.
    static func bumpRecordings(_ text: String) -> String? {
        guard let r = text.range(of: #"Recordings: (\d+)"#, options: .regularExpression) else { return nil }
        let n = Int(text[r].split(separator: " ").last ?? "") ?? 0
        return text.replacingCharacters(in: r, with: "Recordings: \(n + 1)")
    }

    static func headings(_ md: String) -> [String] {
        md.components(separatedBy: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return nil }
            return t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// Splits markdown into (heading, body) at every heading line; text before the first heading is dropped.
    static func sections(_ md: String) -> [(title: String, body: String)] {
        var out: [(String, String)] = []
        var title: String?
        var body: [String] = []
        func close() { if let t = title { out.append((t, body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) } }
        for line in md.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                close()
                title = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                body = []
            } else if title != nil {
                body.append(line)
            }
        }
        close()
        return out.filter { !$0.0.isEmpty }
    }
}
