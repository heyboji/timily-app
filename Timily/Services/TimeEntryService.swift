import Foundation
import SwiftData

/// Manages the creation and modification of `TimeEntry` objects while enforcing
/// the non-overlap invariant described in `03-data-model.md` §5.
///
/// All methods must be called from the main actor because `ModelContext.mainContext`
/// is main-actor-isolated.
@MainActor
struct TimeEntryService {

    // MARK: - Public API

    /// Inserts a new entry for `[start, end]` **without** touching any existing entry.
    ///
    /// - Throws: `TimeEntryError.endBeforeStart` when `end < start`;
    ///           `TimeEntryError.overlapsExistingEntry` when any stored entry conflicts.
    /// - Returns: The newly inserted and saved `TimeEntry`.
    @discardableResult
    func add(
        start: Date,
        end: Date,
        description: String? = nil,
        source: EntrySource,
        project: Project? = nil,
        in context: ModelContext
    ) throws -> TimeEntry {
        let range = try TimeRange(start: start, end: end)
        let conflicts = try overlapping(range: range, in: context)
        guard conflicts.isEmpty else { throw TimeEntryError.overlapsExistingEntry }
        let entry = makeEntry(range: range, description: description, source: source, project: project)
        context.insert(entry)
        try saveOrRollback(context)
        return entry
    }

    /// Inserts a new entry for `[start, end]`, atomically truncating or splitting
    /// any existing entries that conflict with the new range.
    ///
    /// - Replace cases:
    ///   - Existing entry is **fully covered** → deleted.
    ///   - Existing entry **overlaps on one side** → truncated to the non-overlapping piece.
    ///   - Existing entry **fully encloses** the new range → split into two pieces.
    ///   - Running timer (`endDate == nil`) that **starts inside** the new range → deleted;
    ///     if it starts before the new range it is truncated at `start`.
    ///
    /// - Throws: `TimeEntryError.endBeforeStart` when `end < start`.
    /// - Returns: The newly inserted `TimeEntry`.
    @discardableResult
    func replace(
        start: Date,
        end: Date,
        description: String? = nil,
        source: EntrySource,
        project: Project? = nil,
        in context: ModelContext
    ) throws -> TimeEntry {
        let range = try TimeRange(start: start, end: end)
        let conflicts = try overlapping(range: range, in: context)
        do {
            for existing in conflicts {
                try resolveConflict(existing: existing, with: range, in: context)
            }
            let entry = makeEntry(
                range: range,
                description: description,
                source: source,
                project: project
            )
            context.insert(entry)
            try context.save()
            return entry
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Updates an existing entry while preserving the non-overlap invariant.
    ///
    /// When `replacingConflicts` is `false`, overlapping entries cause
    /// `TimeEntryError.overlapsExistingEntry`. When it is `true`, conflicting
    /// entries are truncated, split, or deleted using the same rules as Replace.
    func update(
        _ entry: TimeEntry,
        start: Date,
        end: Date,
        description: String?,
        project: Project?,
        replacingConflicts: Bool,
        in context: ModelContext
    ) throws {
        let range = try TimeRange(start: start, end: end)
        let conflicts = try overlapping(range: range, excluding: entry.id, in: context)
        guard replacingConflicts || conflicts.isEmpty else {
            throw TimeEntryError.overlapsExistingEntry
        }

        do {
            if replacingConflicts {
                for conflict in conflicts {
                    try resolveConflict(existing: conflict, with: range, in: context)
                }
            }

            entry.startDate = range.start
            entry.endDate = range.end
            entry.entryDescription = description
            entry.project = project
            entry.matchedRule = nil
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Deletes an entry while preserving its raw activity segments.
    ///
    /// Each linked segment is materialized as a separate Unassigned entry so
    /// its duration remains accounted for without keeping the deleted entry.
    func delete(_ entry: TimeEntry, in context: ModelContext) throws {
        let segments = entry.activitySegments

        do {
            context.delete(entry)

            for segment in segments {
                let replacement = TimeEntry(
                    startDate: segment.startDate,
                    endDate: segment.endDate,
                    entryDescription: segment.note,
                    source: .fromActivity
                )
                context.insert(replacement)
                segment.timeEntry = replacement
            }

            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Splits `entry` at `boundary` into two consecutive entries.
    ///
    /// Both resulting entries inherit the description, source, and project of the
    /// original. The original entry is deleted from the context.
    ///
    /// - Throws: `TimeEntryError.splitPointOutsideEntry` when `boundary` is not
    ///   strictly inside the entry's `(startDate, endDate)` range, or when the
    ///   entry has no `endDate` (running timer).
    /// - Returns: `(left, right)` — the two new entries in chronological order.
    @discardableResult
    func split(
        entry: TimeEntry,
        at boundary: Date,
        in context: ModelContext
    ) throws -> (TimeEntry, TimeEntry) {
        guard let endDate = entry.endDate else {
            // Running timers have no fixed end — cannot split.
            throw TimeEntryError.splitPointOutsideEntry
        }
        let range = try TimeRange(start: entry.startDate, end: endDate)
        let (leftRange, rightRange) = try range.split(at: boundary)

        do {
            let left = copy(entry, with: leftRange)
            let right = copy(entry, with: rightRange)
            context.delete(entry)
            context.insert(left)
            context.insert(right)
            try context.save()
            return (left, right)
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - Internal helpers

    /// Fetches entries whose intervals overlap `range` using half-open semantics.
    func overlapping(
        range: TimeRange,
        excluding excludedID: UUID? = nil,
        in context: ModelContext
    ) throws -> [TimeEntry] {
        guard range.start < range.end else { return [] }

        let rangeEnd = range.end
        // Fetch candidates whose startDate is before the new range ends.
        // We then filter in memory for the second half of the overlap condition because
        // SwiftData predicates do not elegantly handle Optional<Date> comparisons.
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.startDate < rangeEnd }
        )
        let candidates = try context.fetch(descriptor)
        let rangeStart = range.start
        return candidates.filter { entry in
            guard entry.id != excludedID else { return false }
            // Half-open overlap: existing must end strictly after range.start.
            // A nil endDate means the timer is still running → always potentially overlapping.
            guard let end = entry.endDate else { return true }
            return end > rangeStart
        }
    }

    /// Reconciles one conflicting `existing` entry with the incoming `newRange`.
    /// Does **not** call `context.save()` — the caller is responsible for a single save.
    func resolveConflict(
        existing: TimeEntry,
        with newRange: TimeRange,
        in context: ModelContext
    ) throws {
        guard let existingEnd = existing.endDate else {
            // Running timer (endDate == nil): truncate or delete.
            if existing.startDate >= newRange.start {
                // Timer starts inside (or at the edge of) the new range — delete it.
                context.delete(existing)
            } else {
                // Timer started before the new range — truncate at the new range's start.
                existing.endDate = newRange.start
            }
            return
        }

        let existingRange = try TimeRange(start: existing.startDate, end: existingEnd)
        let pieces = existingRange.subtracting(newRange)

        switch pieces.count {
        case 0:
            // New range completely covers existing entry — delete it.
            context.delete(existing)

        case 1:
            // Partial overlap on one side — resize existing to the surviving piece.
            existing.startDate = pieces[0].start
            existing.endDate = pieces[0].end

        case 2:
            // New range is strictly interior — keep existing as the left piece,
            // insert a new entry for the right piece (inheriting all metadata).
            existing.endDate = pieces[0].end
            let rightEntry = copy(existing, with: pieces[1])
            context.insert(rightEntry)

        default:
            break
        }
    }

    // MARK: - Private helpers

    private func makeEntry(
        range: TimeRange,
        description: String?,
        source: EntrySource,
        project: Project?
    ) -> TimeEntry {
        TimeEntry(
            startDate: range.start,
            endDate: range.end,
            entryDescription: description,
            source: source,
            project: project
        )
    }

    private func copy(_ entry: TimeEntry, with range: TimeRange) -> TimeEntry {
        TimeEntry(
            startDate: range.start,
            endDate: range.end,
            entryDescription: entry.entryDescription,
            source: entry.source,
            project: entry.project,
            matchedRule: entry.matchedRule,
            lastHeartbeatDate: entry.lastHeartbeatDate,
            createdAt: entry.createdAt
        )
    }

    private func saveOrRollback(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
