import SwiftUI

/// What lets a run's results teach: "Matters to me" and why, on items the card step left out. Nil where nothing can
/// be taught, such as a fixture rendered without a morning store.
struct RunTeaching {
    let morning: MorningStore
    /// Told too, so the attention test counts a message marked here like one marked in the rest.
    var attention: AttentionLedger? = nil
    var openLessons: () -> Void = {}
}

/// Under one read item: that it became a card, or "Matters to me" and, once marked, why. Marking never makes a card;
/// it teaches the card step through a lesson.
struct ResultItemTeaching: View {
    @ObservedObject var morning: MorningStore
    let attention: AttentionLedger?
    let facts: LessonFacts
    @State private var writing = false
    @State private var words = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let card = morning.cards.first(where: { $0.tracking?.key == facts.key }) {
                Label("Became a card: \(card.title)", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    .font(.system(size: 11)).foregroundStyle(Pad.inkSoft).lineLimit(1)
            } else {
                let lesson = morning.lesson(for: facts.key)
                let matters = lesson?.verdict?.mattered == true
                HStack(spacing: 8) {
                    Button(matters ? "✓ Matters to me · undo" : "Matters to me") { mark(!matters) }
                        .buttonStyle(AttentionSmallButton(filled: matters))
                        .accessibilityHint(matters ? "Takes back that this matters to you" : "Tells Noteling this matters to you, so it learns")
                    if matters && !writing {
                        Button(lesson?.why == nil ? "Why?" : "Edit why") { begin(lesson?.why) }.buttonStyle(AttentionSmallButton())
                            .help("Say why it matters to you, so Noteling learns")
                    }
                }
                if let why = lesson?.why, !writing {
                    Text("“\(why)”").font(.system(size: 12)).italic().foregroundStyle(Pad.inkSoft).textSelection(.enabled)
                }
                if writing {
                    HStack(spacing: 10) {
                        TextField("Why does it matter to you? Optional", text: $words)
                            .textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
                        Button("Save", action: save).foregroundStyle(Pad.penInk)
                        Button("Cancel") { writing = false }.foregroundStyle(Pad.penInk)
                    }.buttonStyle(.plain).font(.system(size: 12)).onExitCommand { writing = false }
                }
            }
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(Pad.redInk).textSelection(.enabled) }
        }
    }

    /// Marks the item as mattering, or takes that back; taking it back forgets the lesson, words and all.
    func mark(_ matters: Bool) {
        perform { matters ? try morning.teach(facts, verdict: .matters) : try morning.forgetLesson(key: facts.key) }
        if !matters { writing = false }
        attention?.miss(key: facts.key, retract: !matters)
    }

    func save() {
        perform { try morning.teach(facts, why: words) }
        if failure == nil { writing = false }
    }

    private func begin(_ why: String?) {
        words = why ?? ""
        writing = true
        focused = true
    }

    private func perform(_ change: () throws -> Void) {
        do { try change(); failure = nil } catch { failure = error.localizedDescription }
    }
}

/// "What you've taught", with how many lessons there are, once there is one.
struct TaughtLink: View {
    @ObservedObject var morning: MorningStore
    let open: () -> Void

    var body: some View {
        let count = morning.lessons.count
        if count > 0 {
            Button("What you’ve taught (\(count))", action: open).buttonStyle(.plain)
                .font(.system(size: 12)).foregroundStyle(Pad.penInk)
                .help("The lessons Noteling reads when it sorts what your jobs read")
        }
    }
}

/// Every lesson, newest first, each with what it was about, what the person said and why, and a way to forget it.
/// This is what the card step reads beside each job's rules.
struct LessonsView: View {
    @ObservedObject var morning: MorningStore
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What you’ve taught").font(HandFont.font(size: 24))
                Text("When Noteling sorts what a job read, it reads that job’s newest \(MorningLesson.promptLimit) lessons beside its rules, so what matters to you shapes your cards. Mark messages with Matters to me on a run’s results or in the rest, or use the thumbs and Let me explain… on a card.")
                    .font(.system(size: 12)).foregroundStyle(Pad.inkSoft).fixedSize(horizontal: false, vertical: true)
                if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled) }
                if morning.lessons.isEmpty {
                    Text("Nothing yet.").font(.system(size: 13)).foregroundStyle(Pad.inkSoft).padding(.vertical, 12)
                }
                ForEach(morning.lessons) { lesson in row(lesson) }
            }.padding(23)
        }
    }

    private func row(_ lesson: MorningLesson) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(lesson.verdict?.label ?? "Explained")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(lesson.verdict?.mattered == false ? Pad.inkSoft : Pad.penInk)
                    Text(lesson.taughtAt.formatted(date: .abbreviated, time: .omitted) + " · " + lesson.sourceName)
                        .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                }
                Text(lesson.title.isEmpty ? "No subject" : lesson.title).font(.system(size: 13)).lineLimit(2)
                if let from = lesson.from { Text(from).font(.system(size: 11)).foregroundStyle(Pad.inkSoft).lineLimit(1) }
                if let why = lesson.why { Text("“\(why)”").font(.system(size: 12)).italic().textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Forget") {
                do { try morning.forgetLesson(key: lesson.key); failure = nil } catch { failure = error.localizedDescription }
            }
            .buttonStyle(AttentionSmallButton()).help("Noteling stops using this lesson")
        }
        .padding(12).background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}
