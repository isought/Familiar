import AppKit
import SwiftUI

// A task's live window preview, caption, and controls. The feed belongs to execution; presentation can place
// this view in the task screen without putting progress or decisions into the chat history.

@MainActor final class PeekFeed: ObservableObject {
    enum Phase: Equatable { case idle, working, thinking, asking(String), confirming(String), foreground, done, stopped }
    @Published var phase: Phase = .idle
    @Published var frame: CGImage?
    @Published var caption = ""
    @Published var appName = ""
    @Published var windowTitle = ""
    @Published var step = 0
    @Published var cursor: CGPoint?        // normalized 0…1 in window space, top-left origin
    @Published var highlight: CGRect?      // normalized
    @Published var pulse = 0               // increments per click
    @Published var borrowKeepsWindowOffscreen = false
    var startedAt: Date?
    var onStop: (() -> Void)?
    var onGoAhead: (() -> Void)?
    var onNotNow: (() -> Void)?
    var onRaise: (() -> Void)?             // click on the print: bring the window forward
    var approvalRequestID: UUID?           // identifies the owner of confirmation callbacks

    var isWorking: Bool {
        switch phase {
        case .working, .thinking, .asking, .confirming, .foreground: return true
        case .idle, .done, .stopped: return false
        }
    }

    /// "Chrome · New Report · step 4"; empty parts are left out, the step only once one has happened.
    var metaLine: String {
        var parts = [appName, windowTitle].filter { !$0.isEmpty }
        if step > 0 { parts.append("step \(step)") }
        return parts.joined(separator: " · ")
    }

    /// Back to idle with nothing on the print, so the next job starts from a blank photo.
    func reset() {
        approvalRequestID = nil
        onGoAhead = nil
        onNotNow = nil
        phase = .idle
        frame = nil
        caption = ""
        appName = ""
        windowTitle = ""
        step = 0
        cursor = nil
        highlight = nil
        pulse = 0
        borrowKeepsWindowOffscreen = false
        startedAt = nil
    }
}

enum PeekCadence {
    /// Seconds between captures: quick while an action runs so the print shows the click land, slow while the model
    /// thinks or waits for an answer (the window is not changing), none when there is nothing to watch. `foreground`
    /// is the ordinary lane: the human sees the real window, so no print.
    static func interval(phase: PeekFeed.Phase, actionRunning: Bool) -> TimeInterval? {
        switch phase {
        case .idle, .done, .stopped, .foreground: return nil
        case .working, .thinking, .asking, .confirming: return actionRunning ? 0.25 : 1.0
        }
    }
}

/// The ghost cursor as a SwiftUI shape: `GhostCursorArt.path` has its tip at (0, 0) pointing up-left, y down, so it
/// is laid into the rect's top-left corner and the caller positions the rect at the tip.
struct GhostCursorShape: Shape {
    var height: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(GhostCursorArt.path(height: height)).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

struct PeekNoteView: View {
    @ObservedObject var feed: PeekFeed
    var decisionFirst = false
    var showsStop = true

    private static let ghostPurple = Color(red: 0.55, green: 0.3, blue: 0.95)
    private static let cursorHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if decisionBeforePrint { details }
            print
                .padding(.top, 6)      // room for the paperclip's head above the photo
                .padding(.bottom, 2)
            if !decisionBeforePrint { details }
        }
    }

    private var decisionBeforePrint: Bool {
        guard decisionFirst else { return false }
        switch feed.phase {
        case .asking, .confirming: return true
        default: return false
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch feed.phase {
            case .asking(let reason): asking(reason)
            case .confirming(let label): confirming(label)
            default: captionBlock
            }
            if !tabs.isEmpty {
                TabRow(spacing: 6, rowSpacing: -5) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                        Button(t.label, action: t.action).buttonStyle(PaperTabStyle()).zIndex(Double(-i))
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: the print

    /// A 16:10 photo the width of the paper: the frame aspect-fit on the darker sheet colour, a white photo border,
    /// a slight tilt and a paperclip, so it reads as something stuck to the note rather than a screenshot in a box.
    private var print: some View {
        GeometryReader { g in printContent(in: g.size) }
            .aspectRatio(1.6, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .padding(4)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(Pad.tabEdge, lineWidth: 0.8))
            .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1.5)
            .overlay(alignment: .topLeading) {
                Image(systemName: "paperclip").font(.system(size: 14)).foregroundStyle(Pad.inkSoft)
                    .rotationEffect(.degrees(30))
                    .offset(x: 6, y: -8)
            }
            .rotationEffect(.degrees(-1.2))
            .contentShape(Rectangle())
            .onTapGesture { feed.onRaise?() }
            .help(feed.appName.isEmpty ? "Bring the window forward" : "Bring \(feed.appName) forward")
    }

    private func printContent(in size: CGSize) -> some View {
        let fitted = fittedRect(in: size)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Pad.paperDeep)
            if let frame = feed.frame {
                Image(decorative: frame, scale: 1)
                    .resizable().interpolation(.medium)
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
            }
            if let h = feed.highlight {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: .systemPurple), lineWidth: 1.5)
                    .frame(width: max(4, h.width * fitted.width), height: max(4, h.height * fitted.height))
                    .offset(x: fitted.minX + h.minX * fitted.width, y: fitted.minY + h.minY * fitted.height)
            }
            if let c = feed.cursor {
                let tip = CGPoint(x: fitted.minX + c.x * fitted.width, y: fitted.minY + c.y * fitted.height)
                if feed.pulse > 0 {
                    ClickRing(color: Self.ghostPurple).position(tip).id(feed.pulse)   // a fresh ring per click
                }
                ZStack {
                    GhostCursorShape(height: Self.cursorHeight).fill(Self.ghostPurple)
                    GhostCursorShape(height: Self.cursorHeight).stroke(Color.white, lineWidth: 1)
                }
                .frame(width: Self.cursorHeight, height: Self.cursorHeight)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                .offset(x: tip.x, y: tip.y)
                .animation(.easeOut(duration: 0.18), value: c)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// Where the frame lands inside the print: aspect-fit, centred. The cursor and highlight are normalized to the
    /// window, so they are mapped into this rect, not the whole 16:10 box. No frame yet: the box itself.
    private func fittedRect(in size: CGSize) -> CGRect {
        guard let f = feed.frame, f.width > 0, f.height > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let image = CGFloat(f.width) / CGFloat(f.height), box = size.width / size.height
        let w = image > box ? size.width : size.height * image
        let h = image > box ? size.width / image : size.height
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    // MARK: below the print

    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(captionText).font(HandFont.font(size: 14)).foregroundStyle(Pad.ink).textSelection(.enabled)
            if !feed.metaLine.isEmpty {
                Text(feed.metaLine).font(.system(size: 10.5)).foregroundStyle(Pad.inkSoft).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// The caption as written, except that a finished job says so in one word whatever the last caption was.
    private var captionText: String {
        switch feed.phase {
        case .done: return "Done"
        case .stopped: return "Stopped"
        case .idle, .working, .thinking, .asking, .confirming, .foreground: return feed.caption
        }
    }

    private func asking(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(feed.borrowKeepsWindowOffscreen ? "Can I borrow your mouse and keyboard?" : "Can I use your screen, mouse and keyboard?")
                .font(HandFont.font(size: 14)).foregroundStyle(Pad.ink)
            if !reason.isEmpty { Text(reason).font(Pad.body).lineSpacing(Pad.lineSpacing).foregroundStyle(Pad.ink) }
            Text(feed.borrowKeepsWindowOffscreen
                 ? "The task stays on its separate display. I’ll briefly borrow input for each action and return it between steps. Your typing or mouse input interrupts a borrowed action."
                 : "This step uses your screen. Please pause your mouse and keyboard while I work. Typing, clicking, scrolling or pressing Esc takes control back.")
                .font(.system(size: 10.5)).foregroundStyle(Pad.inkSoft)
        }
    }

    private func confirming(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Approve “\(label)”?").font(HandFont.font(size: 14)).foregroundStyle(Pad.ink)
            Text("This action may be irreversible. Approval applies to this control once; it does not give Familiar your mouse.")
                .font(.system(size: 10.5)).foregroundStyle(Pad.inkSoft)
            if !feed.metaLine.isEmpty {
                Text(feed.metaLine).font(.system(size: 10.5)).foregroundStyle(Pad.inkSoft).lineLimit(1)
            }
        }
    }

    private struct Tab { var label: String; var action: () -> Void }

    /// Stop while anything is going on; the two answers while the note is asking; nothing once the job has ended.
    private var tabs: [Tab] {
        // Capture the displayed request's callbacks. An already-rendered button must not read a newer request's
        // callback from the feed when its click is delivered.
        let approve = feed.onGoAhead, decline = feed.onNotNow, stop = feed.onStop
        let stopTabs = showsStop ? [Tab(label: "Stop") { stop?() }] : []
        switch feed.phase {
        case .asking:
            return [Tab(label: "Go ahead") { approve?() }, Tab(label: "Not now") { decline?() }] + stopTabs
        case .confirming:
            return [Tab(label: "Approve once") { approve?() }, Tab(label: "Don't") { decline?() }] + stopTabs
        case .working, .thinking, .foreground:
            return stopTabs
        case .idle, .done, .stopped:
            return []
        }
    }
}

/// One click on the print: a ring that grows from the tip and fades, white under purple so it shows on any frame.
private struct ClickRing: View {
    var color: Color
    @State private var radius: CGFloat = 4
    @State private var alpha: Double = 1

    var body: some View {
        ZStack {
            Circle().stroke(Color.white, lineWidth: 3)
            Circle().stroke(color, lineWidth: 1.5)
        }
        .frame(width: radius * 2, height: radius * 2)
        .opacity(alpha)
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { radius = 16; alpha = 0 } }
    }
}
