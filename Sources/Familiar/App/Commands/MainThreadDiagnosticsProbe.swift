#if DEBUG
import AppKit
import Foundation

/// An isolated debug command exercises real dispatch heartbeats, file output and
/// /usr/bin/sample. It never starts AppDelegate, provider calls or native control.
@MainActor
enum MainThreadDiagnosticsProbe {
    static func run() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = Config.dir.appendingPathComponent("diagnostics/main-thread", isDirectory: true)
        let diagnostics = MainThreadDiagnostics(directory: directory)
        // Only counts are passed to diagnostics. The sentinel makes accidental
        // content capture visible when the resulting event and sample files are checked.
        let privateContent = "PRIVATE-DIAGNOSTIC-FIXTURE-93a721 https://private.example.test/?token=do-not-log"
        diagnostics.start()
        diagnostics.mark(.appReady)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            diagnostics.mark(.transcriptUpdated, itemCount: 1, characterCount: privateContent.count)
            progress("blocking the isolated main thread for four seconds")
            Thread.sleep(forTimeInterval: 4.3)
            diagnostics.mark(.requestFinished)
        }
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(13)
            while Date() < deadline {
                if validate(directory: directory, forbidden: privateContent) {
                    diagnostics.stop()
                    progress("stall, recovery and saved process sample verified")
                    exit(0)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            diagnostics.stop()
            progress("failed to observe stall, recovery and a saved sample within 13 seconds")
            exit(1)
        }
        NSApp.run()
        exit(1)
    }

    nonisolated private static func validate(directory: URL, forbidden: String) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("events.jsonl")),
              let text = String(data: data, encoding: .utf8), !text.contains(forbidden),
              !text.contains("private.example.test") else { return false }
        let events = text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
        let kinds = events.compactMap { $0["kind"] as? String }
        guard kinds.filter({ $0 == "main-thread-stalled" }).count == 1,
              kinds.contains("main-thread-recovered"),
              let sampled = events.first(where: { ($0["kind"] as? String) == "sample-saved" }),
              let report = sampled["report"] as? String,
              let sample = try? String(contentsOf: directory.appendingPathComponent(report), encoding: .utf8),
              sample.count > 100, sample.contains("Call graph"),
              !sample.contains(forbidden), !sample.contains("private.example.test") else { return false }
        return true
    }

    nonisolated private static func progress(_ text: String) {
        FileHandle.standardOutput.write(Data("MAIN THREAD DIAGNOSTICS: \(text)\n".utf8))
    }
}
#endif
