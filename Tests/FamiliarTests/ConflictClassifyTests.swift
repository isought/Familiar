import AppKit
import Testing
@testable import Familiar

@Suite @MainActor
struct ConflictClassifyTests {
    private let target: CGWindowID = 4242
    private let other: CGWindowID = 99
    private let pid: pid_t = 1234
    private let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let inside = CGPoint(x: 400, y: 300)
    private let outside = CGPoint(x: 20, y: 20)

    private func classify(_ kind: ConflictMonitor.Input.Kind, at p: CGPoint, ours: Bool = false, top: CGWindowID? = 4242,
                          recordOutstanding: Bool = false, expectingActivation: Bool = false) -> ConflictMonitor.Verdict {
        ConflictMonitor.classify(ConflictMonitor.Input(kind: kind, locationCG: p, isOurs: ours),
                                 targetPID: pid, targetWindowID: target, targetFrameCG: frame, appName: "Numbers",
                                 topWindowAt: { _ in top }, recordOutstanding: recordOutstanding, expectingActivation: expectingActivation)
    }

    @Test func clickOnTargetStops() {
        #expect(classify(.mouseDown, at: inside) == .stop("you clicked in Numbers"))
    }

    @Test func clickInsideFrameButCoveredPauses() {
        #expect(classify(.mouseDown, at: inside, top: other) == .pause(0.5))
        #expect(classify(.mouseDown, at: inside, top: nil) == .pause(0.5))
    }

    @Test func clickOutsideFramePausesWithoutAskingTheWindowServer() {
        var asked = 0
        let v = ConflictMonitor.classify(ConflictMonitor.Input(kind: .mouseDown, locationCG: outside, isOurs: false),
                                         targetPID: pid, targetWindowID: target, targetFrameCG: frame, appName: "Numbers",
                                         topWindowAt: { _ in asked += 1; return target }, recordOutstanding: false, expectingActivation: false)
        #expect(v == .pause(0.5))
        #expect(asked == 0)
    }

    @Test func ownEventsAreIgnored() {
        #expect(classify(.mouseDown, at: inside, ours: true) == .ignore)
        #expect(classify(.scroll, at: inside, ours: true) == .ignore)
        #expect(classify(.keyDown(0), at: inside, ours: true) == .ignore)
        #expect(classify(.keyDown(0), at: inside, ours: true, recordOutstanding: true) == .ignore)
        #expect(classify(.appActivated(pid), at: .zero, ours: true) == .ignore)
    }

    @Test func keyDownPauses() {
        #expect(classify(.keyDown(0), at: inside) == .pause(0.5))
        #expect(classify(.keyDown(53), at: outside, top: nil) == .pause(0.5))
    }

    @Test func keyDownWhileRecordOutstandingPausesLonger() {
        #expect(classify(.keyDown(0), at: outside, top: nil, recordOutstanding: true) == .pause(1.5))
    }

    @Test func scrollOnTargetIsDirty() {
        #expect(classify(.scroll, at: inside) == .dirty)
    }

    @Test func scrollElsewhereIsIgnored() {
        #expect(classify(.scroll, at: inside, top: other) == .ignore)   // inside the frame but covered
        #expect(classify(.scroll, at: inside, top: nil) == .ignore)
        #expect(classify(.scroll, at: outside) == .ignore)
    }

    @Test func switchingToTargetAppStops() {
        #expect(classify(.appActivated(pid), at: .zero) == .stop("you switched to Numbers"))
    }

    @Test func expectedActivationIsIgnored() {
        #expect(classify(.appActivated(pid), at: .zero, expectingActivation: true) == .ignore)
    }

    @Test func activatingAnotherAppIsIgnored() {
        #expect(classify(.appActivated(pid + 1), at: .zero) == .ignore)
        #expect(classify(.appActivated(pid + 1), at: .zero, expectingActivation: true) == .ignore)
    }

    @Test func mouseUpAndMovesAreIgnored() {
        #expect(classify(.mouseUp, at: inside) == .ignore)
        #expect(classify(.mouseMoved, at: inside) == .ignore)
        #expect(classify(.mouseUp, at: outside) == .ignore)
        #expect(classify(.mouseMoved, at: outside) == .ignore)
    }
}
