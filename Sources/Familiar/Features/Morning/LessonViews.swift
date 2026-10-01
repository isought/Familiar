import SwiftUI

/// The one way "Matters to me" and its words are taught, from a run's results or the rest, so both show the same
/// thing: the lesson is what the person taught, and the attention test is told what to count but never writes the
/// lesson back. Taking a mark back takes its words with it.
@MainActor
struct LessonTeacher {
    let morning: MorningStore
    let attention: AttentionLedger?
    let facts: LessonFacts

    var lesson: MorningLesson? { morning.lesson(for: facts.key) }
    var matters: Bool { lesson?.verdict?.mattered == true }

    func mark(_ matters: Bool) throws {
        if matters { try morning.teach(facts, verdict: .matters) } else { try morning.forgetLesson(key: facts.key) }
        attention?.miss(key: facts.key, retract: !matters)
    }

    /// Saves why, or takes the words back when they are empty, and tells the test the same words.
    func explain(_ words: String) throws {
        try morning.teach(facts, why: words)
        attention?.explain(key: facts.key, card: nil, text: words, via: .rest)
    }

    /// Forgets the lesson, and takes back a "Matters to me" the test counted, so the rest shows it unmarked.
    func forget() throws {
        try morning.forgetLesson(key: facts.key)
        if attention?.isMissed(facts.key) == true { attention?.miss(key: facts.key, retract: true) }
    }
}

extension MorningLesson {
    var facts: LessonFacts { LessonFacts(key: key, sourceID: sourceID, sourceName: sourceName, title: title, from: from) }
}

/// What lets a run's results teach: "Matters to me" and why, on items the card step sorted and left out. Nil where
/// nothing can be taught, such as a fixture rendered without a morning store.
struct RunTeaching {
    let morning: MorningStore
    /// Told too, so the attention test counts a message marked here like one marked in the rest.
    var attention: AttentionLedger? = nil
    var openLessons: () -> Void = {}
    var openCard: (UUID) -> Void = { _ in }
}

/// Under one read item: the card it became, which opens it, or, once the card step has sorted it, "Matters to me" and
/// why. Marking never makes a card; it teaches the card step through a lesson about mail that arrives next.
struct ResultItemTeaching: View {
    @ObservedObject var morning: MorningStore
    let teaching: RunTeaching
    let facts: LessonFacts
    @State private var writing = false
    @State private var words = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    var teacher: LessonTeacher { LessonTeacher(morning: morning, attention: teaching.attention, facts: facts) }

    /// Its own card, or one from another job that names it.
    var card: MorningCard? {
        morning.cardsByKey[facts.key] ?? teaching.attention?.namingCard(for: facts.key, in: morning.cards)
    }

    /// Only an item the card step has judged can be taught about here: before that it may yet become a card.
    var isSorted: Bool { morning.workspace.judgments?[facts.key] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let card {
                Button { teaching.openCard(card.id) } label: {
                    Label("Became a card: \(card.title)", systemImage: "rectangle.portrait.on.rectangle.portrait").lineLimit(1)
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pad.penInk).help("Open the card")
            } else if isSorted {
                let lesson = teacher.lesson, matters = teacher.matters
                HStack(spacing: 8) {
                    Button(matters ? "✓ Matters to me · undo" : "Matters to me") { mark(!matters) }
                        .buttonStyle(AttentionSmallButton(filled: matters))
                        .accessibilityLabel("Matters to me: \(facts.title)")
                        .accessibilityAddTraits(matters ? .isSelected : [])
                        .help(matters ? "Take it back, with any words" : "Tell Noteling this matters to you. It learns for mail that arrives next.")
                    if (matters || lesson?.why != nil) && !writing {
                        Button(lesson?.why == nil ? "Why?" : "Edit why") { begin(lesson?.why) }.buttonStyle(AttentionSmallButton())
                            .accessibilityLabel((lesson?.why == nil ? "Say why: " : "Edit why: ") + facts.title)
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
                            .onAppear { focused = true }
                        Button("Save", action: save).foregroundStyle(Pad.penInk)
                        Button("Cancel") { writing = false }.foregroundStyle(Pad.penInk)
                    }.buttonStyle(.plain).font(.system(size: 12)).onExitCommand { writing = false }
                }
            }
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(Pad.redInk).textSelection(.enabled) }
        }
    }

    func mark(_ matters: Bool) {
        perform { try teacher.mark(matters) }
        if !matters { writing = false }
    }

    func save() {
        perform { try teacher.explain(words) }
        if failure == nil { writing = false }
    }

    private func begin(_ why: String?) {
        words = why ?? ""
        writing = true
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
                .help("The lessons Noteling sends with each job when it sorts what the job read")
        }
    }
}

/// Every lesson, newest first, each with what it was about, what the person said and why, and a way to forget it.
/// This is what the card step sends beside each job's rules.
struct LessonsView: View {
    @ObservedObject var morning: MorningStore
    var attention: AttentionLedger? = nil
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What you’ve taught").font(HandFont.font(size: 24))
                Text("When Noteling sorts what a job read, it sends that job’s newest \(MorningLesson.promptLimit) lessons, with your words, to your Claude connection beside its rules, so what matters to you shapes your cards. It learns for mail that arrives next; what was already sorted stays as it is. Mark messages with Matters to me on a run’s results or in the rest, or use the thumbs and Let me explain… on a card.")
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
            Button("Forget") { forget(lesson) }
                .buttonStyle(AttentionSmallButton())
                .accessibilityLabel("Forget the lesson about \(lesson.title)")
                .help("Noteling stops using this lesson. A card’s thumbs stay as they are.")
        }
        .padding(12).background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    func forget(_ lesson: MorningLesson) {
        do { try LessonTeacher(morning: morning, attention: attention, facts: lesson.facts).forget(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
