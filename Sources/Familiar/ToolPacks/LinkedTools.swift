import Darwin
import FamiliarRuntime
import Foundation

/// The team's tools, from a GitHub repository linked in Settings (github.com or GitHub Enterprise), kept current
/// without git: the newest commit of one branch is downloaded as an archive and unpacked into
/// `~/.noteling/linked-tools`, which the registry loads after your own tools folder. Each update replaces that folder
/// whole, so nothing else ever writes into it.
enum LinkedTools {
    /// The token's name among the secrets: kept like the others (the Keychain in signed builds), never written to
    /// config.json or the log, and never handed to a script.
    static let tokenKey = "NOTELING_TOOLS_REPO_TOKEN"
    static let checkInterval: TimeInterval = 600

    /// The installed copy's folder, when a repository is linked.
    static func root(for config: Config, home: URL = Config.dir) -> URL? {
        config.toolsRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : LinkedToolsFolder(home: home).root
    }

    /// No cache, so a check sees a change pushed a minute ago. The Mac's own proxy settings, the proxy passwords it
    /// keeps and its certificates apply (an ephemeral session would keep credentials in memory only).
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()
}

struct LinkedToolsError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - The address

/// A repository on GitHub, from whatever is pasted for it: the page's address (with or without `.git` or a trailing
/// slash, or deeper, like the `/tree/main` a browser shows), an SSH address (`git@host:owner/repo.git`), or an
/// address with a name and password in it, which are dropped.
struct RepoAddress: Equatable {
    let host: String       // lowercased, without the port
    var port: Int? = nil   // kept from a web address that named one
    let owner: String
    let repo: String

    static let example = "https://github.example.com/team/tools"

    var name: String { "\(owner)/\(repo)" }
    private var authority: String { port.map { "\(host):\($0)" } ?? host }
    /// The plain address of the repository's page: what Settings saves.
    var webURL: String { "https://\(authority)/\(owner)/\(repo)" }
    /// GitHub's REST API for the host: api.github.com for github.com, `api.<host>` for GitHub Enterprise Cloud with
    /// data residency (`*.ghe.com`), and `<host>/api/v3` for GitHub Enterprise Server.
    var apiBase: String {
        if host == "github.com" { return "https://api.github.com" }
        if host.hasSuffix(".ghe.com") { return "https://api.\(host)" }
        return "https://\(authority)/api/v3"
    }

    static func parse(_ text: String) throws -> RepoAddress {
        let notAnAddress = LinkedToolsError("That isn't a repository address. Paste the address of the repository's page, like \(example).")
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { throw notAnAddress }
        if !s.contains("://"), let colon = s.firstIndex(of: ":") {
            // `[user@]host:owner/repo.git`, unless the colon starts a port (`host:8443/owner/repo`).
            let before = s[..<colon], after = s[s.index(after: colon)...]
            let port = after.prefix { $0 != "/" }
            if before.contains("@") || port.isEmpty || !port.allSatisfy(\.isNumber) {
                s = "ssh://" + (before.split(separator: "@").last.map(String.init) ?? "") + "/" + after
            }
        }
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              ["https", "http", "ssh", "git", "git+ssh"].contains(scheme),
              var host = c.host?.lowercased(), !host.isEmpty,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { throw notAnAddress }
        var parts = c.path.split(separator: "/").map(String.init)
        // An API address works too: /repos/owner/repo on api.github.com or api.<host>, /api/v3/repos/owner/repo on a server.
        if host == "www.github.com" { host = "github.com" }
        if host == "api.github.com" || (host.hasPrefix("api.") && host.hasSuffix(".ghe.com")) {
            host = host == "api.github.com" ? "github.com" : String(host.dropFirst(4))
            if parts.first == "repos" { parts.removeFirst() }
        } else if parts.starts(with: ["api", "v3", "repos"]) {
            parts.removeFirst(3)
        }
        guard parts.count >= 2 else {
            throw LinkedToolsError("That address names no repository. It needs the owner and the repository's name, like \(example).")
        }
        let owner = parts[0]
        var repo = parts[1]
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard isName(owner), isName(repo) else { throw notAnAddress }
        // An SSH port is not the web's; a web address keeps its own.
        return RepoAddress(host: host, port: scheme == "https" ? c.port : nil, owner: owner, repo: repo)
    }

    /// What Settings saves for what was typed: the plain address when it is one, else the text without credentials.
    static func cleaned(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = try? parse(t) { return address.webURL }
        if var c = URLComponents(string: t), c.user != nil || c.password != nil {
            c.user = nil
            c.password = nil
            return c.string ?? ""
        }
        return t
    }

    private static func isName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}

// MARK: - GitHub

/// One repository through GitHub's REST API: the newest commit of a branch, and an archive of one commit. The token
/// goes to the API, and on a redirect only to the repository's host and its subdomains (GitHub's download host is one).
struct GitHubRepoClient {
    let address: RepoAddress
    var token: String?
    var session: URLSession = LinkedTools.session

    private var authorization: String? {
        let t = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : "Bearer \(t)"
    }

    /// The commit at the tip of `branch`, sent as plain text: the cheap request every check makes.
    func headCommit(branch: String) async throws -> String {
        let ref = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let (data, response) = try await load("commits/\(ref)", accept: "application/vnd.github.sha") { request, guarding in
            try await session.data(for: request, delegate: guarding)
        }
        try verify(response, body: data, branch: branch)
        let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard [40, 64].contains(sha.count), sha.allSatisfy(\.isHexDigit) else {
            throw LinkedToolsError("\(address.host) didn't answer the way GitHub does. Check that the address is the repository's page; a sign-in page on your network can cause this too.")
        }
        return sha
    }

    /// The archive of commit `sha`, which GitHub sends from its download host, saved at `file`.
    func downloadArchive(sha: String, to file: URL) async throws {
        let (temporary, response) = try await load("tarball/\(sha)", accept: "application/vnd.github+json") { request, guarding in
            try await session.download(for: request, delegate: guarding)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let head: Data = {
            guard let handle = try? FileHandle(forReadingFrom: temporary) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        }()
        try verify(response, body: head, branch: nil)
        guard head.starts(with: [0x1f, 0x8b]) else {   // gzip
            throw LinkedToolsError("The download from \(response.url?.host ?? address.host) wasn't an archive of the repository. Noteling tries again in 10 minutes.")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private func load<T>(_ path: String, accept: String,
                         _ send: (URLRequest, URLSessionTaskDelegate) async throws -> (T, URLResponse)) async throws -> (T, HTTPURLResponse) {
        guard let url = URL(string: "\(address.apiBase)/repos/\(address.owner)/\(address.repo)/\(path)") else {
            throw LinkedToolsError("That isn't a repository address. Paste the address of the repository's page, like \(RepoAddress.example).")
        }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Noteling", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        do {
            let (value, response) = try await send(request, RedirectGuard(host: address.host, authorization: authorization))
            guard let http = response as? HTTPURLResponse else {
                throw LinkedToolsError("\(address.host) didn't answer the way GitHub does. Check that the address is the repository's page.")
            }
            return (value, http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            let host = error.failingURL?.host ?? url.host ?? address.host
            throw LinkedToolsError("Couldn't reach \(host): \(Self.reason(error)) Check your network or VPN connection; Noteling tries again in 10 minutes.")
        }
    }

    /// Why a connection failed, in a few plain words, or as macOS puts it for anything less common.
    static func reason(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "this Mac isn't online."
        case .cannotFindHost, .dnsLookupFailed: return "its name couldn't be looked up."
        case .cannotConnectToHost: return "it didn't accept the connection."
        case .timedOut: return "it didn't answer in time."
        case .networkConnectionLost: return "the connection dropped."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "this Mac doesn't trust its certificate."
        default:
            let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.hasSuffix(".") ? text : text + "."
        }
    }

    /// Anything but success becomes a sentence: what happened, where, and what to do.
    private func verify(_ response: HTTPURLResponse, body: Data, branch: String?) throws {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return }
        let host = address.host
        let said = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["message"] as? String
        let message = (said ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = message.isEmpty || message.count > 120 || message.contains(where: \.isNewline) ? "" : " (“\(message)”)"
        switch status {
        case 401 where authorization == nil:
            throw LinkedToolsError("\(host) needs a token to read \(address.name). Paste the one you were given in Settings, under Team tools from GitHub.")
        case 401:
            throw LinkedToolsError("\(host) refused the token. It may have expired or been mistyped: paste a new one in Settings, under Team tools from GitHub.")
        case 403, 429:
            if status == 429 || response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || message.lowercased().contains("rate limit") {
                throw LinkedToolsError("\(host) turned Noteling away for asking too often\(quoted). Noteling tries again in 10 minutes.")
            }
            throw LinkedToolsError("\(host) didn't allow reading \(address.name)\(quoted). "
                + (authorization == nil ? "Add a token that can read this repository." : "Check that the token can read this repository."))
        case 409:
            throw LinkedToolsError("\(address.name) on \(host) is empty: nothing has been pushed to it yet. Noteling tries again in 10 minutes.")
        case 422 where branch != nil:
            throw LinkedToolsError("\(address.name) on \(host) has no \(branch ?? "") branch\(quoted). Ask whoever looks after it which branch to follow; it is set as toolsRepoBranch in config.json.")
        case 404:
            let what = branch.map { "\(address.name) with a \($0) branch" } ?? address.name
            throw LinkedToolsError(authorization == nil
                ? "\(host) couldn't find \(what). Check the address. If the repository is private, add a token that can read it."
                : "\(host) couldn't find \(what), or the token can't see it. Check the address, and that the token can read the repository.")
        default:
            throw LinkedToolsError("\(host) answered with an error (HTTP \(status)). Noteling tries again in 10 minutes.")
        }
    }
}

/// Keeps the token on a redirect within the repository's host and its subdomains, and takes it off anywhere else.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let host: String
    let authorization: String?

    init(host: String, authorization: String?) {
        self.host = host
        self.authorization = authorization
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var next = request
        let target = request.url?.host?.lowercased() ?? ""
        let trusted = request.url?.scheme?.lowercased() == "https" && (target == host || target.hasSuffix("." + host))
        next.setValue(trusted ? authorization : nil, forHTTPHeaderField: "Authorization")
        return next
    }
}

// MARK: - The copy on this Mac

/// `linked-tools.json`: which copy is installed (address, branch, commit and when), and how the last check went.
struct LinkedToolsRecord: Codable, Equatable {
    var url = ""
    var branch = "main"
    var sha: String?
    var updatedAt: Date?
    var lastCheckedAt: Date?
    var lastError: String?
}

/// Where the copy lives in Noteling's folder: `linked-tools/` holds the packs, `linked-tools.json` the record.
struct LinkedToolsFolder {
    let home: URL
    var root: URL { home.appendingPathComponent("linked-tools") }
    var incoming: URL { home.appendingPathComponent(".linked-tools-incoming") }
    var recordFile: URL { home.appendingPathComponent("linked-tools.json") }

    func record() -> LinkedToolsRecord? {
        guard let data = try? Data(contentsOf: recordFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LinkedToolsRecord.self, from: data)
    }

    func save(_ record: LinkedToolsRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? data.write(to: recordFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordFile.path)
    }

    /// Unpacks a GitHub archive next to the installed copy and swaps its one top folder in with a single rename. A
    /// failure before that leaves the installed copy as it was. Returns the packs in the new copy.
    @discardableResult
    func install(archive: URL) async throws -> [String] {
        let fm = FileManager.default
        try? fm.removeItem(at: incoming)   // what an interrupted install left
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: incoming) }
        // bsdtar refuses entries with `..` in their path, or that would write through a link (-P would allow both).
        let tar = try await Subprocess.run("/usr/bin/tar", ["-xzf", archive.path, "-C", incoming.path], timeout: 120)
        guard tar.code == 0, !tar.timedOut else {
            let why = tar.timedOut ? "it took too long" : tar.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "tar stopped"
            throw LinkedToolsError("The download couldn't be unpacked (\(why)). Nothing was changed.")
        }
        let tops = try fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: [.isDirectoryKey]).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard tops.count == 1, let top = tops.first, (try? top.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw LinkedToolsError("The download didn't hold one folder at the top, as GitHub's archives do. Nothing was changed.")
        }
        Self.dropLinksLeaving(top)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: top.path)   // the team's docs are for this account only
        do { try Self.swap(top, into: root) } catch {
            throw LinkedToolsError("The new copy couldn't be put in place (\(error.localizedDescription)). The copy from before is still in use.")
        }
        return ToolRegistry.packFolders(in: root).map(\.lastPathComponent)
    }

    /// Unlinking: the copy, anything half installed, and the record go.
    func remove() {
        let fm = FileManager.default
        for url in [root, incoming, recordFile] where fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }

    /// Puts `new` at `target` in one step. The old copy is swapped to `new`'s place, to be deleted with it.
    static func swap(_ new: URL, into target: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { try fm.moveItem(at: new, to: target); return }
        if renamex_np(new.path, target.path, UInt32(RENAME_SWAP)) == 0 { return }
        // A volume that can't swap: the old copy goes aside, the new one in, and the old one back if that fails.
        let aside = new.deletingLastPathComponent().appendingPathComponent(".previous")
        try fm.moveItem(at: target, to: aside)
        do { try fm.moveItem(at: new, to: target) } catch {
            try? fm.moveItem(at: aside, to: target)
            throw error
        }
    }

    /// Takes out links that lead outside the copy, or nowhere, so no team file stands for one elsewhere on this Mac.
    static func dropLinksLeaving(_ top: URL) {
        let fm = FileManager.default
        let base = top.resolvingSymlinksInPath().path + "/"
        guard let walk = fm.enumerator(at: top, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        var leaving: [URL] = []
        for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath().path
            if !target.hasPrefix(base) || !fm.fileExists(atPath: target) { leaving.append(url) }
        }
        for url in leaving {
            try? fm.removeItem(at: url)
            Log.info("linked tools: left out \(url.lastPathComponent), a link to outside the tools")
        }
    }
}

// MARK: - Keeping it current

/// Keeps the linked copy current: checks at launch, every 10 minutes, on Update now, and right after Settings saves a
/// changed address, branch or token. One check at a time. When one fails, the copy that worked stays in use and the
/// error stays visible until a check succeeds.
@MainActor
final class LinkedToolsUpdater: ObservableObject {
    @Published private(set) var record: LinkedToolsRecord?
    @Published private(set) var checking = false
    /// After a new copy is installed, or the link removed: the app reloads its tools.
    var onToolsChanged: (() async -> Void)?

    let folder: LinkedToolsFolder
    private let session: URLSession
    private let token: () -> String?
    private let config: () -> Config
    private var loop: Task<Void, Never>?
    private var again = false
    private var checkedSettings: Int?   // the address, branch and token the last check used, hashed

    init(folder: LinkedToolsFolder = LinkedToolsFolder(home: Config.dir), session: URLSession = LinkedTools.session,
         token: @escaping () -> String? = { Secrets.get(LinkedTools.tokenKey) }, config: @escaping () -> Config) {
        self.folder = folder
        self.session = session
        self.token = token
        self.config = config
        record = folder.record()
    }

    /// Checks now, then every 10 minutes.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(LinkedTools.checkInterval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// After Settings saves: a changed address, branch or token is checked right away.
    func settingsSaved() {
        guard settingsKey(config(), token()) != checkedSettings else { return }
        Task { await check() }
    }

    /// Never two at once: asked for during a check, another runs right after it, with the settings as they are then.
    func check() async {
        guard !checking else { again = true; return }
        checking = true
        defer { checking = false }
        repeat {
            again = false
            await checkOnce()
        } while again
    }

    private func checkOnce() async {
        let settings = config()
        let token = self.token()
        checkedSettings = settingsKey(settings, token)
        let text = settings.toolsRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { await unlink(); return }
        let branch = Self.branch(settings)
        var next = record ?? LinkedToolsRecord()
        next.lastCheckedAt = Date()
        do {
            let address = try RepoAddress.parse(text)
            let client = GitHubRepoClient(address: address, token: token, session: session)
            let sha = try await client.headCommit(branch: branch)
            if let installed = record, installed.sha == sha, installed.url == address.webURL, installed.branch == branch,
               FileManager.default.fileExists(atPath: folder.root.path) {
                next.lastError = nil
                keep(next)
                Log.info("linked tools: \(address.name) is current at \(sha.prefix(7))")
                return
            }
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent("noteling-linked-tools-\(UUID().uuidString).tar.gz")
            defer { try? FileManager.default.removeItem(at: archive) }
            try await client.downloadArchive(sha: sha, to: archive)
            let packs = try await folder.install(archive: archive)
            let now = Date()
            keep(LinkedToolsRecord(url: address.webURL, branch: branch, sha: sha, updatedAt: now, lastCheckedAt: now))
            Log.info("linked tools: installed \(address.name) at \(sha.prefix(7)), \(packs.count) pack(s)")
            await onToolsChanged?()
        } catch is CancellationError {
            return
        } catch {
            next.lastError = error.localizedDescription
            keep(next)
            Log.info("linked tools: \(error.localizedDescription)")
        }
    }

    private func unlink() async {
        guard record != nil || FileManager.default.fileExists(atPath: folder.root.path) else { return }
        folder.remove()
        record = nil
        Log.info("linked tools: no repository is linked; removed the copy")
        await onToolsChanged?()
    }

    private func keep(_ next: LinkedToolsRecord) {
        record = next
        folder.save(next)
    }

    private func settingsKey(_ settings: Config, _ token: String?) -> Int {
        var hasher = Hasher()
        hasher.combine(settings.toolsRepo.trimmingCharacters(in: .whitespacesAndNewlines))
        hasher.combine(Self.branch(settings))
        hasher.combine(token ?? "")
        return hasher.finalize()
    }

    static func branch(_ settings: Config) -> String {
        let b = settings.toolsRepoBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? "main" : b
    }

    // MARK: what it says

    /// One line for Settings: the installed copy and how fresh it is, or what went wrong and which copy is in use.
    func status(now: Date = Date()) -> String {
        guard !config().toolsRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let installed = record.flatMap { $0.sha != nil && FileManager.default.fileExists(atPath: folder.root.path) ? $0 : nil }
        if let error = record?.lastError {
            guard let copy = installed, let at = copy.updatedAt else { return error }
            return "Couldn't update. \(error) Using the copy from \(Self.clock(at, now: now))."
        }
        guard let copy = installed, let sha = copy.sha else { return "Not downloaded yet." }
        let name = (try? RepoAddress.parse(copy.url))?.name ?? copy.url
        return "\(name) · \(sha.prefix(7)) · updated \(Self.ago(copy.updatedAt ?? now, now: now))"
    }

    /// A few words for the menu's Tools line.
    func menuNote(linkedPacks: Int) -> String {
        guard !config().toolsRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        if record?.lastError != nil { return " · team tools not updated" }
        guard let url = record?.url, let name = (try? RepoAddress.parse(url))?.name else { return "" }
        return " · \(linkedPacks) from \(name)"
    }

    /// Linked packs your own tools folder has a pack of the same name for: yours are used instead.
    func overriddenPacks() -> [String] {
        guard FileManager.default.fileExists(atPath: folder.root.path) else { return [] }
        let own = Set(ToolRegistry.packFolders(in: config().resolvedToolsDir).map(\.lastPathComponent))
        return ToolRegistry.packFolders(in: folder.root).map(\.lastPathComponent).filter(own.contains)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400:
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "yesterday" : "\(days) days ago"
        }
    }

    static func clock(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
