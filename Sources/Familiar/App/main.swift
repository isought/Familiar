import AppKit
import FamiliarContracts
import FamiliarRuntime
import SwiftUI

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

#if DEBUG
if CommandLine.arguments.contains("--probe-watch-keep") {
    MainActor.assumeIsolated { WatchKeepLayoutProbe.run() }
}
if CommandLine.arguments.contains("--probe-chat-layout") {
    MainActor.assumeIsolated { ChatLayoutProbe.run() }
}
if CommandLine.arguments.contains("--probe-main-thread-diagnostics") {
    MainActor.assumeIsolated { MainThreadDiagnosticsProbe.run() }
}
#endif

if CommandLine.arguments.contains("--record-synthetic") {
    Task { @MainActor in
        await runRecordSynthetic()
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--summarize-recording") {
    Task { @MainActor in
        await runSummarizeRecording()
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--render-mascot") {
    MainActor.assumeIsolated { runRenderMascot() }
} else if CommandLine.arguments.contains("--render-origami") {
    MainActor.assumeIsolated { runRenderOrigami() }
} else if CommandLine.arguments.contains("--render-card") {
    MainActor.assumeIsolated { runRenderCard() }
} else if let index = CommandLine.arguments.firstIndex(of: "--render-background-task"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        do { try BackgroundTaskRender.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        catch { print("Background task render failed: \(error)"); exit(1) }
    }
} else if let index = CommandLine.arguments.firstIndex(of: "--render-morning"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        do { try MorningRender.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        catch { print("Morning files render failed: \(error)"); exit(1) }
    }
} else if CommandLine.arguments.contains("--render-pen") {
    MainActor.assumeIsolated { runRenderPen() }
} else if CommandLine.arguments.contains("--ask") {
    Task { @MainActor in
        await runHeadlessAsk()
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--read-page") {
    // What the page reader sees in the browser window nearest the front. By default only counts, so a check run by
    // anyone, or by an agent, never copies what a page says or which company's site it is; `--full` prints the page.
    Task.detached {
        if let page = PageReader.readFrontBrowser() {
            if CommandLine.arguments.contains("--full") {
                print(page.text(limit: 60_000))
            } else {
                let kinds = Dictionary(grouping: page.elements, by: \.kind).mapValues(\.count).sorted { $0.key < $1.key }
                let host = page.key?.host ?? ""
                let site = host.isEmpty ? "none" : host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost") ? "local"
                    : host.contains("service-now") || page.key?.path.hasSuffix(".do") == true ? "servicenow" : "other"
                print("\(page.appName): \(page.documents.count) document(s), \(page.tabs.count) tab(s), site: \(site)"
                      + (page.sheet != nil ? ", a sheet is open" : ""))
                print(kinds.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                print("with the page's own id: \(page.elements.filter { $0.domID != nil }.count)")
            }
            let visible = page.elements.filter(\.visible).count
            print("\(page.elements.count) things read (\(visible) on screen) in \(Int(page.elapsed * 1_000)) ms"
                  + (page.truncated ? ", stopped at the budget" : ""))
        } else {
            print("No browser window with a page was found, or Accessibility permission isn't granted to the app running this.")
        }
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--selftest") {
    Task { @MainActor in
        await runSelfTest()
        exit(0)
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated { runApp() }
}
