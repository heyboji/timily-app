import Foundation
import SwiftData

enum ActivityTimelineError: LocalizedError, Equatable {
    case insufficientSelection
    case runningEntry
    case overlapsUnselectedEntry

    var errorDescription: String? {
        switch self {
        case .insufficientSelection:
            "Select at least two completed entries to merge."
        case .runningEntry:
            "Stop the running timer before changing this selection."
        case .overlapsUnselectedEntry:
            "The merged range contains an entry that is not selected."
        }
    }
}

@MainActor
struct ActivityTimelineService {
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
