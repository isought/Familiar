import Testing
@testable import Familiar

@Suite
struct BackgroundTaskActivationTests {
    @Test func observationsKeepAnOrdinaryQuestionInChatUntilWorkStarts() {
        var activation = BackgroundTaskActivation()
        for operation in ["screenshot", "zoom", "find_on_screen", "read_screen", "look_at_screen", "target_window", "cursor_position", "mouse_move", "wait"] {
            let adopts = activation.beginIfNeeded(for: operation)
            #expect(!adopts)
        }
        #expect(!activation.hasStarted)
        let firstAction = activation.beginIfNeeded(for: "type")
        #expect(firstAction)
        #expect(activation.hasStarted)
        let secondAction = activation.beginIfNeeded(for: "key")
        #expect(!secondAction)
    }

    @Test(arguments: ["left_click", "right_click", "middle_click", "double_click", "triple_click", "left_click_drag",
                      "left_mouse_down", "left_mouse_up", "scroll", "type", "key", "hold_key", "click_element", "ask_for_the_mouse"])
    func actionAdoptsTaskBeforeItCanRequestApproval(_ operation: String) {
        var activation = BackgroundTaskActivation()
        let firstAction = activation.beginIfNeeded(for: operation)
        let secondAction = activation.beginIfNeeded(for: operation)
        #expect(firstAction)
        #expect(!secondAction)
    }

    @Test func nextSessionCanStartATaskAndUnsupportedOperationsDoNotAdopt() {
        var activation = BackgroundTaskActivation()
        let firstTask = activation.beginIfNeeded(for: "click_element")
        #expect(firstTask)
        activation.reset()
        let unknownOperation = activation.beginIfNeeded(for: "unknown_action")
        #expect(!unknownOperation)
        #expect(!activation.hasStarted)
        let nextTask = activation.beginIfNeeded(for: "ask_for_the_mouse")
        #expect(nextTask)
    }
}
