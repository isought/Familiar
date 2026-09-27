import AppKit
import FamiliarContracts
import FamiliarRuntime
import SwiftUI

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

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
