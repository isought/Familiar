import AppKit
import SwiftUI

/// The note's paper, folded into a crane. Coordinates are in note-size units so the
/// ordinary mascot remains exactly centered while the wings can extend beyond it.
struct OrigamiMascotView: View, Animatable {
    var fold: CGFloat
    var wingBeat: CGFloat
    var size: CGFloat = 64

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(fold, wingBeat) }
        set { fold = newValue.first; wingBeat = newValue.second }
    }

    var body: some View {
        let progress = max(0, min(1, fold))
        let firstFold = origamiEase(progress / 0.34)
        let paperVisible = origamiEase((progress - 0.10) / 0.18)
        ZStack {
            OrigamiPaper(fold: progress, wingBeat: wingBeat)
                .frame(width: size * 3, height: size * 3)
                .opacity(paperVisible)
                .shadow(color: Color(red: 0.36, green: 0.25, blue: 0.04).opacity(0.20),
                        radius: size * 0.035, x: 0, y: size * 0.045)

            // Use the real character, including the selected brow version. Its face
            // travels with the first fold and disappears as the paper closes over it.
            MascotView(mood: .idle, size: size, animated: false, decorations: false)
                .rotationEffect(.degrees(-45 * firstFold))
                .scaleEffect(x: 1 - 0.46 * firstFold, y: 1)
                .rotation3DEffect(.degrees(24 * firstFold), axis: (x: 0, y: 1, z: 0))
                .opacity(1 - origamiEase((progress - 0.12) / 0.20))
        }
        .frame(width: size * 3, height: size * 3)
        .accessibilityHidden(true)
    }
}

private func origamiEase(_ value: CGFloat) -> CGFloat {
    let t = max(0, min(1, value))
    return t * t * (3 - 2 * t)
}

private struct OrigamiPaper: View {
    var fold: CGFloat
    var wingBeat: CGFloat

    private let pale = Color(red: 1.0, green: 0.966, blue: 0.70)
    private let light = Color(red: 1.0, green: 0.91, blue: 0.51)
    private let gold = Color(red: 0.96, green: 0.77, blue: 0.28)
    private let shade = Color(red: 0.78, green: 0.55, blue: 0.15)

    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 3
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let beat = max(-1, min(1, wingBeat)) * origamiEase((fold - 0.85) / 0.15)
            let farTip = CGPoint(x: -0.13 + 0.17 * (1 - abs(beat)),
                                 y: -0.40 - (beat >= 0 ? 0.63 : 0.93) * beat)
            let nearTip = CGPoint(x: 0.48 + 0.23 * (1 - abs(beat)),
                                  y: -0.39 - (beat >= 0 ? 0.68 : 1.20) * beat)
            let farRootA = CGPoint(x: -0.25, y: 0.03)
            let farRootB = CGPoint(x: 0.21, y: 0.10)
            let nearRootA = CGPoint(x: -0.16, y: 0.10)
            let nearRootB = CGPoint(x: 0.37, y: 0.11)
            let nearCrease = CGPoint(x: nearTip.x * 0.68 + 0.03, y: nearTip.y * 0.68 + 0.033)
            let farCrease = CGPoint(x: farTip.x * 0.67 - 0.04, y: farTip.y * 0.67 + 0.02)

            // Every facet begins as a sector of the SAME sheet. The sheet turns,
            // closes to a bird base, then opens the neck, tail and hinged wings.
            // Repeated vertices let triangles and folded polygons share topology.
            let facets: [OrigamiFacet] = [
                .init(source: [(-0.4, -0.4), (0, -0.4), (0, 0)],
                      base: [(0, -0.58), (-0.28, 0), (0, 0.35)],
                      final: [farRootA, farTip, farCrease, farRootB],
                      colors: [light, gold], opens: 0.68, duration: 0.32),
                .init(source: [(0, -0.4), (0.4, -0.4), (0, 0)],
                      base: [(0, -0.58), (0.27, 0), (0, 0.35)],
                      final: [farTip, farCrease, farRootB],
                      colors: [pale, light], opens: 0.68, duration: 0.32),
                .init(source: [(0.4, -0.4), (0.4, 0), (0, 0)],
                      base: [(0, -0.58), (0.23, 0.02), (0, 0.40)],
                      final: [(0.09, 0.08), (0.96, -0.27), (0.39, 0.17)],
                      colors: [pale, gold], opens: 0.53, duration: 0.32),
                .init(source: [(0.4, 0), (0.4, 0.4), (0, 0)],
                      base: [(0.23, 0.02), (0, 0.58), (0, -0.40)],
                      final: [(0.09, 0.08), (0.96, -0.27), (0.29, 0.12)],
                      colors: [light, gold], opens: 0.53, duration: 0.32),
                .init(source: [(-0.4, 0), (-0.4, -0.4), (0, 0)],
                      base: [(-0.27, 0), (0, -0.58), (0, 0.40)],
                      final: [(-0.37, 0.13), (-0.77, -0.60), (-0.68, -0.69), (-0.27, 0.015)],
                      colors: [pale, light], opens: 0.52, duration: 0.30),
                .init(source: [(-0.4, 0.4), (-0.4, 0), (0, 0)],
                      base: [(0, 0.58), (-0.27, 0), (0, -0.40)],
                      final: [(-0.77, -0.60), (-0.68, -0.69), (-1.01, -0.43), (-0.81, -0.51)],
                      colors: [light, gold], opens: 0.64, duration: 0.24),
                .init(source: [(0, 0.4), (-0.4, 0.4), (0, 0)],
                      base: [(0, 0.58), (-0.27, 0), (0, -0.10)],
                      final: [(-0.37, 0.13), (-0.22, -0.02), (0.10, -0.09), (0.41, 0.11), (0.03, 0.29)],
                      colors: [light, gold], opens: 0.52, duration: 0.31),
                .init(source: [(0.4, 0.4), (0, 0.4), (0, 0)],
                      base: [(0.27, 0), (0, 0.58), (0, -0.10)],
                      final: [(-0.37, 0.13), (0.02, 0.13), (0.41, 0.11), (0.03, 0.29)],
                      colors: [gold, shade.opacity(0.86)], opens: 0.52, duration: 0.31),
                .init(source: [(0, 0), (0, 0), (0, 0)],
                      base: [(-0.27, 0), (0, -0.58), (0.27, 0), (0, 0.58)],
                      final: [nearRootA, nearTip, nearCrease, nearRootB],
                      colors: [pale, light], opens: 0.70, duration: 0.30),
                .init(source: [(0, 0), (0, 0), (0, 0)],
                      base: [(0, -0.58), (0.27, 0), (0, 0.58)],
                      final: [nearTip, nearCrease, nearRootB],
                      colors: [light, gold], opens: 0.70, duration: 0.30),
            ]

            for (index, facet) in facets.enumerated() {
                let points = facet.points(at: fold)
                let mapped = points.map { CGPoint(x: center.x + $0.x * unit, y: center.y + $0.y * unit) }
                var path = Path()
                path.addLines(mapped)
                path.closeSubpath()
                var ink = context
                if index >= 8 { ink.opacity = Double(origamiEase((fold - 0.30) / 0.15)) }
                let bounds = path.boundingRect
                ink.fill(path, with: .linearGradient(Gradient(colors: facet.colors),
                    startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                    endPoint: CGPoint(x: bounds.maxX * 0.25 + bounds.minX * 0.75, y: bounds.maxY)))
                ink.stroke(path, with: .color(Color(red: 0.68, green: 0.47, blue: 0.10).opacity(0.32)),
                    style: StrokeStyle(lineWidth: max(0.4, unit * 0.007), lineJoin: .round))

                // One lit edge per fold gives the layered paper a crisp, tactile rim.
                if mapped.count > 1 {
                    var rim = Path()
                    rim.move(to: mapped[0]); rim.addLine(to: mapped[1])
                    ink.stroke(rim, with: .color(.white.opacity(0.45)), lineWidth: max(0.35, unit * 0.006))
                }
            }
        }
        .rotationEffect(.degrees(3 * (1 - fold)))
    }
}

private struct OrigamiFacet {
    var source: [CGPoint]
    var base: [CGPoint]
    var final: [CGPoint]
    var colors: [Color]
    var opens: CGFloat
    var duration: CGFloat

    init(source: [(CGFloat, CGFloat)], base: [(CGFloat, CGFloat)], final: [(CGFloat, CGFloat)],
         colors: [Color], opens: CGFloat, duration: CGFloat) {
        self.init(source: source, base: base, final: final.map { CGPoint(x: $0.0, y: $0.1) },
                  colors: colors, opens: opens, duration: duration)
    }

    init(source: [(CGFloat, CGFloat)], base: [(CGFloat, CGFloat)], final: [CGPoint],
         colors: [Color], opens: CGFloat, duration: CGFloat) {
        self.source = source.map { CGPoint(x: $0.0, y: $0.1) }
        self.base = base.map { CGPoint(x: $0.0, y: $0.1) }
        self.final = final
        self.colors = colors
        self.opens = opens
        self.duration = duration
    }

    func points(at fold: CGFloat) -> [CGPoint] {
        let turn = origamiEase(fold / 0.34)
        let close = origamiEase((fold - 0.28) / 0.22)
        let open = origamiEase((fold - opens) / duration)
        let angle = -.pi / 4 * turn
        func repeated(_ points: [CGPoint], _ index: Int) -> CGPoint { points[min(index, points.count - 1)] }
        return (0..<max(source.count, base.count, final.count)).map { index in
            let point = repeated(source, index)
            let turned = CGPoint(x: (point.x * cos(angle) - point.y * sin(angle)) * (1 - 0.46 * turn),
                                 y: point.x * sin(angle) + point.y * cos(angle))
            let folded = interpolate(turned, repeated(base, index), close)
            return interpolate(folded, repeated(final, index), open)
        }
    }

    private func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// A repeatable visual check of the actual flight view, without launching the app.
@MainActor
func runRenderOrigami() {
    let args = CommandLine.arguments
    guard let flag = args.firstIndex(of: "--render-origami"), flag + 1 < args.count else {
        print("usage: --render-origami <directory> [--style <brow version>]")
        exit(2)
    }
    if let flag = args.firstIndex(of: "--style"), flag + 1 < args.count,
       let style = MascotStyle(rawValue: args[flag + 1]) { MascotStyle.current = style }
    else { MascotStyle.current = .innocentV4 }
    let directory = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    catch { print("Unable to create origami render directory: \(error)"); exit(1) }
    let phases: [(String, CGFloat, CGFloat)] = [
        ("The familiar face", 0, 0), ("First fold", 0.2, 0), ("Bird base", 0.45, 0),
        ("Neck & tail", 0.7, 0), ("Ready to fly", 1, 0.65),
        ("Upstroke", 1, 1), ("Glide", 1, 0), ("Downstroke", 1, -1),
    ]
    func save<V: View>(_ view: V, name: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("Unable to render \(name)"); return
        }
        do { try png.write(to: directory.appendingPathComponent(name)); print("wrote \(name)") }
        catch { print("Unable to save \(name): \(error)") }
    }
    for (index, phase) in phases.enumerated() {
        save(OrigamiMascotView(fold: phase.1, wingBeat: phase.2, size: 96), name: "origami-\(index).png")
    }
    let sheet = VStack(spacing: 0) {
        Text("A little paper adventure").font(.system(size: 22, weight: .medium, design: .rounded)).padding(.top, 24)
        Text("The same note, one fold at a time.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 5)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(216), spacing: 0), count: 4), spacing: 4) {
            ForEach(phases.indices, id: \.self) { index in
                VStack(spacing: 0) {
                    OrigamiMascotView(fold: phases[index].1, wingBeat: phases[index].2, size: 72)
                    Text(phases[index].0).font(.system(size: 12, weight: .medium, design: .rounded))
                }.padding(.bottom, 20)
            }
        }
    }
    .foregroundStyle(Color(red: 0.27, green: 0.23, blue: 0.18))
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
    .background(Color(red: 0.978, green: 0.970, blue: 0.942))
    save(sheet, name: "origami-contact-sheet.png")
    save(HStack(spacing: 0) {
        ForEach([-1.0, 0, 1], id: \.self) { beat in
            OrigamiMascotView(fold: 1, wingBeat: beat, size: 64)
        }
    }.background(Color(white: 0.12)), name: "origami-dark.png")
}
