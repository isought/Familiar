import Foundation

struct CalendarOverlap: Equatable {
    var first: CalendarEventRecord
    var second: CalendarEventRecord
    var interval: DateInterval
}

struct CalendarDayAnalysis: Equatable {
    var busyBlocks: [DateInterval]
    var acceptedOverlaps: [CalendarOverlap]
    var freeWindows: [DateInterval]
    var hasReliableOpenings: Bool
}

/// Calendar facts only. Preferences, importance, relationships and prior decisions are not inferred.
enum CalendarBriefing {
    static func analyze(_ snapshot: CalendarSnapshot) -> CalendarDayAnalysis {
        guard (try? snapshot.validate()) != nil else {
            return CalendarDayAnalysis(busyBlocks: [], acceptedOverlaps: [], freeWindows: [], hasReliableOpenings: false)
        }
        let relevant = snapshot.events.filter { !$0.doesNotBlock }
        let knownBusy = relevant.filter { $0.availability == .busy || $0.availability == .tentative }
        let intervals = knownBusy.compactMap { intersection($0.interval, snapshot.windowInterval) }.sorted { $0.start < $1.start }
        var blocks: [DateInterval] = []
        for interval in intervals {
            if let last = blocks.last, interval.start <= last.end {
                blocks[blocks.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { blocks.append(interval) }
        }
        // Unknown free/busy metadata could hide a blocking all-day event. Never call its gaps free.
        let reliable = snapshot.coverage == .complete && !relevant.contains { $0.availability == .unknown }
        var openings: [DateInterval] = []
        if reliable {
            var cursor = snapshot.windowInterval.start
            for block in blocks {
                if block.start.timeIntervalSince(cursor) >= 30 * 60 { openings.append(DateInterval(start: cursor, end: block.start)) }
                cursor = max(cursor, block.end)
            }
            if snapshot.windowInterval.end.timeIntervalSince(cursor) >= 30 * 60 {
                openings.append(DateInterval(start: cursor, end: snapshot.windowInterval.end))
            }
        }
        // RSVP overlap is a separate fact from whether the calendar marks an event as blocking.
        let accepted = snapshot.events.filter { !$0.isCancelled && $0.response == .accepted }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var overlaps: [CalendarOverlap] = []
        for (index, first) in accepted.enumerated() {
            for second in accepted.dropFirst(index + 1) {
                guard second.start < first.end else { break }
                if let overlap = intersection(first.interval, second.interval), let clipped = intersection(overlap, snapshot.dayInterval) {
                    overlaps.append(CalendarOverlap(first: first, second: second, interval: clipped))
                }
            }
        }
        return CalendarDayAnalysis(busyBlocks: blocks, acceptedOverlaps: overlaps, freeWindows: openings, hasReliableOpenings: reliable)
    }

    static func render(_ snapshot: CalendarSnapshot) -> String {
        guard (try? snapshot.validate()) != nil else { return "This calendar collection is invalid. Collect the day again before using it for a briefing." }
        let analysis = analyze(snapshot)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = snapshot.calendar.timeZone
        clock.dateFormat = "h:mm a"
        func time(_ value: Date) -> String {
            value == snapshot.dayInterval.end ? "midnight (next day)" : clock.string(from: value)
        }
        func span(_ interval: DateInterval) -> String { "\(time(interval.start))–\(time(interval.end))" }
        var lines = ["Calendar for \(snapshot.dateLabel) (\(snapshot.timeZoneID))",
                     "Collected \(snapshot.coverage == .complete ? "the full day" : "part of the day"); analysis window \(span(snapshot.windowInterval))."]
        if !snapshot.coverageNotes.isEmpty { lines.append("Collection notes: " + snapshot.coverageNotes.joined(separator: " ")) }
        let events = snapshot.events.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        if events.isEmpty {
            lines.append(snapshot.coverage == .complete ? "No events were found in this calendar for the day." : "No events were collected. This does not establish an empty schedule.")
        } else {
            lines.append("\nCollected schedule:")
            for event in events {
                let clipped = intersection(event.interval, snapshot.dayInterval)!
                let when = event.allDay ? "All day" : span(clipped)
                var details = [responseLabel(event.response), "availability: \(event.availability.rawValue)"]
                if event.isCancelled { details.append("cancelled") }
                if event.start < snapshot.dayInterval.start { details.append("began before this day") }
                if event.end > snapshot.dayInterval.end { details.append("continues after this day") }
                lines.append("• \(when): \(event.title) (\(details.joined(separator: "; ")))")
            }
        }
        if !analysis.busyBlocks.isEmpty {
            lines.append("\nBusy or tentative blocks within the selected window:")
            lines.append(contentsOf: analysis.busyBlocks.map { "• " + span($0) })
        }
        if !analysis.acceptedOverlaps.isEmpty {
            lines.append("\nOverlapping events you accepted:")
            lines.append(contentsOf: analysis.acceptedOverlaps.map { "• \(span($0.interval)): \($0.first.title) and \($0.second.title)." })
        } else {
            lines.append("\nNo overlaps were found between collected events marked accepted.")
        }
        if analysis.hasReliableOpenings {
            if analysis.freeWindows.isEmpty {
                lines.append("\nNo calendar openings of 30 minutes or longer appear in the selected window.")
            } else {
                lines.append("\nCalendar openings of 30 minutes or longer:")
                lines.append(contentsOf: analysis.freeWindows.map { "• " + span($0) })
            }
            lines.append("Openings reflect this calendar’s recorded availability only.")
        } else {
            var reasons: [String] = []
            if snapshot.coverage == .partial { reasons.append("collection is incomplete") }
            if snapshot.events.contains(where: { !$0.doesNotBlock && $0.availability == .unknown }) { reasons.append("some events have unknown availability") }
            lines.append("\nOpen time is unverified because \(reasons.joined(separator: " and ")).")
        }
        return lines.joined(separator: "\n")
    }

    private static func intersection(_ first: DateInterval, _ second: DateInterval) -> DateInterval? {
        let start = max(first.start, second.start), end = min(first.end, second.end)
        return start < end ? DateInterval(start: start, end: end) : nil
    }

    private static func responseLabel(_ value: CalendarEventResponse) -> String {
        switch value {
        case .notResponded: return "not responded"
        case .unknown: return "response unknown"
        default: return value.rawValue
        }
    }
}
