import CoreGraphics
import Testing
@testable import Familiar

/// The ghost shows only where the human would see the target itself.
@Suite
struct GhostVisibilityTests {
    private let target: CGWindowID = 4210
    private let other: CGWindowID = 77

    @Test
    func showsWhenTheTargetIsTheTopWindowAtThePoint() {
        #expect(GhostCursorPanel.shouldShow(topWindowAtPoint: target, targetWindowID: target, targetOnScreen: true, targetMinimized: false))
    }

    @Test
    func showsWhenNothingCoversThePoint() {
        #expect(GhostCursorPanel.shouldShow(topWindowAtPoint: nil, targetWindowID: target, targetOnScreen: true, targetMinimized: false))
    }

    @Test
    func hidesUnderAnotherWindow() {
        #expect(!GhostCursorPanel.shouldShow(topWindowAtPoint: other, targetWindowID: target, targetOnScreen: true, targetMinimized: false))
    }

    @Test
    func hidesWhenTheTargetIsOffScreen() {
        #expect(!GhostCursorPanel.shouldShow(topWindowAtPoint: target, targetWindowID: target, targetOnScreen: false, targetMinimized: false))
        #expect(!GhostCursorPanel.shouldShow(topWindowAtPoint: nil, targetWindowID: target, targetOnScreen: false, targetMinimized: false))
    }

    @Test
    func hidesWhenTheTargetIsMinimized() {
        #expect(!GhostCursorPanel.shouldShow(topWindowAtPoint: target, targetWindowID: target, targetOnScreen: true, targetMinimized: true))
        #expect(!GhostCursorPanel.shouldShow(topWindowAtPoint: nil, targetWindowID: target, targetOnScreen: true, targetMinimized: true))
    }

    @Test
    func minimizedAndOffScreenBothLose() {
        #expect(!GhostCursorPanel.shouldShow(topWindowAtPoint: target, targetWindowID: target, targetOnScreen: false, targetMinimized: true))
    }

    @Test
    func arrowPathStartsAtTheTipAndScalesWithHeight() {
        let small = GhostCursorArt.path(height: 14).boundingBox
        let large = GhostCursorArt.path(height: 28).boundingBox
        #expect(small.minX == 0 && small.minY == 0)
        #expect(abs(small.height - 14) < 0.001)
        #expect(abs(large.height - 28) < 0.001)
        #expect(abs(large.width - small.width * 2) < 0.001)
        #expect(small.width < small.height)   // an arrow, taller than it is wide
    }
}
