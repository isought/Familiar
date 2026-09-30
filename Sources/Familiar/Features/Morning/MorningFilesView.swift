import SwiftUI

@MainActor final class MorningNavigation: ObservableObject {
    enum Route: Equatable {
        case folders, folder(UUID), card(UUID), people, person(UUID), editPerson(UUID?), editCard(UUID?), editFolder(UUID?), sources
        case sourceRuns, sourceRun(runID: UUID, sourceID: UUID?)
        case attention(AttentionScreen)
    }
    @Published var route: Route = .folders
    @Published var disposition: MorningCardDisposition = .unreviewed
    @Published var newCardFolderID: UUID?
    @Published var calendarSourceID: UUID?
}

struct MorningLauncherView: View {
    @ObservedObject var store: MorningStore
    let open: () -> Void
    let people: () -> Void
    private var count: Int { store.cards.filter { $0.displayDisposition == .unreviewed }.count }
    var body: some View {
        ZStack {
            WindowDragHandle(onClick: open)
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    MorningFolderDrawing().frame(width: 61, height: 46)
                    if count > 0 {
                        Text("\(count)").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .foregroundStyle(Pad.ink).background(Pad.fieldPaper, in: Capsule())
                            .offset(x: 3, y: -2)
                    }
                }
                Text("Morning").font(.system(size: 11, weight: .medium)).foregroundStyle(Pad.ink)
                    .padding(.horizontal, 6).padding(.vertical, 3).background(Pad.fieldPaper.opacity(0.92), in: Capsule())
            }.allowsHitTesting(false)
        }
        .frame(width: 86, height: 78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open morning folders, \(count) files to review")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .help("Click to open. Drag to move.")
        .contextMenu { Button("Open morning folders", action: open); Button("Who’s Who", action: people) }
    }
}

struct MorningFolderDrawing: View {
    var color: Color = Color(red: 0.87, green: 0.75, blue: 0.50)
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.92))
                    .frame(width: g.size.width * 0.43, height: g.size.height * 0.30)
                    .offset(x: -g.size.width * 0.25, y: -g.size.height * 0.66)
                RoundedRectangle(cornerRadius: 4).fill(color).frame(height: g.size.height * 0.82)
                RoundedRectangle(cornerRadius: 2).fill(Pad.fieldPaper).padding(.horizontal, 6)
                    .frame(height: g.size.height * 0.68).rotationEffect(.degrees(-4)).offset(y: -6)
                RoundedRectangle(cornerRadius: 2).fill(Pad.tabPaper).padding(.horizontal, 5)
                    .frame(height: g.size.height * 0.70).rotationEffect(.degrees(3)).offset(y: -2)
                RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [color.opacity(0.96), color], startPoint: .top, endPoint: .bottom))
                    .frame(height: g.size.height * 0.69)
                    .overlay(alignment: .top) { Color.white.opacity(0.35).frame(height: 1).padding(.horizontal, 5) }
            }
        }.shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 3)
    }
}

struct MorningFilesView: View {
    @ObservedObject var store: MorningStore
    @ObservedObject var navigation: MorningNavigation
    let close: () -> Void
    let filed: () -> Void
    let handoff: (MorningWorkItem) -> Void
    var calendarSources: CalendarStore? = nil
    var calendarRunner: CalendarCollectionRunner? = nil
    var teachCalendar: (() -> Void)? = nil
    var cardGeneration: CardGenerationService? = nil
    var discussCard: ((MorningCard) -> Void)? = nil
    var attention: AttentionLedger? = nil
    @State private var localError: String?
    @State private var showingOriginal: UUID?   // the card whose original text is expanded
    @State private var undo: MorningCard?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Pad.tabEdge.opacity(0.35))
            if let cardGeneration, showsGeneration {
                CardGenerationControls(service: cardGeneration, showCards: {
                    navigation.disposition = .unreviewed
                    navigation.route = .folders
                })
            }
            if let error = localError ?? store.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if localError != nil {
                        Button { localError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                    }
                }.font(.system(size: 12)).foregroundStyle(Pad.redInk).padding(12)
            }
            content
            if let notice {
                HStack {
                    Text(notice).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    if let undo { Button("Undo") { restore(undo) }.buttonStyle(.plain).foregroundStyle(Pad.penInk) }
                    Button { self.notice = nil; undo = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss receipt")
                }.padding(12).background(Pad.paperTop.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LinearGradient(colors: [Pad.tabPaper, Pad.fieldPaper], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Pad.tabEdge.opacity(0.6)))
        .foregroundStyle(Pad.ink)
        .environment(\.colorScheme, .light)
        .onExitCommand { if navigation.route == .folders { close() } else { navigation.route = .folders } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if navigation.route != .folders {
                Button { back() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).accessibilityLabel("Back")
            }
            WindowDragHandle()
                .overlay {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(Pad.inkSoft)
                        Text(heading).font(HandFont.font(size: 18)).lineLimit(1)
                        Spacer()
                    }.allowsHitTesting(false)
                }
                .frame(height: 24)
            Menu {
                if calendarSources != nil {
                    Button("Manage sources") { navigation.route = .sources }
                    Button("Run history") { navigation.route = .sourceRuns }
                }
                Button("Create a note") { createNote() }
                Button("Who’s Who") { navigation.route = .people }
                Button("Add folder") { navigation.route = .editFolder(nil) }
                Divider()
                Button("Try sample files") { perform { try store.loadSamples() }; navigation.route = .folders }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                .menuStyle(.borderlessButton).fixedSize().help("Morning folder options")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 12)) }.buttonStyle(.plain).accessibilityLabel("Close morning files")
        }.padding(.horizontal, 18).padding(.vertical, 15)
    }

    private var heading: String {
        switch navigation.route {
        case .folders: return "A little room for your day"
        case .sources: return "Manage sources"
        case .sourceRuns: return "Run history"
        case .sourceRun: return "Collected results"
        case .attention(let screen): return screen.heading
        case .folder(let id): return store.folders.first { $0.id == id }?.name ?? "Folder"
        case .card: return "On your desk"
        case .people, .person: return "Who’s Who"
        case .editPerson(let id): return id == nil ? "Someone you work with" : "Edit person"
        case .editCard(let id): return id == nil ? "A new note" : "Edit note"
        case .editFolder(let id): return id == nil ? "A new folder" : "Rename folder"
        }
    }

    private var showsGeneration: Bool {
        switch navigation.route { case .folders, .sourceRuns, .sourceRun: return true; default: return false }
    }

    @ViewBuilder private var content: some View {
        switch navigation.route {
        case .sources:
            if let calendarSources, let calendarRunner {
                CalendarSourcesHost(store: calendarSources, runner: calendarRunner, initialSourceID: navigation.calendarSourceID,
                                    teach: { teachCalendar?() }, openRun: openRun)
            } else { empty("Sources are unavailable.") }
        case .sourceRuns:
            if let calendarSources { SourceRunHistoryView(runs: calendarSources.runStore, openRun: openRun) }
            else { empty("Run history is unavailable.") }
        case .sourceRun(let runID, let sourceID):
            if let calendarSources, let calendarRunner {
                SourceRunResultsHost(store: calendarSources, runner: calendarRunner, runID: runID, sourceID: sourceID,
                    openRun: openRun, manageSource: { id in
                        navigation.calendarSourceID = id
                        navigation.route = .sources
                    })
            } else { empty("Run results are unavailable.") }
        case .attention(let screen):
            if let attention { AttentionScreenView(ledger: attention, store: store, navigation: navigation, screen: screen) } else { empty("The numbers are unavailable.") }
        case .folders: folders
        case .folder(let id): folder(id)
        case .card(let id):
            if let card = store.cards.first(where: { $0.id == id }) { cardDetail(card) }
            else { empty("This file is no longer here.") }
        case .people: people
        case .person(let id):
            if let person = store.people.first(where: { $0.id == id }) { personDetail(person) }
            else { empty("This person is no longer here.") }
        case .editPerson(let id):
            MorningPersonEditor(person: store.people.first { $0.id == id }, save: { person in
                try store.savePerson(person); navigation.route = .person(person.id)
            }, cancel: { navigation.route = .people }).id(id)
        case .editCard(let id):
            MorningCardEditor(card: store.cards.first { $0.id == id }, folders: store.folders, people: store.people, initialFolderID: navigation.newCardFolderID, save: { card in
                try store.saveCard(card); navigation.route = .card(card.id)
            }, cancel: { navigation.route = id.map { .card($0) } ?? .folders }).id(id)
        case .editFolder(let id):
            MorningFolderEditor(folder: store.folders.first { $0.id == id }, save: { folder in
                try store.saveFolder(folder); navigation.route = .folder(folder.id)
            }, cancel: { navigation.route = .folders }).id(id)
        }
    }

    private var folders: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let calendarSources, let calendarRunner {
                    CalendarBatchHost(store: calendarSources, runner: calendarRunner,
                                      openSources: { navigation.route = .sources }, openRun: openRun,
                                      openHistory: { navigation.route = .sourceRuns })
                } else if calendarSources != nil {
                    Button { navigation.route = .sources } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tray.full").font(.system(size: 23))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Read your sources").font(.system(size: 14, weight: .semibold))
                                Text("Teach Noteling where your information lives, then read it again.")
                                    .font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.padding(14).background(Pad.paperTop.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                if let attention {
                    AttentionDailyLine(ledger: attention, readsScript: { calendarSources?.readingSources.contains(where: \.readsThroughScript) == true },
                                       open: { navigation.route = .attention(.rest(day: $0)) })
                }
                if store.cards.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your morning starts small.").font(HandFont.font(size: 24))
                        Text("Keep a note here, review what needs your attention, and decide what you’d like Noteling to help with.")
                            .font(.system(size: 14)).foregroundStyle(Pad.inkSoft).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Create a note") { createNote() }.buttonStyle(MorningActionButton(primary: true))
                            Button("Try sample files") { perform { try store.loadSamples() } }.buttonStyle(MorningActionButton())
                        }.padding(.top, 5)
                        Text("Stored on this Mac. Samples are fictional; no inbox is connected.").font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                    }.padding(.top, 8)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(folderSubtitle).font(.system(size: 13)).foregroundStyle(Pad.inkSoft)
                        Spacer()
                        dispositionPicker
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 18)], alignment: .leading, spacing: 25) {
                    ForEach(store.folders) { item in folderTile(item) }
                }
                HStack {
                    Button { createNote() } label: { Label("New note", systemImage: "plus") }
                    Spacer()
                }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Pad.penInk)
            }.padding(22)
        }
    }

    private var folderSubtitle: String {
        let count = store.cards.filter { $0.displayDisposition == navigation.disposition }.count
        return count == 0 ? "Nothing here to tend to." : "\(count) \(count == 1 ? "file" : "files"). Start wherever you like."
    }

    private var dispositionPicker: some View {
        Picker("Show files", selection: $navigation.disposition) {
            ForEach(MorningCardDisposition.allCases, id: \.self) { Text($0.label).tag($0) }
        }.labelsHidden().fixedSize().font(.system(size: 12)).accessibilityLabel("Show files by decision")
    }

    private func folderTile(_ folder: MorningFolder) -> some View {
        let count = store.cards.filter { $0.folderID == folder.id && $0.displayDisposition == navigation.disposition }.count
        return Button { navigation.route = .folder(folder.id) } label: {
            VStack(alignment: .leading, spacing: 7) {
                MorningFolderDrawing().frame(height: 100).padding(.horizontal, 12)
                Text(folder.name).font(HandFont.font(size: 19)).lineLimit(2)
                Text("\(count) \(count == 1 ? "file" : "files")").font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(folder.name), \(count) files")
            .contextMenu { Button("Rename folder") { navigation.route = .editFolder(folder.id) }; Button("Create a note") { createNote(folderID: folder.id) } }
    }

    private func folder(_ id: UUID) -> some View {
        let cards = store.cards.filter { $0.folderID == id && $0.displayDisposition == navigation.disposition }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Pick up a file. Put it back whenever you like.").font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                    Spacer(); dispositionPicker
                }
                if cards.isEmpty {
                    Text("No \(navigation.disposition.label.lowercased()) files in this folder.")
                        .font(.system(size: 14)).foregroundStyle(Pad.inkSoft).padding(.vertical, 35)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 17)], alignment: .leading, spacing: 20) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        fileTile(card).rotationEffect(.degrees(index.isMultiple(of: 2) ? -0.7 : 0.7))
                    }
                }
                HStack {
                    Button { createNote(folderID: id) } label: { Label("Add a note", systemImage: "plus") }
                    Spacer()
                    Button("Rename folder") { navigation.route = .editFolder(id) }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pad.penInk)
            }.padding(22)
        }
    }

    private func fileTile(_ card: MorningCard) -> some View {
        Button { navigation.route = .card(card.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(card.isSample ? "SAMPLE FILE" : card.sources.first?.kind.uppercased() ?? "NOTE")
                        .font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Pad.inkSoft)
                    Spacer()
                    Image(systemName: "paperclip").foregroundStyle(Pad.inkSoft)
                }
                Text(card.title).font(HandFont.font(size: 20)).lineLimit(2).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                if !card.meaning.isEmpty {
                    Text(card.meaning).font(.system(size: 12)).lineSpacing(3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading).foregroundStyle(Pad.inkSoft)
                }
                if let tracking = card.tracking {
                    Text(card.isResolved ? "Resolved" : Calendar.current.isDateInToday(tracking.firstSeenAt) ? "New today" : "Carried forward")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Pad.penInk)
                }
                Spacer(minLength: 0)
            }.padding(18).frame(maxWidth: .infinity, minHeight: 200, maxHeight: 200, alignment: .topLeading)
                .background(Pad.fieldPaper, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Pad.tabEdge.opacity(0.55)))
                .shadow(color: Pad.ink.opacity(0.07), radius: 4, x: 1, y: 3)
        }.buttonStyle(.plain).accessibilityLabel("Open file: \(card.title)")
            .contextMenu { Button("Edit note") { navigation.route = .editCard(card.id) } }
    }

    /// A card is three things: what it is, what it means for you, and what you can do. The original stays one tap away.
    private func cardDetail(_ card: MorningCard) -> some View {
        let pending = store.workItems.first { $0.cardID == card.id && $0.status.isPending }
        let history = store.workItems.filter { $0.cardID == card.id && !$0.status.isPending }.sorted { $0.createdAt > $1.createdAt }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(card.isSample ? "FICTIONAL SAMPLE" : card.displayDisposition.label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Pad.inkSoft)
                        Spacer()
                        if let attention { AttentionThumbs(ledger: attention, card: card) }
                        Menu {
                            Button("Edit") { navigation.route = .editCard(card.id) }
                            if let discussCard { Button("Discuss or adjust") { discussCard(card) }.disabled(pending != nil) }
                            if let attention { AttentionExplainMenuItem(ledger: attention, card: card) }
                            if card.disposition != .unreviewed {
                                Button("Return to review folder") {
                                    perform { try store.returnToFolder(cardID: card.id); navigation.disposition = .unreviewed }
                                }.disabled(pending != nil)
                            }
                        } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Pad.penInk) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More for this file")
                    }
                    Text(card.title).font(HandFont.font(size: 27)).fixedSize(horizontal: false, vertical: true)
                    if !card.meaning.isEmpty {
                        Text(card.meaning).font(.system(size: 15)).lineSpacing(4).lineLimit(4).textSelection(.enabled)
                    }
                    if let context = card.personalContext, !context.isEmpty {
                        Label(context, systemImage: "person.bubble").font(.system(size: 12)).lineLimit(2)
                            .foregroundStyle(Pad.inkSoft).help(context).accessibilityLabel("Your note: \(context)")
                    }
                    if let attention { AttentionExplainSlot(ledger: attention, card: card) }
                    if card.isResolved, let evidence = card.tracking?.resolutionEvidence, !evidence.isEmpty {
                        Label(evidence, systemImage: "checkmark.circle").font(.system(size: 12)).lineLimit(2).foregroundStyle(Pad.inkSoft)
                    }
                }
                if let pending {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("\(pending.status.label): \(pending.action.title)", systemImage: "tray.and.arrow.down").font(.system(size: 13, weight: .medium))
                        if !pending.progress.isEmpty { Text(pending.progress).font(.system(size: 12)).foregroundStyle(Pad.inkSoft) }
                        if let message = store.queueMessage { Text(message).font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled) }
                        if pending.status == .queued { Button("Remove from queue") { perform { try store.cancelQueued(id: pending.id) } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pad.penInk) }
                    }
                } else if card.isResolved {
                    Button("Reopen this card") { perform { try store.setCardResolution(cardID: card.id, resolved: false) } }
                        .buttonStyle(MorningActionButton())
                } else {
                    if let previous = history.first, let warning = retryWarning(previous) {
                        Label(warning, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Pad.redInk).fixedSize(horizontal: false, vertical: true)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 9) { optionButtons(card, history: history) }
                        VStack(alignment: .leading, spacing: 8) { optionButtons(card, history: history) }
                    }
                    HStack(spacing: 16) {
                        Button("I’ll do it") { decide(card, .mine) }
                        Button("Ignore") { decide(card, .ignored) }
                        Button("I’ve handled this") { perform { try store.setCardResolution(cardID: card.id, resolved: true) } }
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pad.penInk)
                }
                originalLink(card)
                workResults(card)
            }.padding(23)
        }.task(id: card.id) { attention?.cardOpened(card) }
    }

    /// The card's options, best first; the first is the primary button. An option that works in your apps is marked, and
    /// every option shows what it will do on hover.
    @ViewBuilder private func optionButtons(_ card: MorningCard, history: [MorningWorkItem]) -> some View {
        ForEach(Array(card.options.enumerated()), id: \.element.id) { index, option in
            let ran = Self.hasRun(option, in: history)
            let title = ran ? "\(option.title) again" : option.title
            Button { enqueue(card, kind: .action, optionID: option.id) } label: {
                if option.mode == .desktop { Label(title, systemImage: "macwindow") } else { Text(title) }
            }
            .buttonStyle(MorningActionButton(primary: index == 0))
            .help(option.mode == .desktop ? "Works in your apps: \(option.instruction)" : option.instruction)
            .accessibilityHint(option.mode == .desktop ? "Works in your apps" : "Prepares a result here")
        }
        if let context = card.contextAction {
            Button(context.title) { enqueue(card, kind: .context) }.buttonStyle(MorningActionButton())
        }
    }

    /// An option counts as run once work on it actually started, not when it was removed from the queue first.
    static func hasRun(_ option: MorningAction, in history: [MorningWorkItem]) -> Bool {
        history.contains { $0.kind == .action && $0.action.id == option.id && $0.startedAt != nil }
    }

    /// The original item, one tap away: its page when it has one, otherwise the text Noteling read.
    @ViewBuilder private func originalLink(_ card: MorningCard) -> some View {
        let page = card.sources.lazy.compactMap { URL(string: $0.url) }.first { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
        let hasText = card.sources.contains { !$0.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let shown = showingOriginal == card.id
        if page != nil || hasText {
            HStack(spacing: 16) {
                if hasText {
                    Button { showingOriginal = shown ? nil : card.id } label: {
                        Label(shown ? "Hide original" : "Show original", systemImage: "doc.text")
                    }.buttonStyle(.plain)
                }
                if let page { Link(destination: page) { Label("Open original", systemImage: "arrow.up.right.square") } }
            }.font(.system(size: 12)).foregroundStyle(Pad.penInk)
            if shown { sourceEvidence(card) }
        }
    }

    private func sourceEvidence(_ card: MorningCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(card.sources) { source in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text(source.title).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(source.capturedAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 10)).foregroundStyle(Pad.inkSoft)
                    }
                    // What was read, then what Noteling saw it by, quieter.
                    let parts = source.excerpt.components(separatedBy: "\nVisible evidence: ")
                    Text(parts[0]).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if parts.count > 1 {
                        Text(parts.dropFirst().joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .leading) { Rectangle().fill(Pad.tabEdge).frame(width: 2).padding(.vertical, 10) }
            }
        }
    }

    private func retryWarning(_ work: MorningWorkItem) -> String? {
        switch work.status {
        case .interrupted: return "This work was interrupted. Check what happened and its result below before running it again."
        case .cancelled: return work.startedAt == nil ? "The previous handoff was removed before it started." : "This work was stopped. Review any changes already made before running it again."
        case .failed: return "The previous attempt couldn’t finish. Review its result before trying again."
        default: return nil
        }
    }


    @ViewBuilder private func workResults(_ card: MorningCard) -> some View {
        let results = store.workItems.filter { $0.cardID == card.id && !$0.status.isPending }.sorted { $0.createdAt > $1.createdAt }
        if !results.isEmpty {
            Divider()
            sectionLabel("Work on this file", icon: "tray.full")
            ForEach(results) { work in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(work.action.title).font(.system(size: 13, weight: .semibold)); Spacer(); Text(work.status.label).font(.system(size: 11)).foregroundStyle(Pad.inkSoft) }
                    if !work.result.isEmpty { TaskResultText(text: work.result).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled) }
                    else if work.status == .cancelled { Text(work.startedAt == nil ? "Removed from the queue before starting." : "Stopped. Check the target app before repeating work.").font(.system(size: 12)).foregroundStyle(Pad.inkSoft) }
                    Text(work.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 10)).foregroundStyle(Pad.inkSoft)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var people: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("The people behind your work.").font(HandFont.font(size: 23))
                Text("Roles, relationships, and the context you’d want a helpful colleague to know. You can correct these at any time.")
                    .font(.system(size: 13)).foregroundStyle(Pad.inkSoft)
                Button { navigation.route = .editPerson(nil) } label: { Label("Add a person", systemImage: "plus") }.buttonStyle(MorningActionButton(primary: true))
                ForEach(store.people) { person in
                    Button { navigation.route = .person(person.id) } label: {
                        HStack(spacing: 12) {
                            Text(String(person.name.prefix(1)).uppercased()).font(HandFont.font(size: 21)).frame(width: 38, height: 38).background(Pad.paperTop, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.name + (person.isMe ? " · me" : "")).font(.system(size: 14, weight: .medium))
                                Text([person.role, person.relationship].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                        }.padding(12).background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).contextMenu { Button("Edit person") { navigation.route = .editPerson(person.id) } }
                }
                if store.people.isEmpty { Text("Start with yourself, then add someone you work with.").font(.system(size: 13)).foregroundStyle(Pad.inkSoft).padding(.top, 15) }
            }.padding(22)
        }
    }

    private func personDetail(_ person: MorningPerson) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(person.name).font(HandFont.font(size: 28))
                    if person.isMe { Text("YOU").font(.system(size: 10, weight: .semibold)).padding(5).background(Pad.paperTop, in: Capsule()) }
                    Spacer()
                    Button("Edit") { navigation.route = .editPerson(person.id) }.buttonStyle(MorningActionButton())
                }
                if !person.role.isEmpty { detailSection("Role & team", icon: "building.2", text: person.role) }
                if !person.relationship.isEmpty { detailSection("Relationship to you", icon: "person.2", text: person.relationship) }
                if !person.context.isEmpty { detailSection("Working context", icon: "note.text", text: person.context) }
                if !person.identities.isEmpty { detailSection("Names & identities across tools", icon: "at", text: person.identities.joined(separator: "\n")) }
                let cards = store.cards.filter { $0.personIDs.contains(person.id) }
                if !cards.isEmpty {
                    sectionLabel("Related files", icon: "folder")
                    ForEach(cards) { card in Button(card.title) { navigation.route = .card(card.id) }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Pad.penInk) }
                }
            }.padding(23)
        }
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pad.inkSoft)
    }
    private func detailSection(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { sectionLabel(title, icon: icon); Text(text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled) }
    }
    private func empty(_ title: String) -> some View { Text(title).font(.system(size: 14)).foregroundStyle(Pad.inkSoft).padding(24) }
    private func openRun(_ runID: UUID, _ sourceID: UUID?) {
        navigation.route = .sourceRun(runID: runID, sourceID: sourceID)
    }
    func back() {
        switch navigation.route {
        case .sourceRun: navigation.route = .sourceRuns
        case .card(let id):
            if let card = store.cards.first(where: { $0.id == id }) {
                navigation.disposition = card.displayDisposition
                navigation.route = .folder(card.folderID)
            } else { navigation.route = .folders }
        case .person, .editPerson: navigation.route = .people
        default: navigation.route = .folders
        }
    }
    private func createNote(folderID: UUID? = nil) {
        if let folderID { navigation.newCardFolderID = folderID }
        else if case .folder(let id) = navigation.route { navigation.newCardFolderID = id }
        else { navigation.newCardFolderID = nil }
        navigation.route = .editCard(nil)
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); localError = nil } catch { localError = error.localizedDescription }
    }
    private func decide(_ card: MorningCard, _ disposition: MorningCardDisposition) {
        perform {
            try store.setDisposition(cardID: card.id, to: disposition)
            undo = [.unreviewed, .ignored, .mine].contains(card.disposition) ? card : nil
            notice = disposition == .ignored ? "Filed away. You can find it under Filed away." : "Kept for you under I’ll handle it."
            navigation.route = .folder(card.folderID)
            filed()
        }
    }
    private func restore(_ card: MorningCard) {
        perform { try store.setDisposition(cardID: card.id, to: card.disposition); navigation.disposition = card.disposition; navigation.route = .card(card.id); notice = nil; undo = nil }
    }
    private func enqueue(_ card: MorningCard, kind: MorningWorkKind, optionID: UUID? = nil) {
        perform {
            let item = try store.enqueue(cardID: card.id, kind: kind, optionID: optionID)
            undo = nil
            notice = kind == .context ? "Noteling will help clarify this file. Your decision stays open." : "Handed to Noteling. Progress and results stay with this file."
            if kind == .action { navigation.route = .folder(card.folderID) }
            handoff(item)
        }
    }
}

struct MorningActionButton: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .foregroundStyle(primary ? Color.white : Pad.ink)
            .background(primary ? Pad.penInk : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? Color.clear : Pad.tabEdge.opacity(0.7)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
