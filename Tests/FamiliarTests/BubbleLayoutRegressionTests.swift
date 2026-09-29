#if DEBUG
import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import Familiar

/// A layout spin blocks the main actor, including ordinary async test timeouts.
/// Run the real view in a child so the parent can report that failure and stop it.
struct BubbleLayoutRegressionTests {
    @Test func keepingALongWatchDraftLeavesTheChatResponsive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-layout-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed = false
        defer { if completed { try? FileManager.default.removeItem(at: directory) } }
        let output = directory.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        let child = Process()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        child.executableURL = repository.appendingPathComponent(".build/debug/Familiar")
        child.arguments = ["--probe-watch-keep"]
        var environment = ProcessInfo.processInfo.environment
        environment["FAMILIAR_HOME"] = directory.appendingPathComponent("home").path
        environment["FAMILIAR_BUBBLE_LAYOUT_FIXTURE"] = directory.path
        child.environment = environment
        child.standardOutput = handle
        child.standardError = handle
        try child.run()
        let deadline = Date().addingTimeInterval(15)
        while child.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let timedOut = child.isRunning
        if timedOut {
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = [String(child.processIdentifier), "1", "1", "-file", directory.appendingPathComponent("hang-sample.txt").path]
            sample.standardOutput = handle
            sample.standardError = handle
            try? sample.run()
            sample.waitUntilExit()
            kill(child.processIdentifier, SIGKILL)
            Self.progress("failure artifacts: \(directory.path)")
        }
        child.waitUntilExit()
        let log = try String(contentsOf: output, encoding: .utf8)
        #expect(!timedOut, "The chat main thread stopped responding during Keep. Child progress:\n\(log)")
        #expect(child.terminationStatus == 0, "Hosted chat failed:\n\(log)")
        #expect(log.contains("LAYOUT: keep completed and chat responsive"), "The child did not finish the actual draft-to-Keep flow:\n\(log)")
        completed = !timedOut && child.terminationStatus == 0 && log.contains("LAYOUT: keep completed and chat responsive")
    }

    private static func progress(_ text: String) {
        FileHandle.standardOutput.write(Data("LAYOUT: \(text)\n".utf8))
    }
}
#endif
