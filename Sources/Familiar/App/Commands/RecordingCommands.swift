import AppKit
import SwiftUI
import FamiliarContracts
import FamiliarRuntime

/// `Familiar --record-synthetic <dir>`: a recording from the current screen without a person: 3 full frames a second
/// apart plus 3 crops around the mouse with fake click labels, in the real events.json / meta.json format.
/// Needs Screen Recording, so run the bundle binary (build/Familiar.app/Contents/MacOS/Familiar).
@MainActor
func runRecordSynthetic() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--record-synthetic"), i + 1 < args.count else { print("usage: --record-synthetic <dir>"); exit(2) }
    let dir = URL(fileURLWithPath: args[i + 1])
    let config = Config.load()
    let recorder = WatchRecorder(config: config, watcher: ContextWatcher())
    do {
        let rec = try await recorder.recordSynthetic(into: dir)
        print("recorded \(rec.events.count) events, \(rec.meta.clicks) clicks, \(rec.meta.frames) frames into \(rec.dir.path)")
        for e in rec.events { print("  " + WatchSummarizer.line(e) + (e.crop.map { "  [\($0)]" } ?? "") + (e.full.map { "  [\($0)]" } ?? "")) }
    } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
}

/// `Familiar --summarize-recording <dir> ["purpose"] [--tools-root <dir>] [--keep]`: writes a recording up through Claude
/// and prints the draft JSON; with --keep writes the pack into --tools-root (default: a fresh temp folder, never the real
/// tools folder unless you point there) and shows what the registry makes of it.
@MainActor
func runSummarizeRecording() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--summarize-recording"), i + 1 < args.count else {
        print("usage: --summarize-recording <dir> [\"purpose\"] [--tools-root <dir>] [--keep]"); exit(2)
    }
    let dir = URL(fileURLWithPath: args[i + 1])
    let purpose = i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : nil
    let toolsRoot = args.firstIndex(of: "--tools-root").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("familiar-tools-\(Int(Date().timeIntervalSince1970))")
    var config = Config.load()
    if args.contains("--claude-cli") { config.connectionMode = "claudeCode" }
    do {
        let rec = try Recording.load(dir)
        let picks = WatchSummarizer.selectImages(rec, max: config.watchMaxImages)
        print("recording: \(rec.events.count) events, \(rec.meta.clicks) clicks, hosts \(rec.meta.hosts), \(picks.count) images to send\n")
        let draft = try await WatchSummarizer.summarize(rec, purpose: purpose, config: config, onStatus: { print("  [\($0)]") })
        print("--- draft (parsed: \(draft.parsed)) ---\n\(draft.prettyJSON)\n")
        if args.contains("--keep") {
            guard draft.parsed else { print("not kept: the draft could not be parsed"); exit(1) }
            let files = try PackWriter.write(draft, root: toolsRoot)
            print("--- kept in \(toolsRoot.path) ---")
            for f in files { print("  \(f.path.replacingOccurrences(of: toolsRoot.path + "/", with: ""))") }
            let registry = ToolRegistry(root: toolsRoot, runner: ScriptRunner(config: config))
            await registry.reload()
            for p in registry.packs {
                print("registry: [\(p.dirName)] \(p.name) — \(p.description)\n  match: urls=\(p.match.urls) bundles=\(p.match.bundles) titles=\(p.match.titles)\n  docs: \(p.docs.map(\.relPath))")
            }
        }
    } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
}
