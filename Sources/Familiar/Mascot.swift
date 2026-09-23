import SwiftUI

/// The Familiar character: a small yellow sticky note with two elliptical eyes, two glossy eyebrows and a curled corner.
/// Drawn entirely with SwiftUI shapes so every part can animate.
/// Two brow personalities. `sharp` is the original merge; `innocent` keeps both brows high and arched so curiosity
/// reads as wide-eyed rather than skeptical (a lowered brow is what makes a face look suspicious).
enum MascotStyle: String, CaseIterable {
    case sharp, innocent, innocentV1, innocentV3
    nonisolated(unsafe) static var current: MascotStyle = .innocent
    var isInnocentFamily: Bool { self != .sharp }
}

enum MascotMood: String, CaseIterable {
    case idle, curious, happy, thinking, charging, onIt, peek, sad
}

/// Drives the always-on motion: breathing, blinks and the small bobs/wobbles. One 30 Hz timer per view.
@MainActor
final class MascotClock: ObservableObject {
    @Published private(set) var t: Double = 0      // seconds since start
    @Published private(set) var blink: CGFloat = 0 // 1 while the lids are down
    private var tick: Timer?
    private var blinkTimer: Timer?
    private let start = Date()

    func begin() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.t = Date().timeIntervalSince(self.start) }
        }
        RunLoop.main.add(tick!, forMode: .common)
        scheduleBlink(after: Double.random(in: 1.5...4))
    }

    func end() {
        tick?.invalidate(); tick = nil
        blinkTimer?.invalidate(); blinkTimer = nil
        blink = 0
    }

    private func scheduleBlink(after delay: Double) {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.doBlink(double: Double.random(in: 0...1) < 0.18) }
        }
    }

    private func doBlink(double: Bool) {
        withAnimation(.easeIn(duration: 0.05)) { blink = 1 }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.08)) { self.blink = 0 }
                // a quick second blink now and then reads as "alive"; otherwise wait 3–7 s
                self.scheduleBlink(after: double ? 0.25 : Double.random(in: 3...7))
            }
        }
    }
}

/// Everything that changes between moods. All fields are plain numbers so SwiftUI can spring between them.
private struct Expression {
    struct Brow { var raise: CGFloat; var innerUp: CGFloat; var arch: CGFloat; var peak: CGFloat = 0.5 }  // raise: fraction of body side (+ = up); innerUp: degrees the inner end sits above the outer end; peak: where along the brow the apex sits (0 = outer end … 1 = inner end for the left brow; mirrored for the right)
    var left: Brow, right: Brow
    var eyeOpen: CGFloat = 1     // 1 open … 0 closed (lid squash)
    var eyeScale: CGFloat = 1
    var happy: CGFloat = 0       // 1 = ^ ^ eyes
    var gaze: CGPoint = .zero    // default look direction when no lookAt (x right, y down, magnitude ≤ 1)
    var followsPointer = true
    var lean: CGFloat = 0        // degrees, + = clockwise
    var shift: CGSize = .zero    // fraction of size
    var squashX: CGFloat = 1, squashY: CGFloat = 1
    var motionLines: CGFloat = 0
    var hidden: CGFloat = 0      // 1 = half hidden behind a left edge (peek)

    static func of(_ mood: MascotMood) -> Expression {
        switch MascotStyle.current {
        case .innocent: return innocent(mood)
        case .innocentV1: return innocentV1(mood)
        case .innocentV3: return innocentV3(mood)
        case .sharp: break
        }
        switch mood {
        case .idle:
            return Expression(left: Brow(raise: 0.03, innerUp: 6, arch: 1), right: Brow(raise: -0.015, innerUp: 4, arch: 0.9), lean: 3)
        case .curious:
            return Expression(left: Brow(raise: 0.085, innerUp: 14, arch: 1.5), right: Brow(raise: -0.025, innerUp: -3, arch: 0.6),
                              gaze: CGPoint(x: 0.8, y: 0.25), lean: 5)
        case .happy:
            return Expression(left: Brow(raise: 0.07, innerUp: 6, arch: 1.2), right: Brow(raise: 0.05, innerUp: 6, arch: 1.15),
                              happy: 1, lean: -5, shift: CGSize(width: 0, height: -0.02))
        case .thinking:
            return Expression(left: Brow(raise: 0.07, innerUp: 10, arch: 1.2), right: Brow(raise: 0.03, innerUp: 3, arch: 1.1),
                              gaze: CGPoint(x: -0.7, y: -0.85), followsPointer: false, lean: -3)
        case .charging:
            return Expression(left: Brow(raise: -0.06, innerUp: 0, arch: 0.45), right: Brow(raise: -0.06, innerUp: 0, arch: 0.45),
                              eyeOpen: 0.5, gaze: CGPoint(x: 0, y: 0.15), followsPointer: false)
        case .onIt:
            return Expression(left: Brow(raise: -0.04, innerUp: -24, arch: 0.4), right: Brow(raise: -0.04, innerUp: -24, arch: 0.4),
                              eyeOpen: 0.8, gaze: CGPoint(x: 0.6, y: 0), followsPointer: false, lean: 7,
                              shift: CGSize(width: 0.04, height: 0), squashX: 1.03, squashY: 0.97, motionLines: 1)
        case .peek:
            return Expression(left: Brow(raise: 0.05, innerUp: 10, arch: 1.2), right: Brow(raise: 0.0, innerUp: 3, arch: 0.9),
                              gaze: CGPoint(x: 0.85, y: 0.2), followsPointer: false, lean: -6,
                              shift: CGSize(width: -0.07, height: 0.02), hidden: 1)
        case .sad:
            return Expression(left: Brow(raise: 0.035, innerUp: 26, arch: 0.55), right: Brow(raise: 0.035, innerUp: 26, arch: 0.55),
                              eyeOpen: 0.9, eyeScale: 0.7, gaze: CGPoint(x: 0.1, y: 0.7), followsPointer: false, lean: -2,
                              shift: CGSize(width: 0, height: 0.03), squashX: 1.02, squashY: 0.97)
        }
    }

    /// Innocent brows, v3 (experiment, traced from the reference): both brows the SAME stroke, drooping to the right,
    /// the right one lower, with a cocked eye line. Kept in the picker; v2 is the default.
    static func innocentV3(_ mood: MascotMood) -> Expression {
        let P = 0.36   // apex toward the left end of every brow
        switch mood {
        case .idle:
            return Expression(left: Brow(raise: 0.02, innerUp: -10, arch: 0.75, peak: P), right: Brow(raise: 0.01, innerUp: 14, arch: 0.7, peak: P), lean: 3)
        case .curious:
            return Expression(left: Brow(raise: 0.055, innerUp: -9, arch: 0.85, peak: P), right: Brow(raise: 0.01, innerUp: 16, arch: 0.6, peak: 0.4),
                              gaze: CGPoint(x: 0.8, y: 0.25), lean: 5)
        case .happy:
            return Expression(left: Brow(raise: 0.05, innerUp: -9, arch: 0.8, peak: P), right: Brow(raise: 0.035, innerUp: 13, arch: 0.75, peak: P),
                              happy: 1, lean: -5, shift: CGSize(width: 0, height: -0.02))
        case .thinking:
            return Expression(left: Brow(raise: 0.075, innerUp: -8, arch: 0.8, peak: P), right: Brow(raise: 0.06, innerUp: 13, arch: 0.75, peak: P),
                              gaze: CGPoint(x: -0.7, y: -0.85), followsPointer: false, lean: -3)
        case .charging:
            return Expression(left: Brow(raise: 0.015, innerUp: -8, arch: 0.6, peak: P), right: Brow(raise: 0.005, innerUp: 12, arch: 0.55, peak: P),
                              eyeOpen: 0.55, gaze: CGPoint(x: 0, y: 0.15), followsPointer: false)
        case .onIt:
            return Expression(left: Brow(raise: 0.03, innerUp: -5, arch: 0.6, peak: P), right: Brow(raise: 0.01, innerUp: 9, arch: 0.55, peak: P),
                              eyeOpen: 0.85, gaze: CGPoint(x: 0.6, y: 0), followsPointer: false, lean: 7,
                              shift: CGSize(width: 0.04, height: 0), squashX: 1.03, squashY: 0.97, motionLines: 1)
        case .peek:
            return Expression(left: Brow(raise: 0.05, innerUp: -9, arch: 0.8, peak: P), right: Brow(raise: 0.01, innerUp: 15, arch: 0.6, peak: 0.4),
                              gaze: CGPoint(x: 0.85, y: 0.2), followsPointer: false, lean: -6,
                              shift: CGSize(width: -0.07, height: 0.02), hidden: 1)
        case .sad:
            return Expression(left: Brow(raise: 0.05, innerUp: 18, arch: 0.35, peak: 0.5), right: Brow(raise: 0.04, innerUp: 24, arch: 0.35, peak: 0.5),
                              eyeOpen: 0.9, eyeScale: 0.7, gaze: CGPoint(x: 0.1, y: 0.7), followsPointer: false, lean: -2,
                              shift: CGSize(width: 0, height: 0.03), squashX: 1.02, squashY: 0.97)
        }
    }

    /// Innocent brows, v2 (tagged mascot-v2), the default: long shallow arcs, same size at rest, set wide apart.
    static func innocent(_ mood: MascotMood) -> Expression {
        let L = 0.44, R = 0.56
        switch mood {
        case .idle:
            return Expression(left: Brow(raise: 0.045, innerUp: 6, arch: 0.72, peak: L), right: Brow(raise: 0.045, innerUp: 6, arch: 0.72, peak: R), lean: 3)
        case .curious:
            return Expression(left: Brow(raise: 0.08, innerUp: 8, arch: 0.85, peak: L), right: Brow(raise: 0.045, innerUp: 5, arch: 0.72, peak: R),
                              gaze: CGPoint(x: 0.8, y: 0.25), lean: 5)
        case .happy:
            return Expression(left: Brow(raise: 0.075, innerUp: 6, arch: 0.8, peak: L), right: Brow(raise: 0.07, innerUp: 6, arch: 0.8, peak: R),
                              happy: 1, lean: -5, shift: CGSize(width: 0, height: -0.02))
        case .thinking:
            return Expression(left: Brow(raise: 0.10, innerUp: 12, arch: 0.8, peak: 0.46), right: Brow(raise: 0.095, innerUp: 12, arch: 0.8, peak: 0.54),
                              gaze: CGPoint(x: -0.7, y: -0.85), followsPointer: false, lean: -3)
        case .charging:
            return Expression(left: Brow(raise: 0.025, innerUp: 10, arch: 0.62, peak: 0.45), right: Brow(raise: 0.025, innerUp: 10, arch: 0.62, peak: 0.55),
                              eyeOpen: 0.55, gaze: CGPoint(x: 0, y: 0.15), followsPointer: false)
        case .onIt:
            return Expression(left: Brow(raise: 0.02, innerUp: -6, arch: 0.6, peak: 0.45), right: Brow(raise: 0.02, innerUp: -6, arch: 0.6, peak: 0.55),
                              eyeOpen: 0.85, gaze: CGPoint(x: 0.6, y: 0), followsPointer: false, lean: 7,
                              shift: CGSize(width: 0.04, height: 0), squashX: 1.03, squashY: 0.97, motionLines: 1)
        case .peek:
            return Expression(left: Brow(raise: 0.065, innerUp: 8, arch: 0.8, peak: L), right: Brow(raise: 0.045, innerUp: 6, arch: 0.72, peak: R),
                              gaze: CGPoint(x: 0.85, y: 0.2), followsPointer: false, lean: -6,
                              shift: CGSize(width: -0.07, height: 0.02), hidden: 1)
        case .sad:
            return Expression(left: Brow(raise: 0.05, innerUp: 20, arch: 0.45, peak: 0.45), right: Brow(raise: 0.05, innerUp: 20, arch: 0.45, peak: 0.55),
                              eyeOpen: 0.9, eyeScale: 0.7, gaze: CGPoint(x: 0.1, y: 0.7), followsPointer: false, lean: -2,
                              shift: CGSize(width: 0, height: 0.03), squashX: 1.02, squashY: 0.97)
        }
    }

    /// Innocent brows, v1 (tagged mascot-v1): taller arcs, a smaller right brow that dodges the curl. Kept for comparison.
    static func innocentV1(_ mood: MascotMood) -> Expression {
        let L = 0.42, R = 0.58   // apex positions: toward each brow's outer end
        switch mood {
        case .idle:
            return Expression(left: Brow(raise: 0.045, innerUp: 8, arch: 1.05, peak: L), right: Brow(raise: 0.03, innerUp: 8, arch: 1.0, peak: R), lean: 3)
        case .curious:
            return Expression(left: Brow(raise: 0.105, innerUp: 12, arch: 1.25, peak: L), right: Brow(raise: 0.045, innerUp: 7, arch: 1.0, peak: R),
                              gaze: CGPoint(x: 0.8, y: 0.25), lean: 5)
        case .happy:
            return Expression(left: Brow(raise: 0.085, innerUp: 8, arch: 1.15, peak: L), right: Brow(raise: 0.07, innerUp: 8, arch: 1.1, peak: R),
                              happy: 1, lean: -5, shift: CGSize(width: 0, height: -0.02))
        case .thinking:
            return Expression(left: Brow(raise: 0.115, innerUp: 16, arch: 1.2, peak: 0.46), right: Brow(raise: 0.105, innerUp: 16, arch: 1.15, peak: 0.54),
                              gaze: CGPoint(x: -0.7, y: -0.85), followsPointer: false, lean: -3)
        case .charging:
            return Expression(left: Brow(raise: 0.025, innerUp: 12, arch: 0.85, peak: 0.45), right: Brow(raise: 0.025, innerUp: 12, arch: 0.85, peak: 0.55),
                              eyeOpen: 0.55, gaze: CGPoint(x: 0, y: 0.15), followsPointer: false)
        case .onIt:
            return Expression(left: Brow(raise: 0.02, innerUp: -6, arch: 0.85, peak: 0.45), right: Brow(raise: 0.02, innerUp: -6, arch: 0.85, peak: 0.55),
                              eyeOpen: 0.85, gaze: CGPoint(x: 0.6, y: 0), followsPointer: false, lean: 7,
                              shift: CGSize(width: 0.04, height: 0), squashX: 1.03, squashY: 0.97, motionLines: 1)
        case .peek:
            return Expression(left: Brow(raise: 0.07, innerUp: 12, arch: 1.15, peak: L), right: Brow(raise: 0.04, innerUp: 8, arch: 1.0, peak: R),
                              gaze: CGPoint(x: 0.85, y: 0.2), followsPointer: false, lean: -6,
                              shift: CGSize(width: -0.07, height: 0.02), hidden: 1)
        case .sad:
            return Expression(left: Brow(raise: 0.05, innerUp: 22, arch: 0.6, peak: 0.45), right: Brow(raise: 0.05, innerUp: 22, arch: 0.6, peak: 0.55),
                              eyeOpen: 0.9, eyeScale: 0.7, gaze: CGPoint(x: 0.1, y: 0.7), followsPointer: false, lean: -2,
                              shift: CGSize(width: 0, height: 0.03), squashX: 1.02, squashY: 0.97)
        }
    }
}

struct MascotView: View {
    var mood: MascotMood
    var lookAt: CGPoint? = nil     // direction the pupils look, x right / y down, magnitude 0…1; nil = straight ahead
    var proximity: CGFloat = 0     // 0…1 how close the pointer is; the brows lift a little as it approaches
    var charge: CGFloat = 0        // 0…1 hold-to-charge progress
    var size: CGFloat = 48
    /// 0 = stuck on, 1 = peeled off the screen (rotated away and faded). Animate it when hiding/showing the bubble.
    var peel: CGFloat = 0
    /// Set false for static renders (no timers, no breathing). Toggling it later pauses/resumes the clock.
    var animated = true
    /// The extras around the note (motion lines, charge ring, the edge it peeks from). Off in the tiny card header.
    var decorations = true

    @StateObject private var clock = MascotClock()
    @State private var pop: CGFloat = 0          // transient squash-and-stretch on mood changes

    var body: some View {
        let ex = Expression.of(mood)
        let s = size
        let c = decorations ? max(0, min(1, charge)) : 0
        let t = animated ? clock.t : 0
        let breath = 1 + 0.015 * sin(t * 2 * .pi / 3.4)
        let bob: CGFloat = mood == .thinking ? 0.02 * s * sin(t * 2 * .pi / 1.6) : 0
        let wobble: CGFloat = c > 0.15 ? CGFloat(sin(t * 2 * .pi * 11)) * 2.2 * c : 0      // tremble while bracing
        let browTwitch: CGFloat = (mood == .idle && sin(t * 2 * .pi / 5.3 + 1.2) > 0.985) ? 0.008 * s : 0   // a tiny brow flick every ~5 s
        let squint = ex.eyeOpen * (1 - 0.35 * c)     // the harder the hold, the tighter the squint
        let open = squint * (1 - 0.94 * (animated ? clock.blink : 0))
        let gaze = gazeVector(ex)
        let hidden = decorations ? ex.hidden : 0

        ZStack {
            if decorations {
                motionLines(s: s).opacity(ex.motionLines)
                chargeRing(s: s, charge: c)
            }
            note(s: s, ex: ex, open: open, gaze: gaze, browTwitch: browTwitch)
                .rotationEffect(.degrees(ex.lean + wobble))
                .scaleEffect(x: ex.squashX * (1 + 0.09 * c) * (1 + 0.10 * pop), y: ex.squashY * (1 + 0.04 * c) * (1 - 0.10 * pop))
                .scaleEffect(breath)
                .offset(x: ex.shift.width * s, y: ex.shift.height * s + bob + 0.02 * s * c)
        }
        .frame(width: s, height: s)
        .mask(peekMask(s: s, hidden: hidden))
        .overlay(edgeShadow(s: s).opacity(hidden))
        .rotation3DEffect(.degrees(Double(peel) * 75), axis: (x: 0.35, y: -1, z: 0.15), anchor: .bottomLeading, perspective: 0.7)
        .scaleEffect(1 - 0.15 * peel)
        .opacity(Double(1 - peel * 0.9))
        .animation(.spring(response: 0.38, dampingFraction: 0.55), value: mood)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: charge)
        .animation(.spring(response: 0.45, dampingFraction: 0.65), value: peel)
        .animation(.easeOut(duration: 0.12), value: lookAt)
        .animation(.easeOut(duration: 0.2), value: proximity)
        .onAppear { if animated { clock.begin() } }
        .onDisappear { clock.end() }
        .onChange(of: animated) { _, now in if now { clock.begin() } else { clock.end() } }
        .onChange(of: mood) { _, _ in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { pop = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.42)) { pop = 0 }
            }
        }
    }

    private func gazeVector(_ ex: Expression) -> CGPoint {
        var v = (ex.followsPointer ? lookAt : nil) ?? ex.gaze
        let m = hypot(v.x, v.y)
        if m > 1 { v = CGPoint(x: v.x / m, y: v.y / m) }
        return v
    }

    // MARK: body

    private static let paperTop = Color(red: 1.0, green: 0.95, blue: 0.63)
    private static let paperBottom = Color(red: 0.97, green: 0.83, blue: 0.40)
    private static let paperEdge = Color(red: 0.84, green: 0.66, blue: 0.26)
    private static let ink = Color(red: 0.12, green: 0.11, blue: 0.11)
    private static let brand = Color(red: 0.55, green: 0.3, blue: 0.95)
    private static let gold = Color(red: 1.0, green: 0.78, blue: 0.30)

    private func note(s: CGFloat, ex: Expression, open: CGFloat, gaze: CGPoint, browTwitch: CGFloat) -> some View {
        let b = s * 0.80                       // body side
        let inset = (s - b) / 2
        let curl = b * 0.235
        let rolled = s >= 64                   // the big soft roll needs pixels; below that a plain dog-ear reads better
        let body = CGRect(x: inset, y: inset, width: b, height: b)
        return ZStack {
            ZStack {
                // a darker sheet from the pad peeking out at the right and bottom
                NoteBody(curl: curl)
                    .fill(Self.paperEdge)
                    .offset(x: b * 0.012, y: b * 0.016)
                // paper: warm gradient, lit from the top-left, a touch deeper toward the bottom
                NoteBody(curl: curl)
                    .fill(LinearGradient(colors: [Self.paperTop, Self.paperBottom], startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1)))
                    .overlay(NoteBody(curl: curl).fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.25, y: 0.2), startRadius: 0, endRadius: b * 0.7)))
                    .overlay(NoteBody(curl: curl).fill(LinearGradient(colors: [.clear, Color(red: 0.75, green: 0.55, blue: 0.15).opacity(0.22)], startPoint: UnitPoint(x: 0.5, y: 0.6), endPoint: .bottom)))
                    // a hair of amber at the edge so the silhouette holds on a dark menu bar or a busy wallpaper
                    .overlay(NoteBody(curl: curl).stroke(Self.paperEdge.opacity(0.35), lineWidth: min(1.5, max(0.6, s * 0.02))))
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.22), radius: s * 0.045, x: 0, y: s * 0.035)
            .shadow(color: Color(red: 0.6, green: 0.45, blue: 0.1).opacity(0.18), radius: s * 0.015, y: s * 0.01)
            if rolled { rolledCurl(s: s, b: b, curl: curl) } else { dogEar(s: s, curl: curl) }
            face(body: body, ex: ex, open: open, gaze: gaze, browTwitch: browTwitch)
        }
        .frame(width: s, height: s)
    }

    /// The corner rolled back over the face: bright along the crest, shading into the roll toward its tip, with the
    /// shadow it throws on the paper and a thin rim of light on the curled edge. All clipped to the note.
    private func rolledCurl(s: CGFloat, b: CGFloat, curl: CGFloat) -> some View {
        ZStack {
            NoteCurl(curl: curl)
                .fill(Color.black.opacity(0.30))
                .blur(radius: b * 0.022)
                .offset(x: -b * 0.016, y: b * 0.03)
            NoteCurl(curl: curl)
                .fill(LinearGradient(stops: [.init(color: Color(red: 1.0, green: 0.985, blue: 0.86), location: 0),
                                             .init(color: Color(red: 1.0, green: 0.93, blue: 0.62), location: 0.48),
                                             .init(color: Color(red: 0.90, green: 0.72, blue: 0.30), location: 1)],
                                     startPoint: UnitPoint(x: 0.88, y: 0.12), endPoint: UnitPoint(x: 0.66, y: 0.36)))
            NoteCurl(curl: curl)   // shade tucked in under the roll, along the crease
                .fill(LinearGradient(colors: [Color(red: 0.6, green: 0.42, blue: 0.1).opacity(0.28), .clear],
                                     startPoint: UnitPoint(x: 0.66, y: 0.34), endPoint: UnitPoint(x: 0.75, y: 0.25)))
            NoteCurl(curl: curl)   // a thin bright rim on the curled edge
                .stroke(Color.white.opacity(0.55), lineWidth: max(0.5, b * 0.008))
        }
        .mask(NoteBody(curl: curl))
    }

    /// The small-size corner: a plain folded flap with a soft shadow, cheap and crisp at 48pt and below.
    private func dogEar(s: CGFloat, curl: CGFloat) -> some View {
        ZStack {
            NoteFlap(curl: curl)
                .fill(Color.black.opacity(0.28))
                .blur(radius: s * 0.02)
                .offset(x: -s * 0.012, y: s * 0.022)
                .mask(NoteBody(curl: curl))
            NoteFlap(curl: curl)
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.98, blue: 0.86), Color(red: 0.98, green: 0.90, blue: 0.58), Color(red: 0.92, green: 0.78, blue: 0.38)],
                                     startPoint: UnitPoint(x: 0.85, y: 0.15), endPoint: UnitPoint(x: 0.55, y: 0.45)))
                .overlay(NoteFlap(curl: curl).stroke(Color(red: 0.8, green: 0.62, blue: 0.2).opacity(0.35), lineWidth: max(0.5, s * 0.006)))
        }
    }

    private func face(body: CGRect, ex: Expression, open: CGFloat, gaze: CGPoint, browTwitch: CGFloat) -> some View {
        let b = body.width
        let cx = body.midX, cy = body.midY
        let eyeW = b * 0.175 * ex.eyeScale, eyeH = b * 0.30 * ex.eyeScale   // big, tall eyes: the main "young and harmless" signal
        let eyeDX = b * 0.17, eyeY = cy - b * 0.005          // eyes on the note's midline (they used to hang at 60%)
        let drift = CGSize(width: gaze.x * b * 0.02, height: gaze.y * b * 0.015)   // the eyes themselves drift a hair; the pupils do the looking
        let style = MascotStyle.current
        let innocent = style.isInnocentFamily, v1 = style == .innocentV1
        let browY = cy - b * (innocent ? 0.235 : 0.21)          // just above the eyes, like the reference
        // v2: shorter brows set wide apart, each floating over its own eye (the Clippy "harmless" look)
        let browW = b * (v1 ? 0.26 : innocent ? 0.215 : 0.27), browLW = b * (v1 ? 0.034 : innocent ? 0.038 : 0.042)
        let rightScale: CGFloat = v1 ? 0.80 : innocent ? 0.95 : 0.93        // v1 shortened the right brow to dodge the curl
        let leftDX: CGFloat = v1 ? 0.02 : innocent ? 0.045 : 0.02            // outward push of the left brow
        let rightDX: CGFloat = v1 ? 0.065 : innocent ? 0.045 : 0.01
        let rightDY: CGFloat = v1 ? 0.04 : innocent ? 0.045 : 0.015
        let cock: CGFloat = style == .innocentV3 ? 1 : 0   // v3 only: the face is cocked like the reference (right eye lower)
        // Pointer proximity: both brows drift up a little as the mouse approaches, the one on the pointer's side a bit more.
        let side = max(-1, min(1, gaze.x * 3))
        let liftL = proximity * b * (0.025 + 0.02 * max(0, -side))
        let liftR = proximity * b * (0.025 + 0.02 * max(0, side))
        return ZStack {
            eye(w: eyeW, h: eyeH, open: open, happy: ex.happy, gaze: gaze)
                .rotationEffect(.degrees(6))
                .position(x: cx - eyeDX + drift.width, y: eyeY + drift.height - b * 0.012 * cock)
            eye(w: eyeW, h: eyeH, open: open, happy: ex.happy, gaze: gaze)
                .rotationEffect(.degrees(6))
                .position(x: cx + eyeDX + drift.width, y: eyeY + drift.height + b * 0.03 * cock)
            brow(width: browW, lineWidth: browLW, arch: ex.left.arch, peak: ex.left.peak)
                .rotationEffect(.degrees(Double(-ex.left.innerUp)))
                .position(x: cx - eyeDX - b * leftDX, y: browY - ex.left.raise * b - browTwitch - liftL)
            brow(width: browW * rightScale, lineWidth: browLW, arch: ex.right.arch, peak: ex.right.peak)   // a touch shorter and lower so it clears the curl
                .rotationEffect(.degrees(Double(ex.right.innerUp)))
                .position(x: cx + eyeDX - b * rightDX, y: browY + b * rightDY - ex.right.raise * b - liftR)
        }
    }

    /// A white sclera under a black pupil. The pupil slides (and shrinks a little) toward the gaze, so a white crescent
    /// shows on the far side when the note glances sideways, like the reference's "curious" pose.
    private func eye(w: CGFloat, h: CGFloat, open: CGFloat, happy: CGFloat, gaze: CGPoint) -> some View {
        let look = min(1, hypot(gaze.x, gaze.y))
        let slide = CGSize(width: gaze.x * w * 0.30, height: gaze.y * h * 0.16)
        return ZStack {
            ZStack {
                Ellipse().fill(Color(white: 0.985))
                Ellipse()
                    .fill(LinearGradient(colors: [Color(red: 0.22, green: 0.21, blue: 0.22), Self.ink, .black], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        Ellipse()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: w * 0.38, height: h * 0.23)
                            .offset(x: w * 0.12, y: -h * 0.33))   // catchlight high in the eye, like the reference
                    .scaleEffect(1 - 0.14 * look)
                    .offset(slide)
            }
            .frame(width: w, height: h)
            .clipShape(Ellipse())
            .scaleEffect(x: 1, y: max(0.06, open), anchor: .center)
            .opacity(Double(1 - happy))
            // happy eye: ^
            HappyEye()
                .stroke(Self.ink, style: StrokeStyle(lineWidth: h * 0.2, lineCap: .round, lineJoin: .round))
                .frame(width: w * 1.3, height: h * 0.42)
                .opacity(Double(happy))
        }
    }

    /// A chrome tube: soft drop shadow, dark body, a broad gloss along the top, a thin white sheen and a faint reflection underneath.
    private func brow(width: CGFloat, lineWidth: CGFloat, arch: CGFloat, peak: CGFloat) -> some View {
        let h = width * 0.30 * arch
        let tube = BrowArc(arch: arch, peak: peak).stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        return ZStack {
            BrowArc(arch: arch, peak: peak)
                .stroke(Color.black.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth * 1.15, lineCap: .round))
                .offset(y: lineWidth * 0.35)
                .blur(radius: lineWidth * 0.25)
            BrowArc(arch: arch, peak: peak)
                .stroke(LinearGradient(colors: [Color(red: 0.40, green: 0.39, blue: 0.40), Color(red: 0.20, green: 0.19, blue: 0.20)], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            ZStack {
                BrowArc(arch: arch, peak: peak)   // gloss
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth * 0.28, lineCap: .round))
                    .offset(y: -lineWidth * 0.22)
                BrowArc(arch: arch, peak: peak)   // sheen
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: lineWidth * 0.10, lineCap: .round))
                    .offset(y: -lineWidth * 0.34)
                BrowArc(arch: arch, peak: peak)   // reflection on the underside
                    .stroke(Color(white: 0.7).opacity(0.45), style: StrokeStyle(lineWidth: lineWidth * 0.14, lineCap: .round))
                    .offset(y: lineWidth * 0.30)
            }
            .mask(tube)
        }
        .frame(width: width, height: max(h, lineWidth))
    }

    // MARK: extras

    /// Hold-to-charge progress: a purple-and-gold ring hugging the whole note, filling clockwise from the top.
    private func chargeRing(s: CGFloat, charge: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: charge)
            .stroke(AngularGradient(colors: [Self.brand, Self.gold, Color(red: 0.8, green: 0.5, blue: 1), Self.brand], center: .center),
                    style: StrokeStyle(lineWidth: max(2, s * 0.04), lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: s * 1.22, height: s * 1.22)
            .shadow(color: Self.brand.opacity(0.6 * charge), radius: s * 0.04)
            .opacity(charge > 0.01 ? 1 : 0)
    }

    private func motionLines(s: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: s * 0.085) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == 1 ? Self.paperBottom : Color.primary.opacity(0.55))
                    .frame(width: s * (i == 1 ? 0.30 : 0.22), height: max(1.2, s * 0.028))
            }
        }
        .frame(width: s * 0.30, alignment: .trailing)
        .position(x: s * 0.09, y: s * 0.46)
    }

    /// Wide enough to leave the charge ring alone; slides in from the left to hide the note behind an edge for `peek`.
    private func peekMask(s: CGFloat, hidden: CGFloat) -> some View {
        Rectangle().frame(width: s * (1.5 - 0.77 * hidden), height: s * 1.5).offset(x: s * 0.135 * hidden)
    }

    private func edgeShadow(s: CGFloat) -> some View {
        LinearGradient(colors: [.black.opacity(0.32), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: s * 0.07, height: s)
            .offset(x: -s * (0.5 - 0.27 - 0.035))
    }
}

// MARK: shapes

/// The sheet with its top-right corner missing along a soft crease. Drawn inside rect inset by 10%.
private struct NoteBody: Shape {
    var curl: CGFloat
    var animatableData: CGFloat { get { curl } set { curl = newValue } }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.10)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - curl, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + curl), control: CGPoint(x: r.maxX - curl * 0.42, y: r.minY + curl * 0.42))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY), control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.015))
        p.closeSubpath()
        return p
    }
}

/// The folded-over corner at small sizes: sits on the paper, bounded by the crease and a convex outer edge.
private struct NoteFlap: Shape {
    var curl: CGFloat
    var animatableData: CGFloat { get { curl } set { curl = newValue } }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.10)
        let a = CGPoint(x: r.maxX - curl, y: r.minY), b = CGPoint(x: r.maxX, y: r.minY + curl)
        let tip = CGPoint(x: r.maxX - curl * 0.92, y: r.minY + curl * 0.92)
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: CGPoint(x: r.maxX - curl * 0.42, y: r.minY + curl * 0.42))
        p.addQuadCurve(to: tip, control: CGPoint(x: r.maxX - curl * 0.30, y: r.minY + curl * 0.95))
        p.addQuadCurve(to: a, control: CGPoint(x: r.maxX - curl * 0.95, y: r.minY + curl * 0.30))
        p.closeSubpath()
        return p
    }
}

/// The corner rolled over the face at large sizes: a fat, convex roll whose tip reaches a little past the crease's end.
private struct NoteCurl: Shape {
    var curl: CGFloat
    var animatableData: CGFloat { get { curl } set { curl = newValue } }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.10)
        let c = curl
        let a = CGPoint(x: r.maxX - c, y: r.minY), b = CGPoint(x: r.maxX, y: r.minY + c)
        let tip = CGPoint(x: r.maxX - c * 0.96, y: r.minY + c * 1.0)
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: CGPoint(x: r.maxX - c * 0.42, y: r.minY + c * 0.42))
        p.addCurve(to: tip, control1: CGPoint(x: r.maxX + c * 0.02, y: r.minY + c * 0.78),
                   control2: CGPoint(x: r.maxX - c * 0.40, y: r.minY + c * 1.10))
        p.addCurve(to: a, control1: CGPoint(x: r.maxX - c * 1.14, y: r.minY + c * 0.80),
                   control2: CGPoint(x: r.maxX - c * 1.06, y: r.minY + c * 0.10))
        p.closeSubpath()
        return p
    }
}

private struct BrowArc: Shape {
    var arch: CGFloat
    var peak: CGFloat = 0.5   // apex position along the width
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(arch, peak) }
        set { arch = newValue.first; peak = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.maxY - rect.height * 0.1
        p.move(to: CGPoint(x: rect.minX, y: y))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: y), control: CGPoint(x: rect.minX + rect.width * peak, y: y - rect.width * 0.55 * arch))
        return p
    }
}

private struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.15))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.minY + rect.height * 0.15))
        return p
    }
}
