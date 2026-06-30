import XCTest
@testable import Timily

@MainActor
final class AggregatorTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    private func period(_ start: TimeInterval, _ end: TimeInterval) throws -> TimeRange {
        try TimeRange(start: date(start), end: date(end))
    }

    private func entry(
        _ start: TimeInterval,
        _ end: TimeInterval?,
        project: Project? = nil
    ) -> TimeEntry {
        TimeEntry(
            startDate: date(start),
            endDate: end.map { date($0) },
            source: .manual,
            project: project
        )
    }

    func testSummaryClipsBothSidesAndIgnoresOutsideAndAdjacentEntries() throws {
        let entries = [
            entry(0, 20),
            entry(90, 110),
            entry(0, 10),
            entry(100, 120),
            entry(30, 40)
        ]

        let result = Aggregator.summary(entries: entries, in: try period(10, 100))

        XCTAssertEqual(result.total, 30)
        XCTAssertEqual(result.assigned, 0)
        XCTAssertEqual(result.unassigned, 30)
    }

    func testActiveEntryRunsOnlyToInjectedNow() throws {
        let result = Aggregator.summary(
            entries: [entry(10, nil)],
            in: try period(0, 100),
            now: date(45)
        )

        XCTAssertEqual(result.total, 35)
    }

    func testSummaryTotalEqualsAssignedPlusUnassigned() throws {
        let project = Project(name: "Work", colorHex: "#112233")
        let result = Aggregator.summary(
            entries: [entry(0, 30, project: project), entry(30, 50)],
            in: try period(0, 60)
        )

        XCTAssertEqual(result.assigned, 30)
        XCTAssertEqual(result.unassigned, 20)
        XCTAssertEqual(result.total, result.assigned + result.unassigned)
    }

    func testProjectBucketsIncludeProjectsAndUnassigned() throws {
        let alpha = Project(name: "Alpha", colorHex: "#112233")
        let beta = Project(name: "Beta", colorHex: "#445566")
        let entries = [
            entry(0, 10, project: alpha),
            entry(10, 30, project: alpha),
            entry(30, 45, project: beta),
            entry(45, 60)
        ]

        let buckets = Aggregator.projectBuckets(entries: entries, in: try period(0, 60))

        XCTAssertEqual(buckets, [
            ProjectDurationBucket(projectID: alpha.id, name: "Alpha", duration: 30),
            ProjectDurationBucket(projectID: beta.id, name: "Beta", duration: 15),
            ProjectDurationBucket(projectID: nil, name: "Unassigned", duration: 15)
        ])
    }

    func testAppBucketsGroupTwoAppsAndClipSegmentToPeriodAndParentEntry() throws {
        let timeEntry = entry(10, 90)
        let editor = ActivitySegment(
            appBundleId: "com.apple.dt.Xcode",
            appName: "Xcode",
            startDate: date(0),
            endDate: date(40),
            timeEntry: timeEntry
        )
        let browser = ActivitySegment(
            appBundleId: "com.apple.Safari",
            appName: "Safari",
            startDate: date(40),
            endDate: date(110),
            timeEntry: timeEntry
        )
        timeEntry.activitySegments = [editor, browser]

        let buckets = Aggregator.appBuckets(entries: [timeEntry], in: try period(20, 100))

        XCTAssertEqual(buckets, [
            AppDurationBucket(bundleID: "com.apple.Safari", name: "Safari", duration: 50),
            AppDurationBucket(bundleID: "com.apple.dt.Xcode", name: "Xcode", duration: 20)
        ])
        XCTAssertEqual(buckets.map(\.duration).reduce(0, +), 70)
        XCTAssertEqual(
            buckets.map(\.duration).reduce(0, +),
            Aggregator.summary(entries: [timeEntry], in: try period(20, 100)).total
        )
    }

    func testAppBucketsGroupByBundleIDWhenDisplayNamesDiffer() throws {
        let timeEntry = entry(0, 30)
        timeEntry.activitySegments = [
            ActivitySegment(
                appBundleId: "com.example.editor",
                appName: "Zeta Editor",
                startDate: date(0),
                endDate: date(10),
                timeEntry: timeEntry
            ),
            ActivitySegment(
                appBundleId: "com.example.editor",
                appName: "Alpha Editor",
                startDate: date(10),
                endDate: date(30),
                timeEntry: timeEntry
            )
        ]

        XCTAssertEqual(
            Aggregator.appBuckets(entries: [timeEntry], in: try period(0, 30)),
            [
                AppDurationBucket(
                    bundleID: "com.example.editor",
                    name: "Alpha Editor",
                    duration: 30
                )
            ]
        )
    }

    func testHourBucketsSplitAtHourBoundary() throws {
        let entries = [entry(3_300, 3_900)]

        let buckets = Aggregator.hourBuckets(
            entries: entries,
            in: try period(0, 7_200),
            calendar: utcCalendar
        )

        XCTAssertEqual(buckets, [
            TimeDurationBucket(start: date(0), end: date(3_600), duration: 300),
            TimeDurationBucket(start: date(3_600), end: date(7_200), duration: 300)
        ])
    }

    func testDayBucketsSplitAtMidnight() throws {
        let day: TimeInterval = 86_400
        let entries = [entry(day - 600, day + 900)]

        let buckets = Aggregator.dayBuckets(
            entries: entries,
            in: try period(0, day * 2),
            calendar: utcCalendar
        )

        XCTAssertEqual(buckets, [
            TimeDurationBucket(start: date(0), end: date(day), duration: 600),
            TimeDurationBucket(start: date(day), end: date(day * 2), duration: 900)
        ])
    }

    func testEmptyInputProducesEmptyAggregation() throws {
        let range = try period(0, 100)

        XCTAssertEqual(
            Aggregator.summary(entries: [], in: range),
            AggregationSummary(total: 0, assigned: 0, unassigned: 0)
        )
        XCTAssertTrue(Aggregator.projectBuckets(entries: [], in: range).isEmpty)
        XCTAssertTrue(Aggregator.appBuckets(entries: [], in: range).isEmpty)
        XCTAssertTrue(Aggregator.hourBuckets(entries: [], in: range).isEmpty)
        XCTAssertTrue(Aggregator.dayBuckets(entries: [], in: range).isEmpty)
    }

    func testProjectAndTimeBucketSumsEqualTotal() throws {
        let project = Project(name: "Work", colorHex: "#112233")
        let entries = [
            entry(1_800, 5_400, project: project),
            entry(5_400, 9_000)
        ]
        let range = try period(0, 10_800)
        let total = Aggregator.summary(entries: entries, in: range).total
        let projects = Aggregator.projectBuckets(entries: entries, in: range)
        let hours = Aggregator.hourBuckets(
            entries: entries,
            in: range,
            calendar: utcCalendar
        )
        let days = Aggregator.dayBuckets(
            entries: entries,
            in: range,
            calendar: utcCalendar
        )

        XCTAssertEqual(projects.map(\.duration).reduce(0, +), total)
        XCTAssertEqual(hours.map(\.duration).reduce(0, +), total)
        XCTAssertEqual(days.map(\.duration).reduce(0, +), total)
    }
}
