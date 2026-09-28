/// Keeps a request in chat while native tools only observe. The first operation
/// that attempts work adopts it into the task screen, before any decision is requested.
struct BackgroundTaskActivation {
    private(set) var hasStarted = false

    private static let workOperations: Set<String> = [
        "left_click", "right_click", "middle_click", "double_click", "triple_click", "left_click_drag",
        "left_mouse_down", "left_mouse_up", "scroll", "type", "key", "hold_key",
        "click_element", "send_message", "ask_for_the_mouse",
    ]

    mutating func beginIfNeeded(for operation: String) -> Bool {
        guard !hasStarted, Self.workOperations.contains(operation) else { return false }
        hasStarted = true
        return true
    }

    mutating func reset() { hasStarted = false }
}
