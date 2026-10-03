import Foundation

/// What a pack's `brief:` script says about the page in front, run as soon as the page arrives so the pen and typed
/// questions answer from it without waiting on tool calls. One result per page, kept for two minutes; a run that
/// fails is kept briefly too, so the answer can say what couldn't be checked instead of guessing.
@MainActor
final class PageBriefs {
    struct Brief: Equatable {
        var pack: String
        var script: String
        var page: String
        var text: String
        var at: Date
        var failed = false
    }

    private let registry: ToolRegistry
    private var kept: [String: Brief] = [:]
    private var running: [String: Task<Brief?, Never>] = [:]
    var lifetime: TimeInterval = 120
    var failedLifetime: TimeInterval = 30
    var timeout: TimeInterval = 30
    /// Runs the script; tests replace it.
    var run: (ScriptTool, ToolPack, ScreenContext) async -> Brief

    init(registry: ToolRegistry) {
        self.registry = registry
        run = { script, pack, ctx in await Self.execute(script, pack: pack, context: ctx, registry: registry) }
    }

    /// The pack and script that brief this scene, when a pack for it has one.
    func source(for ctx: ScreenContext?) -> (pack: ToolPack, script: ScriptTool)? {
        guard let ctx, Self.key(ctx) != nil else { return nil }
        for pack in registry.select(for: ctx).active {
            if let script = registry.script(pack.brief, in: pack) { return (pack, script) }
        }
        return nil
    }

    /// Starts the brief for this scene unless a fresh one is kept or one is already running.
    func prefetch(_ ctx: ScreenContext?) {
        guard let ctx, let key = Self.key(ctx), fresh(key) == nil, running[key] == nil, let (pack, script) = source(for: ctx) else { return }
        running[key] = Task { [weak self] in
            guard let self else { return nil }
            let brief = await self.run(script, pack, ctx)
            self.kept[key] = brief
            self.running[key] = nil
            return brief
        }
    }

    /// The brief for this scene: a fresh kept one, else the run in progress or a new one, waited for up to `wait`
    /// seconds. Nil when no pack briefs this page or the run takes longer (it keeps going for next time).
    func brief(for ctx: ScreenContext?, wait: TimeInterval) async -> Brief? {
        guard let ctx, let key = Self.key(ctx) else { return nil }
        if let kept = fresh(key) { return kept }
        prefetch(ctx)
        guard let task = running[key] else { return fresh(key) }
        return await withTaskGroup(of: Brief?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(wait)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func fresh(_ key: String) -> Brief? {
        guard let brief = kept[key] else { return nil }
        let age = Date().timeIntervalSince(brief.at)
        return age < (brief.failed ? failedLifetime : lifetime) ? brief : nil
    }

    /// A page is its address without the part after #.
    static func key(_ ctx: ScreenContext) -> String? {
        guard let url = ctx.url, !url.isEmpty else { return nil }
        return url.components(separatedBy: "#").first
    }

    private static func execute(_ script: ScriptTool, pack: ToolPack, context: ScreenContext, registry: ToolRegistry) async -> Brief {
        let page = key(context) ?? ""
        do {
            let output = try await registry.runner.run(script, args: [:], context: context, secrets: pack.requires, timeout: 30)
            return Brief(pack: pack.name, script: script.id, page: page, text: result(of: output), at: Date())
        } catch {
            return Brief(pack: pack.name, script: script.id, page: page, text: NoteCheckResult.clip(error.localizedDescription), at: Date(), failed: true)
        }
    }

    /// The script's own result from the runner's `{"result": …}`, as compact JSON for the prompt.
    static func result(of output: String) -> String {
        guard let data = output.data(using: .utf8),
              let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = wrapper["result"],
              let json = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return output }
        let text = String(decoding: json, as: UTF8.self)
        return text.count > 12_000 ? String(text.prefix(12_000)) + "…(cut)" : text
    }
}
