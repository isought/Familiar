import Foundation
import Testing
@testable import Familiar

/// A pack's `brief:` script runs as soon as its page arrives, so the pen and typed questions answer from it without
/// waiting: once per page, kept for a while, waited for only so long, and a failure is said plainly.
@Suite @MainActor
struct PageBriefsTests {
    private func registry() async throws -> (ToolRegistry, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shop"), withIntermediateDirectories: true)
        try "---\nname: Shop\nmatch:\n  urls: [shop.example.com/item/]\nbrief: summary\n---\nItems."
            .write(to: root.appendingPathComponent("shop/SKILL.md"), atomically: true, encoding: .utf8)
        let registry = ToolRegistry(root: root, runner: ScriptRunner(config: Config()))
        await registry.reload()
        let pack = try #require(registry.packs.first)
        pack.scripts = [ScriptTool(id: "shop__summary", packDir: "shop", fileName: "summary.py", path: pack.dir.appendingPathComponent("scripts/summary.py"),
                                   description: "Fixture", inputSchema: ["type": "object", "properties": [:]], dependencies: [])]
        return (registry, root)
    }

    private func scene(_ url: String?) -> ScreenContext {
        ScreenContext(appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Item", url: url, focused: nil, timestamp: Date())
    }

    @Test func aPageWhosePackBriefsItIsReadOnceAndKept() async throws {
        let (registry, root) = try await registry()
        defer { try? FileManager.default.removeItem(at: root) }
        let briefs = PageBriefs(registry: registry)
        var runs = 0
        briefs.run = { script, pack, ctx in
            runs += 1
            return PageBriefs.Brief(pack: pack.name, script: script.id, page: PageBriefs.key(ctx) ?? "", text: "{\"price\":12.33}", at: Date())
        }
        let item = scene("https://shop.example.com/item/123#reviews")

        briefs.prefetch(item)
        let first = try #require(await briefs.brief(for: item, wait: 5))
        let again = try #require(await briefs.brief(for: scene("https://shop.example.com/item/123"), wait: 5))

        #expect(first.script == "shop__summary" && first.text == "{\"price\":12.33}")
        #expect(again == first)
        #expect(runs == 1)
        #expect(briefs.source(for: scene("https://elsewhere.example.com/")) == nil)
        #expect(await briefs.brief(for: scene("https://elsewhere.example.com/"), wait: 1) == nil)
        #expect(await briefs.brief(for: scene(nil), wait: 1) == nil)
    }

    @Test func anOldBriefIsReadAgainAndAFailureIsKeptOnlyBriefly() async throws {
        let (registry, root) = try await registry()
        defer { try? FileManager.default.removeItem(at: root) }
        let briefs = PageBriefs(registry: registry)
        var runs = 0
        var fail = true
        briefs.run = { script, pack, ctx in
            runs += 1
            return PageBriefs.Brief(pack: pack.name, script: script.id, page: PageBriefs.key(ctx) ?? "",
                                    text: fail ? "Couldn't reach the item page." : "{}", at: Date(), failed: fail)
        }
        let item = scene("https://shop.example.com/item/9")

        let failed = try #require(await briefs.brief(for: item, wait: 5))
        #expect(failed.failed)
        #expect(await briefs.brief(for: item, wait: 5) == failed)   // kept for a moment: no retry storm
        briefs.failedLifetime = 0
        fail = false
        let recovered = try #require(await briefs.brief(for: item, wait: 5))
        #expect(!recovered.failed && runs == 2)
        briefs.lifetime = 0
        _ = await briefs.brief(for: item, wait: 5)
        #expect(runs == 3)
    }

    @Test func aSlowBriefIsNotWaitedForButKeptForNextTime() async throws {
        let (registry, root) = try await registry()
        defer { try? FileManager.default.removeItem(at: root) }
        let briefs = PageBriefs(registry: registry)
        briefs.run = { script, pack, ctx in
            try? await Task.sleep(for: .milliseconds(400))
            return PageBriefs.Brief(pack: pack.name, script: script.id, page: PageBriefs.key(ctx) ?? "", text: "{\"late\":true}", at: Date())
        }
        let item = scene("https://shop.example.com/item/77")

        #expect(await briefs.brief(for: item, wait: 0.05) == nil)
        try await Task.sleep(for: .milliseconds(700))
        #expect(await briefs.brief(for: item, wait: 0.05)?.text == "{\"late\":true}")
    }

    @Test func theRequestCarriesTheBriefOrSaysItCouldntRun() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let ok = Prompt.brief(PageBriefs.Brief(pack: "Shop", script: "shop__summary", page: "p", text: "{\"price\":12.33}", at: at),
                              now: at.addingTimeInterval(4))
        #expect(ok.contains("What the page's tools say (shop__summary") && ok.contains("4 s ago"))
        #expect(ok.contains("{\"price\":12.33}") && ok.contains("call a tool only for something it doesn't cover"))

        let failed = Prompt.brief(PageBriefs.Brief(pack: "Shop", script: "shop__summary", page: "p", text: "Couldn't reach the item page.",
                                                   at: at, failed: true))
        #expect(failed.contains("couldn't run") && failed.contains("Couldn't reach the item page."))
        #expect(failed.contains("Don't fill the gap with a guess."))
    }

    @Test func theScriptsOwnResultIsWhatTheRequestCarries() {
        #expect(PageBriefs.result(of: "{\"result\": {\"b\": 2, \"a\": 1}, \"stdout\": \"noise\"}") == "{\"a\":1,\"b\":2}")
        #expect(PageBriefs.result(of: "not json") == "not json")
    }

    @Test func aPacksOwnAnswerShapeComesFirstForThePen() {
        let point = WandTarget(screenPoint: .zero, element: nil, windowOwner: nil, windowTitle: nil)
        #expect(Prompt.wandInstruction(target: point, ctx: nil).contains(Prompt.packShapeFirst))
    }
}
