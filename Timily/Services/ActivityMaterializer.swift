import Foundation
import SwiftData

/// Atomically assigns a completed activity capture to accounting entries.
///
/// Existing entries own the portions they already cover. Uncovered gaps become
/// separate `.fromActivity` entries. This keeps `TimeEntry` non-overlapping and
/// gives every persisted activity segment exactly one parent.
@MainActor
final class ActivityMaterializer: ActivitySegmentSink {
    private let context: ModelContext
    private let save: () throws -> Void
    private let rollback: () -> Void

    init(
        context: ModelContext,
        save: (() throws -> Void)? = nil,
        rollback: (() -> Void)? = nil
    ) {
        self.context = context
        self.save = save ?? { try context.save() }
        self.rollback = rollback ?? { context.rollback() }
    }

    func record(_ completed: CompletedActivitySegment) throws {
        let range = try TimeRange(start: completed.startDate, end: completed.endDate)
        guard range.start < range.end else { return }

        let existingMarker = try marker(with: completed.id)
        guard existingMarker?.timeEntry == nil else { return }

        let existingEntries = try TimeEntryService()
            .overlapping(range: range, in: context)
            .sorted(by: entryOrder)
        let boundaries = partitionBoundaries(for: range, entries: existingEntries)
        let rules = try context.fetch(FetchDescriptor<AssignmentRule>())

        do {
            for (index, pair) in zip(boundaries, boundaries.dropFirst()).enumerated() {
                let start = pair.0
                let end = pair.1
                guard end > start else { continue }

                let owner = owner(
                    forStart: start,
                    end: end,
                    among: existingEntries,
                    captureEnd: range.end
                )
                let entry = owner ?? makeActivityEntry(start: start, end: end)
                let segment: ActivitySegment
                if index == 0, let existingMarker {
                    existingMarker.appBundleId = completed.application.bundleIdentifier
                    existingMarker.appName = completed.application.displayName
                    existingMarker.startDate = start
                    existingMarker.endDate = end
                    existingMarker.timeEntry = entry
                    segment = existingMarker
                } else {
                    segment = ActivitySegment(
                        id: index == 0 ? completed.id : UUID(),
                        appBundleId: completed.application.bundleIdentifier,
                        appName: completed.application.displayName,
                        startDate: start,
                        endDate: end,
                        timeEntry: entry
                    )
                }

                if owner == nil {
                    context.insert(entry)
                    RuleEngine.apply(rules, to: entry, for: segment)
                }
                context.insert(segment)
            }

            try save()
        } catch {
            rollback()
            throw error
        }
    }

    private func marker(with id: UUID) throws -> ActivitySegment? {
        var descriptor = FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func partitionBoundaries(
        for range: TimeRange,
        entries: [TimeEntry]
    ) -> [Date] {
        var boundaries: Set<Date> = [range.start, range.end]

        for entry in entries {
            if entry.startDate > range.start && entry.startDate < range.end {
                boundaries.insert(entry.startDate)
            }
            if let endDate = entry.endDate,
               endDate > range.start,
               endDate < range.end {
                boundaries.insert(endDate)
            }
        }

        return boundaries.sorted()
    }

    private func owner(
        forStart start: Date,
        end: Date,
        among entries: [TimeEntry],
        captureEnd: Date
    ) -> TimeEntry? {
        let owners = entries.filter { entry in
            let entryEnd = entry.endDate ?? captureEnd
            return entry.startDate <= start && entryEnd >= end
        }

        return owners.first { $0.source == .timer && $0.endDate == nil }
            ?? owners.first
    }

    private func makeActivityEntry(start: Date, end: Date) -> TimeEntry {
        TimeEntry(
            startDate: start,
            endDate: end,
            source: .fromActivity
        )
    }

    private func entryOrder(_ lhs: TimeEntry, _ rhs: TimeEntry) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
