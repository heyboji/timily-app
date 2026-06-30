import Foundation

// MARK: - TimeEntryError

/// Errors thrown by time-entry invariant checks.
nonisolated enum TimeEntryError: Error, Equatable {
    /// `endDate` is strictly before `startDate`.
    case endBeforeStart
    /// The proposed range overlaps at least one existing entry; use Replace to override.
    case overlapsExistingEntry
    /// The split boundary is at or outside the entry's start/end bounds.
    case splitPointOutsideEntry
}

// MARK: - TimeRange

/// A half-open time interval `[start, end)`.
///
/// **Adjacency rule:** two ranges that touch at exactly one instant are *not*
/// considered overlapping — adjacent entries are allowed (half-open semantics
/// for the overlap check).
nonisolated struct TimeRange: Equatable, Sendable {
    let start: Date
    let end: Date

    /// Creates a `TimeRange`.
    /// - Throws: `TimeEntryError.endBeforeStart` when `end < start`.
    init(start: Date, end: Date) throws {
        guard end >= start else { throw TimeEntryError.endBeforeStart }
        self.start = start
        self.end = end
    }

    /// Private unchecked initialiser for use when the invariant is already guaranteed.
    private init(unchecked start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// Creates a range while clamping `end` so it cannot precede `start`.
    static func clampingEnd(start: Date, end: Date) -> TimeRange {
        TimeRange(unchecked: start, end: max(start, end))
    }

    // MARK: Interval predicates

    /// Returns `true` when the two ranges share more than a single instant.
    ///
    /// Adjacent ranges that meet at exactly one boundary point return `false`:
    ///   `[0, 10]` vs `[10, 20]` → `false`.
    func overlaps(_ other: TimeRange) -> Bool {
        guard start < end, other.start < other.end else { return false }
        return start < other.end && other.start < end
    }

    // MARK: Set operations

    /// Returns the portion(s) of `self` not covered by `other`.
    ///
    /// | Relationship            | Result count |
    /// |-------------------------|-------------|
    /// | `other` fully covers `self` | 0         |
    /// | Partial overlap (one side)  | 1         |
    /// | `other` strictly interior   | 2         |
    /// | No overlap                  | 1 (self)  |
    func subtracting(_ other: TimeRange) -> [TimeRange] {
        guard overlaps(other) else { return [self] }

        var pieces: [TimeRange] = []

        // Left remnant: the portion of `self` that ends before `other` begins.
        if start < other.start {
            pieces.append(TimeRange(unchecked: start, end: min(end, other.start)))
        }

        // Right remnant: the portion of `self` that starts after `other` ends.
        if other.end < end {
            pieces.append(TimeRange(unchecked: max(start, other.end), end: end))
        }

        return pieces
    }

    /// Returns the portions of `self` not covered by any of `others`.
    func subtracting(_ others: [TimeRange]) -> [TimeRange] {
        let sortedOthers = others.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }

        return sortedOthers.reduce([self]) { pieces, other in
            pieces.flatMap { $0.subtracting(other) }
        }
    }

    /// Splits `self` at `point`, returning `(left, right)` where
    /// `left = [start, point]` and `right = [point, end]`.
    ///
    /// - Throws: `TimeEntryError.splitPointOutsideEntry` when `point` is not
    ///   strictly inside `(start, end)` (i.e. at or beyond the bounds).
    func split(at point: Date) throws -> (TimeRange, TimeRange) {
        guard point > start, point < end else {
            throw TimeEntryError.splitPointOutsideEntry
        }
        return (
            TimeRange(unchecked: start, end: point),
            TimeRange(unchecked: point, end: end)
        )
    }
}
