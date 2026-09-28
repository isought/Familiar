import SwiftUI

@MainActor final class MorningNavigation: ObservableObject {
    enum Route: Equatable {
        case folders, folder(UUID), card(UUID), people, person(UUID), editPerson(UUID?), editCard(UUID?), editFolder(UUID?)
    }
    @Published var route: Route = .folders
    @Published var disposition: MorningCardDisposition = .unreviewed
    @Published var newCardFolderID: UUID?
}

struct MorningLauncherView: View {
    @ObservedObject var store: MorningStore
    let open: () -> Void
    let people: () -> Void
    private var count: Int { store.cards.filter { $0.disposition == .unreviewed }.count }
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
    @State private var localError: String?
    @State private var undo: MorningCard?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Pad.tabEdge.opacity(0.35))
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
        case .folder(let id): return store.folders.first { $0.id == id }?.name ?? "Folder"
        case .card: return "On your desk"
        case .people, .person: return "Who’s Who"
        case .editPerson(let id): return id == nil ? "Someone you work with" : "Edit person"
        case .editCard(let id): return id == nil ? "A new note" : "Edit note"
        case .editFolder(let id): return id == nil ? "A new folder" : "Rename folder"
        }
    }

    @ViewBuilder private var content: some View {
        switch navigation.route {
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
                if store.cards.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your morning starts small.").font(HandFont.font(size: 24))
                        Text("Keep a note here, review what needs your attention, and decide what you’d like Familiar to help with.")
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
        let count = store.cards.filter { $0.disposition == navigation.disposition }.count
        return count == 0 ? "Nothing here to tend to." : "\(count) \(count == 1 ? "file" : "files"). Start wherever you like."
    }

    private var dispositionPicker: some View {
        Picker("Show files", selection: $navigation.disposition) {
            ForEach(MorningCardDisposition.allCases, id: \.self) { Text($0.label).tag($0) }
        }.labelsHidden().fixedSize().font(.system(size: 12)).accessibilityLabel("Show files by decision")
    }

    private func folderTile(_ folder: MorningFolder) -> some View {
        let count = store.cards.filter { $0.folderID == folder.id && $0.disposition == navigation.disposition }.count
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
        let cards = store.cards.filter { $0.folderID == id && $0.disposition == navigation.disposition }
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
                Text(card.title).font(HandFont.font(size: 20)).lineLimit(3).multilineTextAlignment(.leading)
                Text(card.summary.isEmpty ? card.sources.first?.excerpt ?? "Open to review the details." : card.summary)
                    .font(.system(size: 12)).lineSpacing(3).lineLimit(3).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading).foregroundStyle(Pad.inkSoft)
                Spacer(minLength: 0)
                if !card.timing.isEmpty { Label(card.timing, systemImage: "clock").font(.system(size: 11)).lineLimit(1).foregroundStyle(Pad.penInk) }
                let names = store.people.filter { card.personIDs.contains($0.id) }.map(\.name)
                if !names.isEmpty { Text(names.joined(separator: " · ")).font(.system(size: 11, weight: .medium)).lineLimit(1) }
            }.padding(18).frame(maxWidth: .infinity, minHeight: 225, maxHeight: 225, alignment: .topLeading)
                .background(Pad.fieldPaper, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Pad.tabEdge.opacity(0.55)))
                .shadow(color: Pad.ink.opacity(0.07), radius: 4, x: 1, y: 3)
        }.buttonStyle(.plain).accessibilityLabel("Open file: \(card.title)")
            .contextMenu { Button("Edit note") { navigation.route = .editCard(card.id) } }
    }

    private func cardDetail(_ card: MorningCard) -> some View {
        let pending = store.workItems.first { $0.cardID == card.id && $0.status.isPending }
        let history = store.workItems.filter { $0.cardID == card.id && !$0.status.isPending }.sorted { $0.createdAt > $1.createdAt }
        let hasRunAction = history.contains { $0.kind == .action }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(card.isSample ? "FICTIONAL SAMPLE" : card.disposition.label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Pad.inkSoft)
                        Spacer()
                        Button("Edit") { navigation.route = .editCard(card.id) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pad.penInk)
                    }
                    Text(card.title).font(HandFont.font(size: 27)).fixedSize(horizontal: false, vertical: true)
                    if !card.summary.isEmpty { Text(card.summary).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled) }
                    if !card.timing.isEmpty { Label(card.timing, systemImage: "clock").font(.system(size: 12)).foregroundStyle(Pad.penInk) }
                    if !card.personIDs.isEmpty { peopleLinks(card) }
                }
                if !card.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("The source", icon: "doc.text")
                        ForEach(card.sources) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text(source.title).font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Text(source.capturedAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.system(size: 10)).foregroundStyle(Pad.inkSoft)
                                }
                                Text(source.excerpt).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let url = URL(string: source.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                                    Link("Open original", destination: url).font(.system(size: 11)).foregroundStyle(Pad.penInk)
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(alignment: .leading) { Rectangle().fill(Pad.tabEdge).frame(width: 2).padding(.vertical, 10) }
                        }
                    }
                } else {
                    Text("No source excerpt is attached. Review the context before handing off work.").font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                }
                if !card.rationale.isEmpty { detailSection("Why this matters", icon: "lightbulb", text: card.rationale) }
                if !card.unknowns.isEmpty { detailSection("Still unclear", icon: "questionmark.circle", text: card.unknowns) }
                workResults(card)
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("What Familiar can do", icon: "sparkles")
                    Text(card.action.title).font(.system(size: 14, weight: .semibold))
                    Text(card.action.instruction).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    Text(card.action.mode == .prepare ? "Prepares a result from this file’s context. Doesn’t operate other apps." : "Works in your apps through the background task system. Existing input and action approvals still apply.")
                        .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Pad.paperTop.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                if let pending {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(pending.status.label, systemImage: "tray.and.arrow.down").font(.system(size: 13, weight: .medium))
                        if !pending.progress.isEmpty { Text(pending.progress).font(.system(size: 12)).foregroundStyle(Pad.inkSoft) }
                        if let message = store.queueMessage { Text(message).font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled) }
                        if pending.status == .queued { Button("Remove from queue") { perform { try store.cancelQueued(id: pending.id) } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pad.penInk) }
                    }
                } else {
                    if let previous = history.first, let warning = retryWarning(previous) {
                        Label(warning, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Pad.redInk).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 9) {
                        Button("Ignore") { decide(card, .ignored) }.buttonStyle(MorningActionButton())
                        Button(hasRunAction ? "Run again" : card.action.title) { enqueue(card, kind: .action) }.buttonStyle(MorningActionButton(primary: true))
                        Button("I’ll do it") { decide(card, .mine) }.buttonStyle(MorningActionButton())
                    }
                    if card.contextAction != nil {
                        Button { enqueue(card, kind: .context) } label: { Label("Help me understand first", systemImage: "questionmark.bubble") }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pad.penInk)
                    }
                    if card.disposition != .unreviewed {
                        Button("Return to review folder") { perform { try store.returnToFolder(cardID: card.id) }; navigation.disposition = .unreviewed }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
                    }
                }
            }.padding(23)
        }
    }

    private func retryWarning(_ work: MorningWorkItem) -> String? {
        switch work.status {
        case .interrupted: return "This work was interrupted. Check what happened and the result above before running it again."
        case .cancelled: return work.startedAt == nil ? "The previous handoff was removed before it started." : "This work was stopped. Review any changes already made before running it again."
        case .failed: return "The previous attempt couldn’t finish. Review its result before trying again."
        default: return nil
        }
    }

    private func peopleLinks(_ card: MorningCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.people.filter { card.personIDs.contains($0.id) }) { person in
                Button { navigation.route = .person(person.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                        Text(person.name).fontWeight(.medium)
                        if !person.relationship.isEmpty { Text("· \(person.relationship)").foregroundStyle(Pad.inkSoft) }
                        Image(systemName: "chevron.right").font(.system(size: 9))
                    }.font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(Pad.penInk)
            }
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
    private func back() {
        switch navigation.route {
        case .card(let id):
            if let card = store.cards.first(where: { $0.id == id }) {
                navigation.disposition = card.disposition
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
    private func enqueue(_ card: MorningCard, kind: MorningWorkKind) {
        perform {
            let item = try store.enqueue(cardID: card.id, kind: kind)
            undo = nil
            notice = kind == .context ? "Familiar will help clarify this file. Your decision stays open." : "Handed to Familiar. Progress and results stay with this file."
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
