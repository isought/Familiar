import SwiftUI

/// The Familiar character: a small yellow sticky note with two elliptical eyes, two glossy eyebrows and a curled corner.
/// Drawn entirely with SwiftUI shapes so every part can animate.
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
    struct Brow { var raise: CGFloat; var innerUp: CGFloat; var arch: CGFloat }  // raise: fraction of body side (+ = up); innerUp: degrees the inner end sits above the outer end
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
        switch mood {
        case .idle:
            return Expression(left: Brow(raise: 0.03, innerUp: 6, arch: 1), right: Brow(raise: -0.015, innerUp: 4, arch: 0.9), lean: 3)
        case .curious:
            return Expression(left: Brow(raise: 0.085, innerUp: 14, arch: 1.5), right: Brow(raise: -0.025, innerUp: -3, arch: 0.6),
                              gaze: CGPoint(x: 0.8, y: 0.25), lean: 5)
        case .happy:
            return Expression(left: Brow(raise: 0.07, innerUp: 6, arch: 1.2), right: Brow(raise: 0.07, innerUp: 6, arch: 1.2),
                              happy: 1, lean: -5, shift: CGSize(width: 0, height: -0.02))
        case .thinking:
            return Expression(left: Brow(raise: 0.07, innerUp: 10, arch: 1.2), right: Brow(raise: 0.045, innerUp: 3, arch: 1.2),
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
}

struct MascotView: View {
    var mood: MascotMood
    var lookAt: CGPoint? = nil     // direction the pupils look, x right / y down, magnitude 0…1; nil = straight ahead
    var charge: CGFloat = 0        // 0…1 hold-to-charge progress
    var size: CGFloat = 48
    /// 0 = stuck on, 1 = peeled off the screen (rotated away and faded). Animate it when hiding/showing the bubble.
    var peel: CGFloat = 0
    /// Set false for static renders (no timers, no breathing).
    var animated = true

    @StateObject private var clock = MascotClock()
    @State private var pop: CGFloat = 0          // transient squash-and-stretch on mood changes

    var body: some View {
        let ex = Expression.of(mood)
        let s = size
        let c = max(0, min(1, charge))
        let t = animated ? clock.t : 0
        let breath = 1 + 0.015 * sin(t * 2 * .pi / 3.4)
        let bob: CGFloat = mood == .thinking ? 0.02 * s * sin(t * 2 * .pi / 1.6) : 0
        let wobble: CGFloat = c > 0.15 ? CGFloat(sin(t * 2 * .pi * 11)) * 2.2 * c : 0      // tremble while bracing
        let browTwitch: CGFloat = (mood == .idle && sin(t * 2 * .pi / 5.3 + 1.2) > 0.985) ? 0.008 * s : 0   // a tiny brow flick every ~5 s
        let squint = ex.eyeOpen * (1 - 0.35 * c)     // the harder the hold, the tighter the squint
        let open = squint * (1 - 0.94 * (animated ? clock.blink : 0))
        let gaze = gazeVector(ex)

        ZStack {
            motionLines(s: s).opacity(ex.motionLines)
            chargeRing(s: s, charge: c)
            note(s: s, ex: ex, open: open, gaze: gaze, browTwitch: browTwitch)
                .rotationEffect(.degrees(ex.lean + wobble))
                .scaleEffect(x: ex.squashX * (1 + 0.11 * c) * (1 + 0.10 * pop), y: ex.squashY * (1 + 0.05 * c) * (1 - 0.10 * pop))
                .scaleEffect(breath)
                .offset(x: ex.shift.width * s, y: ex.shift.height * s + bob + 0.02 * s * c)
        }
        .frame(width: s, height: s)
        .mask(peekMask(s: s, hidden: ex.hidden))
        .overlay(edgeShadow(s: s).opacity(ex.hidden))
        .rotation3DEffect(.degrees(Double(peel) * 75), axis: (x: 0.35, y: -1, z: 0.15), anchor: .bottomLeading, perspective: 0.7)
        .scaleEffect(1 - 0.15 * peel)
        .opacity(Double(1 - peel * 0.9))
        .animation(.spring(response: 0.38, dampingFraction: 0.55), value: mood)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: charge)
        .animation(.spring(response: 0.45, dampingFraction: 0.65), value: peel)
        .animation(.easeOut(duration: 0.12), value: lookAt)
        .onAppear { if animated { clock.begin() } }
        .onDisappear { clock.end() }
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
    private static let ink = Color(red: 0.12, green: 0.11, blue: 0.11)
    private static let brand = Color(red: 0.55, green: 0.3, blue: 0.95)

    private func note(s: CGFloat, ex: Expression, open: CGFloat, gaze: CGPoint, browTwitch: CGFloat) -> some View {
        let b = s * 0.80                       // body side
        let inset = (s - b) / 2
        let curl = b * 0.26
        let body = CGRect(x: inset, y: inset, width: b, height: b)
        return ZStack {
            // paper
            NoteBody(curl: curl)
                .fill(LinearGradient(colors: [Self.paperTop, Self.paperBottom], startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1)))
                .overlay(NoteBody(curl: curl).fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.25, y: 0.2), startRadius: 0, endRadius: b * 0.7)))
                .overlay(NoteBody(curl: curl).fill(LinearGradient(colors: [.clear, Color(red: 0.75, green: 0.55, blue: 0.15).opacity(0.22)], startPoint: UnitPoint(x: 0.5, y: 0.6), endPoint: .bottom)))
                .shadow(color: .black.opacity(0.22), radius: s * 0.045, x: 0, y: s * 0.035)
                .shadow(color: Color(red: 0.6, green: 0.45, blue: 0.1).opacity(0.18), radius: s * 0.015, y: s * 0.01)
            // curled corner: shadow it throws on the paper, then the flap (the paper's back, lighter)
            NoteFlap(curl: curl)
                .fill(Color.black.opacity(0.28))
                .blur(radius: s * 0.02)
                .offset(x: -s * 0.012, y: s * 0.022)
                .mask(NoteBody(curl: curl))
            NoteFlap(curl: curl)
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.98, blue: 0.86), Color(red: 0.98, green: 0.90, blue: 0.58), Color(red: 0.92, green: 0.78, blue: 0.38)],
                                     startPoint: UnitPoint(x: 0.85, y: 0.15), endPoint: UnitPoint(x: 0.55, y: 0.45)))
                .overlay(NoteFlap(curl: curl).stroke(Color(red: 0.8, green: 0.62, blue: 0.2).opacity(0.35), lineWidth: max(0.5, s * 0.006)))
            face(body: body, ex: ex, open: open, gaze: gaze, browTwitch: browTwitch)
        }
        .frame(width: s, height: s)
    }

    private func face(body: CGRect, ex: Expression, open: CGFloat, gaze: CGPoint, browTwitch: CGFloat) -> some View {
        let b = body.width
        let cx = body.midX, cy = body.midY
        let eyeW = b * 0.135 * ex.eyeScale, eyeH = b * 0.23 * ex.eyeScale
        let eyeDX = b * 0.17, eyeY = cy + b * 0.10
        let look = CGSize(width: gaze.x * b * 0.075, height: gaze.y * b * 0.06)
        let browY = cy - b * 0.19
        let browW = b * 0.27, browLW = b * 0.042
        return ZStack {
            eye(w: eyeW, h: eyeH, open: open, happy: ex.happy, look: look)
                .position(x: cx - eyeDX + look.width, y: eyeY + look.height)
            eye(w: eyeW, h: eyeH, open: open, happy: ex.happy, look: look)
                .position(x: cx + eyeDX + look.width, y: eyeY + look.height)
            brow(width: browW, lineWidth: browLW, arch: ex.left.arch)
                .rotationEffect(.degrees(Double(-ex.left.innerUp)))
                .position(x: cx - eyeDX - b * 0.02, y: browY - ex.left.raise * b - browTwitch)
            brow(width: browW, lineWidth: browLW, arch: ex.right.arch)
                .rotationEffect(.degrees(Double(ex.right.innerUp)))
                .position(x: cx + eyeDX + b * 0.02, y: browY - ex.right.raise * b)
        }
    }

    private func eye(w: CGFloat, h: CGFloat, open: CGFloat, happy: CGFloat, look: CGSize) -> some View {
        ZStack {
            // open eye: black ellipse with a glossy highlight
            ZStack {
                Ellipse()
                    .fill(LinearGradient(colors: [Color(red: 0.22, green: 0.21, blue: 0.22), Self.ink, .black], startPoint: .top, endPoint: .bottom))
                Ellipse()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: w * 0.36, height: h * 0.22)
                    .offset(x: w * 0.12, y: -h * 0.26)
            }
            .frame(width: w, height: h)
            .scaleEffect(x: 1, y: max(0.06, open), anchor: .center)
            .opacity(Double(1 - happy))
            // happy eye: ^
            HappyEye()
                .stroke(Self.ink, style: StrokeStyle(lineWidth: h * 0.2, lineCap: .round, lineJoin: .round))
                .frame(width: w * 1.3, height: h * 0.42)
                .opacity(Double(happy))
        }
    }

    private func brow(width: CGFloat, lineWidth: CGFloat, arch: CGFloat) -> some View {
        let h = width * 0.30 * arch
        return ZStack {
            BrowArc(arch: arch)
                .stroke(Color.black.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth * 1.15, lineCap: .round))
                .offset(y: lineWidth * 0.35)
                .blur(radius: lineWidth * 0.25)
            BrowArc(arch: arch)
                .stroke(LinearGradient(colors: [Color(red: 0.40, green: 0.39, blue: 0.40), Color(red: 0.20, green: 0.19, blue: 0.20)], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            BrowArc(arch: arch)   // gloss
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth * 0.28, lineCap: .round))
                .offset(y: -lineWidth * 0.22)
                .mask(BrowArc(arch: arch).stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)))
        }
        .frame(width: width, height: max(h, lineWidth))
    }

    // MARK: extras

    private func chargeRing(s: CGFloat, charge: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: s * 0.08, style: .continuous)
            .trim(from: 0, to: charge)
            .stroke(AngularGradient(colors: [Self.brand, Color(red: 0.8, green: 0.5, blue: 1), Self.brand], center: .center),
                    style: StrokeStyle(lineWidth: max(2, s * 0.045), lineCap: .round))
            .frame(width: s * 0.98, height: s * 0.98)
            .scaleEffect(x: -1)   // run clockwise from the curled corner
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

    private func peekMask(s: CGFloat, hidden: CGFloat) -> some View {
        Rectangle().frame(width: s * (1 - 0.27 * hidden), height: s).offset(x: s * 0.135 * hidden)
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

/// The folded-over corner: sits on the paper, bounded by the crease and a convex outer edge.
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

private struct BrowArc: Shape {
    var arch: CGFloat
    var animatableData: CGFloat { get { arch } set { arch = newValue } }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.maxY - rect.height * 0.1
        p.move(to: CGPoint(x: rect.minX, y: y))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: y), control: CGPoint(x: rect.midX, y: y - rect.width * 0.55 * arch))
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
