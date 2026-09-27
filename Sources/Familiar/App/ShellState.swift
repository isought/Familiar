import Combine
import Foundation

/// Presentation state shared by the app shell and its views. Feature work does not
/// own the panel's geometry, visibility intent, or window actions.
@MainActor
final class ShellState: ObservableObject {
    @Published var expanded = false
    @Published var cardSize = NSSize(width: 400, height: 540)

    enum DragPhase { case moved, ended }
    var onHideBubble: (() -> Void)?
    var onDragBubble: ((DragPhase) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onPoke: (() -> Void)?
    var onResizeCard: ((NSSize, Bool) -> Void)?  // size, then whether the drag ended and should be persisted
    var onToggleLarge: (() -> Void)?

    private var quietExpandPending = false

    /// Show the pad while leaving keyboard focus with the user's current app.
    func expandQuietly() {
        quietExpandPending = true
        expanded = true
    }

    /// The native shell consumes this once when applying an expansion.
    func consumeQuietExpand() -> Bool {
        defer { quietExpandPending = false }
        return quietExpandPending
    }
}
