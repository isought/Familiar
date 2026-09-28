import SwiftUI

struct MorningPersonEditor: View {
    private let existingID: UUID
    let save: (MorningPerson) throws -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var role: String
    @State private var relationship: String
    @State private var context: String
    @State private var identities: String
    @State private var isMe: Bool
    @State private var error: String?

    init(person: MorningPerson?, save: @escaping (MorningPerson) throws -> Void, cancel: @escaping () -> Void) {
        existingID = person?.id ?? UUID()
        self.save = save; self.cancel = cancel
        _name = State(initialValue: person?.name ?? "")
        _role = State(initialValue: person?.role ?? "")
        _relationship = State(initialValue: person?.relationship ?? "")
        _context = State(initialValue: person?.context ?? "")
        _identities = State(initialValue: person?.identities.joined(separator: "\n") ?? "")
        _isMe = State(initialValue: person?.isMe ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                MorningField("Name", text: $name, placeholder: "Maya Chen")
                Toggle("This is me", isOn: $isMe).font(.system(size: 13))
                MorningField("Role & team", text: $role, placeholder: "Product lead · platform team")
                MorningField("Relationship to you", text: $relationship, placeholder: "My project partner")
                MorningTextField("Working context", text: $context, hint: "Shared projects, responsibilities, commitments, or anything Familiar should understand.", minHeight: 95)
                MorningTextField("Names & identities across tools", text: $identities, hint: "One per line, for example an email address, Jira username, or nickname.", minHeight: 72)
                Text("You control this context. Familiar uses it when you hand over a linked file.").font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                MorningEditorFooter(error: error, saveTitle: "Save person", enabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, save: {
                    do {
                        try save(MorningPerson(id: existingID, name: name, role: role, relationship: relationship, context: context,
                                               identities: identities.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, isMe: isMe))
                    } catch { self.error = error.localizedDescription }
                }, cancel: cancel)
            }.padding(23)
        }
    }
}

struct MorningFolderEditor: View {
    private let existingID: UUID
    let save: (MorningFolder) throws -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var error: String?
    init(folder: MorningFolder?, save: @escaping (MorningFolder) throws -> Void, cancel: @escaping () -> Void) {
        existingID = folder?.id ?? UUID()
        self.save = save; self.cancel = cancel
        _name = State(initialValue: folder?.name ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MorningField("Folder name", text: $name, placeholder: "Customer follow-ups")
            MorningEditorFooter(error: error, saveTitle: "Save folder", enabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, save: {
                do { try save(MorningFolder(id: existingID, name: name)) } catch { self.error = error.localizedDescription }
            }, cancel: cancel)
            Spacer()
        }.padding(23)
    }
}

struct MorningCardEditor: View {
    private let original: MorningCard?
    private let existingID: UUID
    let folders: [MorningFolder]
    let people: [MorningPerson]
    let save: (MorningCard) throws -> Void
    let cancel: () -> Void
    @State private var folderID: UUID
    @State private var title: String
    @State private var summary: String
    @State private var sourceTitle: String
    @State private var sourceKind: String
    @State private var sourceExcerpt: String
    @State private var sourceURL: String
    @State private var sourceDate: Date
    @State private var personIDs: Set<UUID>
    @State private var rationale: String
    @State private var unknowns: String
    @State private var timing: String
    @State private var actionTitle: String
    @State private var instruction: String
    @State private var mode: MorningActionMode
    @State private var error: String?
    @State private var moreDetails = false

    init(card: MorningCard?, folders: [MorningFolder], people: [MorningPerson], initialFolderID: UUID? = nil, save: @escaping (MorningCard) throws -> Void, cancel: @escaping () -> Void) {
        original = card; existingID = card?.id ?? UUID()
        self.folders = folders; self.people = people; self.save = save; self.cancel = cancel
        _folderID = State(initialValue: card?.folderID ?? initialFolderID ?? folders.first?.id ?? UUID())
        _title = State(initialValue: card?.title ?? "")
        _summary = State(initialValue: card?.summary ?? "")
        _sourceTitle = State(initialValue: card?.sources.first?.title ?? "Personal note")
        _sourceKind = State(initialValue: card?.sources.first?.kind ?? "Personal note")
        _sourceExcerpt = State(initialValue: card?.sources.first?.excerpt ?? "")
        _sourceURL = State(initialValue: card?.sources.first?.url ?? "")
        _sourceDate = State(initialValue: card?.sources.first?.capturedAt ?? Date())
        _personIDs = State(initialValue: Set(card?.personIDs ?? []))
        _rationale = State(initialValue: card?.rationale ?? "")
        _unknowns = State(initialValue: card?.unknowns ?? "")
        _timing = State(initialValue: card?.timing ?? "")
        _actionTitle = State(initialValue: card?.action.title ?? "Prepare next steps")
        _instruction = State(initialValue: card?.action.instruction ?? "Use the attached context to prepare useful next steps. Identify anything that still needs clarification.")
        _mode = State(initialValue: card?.action.mode ?? .prepare)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MorningField("Title", text: $title, placeholder: "A short, useful heading")
                Picker("Folder", selection: $folderID) { ForEach(folders) { Text($0.name).tag($0.id) } }.font(.system(size: 13))
                MorningTextField("A little context", text: $summary, hint: "What happened? What should you remember when you come back to this?", minHeight: 65)
                MorningTextField("Original message or source note", text: $sourceExcerpt, hint: "Paste the relevant evidence so you can make an informed decision later.", minHeight: 110)
                if !people.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("People involved").font(.system(size: 12, weight: .semibold)).foregroundStyle(Pad.inkSoft)
                        ForEach(people) { person in
                            Toggle(person.name + (person.isMe ? " · me" : ""), isOn: Binding(get: { personIDs.contains(person.id) }, set: { selected in
                                if selected { personIDs.insert(person.id) } else { personIDs.remove(person.id) }
                            })).font(.system(size: 12))
                        }
                    }
                }
                DisclosureGroup("Source details, reasoning & timing", isExpanded: $moreDetails) {
                    VStack(alignment: .leading, spacing: 15) {
                        MorningField("Source title", text: $sourceTitle, placeholder: "Subject or document name")
                        MorningField("Source type", text: $sourceKind, placeholder: "Email, Jira, personal note…")
                        MorningField("Original link (optional)", text: $sourceURL, placeholder: "https://…")
                        DatePicker("Recorded", selection: $sourceDate).font(.system(size: 12))
                        MorningTextField("Why this matters", text: $rationale, hint: "A commitment, relationship, dependency, or other reason to pay attention.", minHeight: 65)
                        MorningTextField("Still unclear", text: $unknowns, hint: "What is missing before you can decide?", minHeight: 65)
                        MorningField("Timing", text: $timing, placeholder: "For example, review before Friday")
                    }.padding(.top, 13)
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(Pad.inkSoft)
                Divider()
                Text("A useful handoff").font(HandFont.font(size: 20))
                MorningField("Action label", text: $actionTitle, placeholder: "Draft a reply")
                MorningTextField("What Familiar should do", text: $instruction, hint: "Be specific about the result you want and the scope of the work.", minHeight: 85)
                Picker("How to work", selection: $mode) { ForEach(availableModes, id: \.self) { Text($0.label).tag($0) } }.font(.system(size: 12)).disabled(original?.isSample == true)
                if original?.isSample == true { Text("Fictional sample files prepare local results only.").font(.system(size: 11)).foregroundStyle(Pad.inkSoft) }
                Text(mode == .prepare ? "Prepare uses the context attached to this file. It won’t read your inbox, browse, or operate another app." : "Work in an app uses the existing background executor. Familiar may need input access or a separate action approval.")
                    .font(.system(size: 11)).foregroundStyle(Pad.inkSoft)
                MorningEditorFooter(error: error, saveTitle: "Save note", enabled: canSave, save: saveNote, cancel: cancel)
            }.padding(23)
        }
    }

    private var availableModes: [MorningActionMode] { original?.isSample == true ? [.prepare] : MorningActionMode.allCases }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !actionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folders.isEmpty
    }

    private func saveNote() {
        var sources = original?.sources ?? []
        if !sourceExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let source = MorningSource(id: sources.first?.id ?? UUID(), title: sourceTitle.isEmpty ? "Personal note" : sourceTitle,
                                       kind: sourceKind, excerpt: sourceExcerpt, url: sourceURL, capturedAt: sourceDate)
            if sources.isEmpty { sources = [source] } else { sources[0] = source }
        } else if !sources.isEmpty { sources.removeFirst() }
        var card = MorningCard(id: existingID, folderID: folderID, title: title, summary: summary,
                               personIDs: people.filter { personIDs.contains($0.id) }.map(\.id), sources: sources, rationale: rationale,
                               action: MorningAction(id: original?.action.id ?? UUID(), title: actionTitle, instruction: instruction, mode: mode),
                               contextAction: original?.contextAction ?? MorningAction(title: "Clarify this file", instruction: "Using only the attached sources and people context, explain what is known, identify missing information, and suggest concrete questions to resolve it. Do not claim to have checked external sources.", mode: .prepare),
                               unknowns: unknowns, timing: timing, isSample: original?.isSample ?? false,
                               disposition: original?.disposition ?? .unreviewed, updatedAt: Date())
        // Preserve a deliberately absent context action only for existing files with no unresolved questions.
        if let original, original.contextAction == nil, unknowns.isEmpty { card.contextAction = nil }
        do { try save(card) } catch { self.error = error.localizedDescription }
    }
}

private struct MorningField: View {
    let title: String
    @Binding var text: String
    var placeholder: String
    init(_ title: String, text: Binding<String>, placeholder: String = "") { self.title = title; _text = text; self.placeholder = placeholder }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pad.inkSoft)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).font(.system(size: 13)).accessibilityLabel(title)
        }
    }
}

private struct MorningTextField: View {
    let title: String
    @Binding var text: String
    var hint: String
    var minHeight: CGFloat
    init(_ title: String, text: Binding<String>, hint: String, minHeight: CGFloat) { self.title = title; _text = text; self.hint = hint; self.minHeight = minHeight }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pad.inkSoft)
            TextEditor(text: $text).font(.system(size: 13)).frame(minHeight: minHeight).scrollContentBackground(.hidden)
                .padding(6).background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Pad.tabEdge.opacity(0.6))).accessibilityLabel(title)
            Text(hint).font(.system(size: 10)).foregroundStyle(Pad.inkSoft)
        }
    }
}

private struct MorningEditorFooter: View {
    let error: String?
    let saveTitle: String
    let enabled: Bool
    let save: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled) }
            HStack {
                Button("Cancel", action: cancel).buttonStyle(MorningActionButton())
                Spacer()
                Button(saveTitle, action: save).buttonStyle(MorningActionButton(primary: true)).disabled(!enabled).opacity(enabled ? 1 : 0.5)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }.padding(.top, 5)
    }
}
