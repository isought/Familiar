import Foundation

/// Findings and collection evidence are presented separately. Source rules belong in Manage sources.
struct SourceResultPresentation: Equatable {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var text: String
        var url: String
        /// For a read item, what the card step calls it (its observation key) and, for mail, its sender: what a
        /// lesson about it is kept under. Nil for a calendar event.
        var key: String? = nil
        var from: String? = nil
    }
    struct Detail: Identifiable, Equatable {
        var title: String
        var text: String
        var id: String { title }
    }
    var sourceID: UUID
    var title: String
    var dateLabel: String
    var state: SourceRunEntry.State
    var stateLabel: String
    var notice: String?
    var emptyMessage: String
    var items: [Item]
    var calendarFacts: [Detail]
    var details: [Detail]

    init(entry: SourceRunEntry) {
        let reading = entry.readingSnapshot
        let calendar = entry.calendarSnapshot
        sourceID = entry.sourceID
        title = entry.sourceName
        dateLabel = entry.dateLabel
        state = entry.state
        stateLabel = entry.state.resultLabel
        let notes = reading?.coverageNotes ?? calendar?.coverageNotes ?? []
        let gap = notes.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? entry.message
        switch entry.state {
        case .complete: notice = nil
        case .partial: notice = "Partial collection. " + Self.excerpt(gap, limit: 180)
        case .failed, .stopped, .notRun, .interrupted: notice = Self.excerpt(entry.message, limit: 240)
        case .waiting, .reading: notice = Self.excerpt(entry.message, limit: 180)
        }
        emptyMessage = entry.state == .complete ? "No items were found in the verified collection."
            : entry.state == .partial ? "No items were collected. This does not establish an empty source."
            : entry.state == .reading || entry.state == .waiting ? "Findings will appear here as this source finishes."
            : "No new findings were saved for this source in this run."
        items = []
        calendarFacts = []
        details = []
        if let reading {
            items = reading.items.map { item in
                Item(id: item.id, title: item.title, text: item.text, url: item.url,
                     key: CardObservation.key(sourceID: entry.sourceID, itemKey: CardGenerationInput.identity(item.identityKey, fallback: item.id)),
                     from: item.mail.flatMap { $0.from.isEmpty ? nil : $0.from })
            }
            details = [Detail(title: "Account observed", text: reading.accountEvidence),
                       Detail(title: "Source observed", text: reading.sourceEvidence),
                       Detail(title: "Coverage checked", text: reading.scopeEvidence)]
            details += reading.items.enumerated().map { Detail(title: "Evidence · \($0.offset + 1)", text: $0.element.evidence) }
        } else if let calendar {
            dateLabel += " · " + calendar.timeZoneID
            let clock = DateFormatter()
            clock.timeZone = calendar.calendar.timeZone
            clock.dateStyle = .none
            clock.timeStyle = .short
            func time(_ value: Date) -> String {
                value == calendar.dayInterval.end ? "midnight (next day)" : clock.string(from: value)
            }
            items = calendar.events.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.map { event in
                let when = event.allDay ? "All day" : "\(time(max(event.start, calendar.dayInterval.start)))–\(time(min(event.end, calendar.dayInterval.end)))"
                let response = event.response == .notResponded ? "not responded" : event.response.rawValue
                let text = "\(when) · \(response) · \(event.availability.rawValue)" + (event.isCancelled ? " · cancelled" : "")
                    + (event.start < calendar.dayInterval.start ? " · began before this day" : "")
                    + (event.end > calendar.dayInterval.end ? " · continues after this day" : "")
                return Item(id: event.id, title: event.title, text: text, url: event.url)
            }
            details = [Detail(title: "Account observed", text: calendar.accountEvidence),
                       Detail(title: "Calendar observed", text: calendar.calendarEvidence),
                       Detail(title: "Date verified", text: calendar.dateEvidence),
                       Detail(title: "Time zone", text: calendar.timeZoneID)]
            details += calendar.events.enumerated().map { Detail(title: "Evidence · \($0.offset + 1)", text: $0.element.evidence) }
            func span(_ value: DateInterval) -> String {
                "\(time(value.start))–\(time(value.end))"
            }
            let analysis = CalendarBriefing.analyze(calendar)
            if !analysis.acceptedOverlaps.isEmpty {
                calendarFacts.append(Detail(title: "Accepted meeting overlaps · \(analysis.acceptedOverlaps.count)",
                    text: analysis.acceptedOverlaps.map { "\(span($0.interval)): \($0.first.title) and \($0.second.title)" }.joined(separator: "\n")))
            } else {
                calendarFacts.append(Detail(title: "Accepted meeting overlaps", text: "No overlaps were found between collected events marked accepted."))
            }
            calendarFacts.append(Detail(title: "Busy or tentative blocks · \(analysis.busyBlocks.count)",
                text: analysis.busyBlocks.isEmpty ? "No busy or tentative blocks were observed in the selected window."
                    : analysis.busyBlocks.map(span).joined(separator: "\n")))
            calendarFacts.append(Detail(title: "Calendar openings of at least 30 minutes",
                text: analysis.hasReliableOpenings
                    ? (analysis.freeWindows.isEmpty ? "No openings of at least 30 minutes appear in the selected window."
                       : analysis.freeWindows.map(span).joined(separator: "\n")) + "\nOpenings reflect only this calendar’s recorded availability."
                    : "Open time is unverified because coverage is incomplete or some events have unknown availability."))
        }
        if !notes.isEmpty { details.insert(Detail(title: "Collection notes", text: notes.joined(separator: "\n\n")), at: 0) }
    }

    static func excerpt(_ value: String, limit: Int) -> String {
        let line = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

extension SourceRunEntry.State {
    var resultLabel: String {
        switch self {
        case .waiting: return "Waiting"
        case .reading: return "Reading"
        case .complete: return "Completed"
        case .partial: return "Partial"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .notRun: return "Not run"
        case .interrupted: return "Interrupted"
        }
    }
}
