import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ActivityTimelineViewModel {
    private(set) var selectedDay: Date
    var selectedEntryIDs = Set<UUID>()
    var errorMessage = ""
    var isShowingError = false

    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let service = ActivityTimelineService()

    init(selectedDay: Date = .now, calendar: Calendar = .current) {
        self.calendar = calendar
        self.selectedDay = calendar.startOfDay(for: selectedDay)
    }

    var dayInterval: DateInterval {
        calendar.dateInterval(of: .day, for: selectedDay)
            ?? DateInterval(start: selectedDay, duration: 24 * 60 * 60)
    }

    var isToday: Bool {
        calendar.isDateInToday(selectedDay)
    }

    func entriesForSelectedDay(_ entries: [TimeEntry], now: Date = .now) -> [TimeEntry] {
        entries.filter { displayInterval(for: $0, now: now) != nil }
        .sorted { lhs, rhs in
            lhs.startDate == rhs.startDate ? lhs.id.uuidString < rhs.id.uuidString : lhs.startDate < rhs.startDate
        }
    }

    func displayInterval(for entry: TimeEntry, now: Date = .now) -> DateInterval? {
        let interval = dayInterval
        let start = max(entry.startDate, interval.start)
        let end = min(entry.endDate ?? now, interval.end)
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    func moveDay(by value: Int) {
        selectedDay = calendar.date(byAdding: .day, value: value, to: selectedDay) ?? selectedDay
        selectedEntryIDs.removeAll()
    }

    func goToToday(now: Date = .now) {
        selectedDay = calendar.startOfDay(for: now)
        selectedEntryIDs.removeAll()
    }

    func pruneSelection(to entries: [TimeEntry]) {
        selectedEntryIDs.formIntersection(entries.map(\.id))
    }

    func assignSelected(
        from entries: [TimeEntry],
        to project: Project?,
        in context: ModelContext
    ) {
        do {
            try service.assign(selectedEntries(from: entries), to: project, in: context)
        } catch {
            show(error)
        }
    }

    func mergeSelected(from entries: [TimeEntry], in context: ModelContext) {
        do {
            let merged = try service.merge(selectedEntries(from: entries), in: context)
            selectedEntryIDs = [merged.id]
        } catch {
            show(error)
        }
    }

    private func selectedEntries(from entries: [TimeEntry]) -> [TimeEntry] {
        entries.filter { selectedEntryIDs.contains($0.id) }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}
