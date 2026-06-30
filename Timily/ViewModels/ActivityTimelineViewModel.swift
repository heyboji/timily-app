import Foundation
import Observation
import SwiftData

enum ActivityTimelineSelection: Hashable {
    case entry(UUID)
    case segment(UUID)
}

@MainActor
@Observable
final class ActivityTimelineViewModel {
    private(set) var selectedDay: Date
    var selection = Set<ActivityTimelineSelection>()
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

    var selectedEntryIDs: Set<UUID> {
        get { ids(in: selection, matching: .entry) }
        set { selection = Set(newValue.map(ActivityTimelineSelection.entry)) }
    }

    var selectedSegmentIDs: Set<UUID> {
        get { ids(in: selection, matching: .segment) }
        set { selection = Set(newValue.map(ActivityTimelineSelection.segment)) }
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

    func segmentsForSelectedDay(in entry: TimeEntry) -> [ActivitySegment] {
        entry.activitySegments
            .filter { displayInterval(for: $0) != nil }
            .sorted {
                $0.startDate == $1.startDate
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.startDate < $1.startDate
            }
    }

    func displayInterval(for segment: ActivitySegment) -> DateInterval? {
        let start = max(segment.startDate, dayInterval.start)
        let end = min(segment.endDate, dayInterval.end)
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    func normalizeSelection(
        from previousSelection: Set<ActivityTimelineSelection>,
        to proposedSelection: Set<ActivityTimelineSelection>
    ) {
        let proposedEntryIDs = ids(in: proposedSelection, matching: .entry)
        let proposedSegmentIDs = ids(in: proposedSelection, matching: .segment)
        guard !proposedEntryIDs.isEmpty, !proposedSegmentIDs.isEmpty else {
            selection = proposedSelection
            return
        }

        let introduced = proposedSelection.subtracting(previousSelection)
        let introducedEntryIDs = ids(in: introduced, matching: .entry)
        let introducedSegmentIDs = ids(in: introduced, matching: .segment)

        if introducedSegmentIDs.isEmpty {
            selectedEntryIDs = proposedEntryIDs
        } else if introducedEntryIDs.isEmpty {
            selectedSegmentIDs = proposedSegmentIDs
        } else if !ids(in: previousSelection, matching: .segment).isEmpty {
            selectedSegmentIDs = proposedSegmentIDs
        } else if !ids(in: previousSelection, matching: .entry).isEmpty {
            selectedEntryIDs = proposedEntryIDs
        } else {
            selectedSegmentIDs = proposedSegmentIDs
        }
    }

    func moveDay(by value: Int) {
        selectedDay = calendar.date(byAdding: .day, value: value, to: selectedDay) ?? selectedDay
        selection.removeAll()
    }

    func goToToday(now: Date = .now) {
        selectedDay = calendar.startOfDay(for: now)
        selection.removeAll()
    }

    func pruneSelection(to entries: [TimeEntry]) {
        var validSelection = Set(entries.map { ActivityTimelineSelection.entry($0.id) })
        for entry in entries {
            validSelection.formUnion(
                segmentsForSelectedDay(in: entry).map { ActivityTimelineSelection.segment($0.id) }
            )
        }
        selection.formIntersection(validSelection)
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

    func assignSelectedSegments(to project: Project?, in context: ModelContext) {
        do {
            try service.assign(segmentIDs: selectedSegmentIDs, to: project, in: context)
            selection.removeAll()
        } catch {
            show(error)
        }
    }

    func canDeleteActivity(_ segment: ActivitySegment) -> Bool {
        service.canDeleteActivity(segment)
    }

    func deleteActivity(_ segment: ActivitySegment, in context: ModelContext) {
        do {
            try service.deleteActivity(id: segment.id, in: context)
            selection.removeAll()
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

    private enum SelectionKind {
        case entry
        case segment
    }

    private func ids(
        in selection: Set<ActivityTimelineSelection>,
        matching kind: SelectionKind
    ) -> Set<UUID> {
        Set(selection.compactMap { item in
            switch (item, kind) {
            case let (.entry(id), .entry), let (.segment(id), .segment):
                id
            default:
                nil
            }
        })
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}
