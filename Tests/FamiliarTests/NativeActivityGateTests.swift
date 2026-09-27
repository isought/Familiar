import Testing
@testable import Familiar

@Suite @MainActor
struct NativeActivityGateTests {
    @Test func captureAndControlCannotOverlapAcrossFeatureCallers() throws {
        let gate = NativeActivityGate()
        let recording = try gate.acquire(.recording)
        #expect(throws: NativeActivityGate.Conflict.self) { try gate.acquire(.desktop) }
        #expect(gate.current == recording)
        gate.release(recording)
        let desktop = try gate.acquire(.desktop)
        #expect(throws: NativeActivityGate.Conflict.self) { try gate.acquire(.recording) }
        #expect(throws: NativeActivityGate.Conflict.self) { try gate.acquire(.desktop) }
        // Cleanup arriving twice from the old recording cannot release the new desktop request.
        gate.release(recording)
        #expect(gate.current == desktop)
        gate.release(desktop)
        #expect(gate.current == nil)
    }
}
