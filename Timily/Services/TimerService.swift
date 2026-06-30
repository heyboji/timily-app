import Foundation
import SwiftData

// MARK: - TimerClock

/// Supplies the current instant so timer timestamps are deterministic in tests.
///
/// Production uses `SystemClock`; tests inject a controllable clock. Declared
/// `nonisolated` + `Sendable` (matching `IdleTimeSource`) so the `@MainActor`
/// `TimerService` can store and call it freely.
nonisolated protocol TimerClock: Sendable {
    /// The current wall-clock instant.
    var now: Date { get }
}

/// Production clock backed by the system wall clock.
nonisolated struct SystemClock: TimerClock {
    var now: Date { Date() }
}

// MARK: - TimerError

enum TimerError: Error, Equatable {
    /// A second timer cannot start while one is already running.
    case timerAlreadyRunning
    /// The timer cannot stop without resolving overlaps with completed entries.
    case stopConflictsWithExistingEntries
}

/// Determines which entries win when a stopped timer overlaps existing work.
enum TimerStopResolution {
    /// Keep the complete timer range and trim, split, or delete existing entries.
    case replaceExisting
    /// Keep existing entries and save only the timer's non-overlapping fragments.
    case keepExisting
}

// MARK: - TimerPreset

/// A reusable project + description pair surfaced from past entries, used to
/// quickly pre-fill the start form. Selecting a preset never starts a timer.
struct TimerPreset {
    /// The project to pre-fill, or `nil` for an Unassigned preset.
    let project: Project?
    /// The description to pre-fill, or `nil` when there is none.
    let description: String?
}

extension TimerPreset: Equatable {
    /// Two presets are equal when they reference the same project (by identity)
    /// and carry the same description.
    static func == (lhs: TimerPreset, rhs: TimerPreset) -> Bool {
        lhs.project?.id == rhs.project?.id && lhs.description == rhs.description
    }
}

// MARK: - TimerService

/// Drives the single global running timer.
///
/// Invariants (see `01-product-spec.md` / `03-data-model.md`):
/// - A running timer is a `TimeEntry` with `source == .timer` and `endDate == nil`.
/// - At most one timer may run at a time, globally.
/// - Stopping fixes `endDate` and clears `lastHeartbeatDate`.
/// - A heartbeat records liveness in `lastHeartbeatDate` so a crash can be recovered.
/// - Recovery after relaunch closes a still-running timer at its last heartbeat,
///   or at its start when no heartbeat was ever recorded.
///
/// Marked `@MainActor` because `ModelContext` is main-actor-isolated, matching the
/// rest of the service layer. The clock is injected for deterministic tests.
@MainActor
struct TimerService {

    private let clock: TimerClock

    init(clock: TimerClock = SystemClock()) {
        self.clock = clock
    }

    // MARK: - Queries

    /// The currently running timer, if any.
    func activeTimer(in context: ModelContext) throws -> TimeEntry? {
        // A running entry is exactly one with no end date; only timers create those.
        let descriptor = FetchDescriptor<TimeEntry>(
            predicate: #Predicate { $0.endDate == nil }
        )
        return try context.fetch(descriptor).first { $0.source == .timer }
    }

    // MARK: - State transitions

    /// Starts a new timer with `source == .timer` and an open `endDate`.
    ///
    /// - Throws: `TimerError.timerAlreadyRunning` when a timer is already active.
    @discardableResult
    func start(
        project: Project? = nil,
        description: String? = nil,
        in context: ModelContext
    ) throws -> TimeEntry {
        guard try activeTimer(in: context) == nil else {
            throw TimerError.timerAlreadyRunning
        }

        let entry = TimeEntry(
            startDate: clock.now,
            endDate: nil,
            entryDescription: description,
            source: .timer,
            project: project
        )
        context.insert(entry)
        try saveOrRollback(context)
        return entry
    }

    /// Stops the running timer at the current instant and clears its heartbeat.
    ///
    /// - Returns: The stopped entry, or `nil` when no timer was running.
    @discardableResult
    func stop(in context: ModelContext) throws -> TimeEntry? {
        guard let timer = try activeTimer(in: context) else { return nil }

        let range = TimeRange.clampingEnd(start: timer.startDate, end: clock.now)
        let conflicts = try TimeEntryService().overlapping(
            range: range,
            excluding: timer.id,
            in: context
        )
        guard conflicts.isEmpty else {
            throw TimerError.stopConflictsWithExistingEntries
        }

        timer.endDate = range.end
        timer.lastHeartbeatDate = nil
        try saveOrRollback(context)
        return timer
    }

    /// Stops the running timer using an explicit overlap resolution.
    ///
    /// - Returns: The completed timer entries, in chronological order. The array
    ///   is empty when no timer was running or existing entries cover it entirely.
    @discardableResult
    func stop(
        resolving resolution: TimerStopResolution,
        in context: ModelContext
    ) throws -> [TimeEntry] {
        guard let timer = try activeTimer(in: context) else { return [] }
        let end = max(clock.now, timer.startDate)
        return try complete(
            timer,
            at: end,
            resolving: resolution,
            discardingUnownedActivity: false,
            in: context
        )
    }

    /// Records a liveness heartbeat on the running timer.
    ///
    /// - Returns: The updated entry, or `nil` when no timer was running.
    @discardableResult
    func heartbeat(in context: ModelContext) throws -> TimeEntry? {
        guard let timer = try activeTimer(in: context) else { return nil }

        timer.lastHeartbeatDate = max(
            max(clock.now, timer.startDate),
            timer.lastHeartbeatDate ?? timer.startDate
        )
        try saveOrRollback(context)
        return timer
    }

    /// Recovers from an unclean shutdown by closing a timer that was left running.
    ///
    /// The entry is stopped at its `lastHeartbeatDate` if present, otherwise at its
    /// `startDate` (no progress was ever recorded). Does not use the clock, because
    /// the gap between the last heartbeat and relaunch is not work time.
    ///
    /// - Returns: The recovered entry, or `nil` when no timer needed recovery.
    @discardableResult
    func recover(in context: ModelContext) throws -> TimeEntry? {
        guard let timer = try activeTimer(in: context) else { return nil }

        let end = max(timer.startDate, timer.lastHeartbeatDate ?? timer.startDate)
        return try complete(
            timer,
            at: end,
            resolving: .keepExisting,
            discardingUnownedActivity: true,
            in: context
        ).first
    }

    // MARK: - Presets

    /// Collects unique project + description pairs from existing entries.
    ///
    /// - Presets whose project is archived are excluded.
    /// - The fully empty pair (no project and no description) is skipped.
    /// - Unassigned presets (no project, but with a description) are kept.
    ///
    /// Ordering is deterministic: by project name, then description.
    func presets(in context: ModelContext) throws -> [TimerPreset] {
        let entries = try context.fetch(FetchDescriptor<TimeEntry>())

        var result: [TimerPreset] = []

        for entry in entries {
            guard entry.source == .timer else { continue }

            let project = entry.project
            // Exclude presets pointing at an archived project.
            if let project, project.isArchived { continue }

            let description = entry.entryDescription == "" ? nil : entry.entryDescription
            // A preset with neither a project nor a description carries no information.
            if project == nil && description == nil { continue }

            let preset = TimerPreset(project: project, description: description)
            if !result.contains(preset) { result.append(preset) }
        }

        return result.sorted { lhs, rhs in
            let leftName = lhs.project?.name ?? ""
            let rightName = rhs.project?.name ?? ""
            if leftName != rightName { return leftName < rightName }
            return (lhs.description ?? "") < (rhs.description ?? "")
        }
    }

    /// Returns the values a preset would pre-fill into the start form.
    ///
    /// This is intentionally pure: selecting a preset only surfaces values and
    /// **never** starts a timer. Starting remains an explicit, separate action.
    func fill(from preset: TimerPreset) -> (project: Project?, description: String?) {
        (preset.project, preset.description)
    }

    // MARK: - Private helpers

    private func complete(
        _ timer: TimeEntry,
        at end: Date,
        resolving resolution: TimerStopResolution,
        discardingUnownedActivity: Bool,
        in context: ModelContext
    ) throws -> [TimeEntry] {
        let range = TimeRange.clampingEnd(start: timer.startDate, end: end)
        let entryService = TimeEntryService()
        let conflicts = try entryService.overlapping(
            range: range,
            excluding: timer.id,
            in: context
        )
        let reconciler = ActivitySegmentReconciler()
        let affectedSegments = try reconciler.snapshot(
            ownedBy: [timer] + conflicts,
            in: context
        )
        let unownedPolicy: UnownedActivitySegmentPolicy = discardingUnownedActivity
            ? .delete
            : .throwError

        do {
            switch resolution {
            case .replaceExisting:
                var finalEntries: [TimeEntry] = []
                for conflict in conflicts {
                    finalEntries.append(
                        contentsOf: try entryService.resolveConflict(
                            existing: conflict,
                            with: range,
                            in: context
                        )
                    )
                }
                timer.endDate = range.end
                timer.lastHeartbeatDate = nil
                finalEntries.append(timer)
                try reconciler.redistribute(
                    affectedSegments,
                    among: finalEntries,
                    unownedPolicy: unownedPolicy,
                    in: context
                )
                try context.save()
                return [timer]

            case .keepExisting:
                let conflictRanges = conflicts.map { conflict in
                    TimeRange.clampingEnd(
                        start: conflict.startDate,
                        end: conflict.endDate ?? range.end
                    )
                }
                let fragments = range.subtracting(conflictRanges)

                guard let first = fragments.first else {
                    context.delete(timer)
                    try reconciler.redistribute(
                        affectedSegments,
                        among: conflicts,
                        unownedPolicy: unownedPolicy,
                        in: context
                    )
                    try context.save()
                    return []
                }

                timer.startDate = first.start
                timer.endDate = first.end
                timer.lastHeartbeatDate = nil

                var entries = [timer]
                for fragment in fragments.dropFirst() {
                    let entry = TimeEntry(
                        startDate: fragment.start,
                        endDate: fragment.end,
                        entryDescription: timer.entryDescription,
                        source: .timer,
                        project: timer.project,
                        matchedRule: timer.matchedRule,
                        lastHeartbeatDate: nil,
                        createdAt: timer.createdAt
                    )
                    context.insert(entry)
                    entries.append(entry)
                }

                try reconciler.redistribute(
                    affectedSegments,
                    among: conflicts + entries,
                    unownedPolicy: unownedPolicy,
                    in: context
                )
                try context.save()
                return entries
            }
        } catch {
            context.rollback()
            throw error
        }
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
