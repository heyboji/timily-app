import Foundation
import SwiftData

enum UnownedActivitySegmentPolicy {
    case throwError
    case delete
    case materializeUnassigned
}

enum ActivitySegmentReconciliationError: Error {
    case missingOwner
}

/// Redistributes captured activity after its owning time entries change shape.
@MainActor
struct ActivitySegmentReconciler {

    func snapshot(
        ownedBy entries: [TimeEntry],
        overlapping range: TimeRange? = nil,
        in context: ModelContext
    ) throws -> [ActivitySegment] {
        let ownerIDs = Set(entries.map(\.id))

        return try context.fetch(FetchDescriptor<ActivitySegment>()).filter { segment in
            guard let ownerID = segment.timeEntry?.id,
                  ownerIDs.contains(ownerID) else {
                return false
            }
            guard let range else { return true }
            return segment.startDate < range.end && segment.endDate > range.start
        }
    }

    func redistribute(
        _ segments: [ActivitySegment],
        among entries: [TimeEntry],
        unownedPolicy: UnownedActivitySegmentPolicy,
        in context: ModelContext
    ) throws {
        let sortedEntries = entries.sorted(by: entryOrder)

        for segment in segments {
            let boundaries = segmentBoundaries(segment, entries: sortedEntries)
            var reusedOriginal = false

            for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                guard end > start else { continue }

                var pieceOwner = owner(
                    forStart: start,
                    end: end,
                    entries: sortedEntries
                )

                if pieceOwner == nil {
                    switch unownedPolicy {
                    case .throwError:
                        throw ActivitySegmentReconciliationError.missingOwner
                    case .delete:
                        continue
                    case .materializeUnassigned:
                        let entry = TimeEntry(
                            startDate: start,
                            endDate: end,
                            entryDescription: segment.note,
                            source: .fromActivity
                        )
                        context.insert(entry)
                        pieceOwner = entry
                    }
                }

                guard let pieceOwner else { continue }

                if !reusedOriginal {
                    segment.startDate = start
                    segment.endDate = end
                    segment.timeEntry = pieceOwner
                    reusedOriginal = true
                } else {
                    context.insert(copy(segment, start: start, end: end, owner: pieceOwner))
                }
            }

            if !reusedOriginal {
                context.delete(segment)
            }
        }
    }

    private func segmentBoundaries(
        _ segment: ActivitySegment,
        entries: [TimeEntry]
    ) -> [Date] {
        var boundaries: Set<Date> = [segment.startDate, segment.endDate]

        for entry in entries {
            if entry.startDate > segment.startDate && entry.startDate < segment.endDate {
                boundaries.insert(entry.startDate)
            }
            if let endDate = entry.endDate,
               endDate > segment.startDate,
               endDate < segment.endDate {
                boundaries.insert(endDate)
            }
        }

        return boundaries.sorted()
    }

    private func owner(
        forStart start: Date,
        end: Date,
        entries: [TimeEntry]
    ) -> TimeEntry? {
        entries.first { entry in
            guard let entryEnd = entry.endDate else { return false }
            return entry.startDate <= start && entryEnd >= end
        }
    }

    private func copy(
        _ segment: ActivitySegment,
        start: Date,
        end: Date,
        owner: TimeEntry
    ) -> ActivitySegment {
        ActivitySegment(
            appBundleId: segment.appBundleId,
            appName: segment.appName,
            windowTitle: segment.windowTitle,
            documentPath: segment.documentPath,
            url: segment.url,
            startDate: start,
            endDate: end,
            timeEntry: owner,
            note: segment.note
        )
    }

    private func entryOrder(_ lhs: TimeEntry, _ rhs: TimeEntry) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
