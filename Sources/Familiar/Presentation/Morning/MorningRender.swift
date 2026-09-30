import AppKit
import SwiftUI

/// Renders the maintained views with fictional local fixtures; no provider or desktop access.
enum MorningRender {
    @MainActor static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("familiar-morning-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let store = MorningStore(directory: fixtures)
        let navigation = MorningNavigation()
        func save(_ name: String) throws {
            try image(MorningFilesView(store: store, navigation: navigation, close: {}, filed: {}, handoff: { _ in }),
                      size: NSSize(width: 650, height: MorningPanelController.preferredHeight(for: navigation.route, isEmpty: store.cards.isEmpty)),
                      to: directory.appendingPathComponent(name))
        }
        try image(MorningLauncherView(store: store, open: {}, people: {}), size: NSSize(width: 86, height: 78),
                  to: directory.appendingPathComponent("morning-launcher.png"))
        try save("morning-empty.png")
        try store.loadSamples()
        try save("morning-folders.png")
        if let card = store.cards.first {
            navigation.route = .folder(card.folderID)
            try save("morning-spread.png")
            navigation.route = .card(card.id)
            try save("morning-file.png")
            let work = try store.enqueue(cardID: card.id)
            let feed = PeekFeed()
            let tasks = BackgroundTaskStore(feed: feed)
            tasks.syncMorning(store.workItems, message: "Waiting for your configured Claude connection.")
            tasks.selectTask(id: work.id)
            try image(BackgroundTaskPanelView(store: tasks, feed: feed), size: NSSize(width: 360, height: 400),
                      to: directory.appendingPathComponent("morning-queue.png"))
        }
        navigation.route = .people
        try save("morning-people.png")
        navigation.route = .editPerson(nil)
        try save("morning-person-editor.png")
        navigation.route = .editCard(nil)
        try save("morning-note-editor.png")
        let calendars = CalendarStore(directory: fixtures.appendingPathComponent("calendars"))
        func saveCalendars(_ name: String, selectedID: UUID? = nil) throws {
            try image(CalendarSourcesView(store: calendars, initialSourceID: selectedID,
                                          teach: {}, collect: { _, _, _, _ in }, stop: {})
                .foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 680),
                to: directory.appendingPathComponent(name))
        }
        try saveCalendars("calendar-sources-empty.png")
        let source = LearnedCalendarSource(name: "Example work calendar", meaning: "My work meeting schedule · fictional example",
            application: "Calendar example", url: "https://calendar.example.com", account: "alex@example.com",
            calendarName: "Work", timeZoneID: "America/New_York",
            navigationHints: "Confirm the Work calendar and date. Open each meeting to read attendance and availability.",
            completionChecks: "Read all timed and all-day entries for the selected day.")
        try calendars.saveSource(source)
        let iso = ISO8601DateFormatter()
        let sampleDay = iso.date(from: "2026-09-29T09:00:00-04:00")!
        let events = [
            CalendarEventRecord(id: "standup", title: "Team check-in", start: sampleDay,
                end: iso.date(from: "2026-09-29T10:00:00-04:00")!, response: .accepted, availability: .busy,
                evidence: "Fictional example: Team check-in, 09:00–10:00, accepted, busy."),
            CalendarEventRecord(id: "review", title: "Project review", start: iso.date(from: "2026-09-29T10:00:00-04:00")!,
                end: iso.date(from: "2026-09-29T12:30:00-04:00")!, response: .accepted, availability: .busy,
                evidence: "Fictional example: Project review, 10:00–12:30, accepted, busy.")
        ]
        try calendars.saveSnapshot(CalendarSnapshot(sourceID: source.id, day: sampleDay, timeZoneID: source.timeZoneID,
            events: events, coverage: .complete, accountEvidence: "Example account alex@example.com",
            calendarEvidence: "Example Work calendar", dateEvidence: "Example date September 29, 2026"))
        try saveCalendars("calendar-sources-result.png")
        var sharedSource = source
        sharedSource.id = UUID()
        sharedSource.name = "Example shared calendar"
        sharedSource.calendarName = "Shared"
        try calendars.saveSource(sharedSource)
        var personalSource = source
        personalSource.id = UUID()
        personalSource.name = "Example personal calendar"
        personalSource.account = "personal@example.com"
        personalSource.calendarName = "Personal"
        try calendars.saveSource(personalSource)
        var calendarEntry = SourceRunEntry(calendar: CalendarReadRequest(source: source, day: sampleDay), state: .complete,
            message: "Collected 2 calendar events.")
        calendarEntry.calendarSnapshot = calendars.latest(for: source.id)
        var sharedEntry = SourceRunEntry(calendar: CalendarReadRequest(source: sharedSource, day: sampleDay), state: .partial,
            message: "Afternoon coverage could not be verified.")
        var sharedSnapshot = calendarEntry.calendarSnapshot!
        sharedSnapshot.sourceID = sharedSource.id
        sharedSnapshot.source = sharedSource
        sharedSnapshot.coverage = .partial
        sharedSnapshot.coverageNotes = ["Afternoon coverage could not be verified."]
        sharedEntry.calendarSnapshot = sharedSnapshot
        let missingEntry = SourceRunEntry(calendar: CalendarReadRequest(source: personalSource, day: sampleDay), state: .failed,
            message: "The demonstrated account could not be found. No new result was saved.")
        let calendarRun = SourceRunRecord(origin: .all, startedAt: sampleDay, finishedAt: sampleDay,
            timeZoneID: "America/New_York", status: .completed, entries: [calendarEntry, sharedEntry, missingEntry])
        try image(SourceRunResultsView(run: calendarRun, sourceID: source.id)
            .foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 680),
            to: directory.appendingPathComponent("source-run-calendar.png"))
        try image(CalendarSourceEditor(source: source, save: { _ in }, cancel: {})
            .padding(23).foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 900),
            to: directory.appendingPathComponent("calendar-source-editor.png"))

        let mailSource = LearnedReadingSource(kind: .mail, name: "Example Gmail inbox",
            meaning: "Read new messages in my work inbox · fictional example", application: "Google Chrome",
            bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox", account: "alex@example.com",
            scope: "The first page of the Inbox, including visible senders, subjects, snippets, and dates.",
            navigationHints: "Confirm the account and selected Inbox. Read each visible message row.",
            completionChecks: "Check every row on the first inbox page; do not mark unread message bodies as read.")
        try calendars.saveReadingSource(mailSource)
        try calendars.saveReadingSnapshot(ReadingSnapshot(requestID: UUID(), sourceID: mailSource.id, source: mailSource,
            items: [ReadingItem(id: "example-mail", title: "Demo agenda for tomorrow",
                                text: "Taylor · 8:42 AM · Please review the agenda before tomorrow’s demo.",
                                evidence: "Fictional inbox row: Taylor, Demo agenda for tomorrow, 8:42 AM.",
                                url: "https://mail.google.com/mail/u/0/#inbox/example")],
            coverage: .complete, accountEvidence: "Fictional account: alex@example.com",
            sourceEvidence: "Fictional Gmail Inbox at the saved address", scopeEvidence: "Every row on the first page was checked."))
        try saveCalendars("sources-gmail-result.png", selectedID: mailSource.id)
        // Long saved rules and collection notes must never crowd findings out of the result screen.
        var resultSource = mailSource
        resultSource.scope = String(repeating: "Read only unread mail from the last two days, skip promotions, and stop after the verified first page. ", count: 12)
        let readingRequest = ReadingReadRequest(source: resultSource, requestedAt: sampleDay)
        let resultSnapshot = ReadingSnapshot(requestID: readingRequest.id, sourceID: resultSource.id, source: resultSource,
            collectedAt: sampleDay, items: [
                ReadingItem(id: "agenda", title: "Please review tomorrow’s demo agenda",
                    text: "Taylor · 8:42 AM\nThe updated agenda is ready. Please check your section before the afternoon rehearsal.",
                    evidence: "Fictional inbox row showing Taylor, agenda subject and 8:42 AM."),
                ReadingItem(id: "review", title: "Design review moved to Thursday",
                    text: "Morgan · Yesterday\nThe design review has moved to Thursday at 2 PM. The updated meeting invitation is on its way.",
                    evidence: "Fictional inbox row showing Morgan, revised review subject and Yesterday.")
            ], coverage: .complete,
            coverageNotes: (1...7).map { "Collection note \($0): " + String(repeating: "The visible first page and selected account were checked during this fictional example. ", count: 4) },
            accountEvidence: "Fictional account alex@example.com", sourceEvidence: "The example Inbox was selected.",
            scopeEvidence: "The visible first page was checked against the requested limits.")
        var completeEntry = SourceRunEntry(reading: readingRequest, state: .complete, message: "2 findings collected.")
        completeEntry.readingSnapshot = resultSnapshot
        completeEntry.finishedAt = sampleDay
        let resultRun = SourceRunRecord(origin: .single, startedAt: sampleDay, finishedAt: sampleDay,
            timeZoneID: "America/New_York", status: .completed, entries: [completeEntry])
        try image(SourceRunResultsView(run: resultRun, sourceID: resultSource.id,
                    directory: fixtures.appendingPathComponent("runs/2026-09-29_09-00-00"), activeSourceIDs: [resultSource.id])
            .foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 680),
            to: directory.appendingPathComponent("source-run-complete.png"))
        var partialEntry = completeEntry
        partialEntry.state = .partial
        partialEntry.readingSnapshot?.coverage = .partial
        partialEntry.readingSnapshot?.coverageNotes.insert("Older message rows could not be verified. The two visible findings are saved; this is not a complete mailbox read.", at: 0)
        var partialRun = resultRun
        partialRun.entries = [partialEntry]
        try image(SourceRunResultsView(run: partialRun, sourceID: resultSource.id, activeSourceIDs: [resultSource.id])
            .foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 680),
            to: directory.appendingPathComponent("source-run-partial.png"))
        var failedEntry = SourceRunEntry(reading: readingRequest, state: .failed,
            message: "The requested account could not be confirmed. No new findings were saved in this run.")
        failedEntry.finishedAt = sampleDay
        var failedRun = resultRun
        failedRun.entries = [failedEntry]
        failedRun.status = .failed
        try image(SourceRunResultsView(run: failedRun, sourceID: resultSource.id, activeSourceIDs: [resultSource.id])
            .foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 680),
            to: directory.appendingPathComponent("source-run-failed.png"))
        try saveCalendars("sources-mixed-management.png", selectedID: mailSource.id)
        try image(SourceManagementList(calendars: calendars.sources, readings: calendars.readingSources,
                                       selectedID: mailSource.id, select: { _ in }, edit: { _ in }, remove: { _ in })
            .padding(23).foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 510),
            to: directory.appendingPathComponent("sources-management-list.png"))
        try image(ReadingSourceEditor(source: mailSource, save: { _ in }, cancel: {})
            .padding(23).foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 1200),
            to: directory.appendingPathComponent("source-reading-editor.png"))
        try image(SourceRunHistoryView(runs: calendars.runStore, openRun: { _, _ in })
            .foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 680),
            to: directory.appendingPathComponent("source-run-history.png"))
        var recoveredRun = resultRun
        recoveredRun.origin = .migration
        try image(SourceRunResultsView(run: recoveredRun, sourceID: resultSource.id)
            .foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 680),
            to: directory.appendingPathComponent("source-run-recovered.png"))
        var recovered = mailSource
        recovered.id = UUID()
        recovered.name = "Saved inbox reading"
        recovered.account = ""
        recovered.uncertainties = ["Recovered from a saved demonstration. Confirm the address and scope before reading."]
        recovered.requiresReview = true
        try calendars.saveReadingSource(recovered)
        try saveCalendars("source-recovered-needs-review.png", selectedID: recovered.id)
        try image(ReadingSourceEditor(source: recovered, save: { _ in }, cancel: {})
            .padding(23).foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 1250),
            to: directory.appendingPathComponent("source-recovered-editor.png"))
        let workflowRoot = fixtures.appendingPathComponent("saved-tools")
        let workflowPack = workflowRoot.appendingPathComponent("example-mail")
        let workflowDirectory = workflowPack.appendingPathComponent("docs/workflows")
        try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
        try "# Example mail\nLearned by watching".write(to: workflowPack.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# Read my Primary inbox\nIn Google Chrome, read the Primary inbox at https://mail.google.com/mail/u/0/#inbox. This is a fictional saved demonstration."
            .write(to: workflowDirectory.appendingPathComponent("primary-inbox.md"), atomically: true, encoding: .utf8)
        calendars.refreshSavedWorkflows(root: workflowRoot)
        try saveCalendars("sources-saved-workflow-review.png")
        try calendars.removeSource(id: mailSource.id)
        try calendars.removeSource(id: sharedSource.id)
        try image(RemovedSourcesList(sources: calendars.removedSources, initiallyExpanded: true, restore: { _ in })
            .padding(23).foregroundStyle(Pad.ink).background(Pad.fieldPaper), size: NSSize(width: 650, height: 320),
            to: directory.appendingPathComponent("sources-removed-restore.png"))
        try saveCalendars("sources-after-removal.png", selectedID: mailSource.id)
        try calendars.restoreSource(id: mailSource.id)
        try saveCalendars("sources-restored-result.png", selectedID: mailSource.id)
        try renderGeneratedCards(fixtures: fixtures, directory: directory)
        try renderLatestRun(fixtures: fixtures, directory: directory)
        try renderAttention(fixtures: fixtures, directory: directory)
    }

    /// Exercise the maintained reconciliation and views with clearly fictional
    /// observations, including a continuing item and an explicitly resolved one.
    @MainActor private static func renderGeneratedCards(fixtures: URL, directory: URL) throws {
        let store = MorningStore(directory: fixtures.appendingPathComponent("generated-cards"))
        let navigation = MorningNavigation()
        let sourceID = UUID()
        let firstRun = UUID(), latestRun = UUID()
        let firstSeen = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let lastSeen = Date().addingTimeInterval(-30 * 60)
        var agenda = CardObservation(runID: firstRun, sourceID: sourceID, itemKey: "example-demo-agenda",
            sourceName: "Example team inbox", kind: "mail", title: "Demo agenda review",
            excerpt: "Fictional example: Taylor asks Alex to review the opening section before the rehearsal.",
            url: "https://mail.example.test/thread/demo-agenda", identityEvidence: "Fictional thread permalink: demo-agenda",
            observedAt: firstSeen, state: .open, stateEvidence: "Taylor's review request is still open.")
        var rehearsal = CardObservation(runID: firstRun, sourceID: sourceID, itemKey: "example-rehearsal-slot",
            sourceName: "Example team inbox", kind: "mail", title: "Confirm the rehearsal slot",
            excerpt: "Fictional example: Morgan is waiting for confirmation of Thursday's rehearsal time.",
            url: "https://mail.example.test/thread/rehearsal-slot", identityEvidence: "Fictional thread permalink: rehearsal-slot",
            observedAt: firstSeen, state: .open, stateEvidence: "The rehearsal time has not yet been confirmed.")
        let agendaProposal = CardProposal(observationKey: agenda.id, title: "Taylor's demo opening needs your review",
            meaning: "Taylor can't finish the agenda before Thursday's rehearsal without your feedback.",
            action: MorningAction(title: "Prepare review questions", instruction: "Draft a short checklist for reviewing the demo's opening section using the saved example thread.", mode: .prepare),
            alternatives: [MorningAction(title: "Ask Taylor about the story", instruction: "Draft a short question to Taylor about the demo's opening story, using the saved example thread. Do not send it.", mode: .prepare),
                           MorningAction(title: "Draft brief feedback", instruction: "Draft two or three lines of feedback on the opening section from the saved example thread. Do not send it.", mode: .prepare)])
        let rehearsalProposal = CardProposal(observationKey: rehearsal.id, title: "Morgan needs the rehearsal time",
            meaning: "The invitation waits on your confirmation of Thursday's slot.",
            action: MorningAction(title: "Prepare a reply", instruction: "Draft a short reply asking Morgan to confirm the proposed rehearsal slot. Do not send it.", mode: .prepare))
        try store.applyCardGeneration(observations: [agenda, rehearsal], proposals: [agendaProposal, rehearsalProposal],
            runIDs: [firstRun], at: firstSeen)
        guard let agendaCard = store.cards.first(where: { $0.tracking?.key == agenda.id }),
              let rehearsalCard = store.cards.first(where: { $0.tracking?.key == rehearsal.id }) else { return }
        try store.updateCardContext(cardID: agendaCard.id,
            context: "Keep the feedback brief. Ask Taylor about the opening story before suggesting changes.")
        agenda.runID = latestRun
        agenda.observedAt = lastSeen
        agenda.excerpt = "Fictional example: Taylor has added the opening story and asks for a brief review before Thursday's 2 PM rehearsal."
        agenda.stateEvidence = "Taylor's latest message still asks for your review."
        rehearsal.runID = latestRun
        rehearsal.observedAt = lastSeen
        rehearsal.state = .resolved
        rehearsal.excerpt = "Fictional example: Morgan confirms Thursday at 2 PM and says no reply is needed."
        rehearsal.stateEvidence = "Morgan confirmed Thursday at 2 PM. No reply is needed."
        try store.applyCardGeneration(observations: [agenda, rehearsal], proposals: [agendaProposal],
            runIDs: [latestRun], at: lastSeen)

        func save(_ name: String) throws {
            try image(MorningFilesView(store: store, navigation: navigation, close: {}, filed: {}, handoff: { _ in }, discussCard: { _ in }),
                size: NSSize(width: 650, height: MorningPanelController.preferredHeight(for: navigation.route, isEmpty: false)),
                to: directory.appendingPathComponent(name))
        }
        navigation.route = .folders
        try save("generated-cards-overview.png")
        navigation.route = .folder(agendaCard.folderID)
        try save("generated-cards-carried.png")
        navigation.route = .card(agendaCard.id)
        try save("generated-card-carried-detail.png")
        navigation.disposition = .resolved
        navigation.route = .folder(rehearsalCard.folderID)
        try save("generated-cards-resolved.png")
        navigation.route = .card(rehearsalCard.id)
        try save("generated-card-resolved-detail.png")
    }

    @MainActor static func image<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light).frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw RenderError.bitmap }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.encoding }
        try data.write(to: url)
        print("wrote \(url.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
    private enum RenderError: Error { case bitmap, encoding }
}
