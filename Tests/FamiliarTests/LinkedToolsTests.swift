import FamiliarContracts
import Foundation
import Testing
@testable import Familiar

/// The team's tools from a linked GitHub repository: what people paste as its address, the cheap check and the
/// download (against a stand-in for GitHub inside the process, never the network), unpacking a real archive made with
/// tar, the one-step swap that keeps the last copy that worked, and a registry that puts your own packs first and
/// never writes into the linked folder.
@Suite @MainActor
struct LinkedToolsTests {
    static let first = String(repeating: "a1", count: 20)
    static let second = String(repeating: "b2", count: 20)

    // MARK: - The address

    @Test func addressesAsPeoplePasteThem() throws {
        let server = RepoAddress(host: "github.example.com", owner: "acme", repo: "tools")
        for text in ["https://github.example.com/acme/tools", "https://github.example.com/acme/tools.git",
                     "git@github.example.com:acme/tools.git", "https://github.example.com/acme/tools/tree/main",
                     "https://github.example.com/acme/tools/", "https://user:secret@github.example.com/acme/tools",
                     "  github.example.com/acme/tools\n", "ssh://git@github.example.com:22/acme/tools.git",
                     "https://github.example.com/api/v3/repos/acme/tools", "HTTPS://GitHub.Example.com/acme/tools.GIT"] {
            #expect(try RepoAddress.parse(text) == server, "\(text)")
        }
        #expect(server.apiBase == "https://github.example.com/api/v3")
        #expect(server.webURL == "https://github.example.com/acme/tools")
        #expect(server.name == "acme/tools")

        let dotCom = try RepoAddress.parse("https://github.com/acme/tools")
        #expect(dotCom.host == "github.com" && dotCom.apiBase == "https://api.github.com")
        #expect(try RepoAddress.parse("https://www.github.com/acme/tools") == dotCom)
        #expect(try RepoAddress.parse("https://api.github.com/repos/acme/tools") == dotCom)
        #expect(try RepoAddress.parse("https://acme.ghe.com/acme/tools").apiBase == "https://api.acme.ghe.com")
        let port = try RepoAddress.parse("https://github.example.com:8443/acme/tools")
        #expect(port.apiBase == "https://github.example.com:8443/api/v3" && port.webURL == "https://github.example.com:8443/acme/tools")
        #expect(try RepoAddress.parse("https://github.example.com/acme/.github").repo == ".github")

        // Settings keeps the plain address, never what was pasted with it.
        #expect(RepoAddress.cleaned("https://user:secret@github.example.com/acme/tools.git") == "https://github.example.com/acme/tools")
        #expect(!RepoAddress.cleaned("https://user:secret@github.example.com/acme").contains("secret"))
        #expect(RepoAddress.cleaned("  ") == "")
    }

    @Test func whatIsntARepositoryAddressIsRefusedPlainly() {
        for text in ["", "tools", "https://github.example.com/acme", "https://github.example.com/",
                     "ftp://github.example.com/acme/tools", "https://github.example.com/ac me/tools",
                     "https://github.example.com/acme/../etc", "https://github.example.com/acme/to;ols",
                     "https://github.example.com/acme/%2e%2e", "https://github example com/acme/tools"] {
            #expect(throws: LinkedToolsError.self, "\(text)") { try RepoAddress.parse(text) }
        }
        do { _ = try RepoAddress.parse("https://github.example.com/acme"); Issue.record("an owner alone was taken") } catch {
            #expect(error.localizedDescription == "That address names no repository. It needs the owner and the repository's name, like https://github.example.com/team/tools.")
        }
        do { _ = try RepoAddress.parse("not an address"); Issue.record("words were taken for an address") } catch {
            #expect(error.localizedDescription.hasPrefix("That isn't a repository address."))
        }
    }

    // MARK: - Checking and downloading

    @Test func anUnchangedCommitDownloadsNothing() async throws {
        let f = Fixture()
        defer { f.remove() }
        f.serve(sha: Self.first, archive: try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\nTeam shop."]))
        let updater = f.makeUpdater()

        await updater.check()
        #expect(f.server.paths == ["/api/v3/repos/acme/tools/commits/main", "/api/v3/repos/acme/tools/tarball/\(Self.first)",
                                   "/acme/tools/legacy.tar.gz/\(Self.first)"])
        let check = try #require(f.server.requests.first)
        #expect(check.value(forHTTPHeaderField: "Accept") == "application/vnd.github.sha")
        #expect(check.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(check.value(forHTTPHeaderField: "User-Agent") == "Noteling")
        #expect(check.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        // GitHub's download host is the repository host's own subdomain: the token may go there.
        #expect(f.server.requests.last?.url?.host == "codeload.\(f.host)")
        #expect(f.server.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(try String(contentsOf: f.folder.root.appendingPathComponent("shop/SKILL.md"), encoding: .utf8).contains("Team shop."))
        #expect(f.changes == 1)
        let record = try #require(updater.record)
        #expect(record.url == "https://\(f.host)/acme/tools" && record.branch == "main" && record.sha == Self.first && record.lastError == nil)
        let saved = try #require(f.folder.record())   // on disk to the second
        #expect(saved.url == record.url && saved.sha == record.sha && saved.lastError == nil)
        #expect(abs(saved.updatedAt!.timeIntervalSince(record.updatedAt!)) < 1)
        #expect(updater.status(now: record.updatedAt!.addingTimeInterval(185)) == "acme/tools · a1a1a1a · updated 3 min ago")
        #expect(updater.menuNote(linkedPacks: 1) == " · 1 from acme/tools")
        #expect(try Self.permissions(f.folder.root) == 0o700 && Self.permissions(f.folder.recordFile) == 0o600)
        #expect(!(try String(contentsOf: f.folder.recordFile, encoding: .utf8)).contains("fixture-token"))

        // The next check finds the same commit: one small request, nothing downloaded, nothing reloaded.
        await updater.check()
        #expect(f.server.paths.count == 4 && f.server.paths.last == "/api/v3/repos/acme/tools/commits/main")
        #expect(f.changes == 1)
        #expect(updater.record?.sha == Self.first && updater.record?.updatedAt == record.updatedAt)
        #expect(try #require(updater.record?.lastCheckedAt) >= record.lastCheckedAt!)
    }

    @Test func aNewCommitReplacesTheCopyWhole() async throws {
        let f = Fixture()
        defer { f.remove() }
        f.serve(sha: Self.first, archive: try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\nVersion one.",
                                                            "crm/SKILL.md": "---\nname: CRM\n---\n"]))
        let updater = f.makeUpdater()
        await updater.check()
        f.serve(sha: Self.second, archive: try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\nVersion two.",
                                                             "hr/SKILL.md": "---\nname: HR\n---\n"], top: "acme-tools-b2b2b2b"))
        await updater.check()

        #expect(ToolRegistry.packFolders(in: f.folder.root).map(\.lastPathComponent) == ["hr", "shop"])   // crm went with the old copy
        #expect(try String(contentsOf: f.folder.root.appendingPathComponent("shop/SKILL.md"), encoding: .utf8).contains("Version two."))
        #expect(updater.record?.sha == Self.second && f.changes == 2)
        #expect(!FileManager.default.fileExists(atPath: f.folder.incoming.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.home.path).sorted() == ["linked-tools", "linked-tools.json", "tools"])
    }

    @Test func theTokenNeverFollowsARedirectToAnotherHost() async throws {
        let f = Fixture()
        defer { f.remove() }
        f.serve(sha: Self.first, archive: try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\n"]), downloadHost: f.elsewhere)
        await f.makeUpdater().check()
        let download = try #require(f.server.requests.last)
        #expect(download.url?.host == f.elsewhere)
        #expect(download.value(forHTTPHeaderField: "Authorization") == nil)   // the stand-in passes every header on; the guard took it off
        #expect(f.changes == 1)
    }

    @Test func failuresSayWhatHappenedAndKeepTheCopyThatWorked() async throws {
        let f = Fixture()
        defer { f.remove() }
        let archive = try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\nThe copy that worked.", "shop/docs/guide.md": "Guide."])
        f.serve(sha: Self.first, archive: archive)
        let updater = f.makeUpdater()
        await updater.check()
        let installed = try Self.snapshot(f.folder.root)

        func json(_ message: String) -> Data { try! JSONSerialization.data(withJSONObject: ["message": message]) }
        let host = f.host
        let cases: [(GitHubStub.Reply, String)] = [
            (.init(status: 401, body: json("Bad credentials")),
             "\(host) refused the token. It may have expired or been mistyped: paste a new one in Settings, under Team tools from GitHub."),
            (.init(status: 403, body: json("Resource not accessible by personal access token")),
             "\(host) didn't allow reading acme/tools (“Resource not accessible by personal access token”). Check that the token can read this repository."),
            (.init(status: 403, body: json("API rate limit exceeded for user ID 1."), headers: ["X-RateLimit-Remaining": "0"]),
             "\(host) turned Noteling away for asking too often (“API rate limit exceeded for user ID 1.”). Noteling tries again in 10 minutes."),
            (.init(status: 404, body: json("Not Found")),
             "\(host) couldn't find acme/tools with a main branch, or the token can't see it. Check the address, and that the token can read the repository."),
            (.init(status: 422, body: json("No commit found for SHA: main")),
             "acme/tools on \(host) has no main branch (“No commit found for SHA: main”). Ask whoever looks after it which branch to follow"),
            (.init(status: 409, body: json("Git Repository is empty.")), "acme/tools on \(host) is empty: nothing has been pushed to it yet."),
            (.init(status: 502, body: Data("Bad gateway".utf8)), "\(host) answered with an error (HTTP 502). Noteling tries again in 10 minutes."),
            (.init(failure: URLError(.cannotFindHost)),
             "Couldn't reach \(host): its name couldn't be looked up. Check your network or VPN connection; Noteling tries again in 10 minutes."),
            (.init(failure: URLError(.serverCertificateUntrusted)), "Couldn't reach \(host): this Mac doesn't trust its certificate."),
            (.init(status: 200, body: Data("<html>Sign in to continue</html>".utf8)), "\(host) didn't answer the way GitHub does."),
        ]
        for (reply, expected) in cases {
            f.server.handler = { _ in reply }
            await updater.check()
            let record = try #require(updater.record)
            #expect(record.lastError?.hasPrefix(expected) == true, "\(record.lastError ?? "no error")")
            #expect(record.sha == Self.first && record.lastError?.contains("fixture-token") == false)
            #expect(try Self.snapshot(f.folder.root) == installed)
            let status = updater.status()
            #expect(status.hasPrefix("Couldn't update. \(expected)") && status.hasSuffix("Using the copy from \(LinkedToolsUpdater.clock(record.updatedAt!, now: Date()))."), "\(status)")
            #expect(updater.menuNote(linkedPacks: 1) == " · team tools not updated")
        }
        #expect(f.changes == 1)

        // A new commit whose download isn't an archive changes nothing either.
        f.serve(sha: Self.second, archive: Data("<html>Sign in</html>".utf8))
        await updater.check()
        #expect(updater.record?.lastError?.hasPrefix("The download from codeload.\(host) wasn't an archive of the repository.") == true)
        #expect(try Self.snapshot(f.folder.root) == installed && updater.record?.sha == Self.first)

        // Once it works again, the error goes.
        f.serve(sha: Self.first, archive: archive)
        await updater.check()
        #expect(updater.record?.lastError == nil && updater.status().hasPrefix("acme/tools · a1a1a1a · updated "))
        #expect(f.changes == 1)
    }

    @Test func aPublicRepositoryIsReadWithoutAToken() async throws {
        let f = Fixture()
        defer { f.remove() }
        f.token = nil
        f.server.handler = { _ in GitHubStub.Reply(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8)) }
        let updater = f.makeUpdater()
        await updater.check()
        #expect(f.server.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(updater.status() == "\(f.host) couldn't find acme/tools with a main branch. Check the address. If the repository is private, add a token that can read it.")
        f.server.handler = { _ in GitHubStub.Reply(status: 401, body: Data(#"{"message":"Must authenticate to access this API."}"#.utf8)) }
        await updater.check()   // a server that lets no one in without a token
        #expect(updater.status() == "\(f.host) needs a token to read acme/tools. Paste the one you were given in Settings, under Team tools from GitHub.")
        #expect(!FileManager.default.fileExists(atPath: f.folder.root.path) && f.changes == 0)

        f.serve(sha: Self.first, archive: try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\n"]))
        await updater.check()
        #expect(f.server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(updater.record?.sha == Self.first && f.changes == 1)
    }

    @Test func twoChecksNeverRunAtOnce() async throws {
        let f = Fixture()
        defer { f.remove() }
        f.serve(sha: Self.first, archive: try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\n"]), delay: 0.2)
        let updater = f.makeUpdater()
        async let one: Void = updater.check()
        async let two: Void = updater.check()
        _ = await (one, two)
        #expect(f.server.maxInFlight == 1)
        // The one asked for during the first ran right after it, and found nothing new.
        #expect(f.server.paths.filter { $0.hasSuffix("/commits/main") }.count == 2)
        #expect(f.changes == 1 && !updater.checking)
    }

    @Test func savingSettingsChecksOnlyWhatChanged() async throws {
        let f = Fixture()
        defer { f.remove() }
        f.serve(sha: Self.first, archive: try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\n"]))
        let updater = f.makeUpdater()
        await updater.check()
        let before = f.server.requests.count

        updater.settingsSaved()   // nothing changed
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.server.requests.count == before)

        f.token = "new-token"
        updater.settingsSaved()
        try await Self.waitUntil { f.server.requests.count > before && !updater.checking }
        #expect(f.server.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
    }

    @Test func unlinkingRemovesTheCopyAndTheRecord() async throws {
        let f = Fixture()
        defer { f.remove() }
        f.serve(sha: Self.first, archive: try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\n"]))
        let updater = f.makeUpdater()
        await updater.check()
        #expect(FileManager.default.fileExists(atPath: f.folder.root.path))

        f.config.toolsRepo = ""
        await updater.check()
        #expect(!FileManager.default.fileExists(atPath: f.folder.root.path))
        #expect(!FileManager.default.fileExists(atPath: f.folder.recordFile.path))
        #expect(updater.record == nil && updater.status() == "" && updater.menuNote(linkedPacks: 0) == "")
        #expect(f.changes == 2)   // the app reloads without them
        #expect(LinkedTools.root(for: f.config, home: f.home) == nil)

        await updater.check()   // and nothing more happens while unlinked
        #expect(f.changes == 2)
    }

    // MARK: - Unpacking

    @Test func anArchiveInstallsWithoutItsTopFolder() async throws {
        let home = Self.temporary("linked-install")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = LinkedToolsFolder(home: home)
        let file = home.appendingPathComponent("download.tar.gz")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\n", "shop/docs/guide.md": "Guide.", "shop/scripts/total.py": "def run(): return 1\n",
                          "README.md": "The team's tools."]).write(to: file)

        #expect(try await folder.install(archive: file) == ["shop"])
        #expect(try Self.snapshot(folder.root) == ["README.md": "The team's tools.", "shop/SKILL.md": "---\nname: Shop\n---\n",
                                                   "shop/docs/guide.md": "Guide.", "shop/scripts/total.py": "def run(): return 1\n"])
        #expect(!FileManager.default.fileExists(atPath: folder.incoming.path))
    }

    @Test func aBrokenArchiveLeavesThePreviousCopy() async throws {
        let home = Self.temporary("linked-broken")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = LinkedToolsFolder(home: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("download.tar.gz")
        try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\nWorks."]).write(to: file)
        try await folder.install(archive: file)
        let installed = try Self.snapshot(folder.root)

        let broken: [(Data, String)] = [
            (Data([0x1f, 0x8b, 0x08, 0x00]) + Data("not really gzip".utf8), "The download couldn't be unpacked ("),
            (try Self.archive(["shop/SKILL.md": "x"], tops: ["acme-tools-a", "acme-tools-b"]),
             "The download didn't hold one folder at the top, as GitHub's archives do. Nothing was changed."),
            (try Self.archive(["README.md": "x"], tops: []), "The download didn't hold one folder at the top"),
            // bsdtar refuses a path with `..` in it; the whole install stops.
            (try Self.archive(["shop/SKILL.md": "x"], outside: ["evil.txt": "x"], members: ["acme-tools-abc1234", "acme-tools-abc1234/../evil.txt"]),
             "The download couldn't be unpacked (acme-tools-abc1234/../evil.txt: Path contains '..'"),
        ]
        for (data, expected) in broken {
            try data.write(to: file)
            do {
                try await folder.install(archive: file)
                Issue.record("installed a broken archive (\(expected))")
            } catch {
                #expect(error.localizedDescription.hasPrefix(expected), "\(error.localizedDescription)")
            }
            #expect(try Self.snapshot(folder.root) == installed)
            #expect(!FileManager.default.fileExists(atPath: folder.incoming.path))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("evil.txt").path))
        }
    }

    @Test func linksLeavingTheToolsAreDropped() async throws {
        let home = Self.temporary("linked-links")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = LinkedToolsFolder(home: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("download.tar.gz")
        try Self.archive(["shop/SKILL.md": "---\nname: Shop\n---\n", "shop/docs/guide.md": "Guide."],
                         links: ["shop/docs/same-guide.md": "guide.md", "shop/docs/skill.md": "../SKILL.md",
                                 "shop/docs/hosts.md": "/etc/hosts", "shop/docs/up.md": "../../../../../../../../etc/hosts",
                                 "shop/docs/nowhere.md": "missing.md"]).write(to: file)
        try await folder.install(archive: file)
        let docs = try FileManager.default.contentsOfDirectory(atPath: folder.root.appendingPathComponent("shop/docs").path).sorted()
        #expect(docs == ["guide.md", "same-guide.md", "skill.md"])
    }

    // MARK: - The registry

    @Test func yourOwnPackWinsOverALinkedOneOfTheSameName() async throws {
        let f = Fixture()
        defer { f.remove() }
        let linked = f.folder.root
        try Self.write("---\nname: My shop\nmatch:\n  urls: [shop.example.com]\n---\nMine.", to: f.personal.appendingPathComponent("shop/SKILL.md"))
        try Self.write("---\nname: Team shop\nmatch:\n  urls: [shop.example.com]\n---\nTheirs.", to: linked.appendingPathComponent("shop/SKILL.md"))
        try Self.write("---\nname: Team CRM\nrequires: [NOTELING_TOOLS_REPO_TOKEN, CRM_KEY]\nmatch:\n  urls: [crm.example.com]\n---\n",
                       to: linked.appendingPathComponent("crm/SKILL.md"))
        try Self.write("Approvals take two days.", to: linked.appendingPathComponent("crm/docs/guide.md"))
        let registry = ToolRegistry(root: f.personal, runner: ScriptRunner(config: Config()))
        registry.linkedRoot = linked
        await registry.reload()

        #expect(registry.packs.map(\.name) == ["My shop", "Team CRM"])
        #expect(registry.packs.map(\.linked) == [false, true])
        let crm = try #require(registry.packs.last)
        #expect(crm.requires == ["CRM_KEY"])   // the link's own token is never a script's secret
        #expect(crm.docs.map(\.relPath) == ["crm/docs/guide.md"])
        #expect(registry.select(for: Self.scene("https://crm.example.com/deals")).active.map(\.name) == ["Team CRM"])
        #expect(registry.select(for: Self.scene("https://shop.example.com/cart")).active.map(\.name) == ["My shop"])
        #expect(f.makeUpdater().overriddenPacks() == ["shop"])

        registry.linkedRoot = nil
        await registry.reload()
        #expect(registry.packs.map(\.name) == ["My shop"])
    }

    @Test func linkedDocsResolveAndPathsStayInside() throws {
        let f = Fixture()
        defer { f.remove() }
        let linked = f.folder.root
        try Self.write("Mine: the shop's returns take a week.", to: f.personal.appendingPathComponent("shop/docs/mine.md"))
        try Self.write("Theirs: hidden by yours.", to: linked.appendingPathComponent("shop/docs/theirs.md"))
        try Self.write("Approvals take two days.", to: linked.appendingPathComponent("crm/docs/guide.md"))
        try Self.write("Never read.", to: f.home.appendingPathComponent("tools-other/secret.md"))
        func run(_ name: String, _ input: [String: Any]) -> (text: String, isError: Bool) {
            let r = BuiltinTools.execute(name, input, root: f.personal, linkedRoot: linked)
            return (r.content as? String ?? "", r.isError)
        }

        #expect(run("read_file", ["path": "crm/docs/guide.md"]) == ("Approvals take two days.", false))
        #expect(run("read_file", ["path": "shop/docs/mine.md"]) == ("Mine: the shop's returns take a week.", false))
        #expect(run("read_file", ["path": "shop/docs/theirs.md"]).isError)   // your shop is the one in use
        for path in ["../tools-other/secret.md", "crm/../../tools-other/secret.md", "../linked-tools/../tools-other/secret.md", "../linked-tools.json"] {
            #expect(run("read_file", ["path": path]) == ("Invalid path.", true), "\(path)")
        }
        let hits = run("grep", ["pattern": "take|hidden"]).text.components(separatedBy: "\n").sorted()
        #expect(hits == ["crm/docs/guide.md:1: Approvals take two days.", "shop/docs/mine.md:1: Mine: the shop's returns take a week."])
        #expect(run("grep", ["pattern": "take", "path": "crm"]).text == "crm/docs/guide.md:1: Approvals take two days.")
        #expect(run("grep", ["pattern": "take"]).text == run("grep", ["pattern": "take", "path": "../tools-other"]).text)   // outside: everything, as before
    }

    @Test func nothingWritesIntoTheLinkedFolder() async throws {
        let f = Fixture()
        defer { f.remove() }
        let linked = f.folder.root
        let teamNote = StickyNote(id: "team-1", anchor: NoteAnchor(host: "crm.example.com", role: "AXButton", label: "Approve"),
                                  kind: "warning", text: "Approvals take two days", by: "Team", at: "2026-10-01", confirmed: "2026-10-01")
        try Self.write("---\nname: Team CRM\nmatch:\n  urls: [crm.example.com]\n---\n", to: linked.appendingPathComponent("crm-example-com/SKILL.md"))
        try NoteStore.save([teamNote], packDir: linked.appendingPathComponent("crm-example-com"))
        let untouched = try Self.snapshot(linked)
        let registry = ToolRegistry(root: f.personal, runner: ScriptRunner(config: Config()))
        registry.linkedRoot = linked
        await registry.reload()
        let store = NotesStore(directory: f.home.appendingPathComponent("notes"))
        #expect(store.moveNotes(fromPacksIn: linked, rename: false) == 1)   // the team's notes come in; their file stays
        registry.notesStore = store
        let service = ContextNotesService(registry: registry)
        let page = Self.scene("https://crm.example.com/deals/1")
        #expect(registry.notes(for: page) == [teamNote])

        // Editing a team note keeps it in your notes; removing it hides the team's copy for good.
        var edited = teamNote
        edited.text = "Approvals take two days, three in December"
        _ = try await service.keep(edited, appName: "Browser")
        #expect(registry.notes(for: page) == [edited])
        try service.remove(teamNote.id)
        await registry.reload()
        #expect(registry.notes(for: page).isEmpty)

        // A note kept in packs goes in one of your own, never the team's, whose folder name it doesn't take.
        let crm = try #require(registry.packs.first { $0.linked })
        #expect(throws: ClaudeError.self) { try registry.put(edited, in: crm) }
        let mine = try await ContextNotesService(registry: registry).save(StickyNote(id: "mine-1", anchor: teamNote.anchor, kind: "tip",
            text: "Mine", by: "Me", at: "2026-10-02", confirmed: "2026-10-02"), appName: "Browser")
        #expect(!mine.linked && mine.dir.deletingLastPathComponent().lastPathComponent == "tools" && mine.dirName == "crm-example-com-mine")
        #expect(registry.personalPackDir(for: "crm-example-com") == "crm-example-com-mine")   // where Watch Me puts a draft for it
        #expect(registry.personalPackDir(for: "shop") == "shop")

        #expect(try Self.snapshot(linked) == untouched)
    }

    // MARK: - Helpers

    static func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func scene(_ url: String) -> ScreenContext {
        ScreenContext(appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: "Page", url: url, focused: nil, timestamp: Date())
    }

    static func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Every file under a folder with its text, by relative path: what "unchanged" means here.
    static func snapshot(_ root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        let base = root.resolvingSymlinksInPath().path + "/"
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return files }
        for case let url as URL in walk where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            files[url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    /// An archive shaped like GitHub's: one folder at the top (`owner-repo-sha`) holding the repository, made by the
    /// system tar. `members` and `outside` build the archives GitHub never sends.
    static func archive(_ files: [String: String], links: [String: String] = [:], tops: [String] = ["acme-tools-abc1234"],
                        top: String? = nil, outside: [String: String] = [:], members: [String]? = nil) throws -> Data {
        let dir = temporary("archive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tops = top.map { [$0] } ?? tops
        for folder in tops {
            for (path, text) in files { try write(text, to: dir.appendingPathComponent(folder).appendingPathComponent(path)) }
            for (path, target) in links {
                try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent(folder).appendingPathComponent(path).path,
                                                           withDestinationPath: target)
            }
        }
        if tops.isEmpty { for (path, text) in files { try write(text, to: dir.appendingPathComponent(path)) } }
        for (path, text) in outside { try write(text, to: dir.appendingPathComponent(path)) }
        let out = dir.appendingPathComponent("out.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", out.path, "-P", "-C", dir.path] + (members ?? (tops.isEmpty ? Array(files.keys) : tops))
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try Data(contentsOf: out)
    }

    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }
}

/// One test's world: Noteling's folder, your own tools folder, settings, a token, and GitHub's stand-in on made-up hosts.
@MainActor
private final class Fixture {
    let home = LinkedToolsTests.temporary("linked-tools")
    let id = UUID().uuidString.prefix(8).lowercased()
    var host: String { "github-\(id).example.com" }
    var elsewhere: String { "downloads-\(id).example.net" }
    var config = Config()
    var token: String? = "fixture-token"
    var changes = 0
    let server: GitHubStub.Server

    var personal: URL { home.appendingPathComponent("tools") }
    var folder: LinkedToolsFolder { LinkedToolsFolder(home: home) }

    init() {
        server = GitHubStub.Server(hosts: ["github-\(id).example.com", "codeload.github-\(id).example.com", "downloads-\(id).example.net"])
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("tools"), withIntermediateDirectories: true)
        config.toolsRepo = "https://github-\(id).example.com/acme/tools"
        config.toolsDir = home.appendingPathComponent("tools").path
    }

    func makeUpdater() -> LinkedToolsUpdater {
        let updater = LinkedToolsUpdater(folder: folder, session: server.session, token: { [unowned self] in self.token },
                                         config: { [unowned self] in self.config })
        updater.onToolsChanged = { [unowned self] in self.changes += 1 }
        return updater
    }

    /// Answers like GitHub: the branch's commit as text, and its archive by way of a download host.
    func serve(sha: String, archive: Data, downloadHost: String? = nil, delay: TimeInterval = 0) {
        let download = downloadHost ?? "codeload.\(host)"
        server.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v3/repos/acme/tools/commits/main" { return .init(body: Data(sha.utf8), delay: delay) }
            if path == "/api/v3/repos/acme/tools/tarball/\(sha)" { return .init(redirect: "https://\(download)/acme/tools/legacy.tar.gz/\(sha)?token=short-lived") }
            if request.url?.host == download { return .init(body: archive) }
            return .init(status: 404, body: Data(#"{"message":"Not Found"}"#.utf8))
        }
    }

    func remove() {
        server.close()
        try? FileManager.default.removeItem(at: home)
    }
}

/// GitHub's stand-in inside the process. Each fixture registers its own hosts, so tests can run side by side. A
/// redirect carries every header on, as a careless client would, so the token guard is what takes it off.
private final class GitHubStub: URLProtocol {
    struct Reply {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var redirect: String? = nil
        var failure: URLError? = nil
        var delay: TimeInterval = 0
    }

    final class Server: @unchecked Sendable {
        let hosts: [String]
        let session: URLSession
        private let lock = NSLock()
        private var _handler: (URLRequest) -> Reply = { _ in Reply(status: 404) }
        private var _requests: [URLRequest] = []
        private var inFlight = 0
        private var _maxInFlight = 0

        init(hosts: [String]) {
            self.hosts = hosts
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GitHubStub.self]
            configuration.urlCache = nil
            session = URLSession(configuration: configuration)
            GitHubStub.register(self)
        }

        var handler: (URLRequest) -> Reply {
            get { lock.lock(); defer { lock.unlock() }; return _handler }
            set { lock.lock(); _handler = newValue; lock.unlock() }
        }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        var paths: [String] { requests.map { $0.url?.path ?? "" } }
        var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxInFlight }

        fileprivate func begin(_ request: URLRequest) -> Reply {
            lock.lock()
            _requests.append(request)
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
            let handler = _handler
            lock.unlock()
            return handler(request)
        }

        fileprivate func end() { lock.lock(); inFlight -= 1; lock.unlock() }

        func close() {
            session.invalidateAndCancel()
            GitHubStub.unregister(self)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: Server] = [:]

    static func register(_ server: Server) { lock.lock(); for h in server.hosts { servers[h] = server }; lock.unlock() }
    static func unregister(_ server: Server) { lock.lock(); for h in server.hosts { servers[h] = nil }; lock.unlock() }
    static func server(for host: String) -> Server? { lock.lock(); defer { lock.unlock() }; return servers[host] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let server = Self.server(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = server.begin(request)
        let deliver = { [self] in
            server.end()
            if let failure = reply.failure {
                client?.urlProtocol(self, didFailWithError: failure)
                return
            }
            if let redirect = reply.redirect, let target = URL(string: redirect),
               let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect]) {
                var next = request
                next.url = target
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                return
            }
            guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) } else { deliver() }
    }

    override func stopLoading() {}
}
