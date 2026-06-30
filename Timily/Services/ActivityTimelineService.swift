import Foundation
import SwiftData

enum ActivityTimelineError: LocalizedError, Equatable {
    case insufficientSelection
    case emptySelection
    case invalidSegmentRange
    case missingSegment
    case orphanSegment
    case activityMustBeIsolated
    case runningEntry
    case overlapsUnselectedEntry

    var errorDescription: String? {
        switch self {
        case .insufficientSelection:
            "Select at least two completed entries to merge."
        case .emptySelection:
            "Select at least one activity segment."
        case .invalidSegmentRange:
            "One or more selected activity segments have invalid time boundaries."
        case .missingSegment:
            "One or more selected activity segments no longer exist."
        case .orphanSegment:
            "One or more selected activity segments have no time entry."
        case .activityMustBeIsolated:
            "Only an isolated Unassigned activity entry can be deleted."
        case .runningEntry:
            "Stop the running timer before changing this selection."
        case .overlapsUnselectedEntry:
            "The merged range contains an entry that is not selected."
        }
    }
}

@MainActor
struct ActivityTimelineService {
    func canDeleteActivity(_ segment: ActivitySegment) -> Bool {
        guard let owner = segment.timeEntry,
              let ownerEnd = owner.endDate else {
            return false
        }

        return owner.source == .fromActivity
            && owner.project == nil
            && owner.activitySegments.count == 1
            && owner.activitySegments.first?.id == segment.id
            && owner.startDate == segment.startDate
            && ownerEnd == segment.endDate
    }

    func deleteActivity(id: UUID, in context: ModelContext) throws {
        let segments = try context.fetch(FetchDescriptor<ActivitySegment>())
        guard let segment = segments.first(where: { $0.id == id }) else {
            throw ActivityTimelineError.missingSegment
        }
        guard canDeleteActivity(segment), let owner = segment.timeEntry else {
            throw ActivityTimelineError.activityMustBeIsolated
        }

        do {
            context.delete(segment)
            context.delete(owner)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func assign(
        segmentIDs: Set<UUID>,
        to project: Project?,
        in context: ModelContext
    ) throws {
        guard !segmentIDs.isEmpty else {
            throw ActivityTimelineError.emptySelection
        }

        let allSegments = try context.fetch(FetchDescriptor<ActivitySegment>())
        let selectedSegments = allSegments.filter { segmentIDs.contains($0.id) }
        guard selectedSegments.count == segmentIDs.count else {
            throw ActivityTimelineError.missingSegment
        }
        guard selectedSegments.allSatisfy({ $0.timeEntry != nil }) else {
            throw ActivityTimelineError.orphanSegment
        }
        guard selectedSegments.allSatisfy({ $0.timeEntry?.endDate != nil }) else {
            throw ActivityTimelineError.runningEntry
        }

        var ownersByID: [UUID: TimeEntry] = [:]
        var selectedByOwnerID: [UUID: [ActivitySegment]] = [:]
        for segment in selectedSegments {
            guard let owner = segment.timeEntry else {
                throw ActivityTimelineError.orphanSegment
            }
            ownersByID[owner.id] = owner
            selectedByOwnerID[owner.id, default: []].append(segment)
        }

        let owners = ownersByID.values.sorted(by: entryOrder)
        for owner in owners {
            try validate(
                selectedByOwnerID[owner.id, default: []].sorted(by: segmentOrder),
                within: owner
            )
        }
        let reconciler = ActivitySegmentReconciler()
        let affectedSegments = try reconciler.snapshot(ownedBy: owners, in: context)

        do {
            var replacements: [TimeEntry] = []
            for owner in owners {
                guard let endDate = owner.endDate else {
                    throw ActivityTimelineError.runningEntry
                }
                let selected = selectedByOwnerID[owner.id, default: []].sorted(by: segmentOrder)
                var cursor = owner.startDate

                for segment in selected {
                    if cursor < segment.startDate {
                        replacements.append(copy(owner, start: cursor, end: segment.startDate))
                    }
                    replacements.append(
                        assignedCopy(
                            owner,
                            start: segment.startDate,
                            end: segment.endDate,
                            project: project
                        )
                    )
                    cursor = segment.endDate
                }

                if cursor < endDate {
                    replacements.append(copy(owner, start: cursor, end: endDate))
                }
                context.delete(owner)
            }

            replacements.forEach(context.insert)
            try reconciler.redistribute(
                affectedSegments,
                among: replacements,
                unownedPolicy: .throwError,
                in: context
            )
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func assign(
        _ entries: [TimeEntry],
        to project: Project?,
        in context: ModelContext
    ) throws {
        let entries = unique(entries)
        guard !entries.isEmpty else { throw ActivityTimelineError.insufficientSelection }
        guard entries.allSatisfy({ $0.endDate != nil }) else {
            throw ActivityTimelineError.runningEntry
        }

        do {
            for entry in entries {
                entry.project = project
                entry.matchedRule = nil
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    @discardableResult
    func merge(
        _ entries: [TimeEntry],
        in context: ModelContext
    ) throws -> TimeEntry {
        let entries = unique(entries)
        guard entries.count >= 2 else { throw ActivityTimelineError.insufficientSelection }

        let completed = try entries.map { entry -> (TimeEntry, Date) in
            guard let endDate = entry.endDate else { throw ActivityTimelineError.runningEntry }
            return (entry, endDate)
        }
        let start = entries.map(\.startDate).min() ?? .distantPast
        let end = completed.map(\.1).max() ?? start
        let range = try TimeRange(start: start, end: end)
        let selectedIDs = Set(entries.map(\.id))
        let conflicts = try TimeEntryService().overlapping(range: range, in: context)
        guard conflicts.allSatisfy({ selectedIDs.contains($0.id) }) else {
            throw ActivityTimelineError.overlapsUnselectedEntry
        }

        let merged = TimeEntry(
            startDate: start,
            endDate: end,
            entryDescription: sharedDescription(in: entries),
            source: .manual,
            project: sharedProject(in: entries),
            createdAt: entries.map(\.createdAt).min() ?? .now
        )
        let segments = entries.flatMap(\.activitySegments)

        do {
            context.insert(merged)
            for segment in segments {
                segment.timeEntry = merged
            }
            for entry in entries {
                context.delete(entry)
            }
            try context.save()
            return merged
        } catch {
            context.rollback()
            throw error
        }
    }

    private func unique(_ entries: [TimeEntry]) -> [TimeEntry] {
        var seen = Set<UUID>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    private func copy(
        _ entry: TimeEntry,
        start: Date,
        end: Date
    ) -> TimeEntry {
        TimeEntry(
            startDate: start,
            endDate: end,
            entryDescription: entry.entryDescription,
            source: entry.source,
            project: entry.project,
            matchedRule: entry.matchedRule,
            lastHeartbeatDate: entry.lastHeartbeatDate,
            createdAt: entry.createdAt
        )
    }

    private func assignedCopy(
        _ entry: TimeEntry,
        start: Date,
        end: Date,
        project: Project?
    ) -> TimeEntry {
        TimeEntry(
            startDate: start,
            endDate: end,
            entryDescription: entry.entryDescription,
            source: entry.source,
            project: project,
            matchedRule: nil,
            lastHeartbeatDate: entry.lastHeartbeatDate,
            createdAt: entry.createdAt
        )
    }

    private func entryOrder(_ lhs: TimeEntry, _ rhs: TimeEntry) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func segmentOrder(_ lhs: ActivitySegment, _ rhs: ActivitySegment) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func validate(
        _ segments: [ActivitySegment],
        within owner: TimeEntry
    ) throws {
        guard let ownerEnd = owner.endDate else {
            throw ActivityTimelineError.runningEntry
        }

        var previousEnd = owner.startDate
        for segment in segments {
            guard segment.startDate >= owner.startDate,
                  segment.startDate < segment.endDate,
                  segment.endDate <= ownerEnd,
                  segment.startDate >= previousEnd else {
                throw ActivityTimelineError.invalidSegmentRange
            }
            previousEnd = segment.endDate
        }
    }

    private func sharedProject(in entries: [TimeEntry]) -> Project? {
        let projectIDs = Set(entries.map { $0.project?.id })
        guard projectIDs.count == 1 else { return nil }
        return entries[0].project
    }

    private func sharedDescription(in entries: [TimeEntry]) -> String? {
        let descriptions = Set(entries.map(\.entryDescription))
        guard descriptions.count == 1 else { return nil }
        return entries[0].entryDescription
    }
}
