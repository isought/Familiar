import CoreGraphics
import Testing
@testable import Familiar

@Suite
struct ActionVerifierTests {
    // MARK: Synthetic images (a 160x120 px crop, the size the verifier takes around an action point)

    private static let size = (w: 160, h: 120)

    /// White canvas with `rects` painted in `colours` (top-left pixel coordinates).
    private static func image(_ rects: [(CGRect, CGColor)] = []) -> CGImage {
        let ctx = CGContext(data: nil, width: size.w, height: size.h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.w, height: size.h))
        for (r, c) in rects {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: r.minX, y: CGFloat(size.h) - r.maxY, width: r.width, height: r.height))
        }
        return ctx.makeImage()!
    }

    private static let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    private static let buttonIdle = CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
    private static let buttonPressed = CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)
    private static let button = CGRect(x: 50, y: 48, width: 60, height: 24)

    private static func grey(_ i: CGImage) -> [UInt8] { ActionVerifier.grey(i, w: 16, h: 12) }

    @Test
    func greyHasGridSizeAndReadsLuminance() {
        let white = Self.grey(Self.image())
        #expect(white.count == 16 * 12)
        #expect(white.allSatisfy { $0 >= 250 })
        let dark = Self.grey(Self.image([(CGRect(x: 0, y: 0, width: 160, height: 120), Self.black)]))
        #expect(dark.allSatisfy { $0 <= 5 })
        #expect(ActionVerifier.grey(Self.image(), w: 0, h: 12).isEmpty)
    }

    @Test
    func identicalImagesDoNotDiffer() {
        let a = Self.grey(Self.image([(Self.button, Self.buttonIdle)]))
        let b = Self.grey(Self.image([(Self.button, Self.buttonIdle)]))
        #expect(a == b)
        #expect(!ActionVerifier.differs(a, b))
    }

    @Test
    func caretSizedChangeStaysUnderThreshold() {
        // A blinking insertion point: 3x20 px of black appearing on white, at a few positions including cell straddles.
        let before = Self.grey(Self.image())
        for origin in [CGPoint(x: 80, y: 50), CGPoint(x: 78, y: 45), CGPoint(x: 9, y: 9), CGPoint(x: 150, y: 95)] {
            let caret = CGRect(origin: origin, size: CGSize(width: 3, height: 20))
            let after = Self.grey(Self.image([(caret, Self.black)]))
            #expect(!ActionVerifier.differs(before, after), "caret at \(origin) should not count as a change")
        }
    }

    @Test
    func buttonSizedChangeIsOverThreshold() {
        let idle = Self.grey(Self.image([(Self.button, Self.buttonIdle)]))
        let pressed = Self.grey(Self.image([(Self.button, Self.buttonPressed)]))
        #expect(ActionVerifier.differs(idle, pressed))
        // A button appearing or vanishing is a change too.
        #expect(ActionVerifier.differs(Self.grey(Self.image()), pressed))
    }

    @Test
    func differsHonoursExplicitParameters() {
        let before = Self.grey(Self.image())
        let caret = Self.grey(Self.image([(CGRect(x: 80, y: 50, width: 3, height: 20), Self.black)]))
        #expect(ActionVerifier.differs(before, caret, threshold: 24, fraction: 0))   // any cell counts
        #expect(!ActionVerifier.differs(before, caret, threshold: 200, fraction: 0)) // nothing that dark
        #expect(ActionVerifier.differs([], [1]))                                      // mismatched lengths differ
        #expect(!ActionVerifier.differs([], []))
    }

    // MARK: Verdicts

    private static let same: [UInt8] = Array(repeating: 200, count: 16 * 12)
    private static let moved: [UInt8] = Array(repeating: 200, count: 16 * 12 - 20) + Array(repeating: 40, count: 20)

    private static func snap(value: String? = nil, focused: Bool? = nil, range: [Int]? = nil, focusID: String? = "AXTextField @1,1 10x10",
                             title: String? = "Doc", windows: Int = 1, grey: [UInt8]? = same) -> AXSnapshot {
        AXSnapshot(value: value, focused: focused, selectedRange: range, appFocusedElementID: focusID,
                   windowTitle: title, windowCount: windows, cropGrey: grey)
    }

    private static func isConfirmed(_ v: Verdict) -> Bool { if case .confirmed = v { return true }; return false }
    private static func isUnverifiable(_ v: Verdict) -> Bool { if case .unverifiable = v { return true }; return false }
    private static func isNoEffect(_ v: Verdict) -> Bool { if case .noEffect = v { return true }; return false }

    @Test
    func snapshotEquality() {
        #expect(Self.snap(value: "a", range: [1, 2]) == Self.snap(value: "a", range: [1, 2]))
        #expect(Self.snap(value: "a", range: [1, 2]) != Self.snap(value: "a", range: [1, 3]))
        #expect(Self.snap(grey: Self.same) != Self.snap(grey: Self.moved))
    }

    @Test
    func anyChange() {
        let before = Self.snap(value: "a")
        for trust in [true, false] {
            // Nothing moved at all → noEffect, whoever the toolkit is.
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: before, after: before, expecting: .anyChange, trustAX: trust)))
            // No crop on either side and no AX change → still noEffect (the caller softens key presses, not us).
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: Self.snap(grey: nil), after: Self.snap(grey: nil), expecting: .anyChange, trustAX: trust)))
            // The screen moved → confirmed regardless of AX trust.
            #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: Self.snap(value: "a", grey: Self.moved), expecting: .anyChange, trustAX: trust)))
        }
        // AX-only change: confirmed when trusted, unverifiable when not.
        let axOnly = Self.snap(value: "ab")
        #expect(ActionVerifier.verdict(before: before, after: axOnly, expecting: .anyChange, trustAX: true) == .confirmed("value changed to “ab”"))
        #expect(Self.isUnverifiable(ActionVerifier.verdict(before: before, after: axOnly, expecting: .anyChange, trustAX: false)))
        // Other AX facts count as change too.
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: Self.snap(value: "a", windows: 2), expecting: .anyChange, trustAX: true)))
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: Self.snap(value: "a", title: "Doc — edited"), expecting: .anyChange, trustAX: true)))
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: Self.snap(value: "a", focusID: "AXButton @5,5 20x20"), expecting: .anyChange, trustAX: true)))
    }

    @Test
    func focusOn() {
        let before = Self.snap(focused: false)
        let gained = Self.snap(focused: true)
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: gained, expecting: .focusOn, trustAX: true)))
        #expect(Self.isUnverifiable(ActionVerifier.verdict(before: before, after: gained, expecting: .focusOn, trustAX: false)))
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: Self.snap(focused: true, grey: Self.moved), expecting: .focusOn, trustAX: false)))
        // Already focused still satisfies the expectation.
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: gained, after: gained, expecting: .focusOn, trustAX: true)))
        for trust in [true, false] {
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: before, after: before, expecting: .focusOn, trustAX: trust)))
            // Focus went somewhere else.
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: before, after: Self.snap(focused: false, focusID: "AXButton @5,5 20x20"), expecting: .focusOn, trustAX: trust)))
            // Focus attribute unreadable and nothing else moved.
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(), expecting: .focusOn, trustAX: trust)))
        }
        // Unreadable focus but the app's focused element changed: a note, not a fall-through, when AX is trusted.
        #expect(Self.isUnverifiable(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(focusID: "AXTextArea @1,1 10x10"), expecting: .focusOn, trustAX: true)))
        // Same, untrusted and the screen is still → judged by the screen alone.
        #expect(Self.isNoEffect(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(focusID: "AXTextArea @1,1 10x10"), expecting: .focusOn, trustAX: false)))
        #expect(Self.isUnverifiable(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(grey: Self.moved), expecting: .focusOn, trustAX: false)))
    }

    @Test
    func valueContains() {
        let before = Self.snap(value: "Dear")
        let typed = Self.snap(value: "Dear Ada")
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: typed, expecting: .valueContains("Ada"), trustAX: true)))
        #expect(Self.isUnverifiable(ActionVerifier.verdict(before: before, after: typed, expecting: .valueContains("Ada"), trustAX: false)))
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: Self.snap(value: "Dear Ada", grey: Self.moved), expecting: .valueContains("Ada"), trustAX: false)))
        // Whitespace and case differences in the echo are tolerated.
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: Self.snap(value: "dear  ADA"), expecting: .valueContains("Dear Ada"), trustAX: true)))
        for trust in [true, false] {
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: before, after: before, expecting: .valueContains("Ada"), trustAX: trust)))
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: before, after: Self.snap(value: "Dear Bob"), expecting: .valueContains("Ada"), trustAX: trust)))
            // Value unreadable: the screen decides between a note and a fall-through.
            #expect(Self.isUnverifiable(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(grey: Self.moved), expecting: .valueContains("Ada"), trustAX: trust)))
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(), expecting: .valueContains("Ada"), trustAX: trust)))
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: Self.snap(grey: nil), after: Self.snap(grey: nil), expecting: .valueContains("Ada"), trustAX: trust)))
        }
    }

    @Test
    func valueChanged() {
        let before = Self.snap(value: "1")
        let after = Self.snap(value: "2")
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: after, expecting: .valueChanged, trustAX: true)))
        #expect(Self.isUnverifiable(ActionVerifier.verdict(before: before, after: after, expecting: .valueChanged, trustAX: false)))
        #expect(Self.isConfirmed(ActionVerifier.verdict(before: before, after: Self.snap(value: "2", grey: Self.moved), expecting: .valueChanged, trustAX: false)))
        #expect(Self.isNoEffect(ActionVerifier.verdict(before: before, after: before, expecting: .valueChanged, trustAX: true)))
        #expect(Self.isNoEffect(ActionVerifier.verdict(before: before, after: before, expecting: .valueChanged, trustAX: false)))
        // Trusted AX says unchanged although the screen moved (a caret, a hover): unchanged wins.
        #expect(Self.isNoEffect(ActionVerifier.verdict(before: before, after: Self.snap(value: "1", grey: Self.moved), expecting: .valueChanged, trustAX: true)))
        // Untrusted AX lagging behind a visible change: a note, not a fall-through.
        #expect(Self.isUnverifiable(ActionVerifier.verdict(before: before, after: Self.snap(value: "1", grey: Self.moved), expecting: .valueChanged, trustAX: false)))
        // Value unreadable on both sides.
        #expect(Self.isUnverifiable(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(grey: Self.moved), expecting: .valueChanged, trustAX: true)))
        #expect(Self.isNoEffect(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(), expecting: .valueChanged, trustAX: true)))
    }

    @Test
    func scrolled() {
        for trust in [true, false] {
            #expect(Self.isConfirmed(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(grey: Self.moved), expecting: .scrolled, trustAX: trust)))
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: Self.snap(), after: Self.snap(), expecting: .scrolled, trustAX: trust)))
            // An AX change without screen movement is not a scroll.
            #expect(Self.isNoEffect(ActionVerifier.verdict(before: Self.snap(value: "a"), after: Self.snap(value: "b"), expecting: .scrolled, trustAX: trust)))
            // No crop to compare: never a fall-through.
            #expect(Self.isUnverifiable(ActionVerifier.verdict(before: Self.snap(grey: nil), after: Self.snap(grey: nil), expecting: .scrolled, trustAX: trust)))
        }
    }

    @Test
    func verifyPollsUntilSomethingOtherThanNoEffect() async {
        let before = Self.snap(value: "a")
        var calls = 0
        let v = await ActionVerifier.verify(before: before, expecting: .valueChanged, pollMs: [0, 0, 0]) {
            calls += 1
            return calls < 3 ? before : Self.snap(value: "b")
        }
        #expect(v == .confirmed("value changed to “b”"))
        #expect(calls == 3)

        calls = 0
        let none = await ActionVerifier.verify(before: before, expecting: .valueChanged, pollMs: [0, 0]) { calls += 1; return before }
        #expect(Self.isNoEffect(none))
        #expect(calls == 2)

        // Untrusted AX threads through to the verdict.
        let soft = await ActionVerifier.verify(before: before, expecting: .valueChanged, pollMs: [0], trustAX: false) { Self.snap(value: "b") }
        #expect(Self.isUnverifiable(soft))
    }
}
