import SwiftUI

/// Source definitions have their own screen; collected results open by run identity.
struct CalendarSourcesHost: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject var runner: CalendarCollectionRunner
    var initialSourceID: UUID? = nil
    let teach: () -> Void
    var openRun: (UUID, UUID?) -> Void = { _, _ in }

    var body: some View {
        CalendarSourcesView(store: store, isRunning: runner.isRunning,
                            status: runner.status, runError: runner.error,
                            isBatchRunning: runner.isBatchRunning,
                            initialSourceID: initialSourceID,
                            runAll: {
                                if runner.collectAll() != nil, let id = runner.currentRunID { openRun(id, nil) }
                            },
                            teach: teach, collect: { source, day, start, end in
                                if runner.collect(source: source, day: day, startHour: start, endHour: end) != nil,
                                   let id = runner.currentRunID { openRun(id, source.id) }
                            }, collectReading: { source in
                                if runner.collect(source: source) != nil, let id = runner.currentRunID { openRun(id, source.id) }
                            },
                            stop: { _ = runner.stopActive() })
    }
}

/// The Morning Files entry observes both stores, including work started from the sources screen.
struct CalendarBatchHost: View {
    @ObservedObject var store: CalendarStore
    @ObservedObject var runner: CalendarCollectionRunner
    @ObservedObject private var runs: SourceRunStore
    let openSources: () -> Void
    let openRun: (UUID, UUID?) -> Void
    let openHistory: () -> Void

    init(store: CalendarStore, runner: CalendarCollectionRunner, openSources: @escaping () -> Void,
         openRun: @escaping (UUID, UUID?) -> Void, openHistory: @escaping () -> Void) {
        self.store = store
        self.runner = runner
        self.runs = store.runStore
        self.openSources = openSources
        self.openRun = openRun
        self.openHistory = openHistory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: "tray.full").font(.system(size: 22))
                Text("Your sources").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Manage sources", action: openSources).buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Pad.penInk)
            }
            CalendarBatchControls(sourceCount: store.sources.count + store.readingSources.count, isRunning: runner.isRunning,
                                  isBatchRunning: runner.isBatchRunning, status: runner.status,
                                  runAll: {
                                      if runner.collectAll() != nil, let id = runner.currentRunID { openRun(id, nil) }
                                  }, stop: { _ = runner.stopActive() })
            if let latest = runs.runs.first { SourceRunSummary(run: latest, openRun: openRun) }
            Button("Run history", action: openHistory).buttonStyle(.plain)
                .font(.system(size: 12)).foregroundStyle(Pad.penInk)
            if !store.savedReadingWorkflows.isEmpty {
                Button("Review saved demonstrations (\(store.savedReadingWorkflows.count))", action: openSources)
                    .buttonStyle(MorningActionButton()).disabled(runner.isRunning)
            }
            if let error = runner.error ?? runs.error ?? store.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled)
            }
        }.padding(14).background(Pad.paperTop.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Every saved source has visible editing and recoverable removal controls.
struct SourceManagementList: View {
    let calendars: [LearnedCalendarSource]
    let readings: [LearnedReadingSource]
    var selectedID: UUID? = nil
    var isRunning = false
    let select: (UUID) -> Void
    let edit: (UUID) -> Void
    let remove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Saved sources").font(.system(size: 13, weight: .semibold))
            Text("Choose a source to review its definition. Edit its context and reading rules, or remove it from future runs.")
                .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
            ForEach(calendars) { source in
                row(id: source.id, name: source.name, kind: "Calendar", detail: source.meaning, symbol: "calendar")
            }
            ForEach(readings) { source in
                row(id: source.id, name: source.name, kind: source.kind == .mail ? "Mail" : "Web", detail: source.meaning,
                    symbol: source.kind == .mail ? "envelope" : "globe", requiresReview: source.requiresReview)
            }
        }
    }

    private func row(id: UUID, name: String, kind: String, detail: String, symbol: String, requiresReview: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { select(id) } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: symbol).frame(width: 17).foregroundStyle(Pad.penInk)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(size: 12, weight: .semibold))
                        Text(requiresReview ? "\(kind) · Needs review" : kind)
                            .font(.system(size: 10)).foregroundStyle(requiresReview ? Pad.redInk : Pad.inkSoft)
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 11)).foregroundStyle(Pad.inkSoft).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(isRunning)
                .help("Show this source’s definition and reading rules")
            Button(requiresReview ? "Review" : "Edit") { edit(id) }
                .buttonStyle(MorningActionButton()).disabled(isRunning)
                .accessibilityLabel("\(requiresReview ? "Review" : "Edit") \(name)")
            Button("Remove") { remove(id) }
                .buttonStyle(MorningActionButton()).disabled(isRunning)
                .accessibilityLabel("Remove \(name)")
                .help("Remove from future runs. You can restore this source and its saved collections below.")
        }.padding(11)
            .background(id == selectedID ? Pad.paperTop.opacity(0.8) : Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct RemovedSourcesList: View {
    let sources: [RemovedSource]
    var isRunning = false
    let restore: (UUID) -> Void
    @State private var expanded: Bool

    init(sources: [RemovedSource], isRunning: Bool = false, initiallyExpanded: Bool = false, restore: @escaping (UUID) -> Void) {
        self.sources = sources
        self.isRunning = isRunning
        self.restore = restore
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup("Removed sources · \(sources.count)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Restore a source with its saved collections. Removing a source leaves its original app and saved workflow documents untouched.")
                    .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                ForEach(sources) { source in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).font(.system(size: 12, weight: .medium))
                            Text("Removed \(source.removedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(Pad.inkSoft)
                        }
                        Spacer(minLength: 8)
                        Button("Restore") { restore(source.id) }.buttonStyle(MorningActionButton()).disabled(isRunning)
                            .accessibilityLabel("Restore \(source.name)")
                    }.padding(10).background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                }
            }.padding(.top, 10)
        }.font(.system(size: 12, weight: .medium))
    }
}

/// Calendars read today; mail and web sources use their saved reading scope.
struct CalendarBatchControls: View {
    let sourceCount: Int
    var isRunning = false
    var isBatchRunning = false
    var status = ""
    let runAll: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Run all sources", action: runAll)
                    .buttonStyle(MorningActionButton(primary: true)).disabled(sourceCount == 0 || isRunning)
                if isBatchRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop all", action: stop).buttonStyle(MorningActionButton())
                }
            }
            Text(sourceCount == 0 ? "No sources are ready yet. Add a saved demonstration or teach a source to begin."
                 : "Reads \(sourceCount) saved \(sourceCount == 1 ? "source" : "sources"). Calendars use today, 9 AM–5 PM in their time zone. Mail and web sources use their saved scope.")
                .font(.system(size: 11)).foregroundStyle(Pad.inkSoft).fixedSize(horizontal: false, vertical: true)
            if isBatchRunning, !status.isEmpty {
                Text(status).font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
            }
        }
    }
}

struct CalendarSourcesView: View {
    @ObservedObject var store: CalendarStore
    var isRunning = false
    var status = ""
    var runError: String? = nil
    var isBatchRunning = false
    var initialSourceID: UUID? = nil
    var runAll: () -> Void = {}
    let teach: () -> Void
    let collect: (LearnedCalendarSource, Date, Int, Int) -> Void
    var collectReading: (LearnedReadingSource) -> Void = { _ in }
    let stop: () -> Void
    @State private var selectedID: UUID?
    @State private var day = Date()
    @State private var startHour = 9
    @State private var endHour = 17
    @State private var editing = false
    @State private var readingDraft: LearnedReadingSource?
    @State private var localError: String?
    @State private var feedback: String?
    @State private var removedForUndo: UUID?

    private var sourceCount: Int { store.sources.count + store.readingSources.count }
    private var activeIDs: Set<UUID> { Set(store.sources.map(\.id) + store.readingSources.map(\.id)) }
    private var resolvedID: UUID? {
        if let selectedID, activeIDs.contains(selectedID) { return selectedID }
        if let initialSourceID, activeIDs.contains(initialSourceID) { return initialSourceID }
        return store.sources.first?.id ?? store.readingSources.first?.id
    }
    private var selected: LearnedCalendarSource? { store.sources.first { $0.id == resolvedID } }
    private var selectedReading: LearnedReadingSource? { store.readingSources.first { $0.id == resolvedID } }
    private var savedWorkflows: [SavedReadingWorkflow] {
        store.savedReadingWorkflows.filter { workflow in !store.readingSources.contains { $0.id == workflow.draft.id } }
    }

    var body: some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isRunning && (readingDraft != nil || editing) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Reading sources. Editing will be available when the run ends.")
                                .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                            Spacer()
                            Button(isBatchRunning ? "Stop all" : "Stop", action: stop).buttonStyle(MorningActionButton())
                        }
                        if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(Pad.inkSoft) }
                    }.id("editor-running")
                }
                if let readingDraft {
                    ReadingSourceEditor(source: readingDraft, isRunning: isRunning, save: { source in
                        guard !isRunning else { throw CalendarDataError.invalid("Wait for the current reading to finish before saving changes.") }
                        try store.saveReadingSource(source)
                        selectedID = source.id
                        self.readingDraft = nil
                        feedback = "\(source.name) saved. Future reads will use these source details and reading rules."
                        removedForUndo = nil
                    }, cancel: { self.readingDraft = nil }).id(readingDraft.id)
                } else if editing, let selected {
                    CalendarSourceEditor(source: selected, isRunning: isRunning, save: { source in
                        guard !isRunning else { throw CalendarDataError.invalid("Wait for the current reading to finish before saving changes.") }
                        try store.saveSource(source)
                        editing = false
                        feedback = "\(source.name) saved. Future reads will use these source details."
                        removedForUndo = nil
                    }, cancel: { editing = false }).id(selected.id)
                } else {
                    introduction
                    CalendarBatchControls(sourceCount: sourceCount, isRunning: isRunning,
                                          isBatchRunning: isBatchRunning, status: status,
                                          runAll: { localError = nil; runAll() }, stop: stop)
                    if let feedback {
                        HStack(alignment: .top, spacing: 10) {
                            Text(feedback).font(.system(size: 12)).foregroundStyle(Pad.penInk)
                            Spacer(minLength: 8)
                            if let id = removedForUndo, store.removedSources.contains(where: { $0.id == id }) {
                                Button("Undo") { restoreSource(id) }.buttonStyle(MorningActionButton()).disabled(isRunning)
                            }
                        }.padding(12).background(Pad.paperTop.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    }
                    if sourceCount > 0 {
                        SourceManagementList(calendars: store.sources, readings: store.readingSources,
                                             selectedID: resolvedID, isRunning: isRunning, select: { id in
                            selectedID = id
                            localError = nil
                            withAnimation { reader.scrollTo("selected-source", anchor: .top) }
                        }, edit: editSource, remove: removeSource)
                    }
                    if !store.removedSources.isEmpty {
                        RemovedSourcesList(sources: store.removedSources, isRunning: isRunning, restore: restoreSource)
                    }
                    if !savedWorkflows.isEmpty { savedWorkflowList }
                    Divider()
                    if let selected {
                        sourceControls(selected).id("selected-source")
                        readControls(selected)
                    } else if let source = selectedReading {
                        readingSourceControls(source).id("selected-source")
                        readingControls(source)
                    }
                }
                if let message = localError ?? runError ?? store.error {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled)
                }
            }.padding(23)
        }
        .onAppear {
            if selectedID == nil { selectedID = initialSourceID }
            if initialSourceID != nil { reader.scrollTo("selected-source", anchor: .top) }
        }
        .onChange(of: initialSourceID) { _, value in
            selectedID = value
            editing = false
            readingDraft = nil
            if value != nil { reader.scrollTo("selected-source", anchor: .top) }
        }
        .onChange(of: readingDraft?.id) { _, value in
            if let value { reader.scrollTo(value, anchor: .top) }
            else { reader.scrollTo("selected-source", anchor: .top) }
        }
        .onChange(of: editing) { _, value in
            if value, let id = selected?.id { reader.scrollTo(id, anchor: .top) }
            else { reader.scrollTo("selected-source", anchor: .top) }
        }
        .onChange(of: isRunning) { _, value in
            if value && (readingDraft != nil || editing) { reader.scrollTo("editor-running", anchor: .top) }
        }
        }
    }

    private func editSource(_ id: UUID) {
        guard !isRunning else { return }
        selectedID = id
        localError = nil
        if let source = store.readingSources.first(where: { $0.id == id }) {
            readingDraft = source
        } else if store.sources.contains(where: { $0.id == id }) {
            editing = true
        }
    }

    private func removeSource(_ id: UUID) {
        guard !isRunning else { return }
        let name = store.sources.first(where: { $0.id == id })?.name
            ?? store.readingSources.first(where: { $0.id == id })?.name ?? "Source"
        do {
            try store.removeSource(id: id)
            selectedID = resolvedID
            localError = nil
            feedback = "\(name) removed from future runs. You can restore it with its saved collections."
            removedForUndo = id
        } catch { localError = error.localizedDescription }
    }

    private func restoreSource(_ id: UUID) {
        guard !isRunning else { return }
        let name = store.removedSources.first(where: { $0.id == id })?.name ?? "Source"
        do {
            try store.restoreSource(id: id)
            selectedID = id
            localError = nil
            feedback = "\(name) restored with its saved collections."
            removedForUndo = nil
        } catch { localError = error.localizedDescription }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources Noteling understands.").font(HandFont.font(size: 24))
            Text("Show Noteling a calendar, inbox, or web page. Explain what it means, which information to collect, and how to recognize when the reading is complete.")
                .font(.system(size: 13)).foregroundStyle(Pad.inkSoft).fixedSize(horizontal: false, vertical: true)
            Button("Teach a source with Watch Me", action: teach)
                .buttonStyle(MorningActionButton(primary: sourceCount == 0)).disabled(isRunning)
            if sourceCount == 0 {
                Text("Review and keep what Noteling learned in chat. Your source will appear here afterward.")
                    .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
            }
        }
    }

    private func sourcePicker(_ fallbackID: UUID) -> some View {
        Picker("Source", selection: Binding(get: { resolvedID ?? fallbackID }, set: {
            selectedID = $0
            localError = nil
        })) {
            ForEach(store.sources) { Text("\($0.name) · Calendar").tag($0.id) }
            ForEach(store.readingSources) { Text("\($0.name) · \($0.kind == .mail ? "Mail" : "Web")").tag($0.id) }
        }.disabled(isRunning)
    }

    private var savedWorkflowList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved reading workflows").font(.system(size: 13, weight: .semibold))
            Text("These demonstrations are not in your source list yet. Review the page and reading scope before adding one.")
                .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
            ForEach(savedWorkflows) { workflow in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workflow.name).font(.system(size: 13, weight: .medium))
                            Text(workflow.draft.meaning).font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                        }
                        Spacer(minLength: 10)
                        Button("Review & add") { readingDraft = workflow.draft; localError = nil }
                            .buttonStyle(MorningActionButton()).disabled(isRunning)
                    }
                    Label("Needs review before reading", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(Pad.redInk)
                    if !workflow.draft.uncertainties.isEmpty {
                        Text(workflow.draft.uncertainties.joined(separator: " "))
                            .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                    }
                }.padding(12).background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func readingSourceControls(_ source: LearnedReadingSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sourcePicker(source.id)
                Button(source.requiresReview ? "Review source" : "Edit source") { editSource(source.id) }
                    .buttonStyle(.plain).foregroundStyle(Pad.penInk).disabled(isRunning)
            }.font(.system(size: 12))
            Text(source.meaning).font(.system(size: 14)).textSelection(.enabled)
            Text([source.application, source.account].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
            if !source.url.isEmpty { sourceLink(source.url, title: "Open source") }
            if source.requiresReview {
                Label("Needs review: confirm the source address and what to collect before reading.", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(Pad.redInk)
            }
            if !source.uncertainties.isEmpty {
                Text("Still to confirm: " + source.uncertainties.joined(separator: " "))
                    .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(Pad.paperTop.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func readingControls(_ source: LearnedReadingSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reading rules").font(.system(size: 13, weight: .semibold))
            Text(source.scope).font(.system(size: 13)).textSelection(.enabled)
            Text("Use Edit source to describe what to collect and where to stop. Noteling uses these instructions during each read.")
                .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
            if source.account.isEmpty && !source.url.isEmpty {
                Text("Uses the account currently shown at this address. Noteling verifies the visible account during each read.")
                    .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
            }
            HStack {
                Button("Read source") {
                    do {
                        try source.validateForRead()
                        localError = nil
                        collectReading(source)
                    } catch { localError = error.localizedDescription }
                }.buttonStyle(MorningActionButton(primary: true)).disabled(isRunning || source.requiresReview)
                if isRunning && !isBatchRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop", action: stop).buttonStyle(MorningActionButton())
                }
            }
            if !isBatchRunning, !status.isEmpty { Text(status).font(.system(size: 12)).foregroundStyle(Pad.inkSoft) }
        }
    }

    @ViewBuilder private func sourceLink(_ value: String, title: String) -> some View {
        if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            Link(title, destination: url).font(.system(size: 12))
        }
    }

    private func sourceControls(_ source: LearnedCalendarSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sourcePicker(source.id)
                Button("Edit source") { editSource(source.id) }
                    .buttonStyle(.plain).foregroundStyle(Pad.penInk).disabled(isRunning)
            }.font(.system(size: 12))
            Text(source.meaning).font(.system(size: 14)).textSelection(.enabled)
            Text([source.application, source.account, source.calendarName].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
            if !source.uncertainties.isEmpty {
                Text("Still to confirm: " + source.uncertainties.joined(separator: " "))
                    .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(Pad.paperTop.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func readControls(_ source: LearnedCalendarSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read one source on a chosen day").font(.system(size: 13, weight: .semibold))
            DatePicker("Read this day", selection: $day, displayedComponents: .date)
                .environment(\.timeZone, TimeZone(identifier: source.timeZoneID) ?? .current)
                .disabled(isRunning)
            HStack {
                Picker("From", selection: $startHour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Picker("Until", selection: $endHour) {
                    ForEach(1...24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
            }.disabled(isRunning)
            Text(source.timeZoneID.isEmpty ? "Review the source to confirm its time zone, account, and calendar before reading." : "Briefing window in \(source.timeZoneID). Open time refers only to this calendar.")
                .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
            HStack {
                Button("Read calendar") {
                    let request = CalendarReadRequest(source: source, day: day, startHour: startHour, endHour: endHour)
                    do {
                        try request.validate()
                        localError = nil
                        collect(source, day, startHour, endHour)
                    } catch { localError = error.localizedDescription }
                }.buttonStyle(MorningActionButton(primary: true)).disabled(isRunning)
                if isRunning && !isBatchRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop", action: stop).buttonStyle(MorningActionButton())
                }
            }
            if !isBatchRunning, !status.isEmpty { Text(status).font(.system(size: 12)).foregroundStyle(Pad.inkSoft) }
        }.font(.system(size: 13))
    }


}

struct ReadingSourceEditor: View {
    @State private var draft: LearnedReadingSource
    @State private var error: String?
    var isRunning: Bool
    let save: (LearnedReadingSource) throws -> Void
    let cancel: () -> Void

    init(source: LearnedReadingSource, isRunning: Bool = false,
         save: @escaping (LearnedReadingSource) throws -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: source)
        self.isRunning = isRunning
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(draft.requiresReview ? "Review source" : "Edit source").font(HandFont.font(size: 23))
            Text(draft.kind == .mail ? "Mail source" : "Web source").font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
            if draft.requiresReview {
                Label("Review the address, account and scope before enabling this source.", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(Pad.redInk)
            }
            field("Source name", text: $draft.name)
            field("Meaning", text: $draft.meaning)
            Text("Why this source matters to you. Keep this context separate from the reading rules below.")
                .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
            field("Application", text: $draft.application)
            DisclosureGroup("Application details") {
                field("Native app identifier", text: $draft.bundleID)
            }.font(.system(size: 12))
            field("Exact source address (if used)", text: $draft.url)
            field("Account shown in the app (optional with an exact address)", text: $draft.account)
            Text("If you leave the account blank, Noteling reads only the account currently shown at this address and verifies it each time.")
                .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
            notes("Reading rules", text: $draft.scope)
            Text("Describe what to collect and where to stop, using the views and information this source makes available. These instructions guide future reads.")
                .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
            notes("How to recognize and read this source", text: $draft.navigationHints)
            notes("How to know the reading is complete", text: $draft.completionChecks)
            notes("Remaining uncertainties", text: Binding(get: { draft.uncertainties.joined(separator: "\n") }, set: {
                draft.uncertainties = $0.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Pad.redInk) }
            HStack {
                Button("Cancel", action: cancel).buttonStyle(MorningActionButton())
                Spacer()
                Button(draft.requiresReview ? "Confirm & add source" : "Save source") {
                    guard !isRunning else { return }
                    do {
                        var confirmed = draft
                        confirmed.requiresReview = false
                        try confirmed.validateForRead()
                        try save(confirmed)
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(MorningActionButton(primary: true))
            }
        }.disabled(isRunning)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextField(title, text: text).textFieldStyle(.roundedBorder).font(.system(size: 13))
        }
    }

    private func notes(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextEditor(text: text).font(.system(size: 12)).frame(minHeight: 65)
                .scrollContentBackground(.hidden).padding(6)
                .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 5)).accessibilityLabel(title)
        }
    }
}

struct CalendarSourceEditor: View {
    @State private var draft: LearnedCalendarSource
    @State private var error: String?
    var isRunning: Bool
    let save: (LearnedCalendarSource) throws -> Void
    let cancel: () -> Void

    init(source: LearnedCalendarSource, isRunning: Bool = false,
         save: @escaping (LearnedCalendarSource) throws -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: source)
        self.isRunning = isRunning
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Edit calendar source").font(HandFont.font(size: 23))
            field("Source name", text: $draft.name)
            field("Meaning", text: $draft.meaning)
            field("Application", text: $draft.application)
            DisclosureGroup("Application details") {
                field("Native app identifier", text: $draft.bundleID)
                Text("The app identity observed during teaching, such as com.microsoft.Outlook. Keep it consistent with the application above; browser calendars can use their page address.")
                    .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
            }.font(.system(size: 12))
            field("Account shown in the app", text: $draft.account)
            field("Calendar name", text: $draft.calendarName)
            field("Time zone", text: $draft.timeZoneID)
            Text("Use the calendar’s time zone, for example America/New_York or Europe/London. Your Mac uses \(TimeZone.current.identifier).")
                .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
            field("Calendar page (if used)", text: $draft.url)
            notes("How to recognize and read the calendar", text: $draft.navigationHints)
            notes("How to know a day is completely read", text: $draft.completionChecks)
            notes("Remaining uncertainties", text: Binding(get: { draft.uncertainties.joined(separator: "\n") }, set: {
                draft.uncertainties = $0.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Pad.redInk) }
            HStack {
                Button("Cancel", action: cancel).buttonStyle(MorningActionButton())
                Spacer()
                Button("Save source") {
                    guard !isRunning else { return }
                    do { try save(draft) } catch { self.error = error.localizedDescription }
                }.buttonStyle(MorningActionButton(primary: true))
            }
        }.disabled(isRunning)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextField(title, text: text).textFieldStyle(.roundedBorder).font(.system(size: 13))
        }
    }

    private func notes(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextEditor(text: text).font(.system(size: 12)).frame(minHeight: 75)
                .scrollContentBackground(.hidden).padding(6)
                .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 5)).accessibilityLabel(title)
        }
    }
}
