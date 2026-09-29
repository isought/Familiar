import Foundation

/// Local removal is reversible. The original source profile and its observations
/// remain together, while the saved Watch Me files are left untouched.
struct RemovedSource: Codable, Identifiable, Equatable {
    var id: UUID
    var removedAt: Date = Date()
    var calendar: LearnedCalendarSource? = nil
    var reading: LearnedReadingSource? = nil
    var calendarSnapshots: [CalendarSnapshot] = []
    var readingSnapshots: [ReadingSnapshot] = []

    var name: String { calendar?.name ?? reading?.name ?? "Removed source" }
    var workflowPath: String? {
        let value = calendar?.workflowPath ?? reading?.workflowPath
        return value.flatMap { calendarHasText($0) ? $0 : nil }
    }

    func validate() throws {
        try calendarRequire((calendar != nil) != (reading != nil), "A removed source must contain exactly one source profile.")
        try calendarRequire(removedAt.timeIntervalSince1970.isFinite, "The source removal time is invalid.")
        if let calendar {
            try calendar.validate()
            try calendarRequire(calendar.id == id, "The removed calendar has a mismatched identifier.")
            try calendarRequire(readingSnapshots.isEmpty, "A removed calendar contains unrelated reading observations.")
            var days: Set<String> = []
            try calendarRequire(Set(calendarSnapshots.map(\.id)).count == calendarSnapshots.count, "A removed calendar contains duplicate collection identifiers.")
            for snapshot in calendarSnapshots {
                try snapshot.validate()
                try calendarRequire(snapshot.sourceID == id, "A removed calendar contains another source’s collection.")
                try calendarRequire(days.insert(snapshot.dateLabel).inserted, "A removed calendar contains duplicate collections for one day.")
            }
        }
        if let reading {
            try reading.validate()
            try calendarRequire(reading.id == id, "The removed reading source has a mismatched identifier.")
            try calendarRequire(calendarSnapshots.isEmpty, "A removed reading source contains unrelated calendar observations.")
            try calendarRequire(readingSnapshots.count <= 1, "A removed reading source contains duplicate latest collections.")
            for snapshot in readingSnapshots {
                try snapshot.validate()
                try calendarRequire(snapshot.sourceID == id, "A removed reading source contains another source’s collection.")
            }
        }
    }
}
