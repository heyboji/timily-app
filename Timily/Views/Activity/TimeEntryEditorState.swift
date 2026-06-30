import Foundation

struct TimeEntryEditorState: Identifiable {
    let id = UUID()
    let entry: TimeEntry?
    var startDate: Date
    var endDate: Date
    var projectID: UUID?
    var entryDescription: String

    init(entry: TimeEntry? = nil, now: Date = .now, calendar: Calendar = .current) {
        self.entry = entry

        if let entry {
            startDate = entry.startDate
            endDate = entry.endDate ?? now
            projectID = entry.project?.id
            entryDescription = entry.entryDescription ?? ""
        } else {
            let roundedNow = Self.minuteStart(for: now, calendar: calendar)
            startDate = calendar.date(byAdding: .hour, value: -1, to: roundedNow) ?? roundedNow
            endDate = roundedNow
            projectID = nil
            entryDescription = ""
        }
    }

    init(startDate: Date, endDate: Date) {
        self.entry = nil
        self.startDate = startDate
        self.endDate = endDate
        self.projectID = nil
        self.entryDescription = ""
    }

    var title: String {
        entry == nil ? "New Entry" : "Edit Entry"
    }

    var canSave: Bool {
        normalizedEndDate >= normalizedStartDate
    }

    var normalizedStartDate: Date {
        Self.minuteStart(for: startDate)
    }

    var normalizedEndDate: Date {
        Self.minuteStart(for: endDate)
    }

    var normalizedDescription: String? {
        let value = entryDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func minuteStart(
        for date: Date,
        calendar: Calendar = .current
    ) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }
}
