import AppKit
import FamiliarContracts
import SwiftUI

/// The latest run on its own screen and the main screen around it, from fictional runs of two example sources: a
/// finished run, a run where one source failed, and card work while it runs and after it fails. A stand-in model
/// proposes the cards or waits to be stopped; nothing reads a real source or reaches a provider.
extension MorningRender {
    @MainActor static func renderLatestRun(fixtures: URL, directory: URL) throws {
        let root = fixtures.appendingPathComponent("latest-run")
        let store = MorningStore(directory: root.appendingPathComponent("morning"))
        let sources = CalendarStore(directory: root.appendingPathComponent("sources"))
        let config = Config(), activities = NativeActivityGate()
        let desktop = DesktopExecutionService(control: ComputerController(), activities: activities)
        let runner = CalendarCollectionRunner(store: sources, desktop: desktop,
            registry: ToolRegistry(root: root.appendingPathComponent("tools"), runner: ScriptRunner(config: config)),
            activities: activities, config: { config }, makeClient: { _ in nil })
        let model = RenderCardModel()
        let cards = CardGenerationService(morning: store, sources: sources, desktop: desktop, config: { config },
                                          makeClient: { _ in model.connected ? model : nil })
        let navigation = MorningNavigation()
        func save(_ name: String, _ route: MorningNavigation.Route) throws {
            navigation.route = route
            try image(MorningFilesView(store: store, navigation: navigation, close: {}, filed: {}, handoff: { _ in },
                                       calendarSources: sources, calendarRunner: runner, cardGeneration: cards),
                      size: NSSize(width: 650, height: MorningPanelController.preferredHeight(for: route)),
                      to: directory.appendingPathComponent(name))
        }
        func settle(_ done: () -> Bool, _ what: String) throws {
            let limit = Date().addingTimeInterval(10)
            while !done() {
                guard Date() < limit else { throw LatestRunRenderFailure("Timed out waiting for \(what).") }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        /// Cards the stand-in model proposes, by the title of the saved finding each one is about.
        func propose(_ proposals: [(finding: String, title: String, meaning: String, option: String, instruction: String)]) throws {
            let observations = CardGenerationInput.saved(in: sources, runID: nil, excluding: []).observations
            model.proposals = try proposals.map { proposal -> [String: Any] in
                guard let observation = observations.first(where: { $0.title == proposal.finding }) else {
                    throw LatestRunRenderFailure("No saved finding is titled “\(proposal.finding)”.")
                }
                return ["observationKey": observation.id, "title": proposal.title, "meaning": proposal.meaning,
                        "options": [["title": proposal.option, "instruction": proposal.instruction, "mode": "prepare"]]]
            }
        }

        let mail = LearnedReadingSource(kind: .mail, name: "Example Gmail inbox",
            meaning: "Read new messages in my inbox · fictional example", application: "Google Chrome",
            bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox", account: "alex@example.com",
            scope: "Unread messages in the Inbox from the last day.")
        let school = LearnedReadingSource(kind: .web, name: "Example school portal",
            meaning: "Notes from my kid’s class · fictional example", application: "Safari",
            url: "https://school.example.test/announcements", scope: "New announcements on the first page.")
        try sources.saveReadingSource(mail)
        try sources.saveReadingSource(school)
        func read(_ source: LearnedReadingSource, at: Date, _ items: [ReadingItem]) -> SourceRunEntry {
            let request = ReadingReadRequest(source: source, requestedAt: at)
            var entry = SourceRunEntry(reading: request, state: .complete,
                message: "Saved \(items.count) \(items.count == 1 ? "item" : "items") from the saved scope.")
            entry.startedAt = at
            entry.finishedAt = at.addingTimeInterval(40)
            entry.readingSnapshot = ReadingSnapshot(requestID: request.id, sourceID: source.id, source: source,
                collectedAt: at.addingTimeInterval(40), items: items, coverage: .complete,
                accountEvidence: "Fictional account alex@example.com", sourceEvidence: "The fictional \(source.name) was open.",
                scopeEvidence: "Everything in the saved scope was checked.")
            return entry
        }
        func run(_ entries: [SourceRunEntry], at: Date) throws {
            let run = try sources.runStore.begin(entries: entries, origin: .all, startedAt: at, timeZoneID: "America/New_York")
            try sources.runStore.finish(runID: run.id, status: .completed, finishedAt: at.addingTimeInterval(90))
        }
        let iso = ISO8601DateFormatter()
        let early = iso.date(from: "2026-09-30T07:30:00-04:00")!, later = iso.date(from: "2026-09-30T08:30:00-04:00")!

        try save("latest-run-empty.png", .latestRun)

        // A finished run, and the cards made from it.
        try run([
            read(mail, at: early, [
                ReadingItem(id: "lease", title: "Lease renewal: sign by Friday",
                    text: "Dana Ruiz · 7:02 AM\nPlease sign the renewal by Friday so the rent stays the same.",
                    evidence: "Fictional inbox row: Dana Ruiz, Lease renewal, 7:02 AM."),
                ReadingItem(id: "package", title: "Your package is delayed",
                    text: "Example Shop · Yesterday\nYour order will arrive Thursday instead of Tuesday.",
                    evidence: "Fictional inbox row: Example Shop, package delayed, Yesterday.")]),
            read(school, at: early.addingTimeInterval(45), [
                ReadingItem(id: "field-trip", title: "Field trip form due Wednesday",
                    text: "Ms. Park · Posted today\nPlease sign and return the museum trip form by Wednesday.",
                    evidence: "Fictional announcement: Ms. Park, field trip form, posted today.")])
        ], at: early)
        try propose([
            ("Lease renewal: sign by Friday", "Dana needs the signed lease by Friday", "The renewal lapses Friday; signing keeps this rent.",
             "Draft a reply", "Draft a short reply to the fictional message. Do not send it."),
            ("Field trip form due Wednesday", "Sign the field trip form by Wednesday", "Ms. Park needs it back before the museum trip.",
             "Draft a note to Ms. Park", "Draft a short note saying the form is on its way. Do not send it.")])
        cards.generate()
        try settle({ !cards.isRunning }, "the first cards")
        try save("morning-latest-run.png", .folders)
        try save("latest-run.png", .latestRun)

        // A newer run where the school portal failed, then cards being prepared from it, stopped, and failing.
        var failed = SourceRunEntry(reading: ReadingReadRequest(source: school, requestedAt: later.addingTimeInterval(45)), state: .failed,
            message: "The portal asked to sign in again. No new findings were saved in this run.")
        failed.startedAt = later.addingTimeInterval(45)
        failed.finishedAt = later.addingTimeInterval(60)
        try run([
            read(mail, at: later, [
                ReadingItem(id: "dentist", title: "Your cleaning moved to 3 PM",
                    text: "Dr. Lee’s office · 8:12 AM\nTomorrow’s cleaning is now at 3 PM. Reply if that time doesn’t work.",
                    evidence: "Fictional inbox row: Dr. Lee’s office, cleaning moved, 8:12 AM.")]),
            failed
        ], at: later)
        model.proposals = nil
        cards.generate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard cards.isRunning else { throw LatestRunRenderFailure("Card work ended before it could be drawn: \(cards.status)") }
        try save("morning-cards-preparing.png", .folders)
        try save("latest-run-cards-preparing.png", .latestRun)
        cards.stop()
        try settle({ !cards.isRunning }, "card work to stop")
        model.connected = false
        cards.generate()
        try settle({ !cards.isRunning }, "card work to fail")
        guard cards.error != nil else { throw LatestRunRenderFailure("Card work without a model didn’t fail.") }
        try save("morning-cards-error.png", .folders)

        model.connected = true
        try propose([("Your cleaning moved to 3 PM", "Dr. Lee moved your cleaning to 3 PM", "Tomorrow’s appointment is later; check it still fits.",
                      "Draft a reply", "Draft a short reply confirming 3 PM works. Do not send it.")])
        cards.generate()
        try settle({ !cards.isRunning }, "the second cards")
        guard cards.error == nil else { throw LatestRunRenderFailure("The second cards failed: \(cards.error ?? "")") }
        try save("morning-latest-run-failed.png", .folders)
        try save("latest-run-failed.png", .latestRun)
    }
}

/// Stands in for the model: submits the proposals it was given, or, with none, waits until the work is stopped.
private final class RenderCardModel: ConversationClient {
    var effort = "medium"
    var maxTokens = 8_192
    var maxToolRounds = 3
    var shouldStop: () -> Bool = { false }
    var connected = true
    var proposals: [[String: Any]]?

    func converse(system: String, tools: [[String: Any]], messages: inout [[String: Any]],
                  executor: @escaping ToolExecutor, onStatus: @escaping (String) -> Void) async throws -> ClaudeReply {
        guard let proposals else {
            while !shouldStop() && !Task.isCancelled { try await Task.sleep(nanoseconds: 50_000_000) }
            throw CancellationError()
        }
        _ = await executor(CardGenerationSubmission.toolName, ["proposals": proposals], nil)
        return ClaudeReply(text: "Proposed \(proposals.count) cards.", inputTokens: 1, outputTokens: 1, cacheRead: 0, toolCalls: 1)
    }
}

private struct LatestRunRenderFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
