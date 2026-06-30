import Foundation

nonisolated struct AggregationSummary: Equatable, Sendable {
    let total: TimeInterval
    let assigned: TimeInterval
    let unassigned: TimeInterval
}

nonisolated struct ProjectDurationBucket: Equatable, Sendable {
    let projectID: UUID?
    let name: String
    let duration: TimeInterval
}

nonisolated struct AppDurationBucket: Equatable, Sendable {
    let bundleID: String
    let name: String
    let duration: TimeInterval
}

nonisolated struct TimeDurationBucket: Equatable, Sendable {
    let start: Date
    let end: Date
    let duration: TimeInterval
}

/// Pure dashboard calculations over caller-supplied time entries.
@MainActor
enum Aggregator {
    static func summary(
        entries: [TimeEntry],
        in period: TimeRange,
        now: Date = .now
    ) -> AggregationSummary {
        var assigned: TimeInterval = 0
        var unassigned: TimeInterval = 0

        for entry in entries {
            let duration = clippedDuration(of: entry, in: period, now: now)
            if entry.project == nil {
                unassigned += duration
            } else {
                assigned += duration
            }
        }

        return AggregationSummary(
            total: assigned + unassigned,
            assigned: assigned,
            unassigned: unassigned
        )
    }

    static func projectBuckets(
        entries: [TimeEntry],
        in period: TimeRange,
        now: Date = .now
    ) -> [ProjectDurationBucket] {
        struct ProjectKey: Hashable {
            let id: UUID?
            let name: String
        }

        var durations: [ProjectKey: TimeInterval] = [:]

        for entry in entries {
            let duration = clippedDuration(of: entry, in: period, now: now)
            guard duration > 0 else { continue }

            let key = ProjectKey(
                id: entry.project?.id,
                name: entry.project?.name ?? "Unassigned"
            )
            durations[key, default: 0] += duration
        }

        return durations
            .map {
                ProjectDurationBucket(
                    projectID: $0.key.id,
                    name: $0.key.name,
                    duration: $0.value
                )
            }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.projectID?.uuidString ?? "") < ($1.projectID?.uuidString ?? "")
            }
    }

    /// Groups linked activity context without adding it to entry totals.
    static func appBuckets(
        entries: [TimeEntry],
        in period: TimeRange,
        now: Date = .now
    ) -> [AppDurationBucket] {
        var durations: [String: TimeInterval] = [:]
        var names: [String: String] = [:]

        for entry in entries {
            let parentEnd = entry.endDate ?? now

            for segment in entry.activitySegments {
                let start = max(period.start, max(entry.startDate, segment.startDate))
                let end = min(period.end, min(parentEnd, segment.endDate))
                guard start < end else { continue }

                let bundleID = segment.appBundleId
                durations[bundleID, default: 0] += end.timeIntervalSince(start)

                if !segment.appName.isEmpty,
                   names[bundleID].map({ segment.appName < $0 }) ?? true {
                    names[bundleID] = segment.appName
                }
            }
        }

        return durations
            .map {
                AppDurationBucket(
                    bundleID: $0.key,
                    name: names[$0.key] ?? "",
                    duration: $0.value
                )
            }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.bundleID < $1.bundleID
            }
    }

    static func hourBuckets(
        entries: [TimeEntry],
        in period: TimeRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [TimeDurationBucket] {
        timeBuckets(
            entries: entries,
            in: period,
            now: now,
            calendar: calendar,
            component: .hour
        )
    }

    static func dayBuckets(
        entries: [TimeEntry],
        in period: TimeRange,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [TimeDurationBucket] {
        timeBuckets(
            entries: entries,
            in: period,
            now: now,
            calendar: calendar,
            component: .day
        )
    }

    private static func clippedRange(
        of entry: TimeEntry,
        in period: TimeRange,
        now: Date
    ) -> (start: Date, end: Date)? {
        let start = max(entry.startDate, period.start)
        let end = min(entry.endDate ?? now, period.end)
        guard start < end else { return nil }
        return (start, end)
    }

    private static func clippedDuration(
        of entry: TimeEntry,
        in period: TimeRange,
        now: Date
    ) -> TimeInterval {
        guard let range = clippedRange(of: entry, in: period, now: now) else { return 0 }
        return range.end.timeIntervalSince(range.start)
    }

    private static func timeBuckets(
        entries: [TimeEntry],
        in period: TimeRange,
        now: Date,
        calendar: Calendar,
        component: Calendar.Component
    ) -> [TimeDurationBucket] {
        var durations: [Date: TimeInterval] = [:]
        var intervals: [Date: DateInterval] = [:]

        for entry in entries {
            guard let range = clippedRange(of: entry, in: period, now: now) else { continue }
            var cursor = range.start

            while cursor < range.end,
                  let bucket = calendar.dateInterval(of: component, for: cursor) {
                let sliceEnd = min(range.end, bucket.end)
                guard cursor < sliceEnd else { break }

                durations[bucket.start, default: 0] += sliceEnd.timeIntervalSince(cursor)
                intervals[bucket.start] = bucket
                cursor = sliceEnd
            }
        }

        return durations.keys.sorted().compactMap { start in
            guard let interval = intervals[start], let duration = durations[start] else { return nil }
            return TimeDurationBucket(
                start: interval.start,
                end: interval.end,
                duration: duration
            )
        }
    }
}
