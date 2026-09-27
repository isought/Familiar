import Foundation

/// Existing capture/control conflicts live below feature UIs. Read-only model work
/// needs no lease; recording and desktop execution cannot own native input together.
@MainActor
final class NativeActivityGate {
    enum Activity: Equatable { case recording, desktop }
    struct Lease: Equatable {
        fileprivate let id = UUID()
        let activity: Activity
    }
    struct Conflict: LocalizedError {
        let active: Activity
        var errorDescription: String? {
            active == .recording ? "Watching — stop watching before starting desktop control."
                : "Desktop work is running — stop it before starting another native activity."
        }
    }
    private(set) var current: Lease?

    func acquire(_ activity: Activity) throws -> Lease {
        guard current == nil else { throw Conflict(active: current!.activity) }
        let lease = Lease(activity: activity)
        current = lease
        return lease
    }

    func release(_ lease: Lease) {
        if current == lease { current = nil }
    }
}
