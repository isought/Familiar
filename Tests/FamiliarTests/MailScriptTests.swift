import Foundation
import Testing

/// The bundled IMAP mail script, run against a fake server in imaplib's real response shapes (Tests/python).
@Suite
struct MailScriptTests {
    @Test func theMailScriptReadsEveryMessageAndNeverChangesTheMailbox() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("Tests/python/test_imap_mail.py").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(text)")
    }
}
