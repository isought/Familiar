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
} else if CommandLine.arguments.contains("--selftest") {
    Task { @MainActor in
        await runSelfTest()
        exit(0)
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated { runApp() }
}
