import CryptoKit
import Foundation

/// Older Watch Me saves are offered for review, never silently converted into runnable work.
struct SavedReadingWorkflow: Identifiable {
    var name: String
    var relativePath: String
    var draft: LearnedReadingSource
    var id: String { relativePath }

    static func discover(root: URL) -> [Self] {
        let manager = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        func contained(_ url: URL) -> Bool { url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot) }
        guard let packs = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var result: [Self] = []
        for pack in packs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(100) {
            let skillURL = pack.appendingPathComponent("SKILL.md")
            guard contained(skillURL), let skill = try? String(contentsOf: skillURL, encoding: .utf8),
                  skill.contains("Learned by watching") else { continue }
            let folder = pack.appendingPathComponent("docs/workflows")
            guard contained(folder), let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(100) {
                guard file.pathExtension == "md", contained(file),
                      let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 200_000,
                      let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let path = "\(pack.lastPathComponent)/docs/workflows/\(file.lastPathComponent)"
                let name = body.components(separatedBy: .newlines).first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
                    ?? file.deletingPathExtension().lastPathComponent
                let urls = sourceURLs(in: body)
                let url = urls.count == 1 ? urls[0] : ""
                let gmail = URL(string: url)?.host?.lowercased() == "mail.google.com"
                let bytes = SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
                let uuid = "\(bytes.prefix(8))-\(bytes.dropFirst(8).prefix(4))-\(bytes.dropFirst(12).prefix(4))-\(bytes.dropFirst(16).prefix(4))-\(bytes.suffix(12))"
                let source = LearnedReadingSource(id: UUID(uuidString: uuid)!, kind: gmail ? .mail : .web,
                    name: name, meaning: "Read information from the view taught in ‘\(name)’.",
                    application: body.contains("Google Chrome") ? "Google Chrome" : "",
                    bundleID: body.contains("Google Chrome") ? "com.google.Chrome" : "", url: url,
                    scope: gmail && body.contains("Primary") ? "Read up to 25 recent message rows from the first page of the Primary inbox, including visible sender, subject, snippet and date."
                        : "Read up to 25 visible items from the demonstrated view. Confirm the intended view before reading.",
                    navigationHints: String(body.prefix(12_000)),
                    completionChecks: "Verify the source location and displayed account, then the saved view and the number of rows inspected. Report unreadable or missing information as partial coverage.",
                    uncertainties: ["Recovered from a saved workflow. Review the location, account and reading scope before adding it.",
                                    "Only observations from a new run become results; the old workflow’s example data is not current."],
                    requiresReview: true, workflowPath: path)
                result.append(Self(name: name, relativePath: path, draft: source))
            }
        }
        return result
    }

    private static func sourceURLs(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        // NSDataDetector can include a closing Markdown code tick in the fragment.
        let prose = text.replacingOccurrences(of: "`", with: " ")
        let links = detector.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)).compactMap { match -> String? in
            guard let range = Range(match.range, in: prose), let parsed = match.url else { return nil }
            let literal = String(prose[range])
            let value = literal.lowercased().hasPrefix("http") ? parsed.absoluteString : "https://" + literal
            return readingHTTPURL(value) ? value : nil
        }
        return Array(Set(links)).sorted()
    }
}
