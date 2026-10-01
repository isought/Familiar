import Foundation

/// What the person taught about one item a job read: that it mattered to them or didn't, and why, in their words. The
/// card step reads a job's lessons beside its rules, so what one person finds worth their notice shapes their cards.
/// Lessons are kept with the cards, apart from the attention test's file, which never leaves the Mac.
struct MorningLesson: Codable, Equatable, Identifiable {
    enum Verdict: String, Codable, CaseIterable {
        case matters, mattersALot = "matters_a_lot", notForMe = "not_for_me", notAtAll = "not_at_all"

        var mattered: Bool { self == .matters || self == .mattersALot }
        var label: String {
            switch self {
            case .matters: return "Matters to me"
            case .mattersALot: return "Matters a lot"
            case .notForMe: return "Not for me"
            case .notAtAll: return "Not at all"
            }
        }

        /// The verdict a card's thumb gives: nil for a cleared thumb, and for words, which never change it.
        init?(_ value: AttentionLabelValue) {
            switch value {
            case .yes: self = .matters
            case .strongYes: self = .mattersALot
            case .no: self = .notForMe
            case .strongNo: self = .notAtAll
            case .explain, .clear: return nil
            }
        }
    }

    /// The item's observation key: its job and its identity there, such as a Message-ID.
    var key: String
    var sourceID: UUID
    var sourceName: String
    /// The subject or title, and for mail its sender, as read: enough for the card step to see what kind of item it was.
    var title: String
    var from: String?
    var verdict: Verdict?
    var why: String?
    var taughtAt: Date
    var id: String { key }

    /// Neither a verdict nor words: nothing to teach, so it is not kept.
    var isEmpty: Bool { verdict == nil && (why ?? "").isEmpty }

    /// Lessons kept, newest first; the oldest go once there are more.
    static let limit = 300
    /// A job's newest lessons the card step reads.
    static let promptLimit = 40
    static let whyLimit = 500
}

/// What a lesson is about, as the place it was taught from knows it.
struct LessonFacts: Equatable {
    var key: String
    var sourceID: UUID
    var sourceName: String
    var title: String
    var from: String?
}

extension MorningStore {
    /// Newest first.
    var lessons: [MorningLesson] { workspace.lessons ?? [] }

    func lesson(for key: String) -> MorningLesson? { lessons.first { $0.key == key } }

    /// Records that an item mattered to the person or didn't, or takes that back with nil. Words already given stay.
    func teach(_ facts: LessonFacts, verdict: MorningLesson.Verdict?, at date: Date = Date()) throws {
        try updateLesson(facts, at: date) { $0.verdict = verdict }
    }

    /// Saves why an item mattered or didn't, up to 500 characters; empty words take it back.
    func teach(_ facts: LessonFacts, why: String, at date: Date = Date()) throws {
        let words = String(why.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MorningLesson.whyLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try updateLesson(facts, at: date) { $0.why = words.isEmpty ? nil : words }
    }

    /// What a thumb, an explanation or "Matters to me" in the attention test taught, kept as a lesson.
    func teach(_ facts: LessonFacts, _ teaching: AttentionTeaching) throws {
        switch teaching {
        case .verdict(let verdict): try teach(facts, verdict: verdict)
        case .why(let words): try teach(facts, why: words)
        }
    }

    func forgetLesson(key: String) throws {
        guard lesson(for: key) != nil else { return }
        try changeLessons { $0.removeAll { $0.key == key } }
    }

    /// A change that leaves the lesson as it was writes nothing, so teaching the same thing from two places (the run
    /// results and the attention test's rest) keeps one lesson and its first time.
    private func updateLesson(_ facts: LessonFacts, at date: Date, _ change: (inout MorningLesson) -> Void) throws {
        let previous = lesson(for: facts.key)
        var lesson = previous ?? MorningLesson(key: facts.key, sourceID: facts.sourceID, sourceName: facts.sourceName,
                                               title: facts.title, from: facts.from, taughtAt: date)
        change(&lesson)
        guard lesson != previous, !(previous == nil && lesson.isEmpty) else { return }
        lesson.taughtAt = date
        try changeLessons { lessons in
            lessons.removeAll { $0.key == facts.key }
            if !lesson.isEmpty { lessons.insert(lesson, at: 0) }
        }
    }
}
