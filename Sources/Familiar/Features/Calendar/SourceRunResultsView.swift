import AppKit
import SwiftUI

struct SourceRunResultsHost: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject var runner: CalendarCollectionRunner
    @ObservedObject private var runs: SourceRunStore
    let runID: UUID
    let sourceID: UUID?
    let openRun: (UUID, UUID?) -> Void
    let manageSource: (UUID) -> Void
    let teaching: RunTeaching?

    init(store: CalendarStore, runner: CalendarCollectionRunner, runID: UUID, sourceID: UUID?,
         openRun: @escaping (UUID, UUID?) -> Void, manageSource: @escaping (UUID) -> Void, teaching: RunTeaching? = nil) {
        self.store = store
        self.runner = runner
        self.runs = store.runStore
        self.runID = runID
        self.sourceID = sourceID
        self.openRun = openRun
        self.manageSource = manageSource
        self.teaching = teaching
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = runs.error ?? (runner.currentRunID == runID ? runner.error : nil) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled).padding(16)
            }
            if let run = runs.run(id: runID) {
                SourceRunResultsView(run: run, sourceID: sourceID, directory: runs.directory(for: runID),
                    isRunning: runner.isRunning && runner.currentRunID == runID,
                    activeSourceIDs: Set(store.sources.map(\.id) + store.readingSources.map(\.id)),
                    openRun: openRun, manageSource: manageSource, stop: { _ = runner.stopActive() }, teaching: teaching)
            } else {
                Text("This run could not be found. Open Run history to choose another saved run.")
                    .font(.system(size: 13)).foregroundStyle(Pad.inkSoft).padding(23)
            }
        }
    }
}

/// The newest run in full, on its own screen. It follows a run that starts while it is open.
struct LatestRunHost: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject var runner: CalendarCollectionRunner
    @ObservedObject private var runs: SourceRunStore
    let openRun: (UUID, UUID?) -> Void
    let manageSource: (UUID) -> Void
    let teaching: RunTeaching?

    init(store: CalendarStore, runner: CalendarCollectionRunner,
         openRun: @escaping (UUID, UUID?) -> Void, manageSource: @escaping (UUID) -> Void, teaching: RunTeaching? = nil) {
        self.store = store
        self.runner = runner
        self.runs = store.runStore
        self.openRun = openRun
        self.manageSource = manageSource
        self.teaching = teaching
    }

    var body: some View {
        if let latest = runs.runs.first {
            SourceRunResultsHost(store: store, runner: runner, runID: latest.id, sourceID: nil,
                                 openRun: openRun, manageSource: manageSource, teaching: teaching).id(latest.id)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let error = runs.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled)
                }
                Text("No runs yet. Read your sources, and the newest run will show here.")
                    .font(.system(size: 13)).foregroundStyle(Pad.inkSoft)
            }.padding(23)
        }
    }
}

/// What the Latest run link says after its name: that the run is still reading, or how many sources didn't finish,
/// so moving the run off the main screen never hides a failure.
struct LatestRunNote: Equatable {
    let text: String
    let isProblem: Bool

    init?(run: SourceRunRecord) {
        if run.status == .running {
            text = "reading now"
            isProblem = false
            return
        }
        let unfinished = run.entries.filter(\.state.didNotFinish).count
        guard unfinished > 0 else { return nil }
        text = "\(unfinished) \(unfinished == 1 ? "source" : "sources") didn’t finish"
        isProblem = true
    }
}

/// Names the sources in a run that didn't finish. It sits above the findings, so the failure the Latest run link
/// promised is on screen when the run opens, not below every other source's findings.
struct UnfinishedSourcesNote: Equatable {
    let text: String

    init?(run: SourceRunRecord) {
        let names = run.entries.filter(\.state.didNotFinish).map(\.sourceName)
        guard !names.isEmpty else { return nil }
        text = "\(names.count) \(names.count == 1 ? "source" : "sources") didn’t finish: \(names.joined(separator: ", "))"
    }
}

struct UnfinishedSourcesLine: View {
    let note: UnfinishedSourcesNote

    var body: some View {
        Label(note.text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Pad.redInk).textSelection(.enabled)
    }
}

struct SourceRunResultsView: View {
    let run: SourceRunRecord
    var sourceID: UUID? = nil
    var directory: URL? = nil
    var isRunning = false
    var activeSourceIDs: Set<UUID> = []
    var openRun: (UUID, UUID?) -> Void = { _, _ in }
    var manageSource: (UUID) -> Void = { _ in }
    var stop: () -> Void = {}
    var teaching: RunTeaching? = nil

    private var entries: [SourceRunEntry] {
        if let sourceID { return run.entries.filter { $0.sourceID == sourceID } }
        return run.entries
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                        if run.origin == .migration {
                            Text("Recovered saved collection · original run details unavailable")
                                .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                        }
                        if sourceID == nil, let unfinished = UnfinishedSourcesNote(run: run) {
                            UnfinishedSourcesLine(note: unfinished).padding(.top, 4)
                        }
                        if sourceID != nil && run.entries.count > 1 {
                            Button("All sources in this run") { openRun(run.id, nil) }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pad.penInk)
                        }
                        if let teaching { TaughtLink(morning: teaching.morning, open: teaching.openLessons) }
                    }
                    Spacer(minLength: 8)
                    if isRunning {
                        ProgressView().controlSize(.small)
                        Button("Stop run", action: stop).buttonStyle(MorningActionButton())
                    }
                    if let directory {
                        Button("Show run folder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                            .buttonStyle(MorningActionButton()).help("Reveal this run’s saved files in Finder")
                    }
                }
                if entries.isEmpty {
                    Text("This source was not included in this run.").font(.system(size: 13)).foregroundStyle(Pad.inkSoft)
                }
                ForEach(entries) { entry in
                    SourceResultContent(presentation: SourceResultPresentation(entry: entry),
                        collectedAt: entry.readingSnapshot?.collectedAt ?? entry.calendarSnapshot?.collectedAt,
                        manageSource: activeSourceIDs.contains(entry.sourceID) ? { manageSource(entry.sourceID) } : nil,
                        teaching: teaching)
                    if entry.id != entries.last?.id { Divider().padding(.vertical, 6) }
                }
            }.padding(23)
        }
    }
}

struct SourceRunHistoryView: View {
    @ObservedObject var runs: SourceRunStore
    let openRun: (UUID, UUID?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Run history").font(HandFont.font(size: 24))
                Text("Each run keeps the findings collected at that time, including partial reads and failures.")
                    .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                if let error = runs.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled)
                }
                if runs.runs.isEmpty {
                    Text("No saved runs yet. Run your sources from Morning Files to collect the first results.")
                        .font(.system(size: 13)).foregroundStyle(Pad.inkSoft).padding(.vertical, 15)
                }
                ForEach(runs.runs) { run in
                    Button { openRun(run.id, nil) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "tray.full").foregroundStyle(Pad.penInk)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 14, weight: .semibold))
                                Text(run.entries.map(\.sourceName).joined(separator: " · "))
                                    .font(.system(size: 12)).lineLimit(2)
                                Text("\(run.entries.count) \(run.entries.count == 1 ? "source" : "sources") · \(run.status.rawValue.capitalized)")
                                    .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                                let gaps = run.entries.filter(\.state.didNotFinish).count
                                if gaps > 0 {
                                    Text("\(gaps) \(gaps == 1 ? "source has" : "sources have") incomplete results")
                                        .font(.system(size: 11)).foregroundStyle(Pad.redInk)
                                }
                                if run.origin == .migration {
                                    Text("Recovered saved collection").font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                        }.padding(15).background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(23)
        }
    }
}

extension SourceRunEntry.State {
    /// The source stopped short of a full read in this run, so its findings are missing or incomplete.
    var didNotFinish: Bool { [.partial, .failed, .stopped, .notRun, .interrupted].contains(self) }
    var resultSymbol: String {
        switch self {
        case .complete: return "checkmark.circle"
        case .partial: return "circle.lefthalf.filled"
        case .failed, .interrupted: return "exclamationmark.triangle"
        case .reading: return "arrow.triangle.2.circlepath"
        case .waiting: return "clock"
        case .stopped: return "stop.circle"
        case .notRun: return "minus.circle"
        }
    }
    var resultTint: Color { self == .partial || self == .failed || self == .interrupted ? Pad.redInk : Pad.penInk }
}

struct SourceResultContent: View {
    let presentation: SourceResultPresentation
    var collectedAt: Date? = nil
    var manageSource: (() -> Void)? = nil
    var teaching: RunTeaching? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 7) {
                Text(presentation.title).font(.system(size: 20, weight: .semibold)).textSelection(.enabled)
                HStack(spacing: 9) {
                    Label(presentation.stateLabel, systemImage: presentation.state.resultSymbol)
                        .foregroundStyle(presentation.state.resultTint)
                    Text(presentation.dateLabel).foregroundStyle(Pad.inkSoft)
                }.font(.system(size: 12))
                if let collectedAt {
                    Text("Collected \(collectedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                }
            }
            if let notice = presentation.notice, !notice.isEmpty {
                Text(notice).font(.system(size: 12)).foregroundStyle(presentation.state.resultTint)
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .background(presentation.state.resultTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            if presentation.items.isEmpty {
                Text(presentation.emptyMessage).font(.system(size: 13)).foregroundStyle(Pad.inkSoft).padding(.vertical, 12)
            } else {
                Text("\(presentation.items.count) \(presentation.items.count == 1 ? "finding" : "findings")")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Pad.inkSoft)
                ForEach(presentation.items) { item in
                    SourceResultItemCard(item: item, teaching: teaching.flatMap { teaching in
                        item.key.map { key in
                            (teaching, LessonFacts(key: key, sourceID: presentation.sourceID, sourceName: presentation.title,
                                                   title: item.title, from: item.from))
                        }
                    })
                }
            }
            if !presentation.calendarFacts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Schedule summary").font(.system(size: 13, weight: .semibold))
                    ForEach(presentation.calendarFacts) { fact in
                        DisclosureGroup {
                            Text(fact.text).font(.system(size: 12)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(fact.title).font(.system(size: 12, weight: .medium))
                                Text(SourceResultPresentation.excerpt(fact.text, limit: 140))
                                    .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                            }
                        }
                    }
                }.padding(13).background(Pad.paperTop.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            if !presentation.details.isEmpty {
                DisclosureGroup("Collection details") {
                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(presentation.details) { detail in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(detail.title).font(.system(size: 12, weight: .semibold))
                                Text(detail.text).font(.system(size: 12)).foregroundStyle(Pad.inkSoft).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.top, 10)
                }.font(.system(size: 12))
            }
            if let manageSource {
                Button("Manage source", action: manageSource).buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Pad.penInk)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SourceResultItemCard: View {
    let item: SourceResultPresentation.Item
    /// Where marking it "Matters to me" teaches, and what the lesson is about; nil when it can't be taught.
    var teaching: (RunTeaching, LessonFacts)? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
            Text(expanded || item.text.count <= 600 ? item.text : SourceResultPresentation.excerpt(item.text, limit: 600))
                .font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
            HStack {
                if item.text.count > 600 {
                    Button(expanded ? "Show less" : "Read more") { expanded.toggle() }.buttonStyle(.plain)
                }
                if readingHTTPURL(item.url), let url = URL(string: item.url) { Link("Open original", destination: url) }
            }.font(.system(size: 11)).foregroundStyle(Pad.penInk)
            if let (teaching, facts) = teaching {
                ResultItemTeaching(morning: teaching.morning, attention: teaching.attention, facts: facts).padding(.top, 2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Pad.tabEdge.opacity(0.35)))
    }
}
