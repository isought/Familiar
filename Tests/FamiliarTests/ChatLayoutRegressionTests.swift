#if DEBUG
import Darwin
import Foundation
import Testing

/// The parent stays outside the UI process so a SwiftUI main-thread spin cannot block its timeout.
struct ChatLayoutRegressionTests {
    @Test func followingUpAfterLongAnswersKeepsChatResponsive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-chat-layout-\(UUID().uuidString)")
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
        child.arguments = ["--probe-chat-layout"]
        var environment = ProcessInfo.processInfo.environment
        environment["NOTELING_HOME"] = directory.appendingPathComponent("home").path
        environment["FAMILIAR_BUBBLE_LAYOUT_FIXTURE"] = directory.path
        child.environment = environment
        child.standardOutput = handle
        child.standardError = handle
        try child.run()
        let deadline = Date().addingTimeInterval(20)
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
            FileHandle.standardOutput.write(Data("CHAT LAYOUT: failure artifacts: \(directory.path)\n".utf8))
        }
        child.waitUntilExit()
        let log = try String(contentsOf: output, encoding: .utf8)
        #expect(!timedOut, "The chat main thread stopped responding after a follow-up. Child progress:\n\(log)")
        #expect(child.terminationStatus == 0, "Hosted chat failed:\n\(log)")
        #expect(log.contains("CHAT LAYOUT: conversation completed and chat responsive"), "The child did not finish the conversation:\n\(log)")
        completed = !timedOut && child.terminationStatus == 0 && log.contains("CHAT LAYOUT: conversation completed and chat responsive")
    }
}
#endif
