import Foundation
import Testing
@testable import FamiliarRuntime

@Suite
struct SubprocessTests {
    /// Stop cancels the task that runs a script; the process has to end then, not when it finishes on its own.
    @Test func cancellingTheCallerEndsTheProcess() async throws {
        let started = Date()
        let task = Task { try await Subprocess.run("/bin/sleep", ["30"], timeout: 60, stopsWithCaller: true) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = try await task.value
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(result.code != 0)
    }

    /// Loading tools runs to completion even when its caller was cancelled.
    @Test func otherWorkFinishesEvenIfTheCallerIsCancelled() async throws {
        let task = Task { try await Subprocess.run("/bin/sleep", ["1"], timeout: 60) }
        task.cancel()
        let result = try await task.value
        #expect(result.code == 0 && !result.timedOut)
    }
}
