import SwiftData
import XCTest
@testable import Timily

@MainActor
final class ActivityTimelineViewModelTests: XCTestCase {
    func testEntriesForSelectedDayIncludesCrossMidnightAndExcludesBoundary() {
        let calendar = utcCalendar()
        let day = date(2026, 6, 30, 12, calendar: calendar)
        let viewModel = ActivityTimelineViewModel(selectedDay: day, calendar: calendar)
        let crossing = entry(
            date(2026, 6, 29, 23, 30, calendar: calendar),
            date(2026, 6, 30, 0, 30, calendar: calendar)
        )
        let endingAtStart = entry(
            date(2026, 6, 29, 23, calendar: calendar),
            date(2026, 6, 30, 0, calendar: calendar)
        )
        let startingAtEnd = entry(
            date(2026, 7, 1, 0, calendar: calendar),
            date(2026, 7, 1, 1, calendar: calendar)
        )

        let result = viewModel.entriesForSelectedDay([startingAtEnd, endingAtStart, crossing])

        XCTAssertEqual(result.map(\.id), [crossing.id])
        XCTAssertEqual(
            viewModel.displayInterval(for: crossing),
            DateInterval(
                start: date(2026, 6, 30, 0, calendar: calendar),
                end: date(2026, 6, 30, 0, 30, calendar: calendar)
            )
        )
    }

    func testRunningEntryIsClippedToDayAndInjectedNow() {
        let calendar = utcCalendar()
        let viewModel = ActivityTimelineViewModel(
            selectedDay: date(2026, 6, 30, 12, calendar: calendar),
            calendar: calendar
        )
        let running = TimeEntry(
            startDate: date(2026, 6, 29, 23, calendar: calendar),
            source: .timer
        )
        let now = date(2026, 6, 30, 12, calendar: calendar)

        XCTAssertEqual(
            viewModel.displayInterval(for: running, now: now),
            DateInterval(
                start: date(2026, 6, 30, 0, calendar: calendar),
                end: now
            )
        )
    }

    func testDayNavigationUsesCalendarDaysAndClearsSelection() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let viewModel = ActivityTimelineViewModel(
            selectedDay: date(2026, 3, 7, 12, calendar: calendar),
            calendar: calendar
        )
        viewModel.selection = [.entry(UUID()), .segment(UUID())]

        viewModel.moveDay(by: 1)
        let dstDuration = viewModel.dayInterval.duration
        viewModel.moveDay(by: 1)
        let followingDuration = viewModel.dayInterval.duration

        XCTAssertTrue(viewModel.selection.isEmpty)
        XCTAssertEqual(dstDuration, 23 * 60 * 60)
        XCTAssertEqual(followingDuration, 24 * 60 * 60)
    }

    func testPruneSelectionRemovesEntriesOutsideSnapshot() {
        let first = entry(Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 10))
        let second = entry(Date(timeIntervalSince1970: 20), Date(timeIntervalSince1970: 30))
        let viewModel = ActivityTimelineViewModel()
        viewModel.selectedEntryIDs = [first.id, second.id]

        viewModel.pruneSelection(to: [second])

        XCTAssertEqual(viewModel.selectedEntryIDs, [second.id])
    }

    func testSegmentSelectionIsDerivedFromUnifiedSelection() {
        let entryID = UUID()
        let segmentID = UUID()
        let viewModel = ActivityTimelineViewModel()

        viewModel.selection = [.entry(entryID), .segment(segmentID)]

        XCTAssertEqual(viewModel.selectedEntryIDs, [entryID])
        XCTAssertEqual(viewModel.selectedSegmentIDs, [segmentID])
    }

    func testNormalizeSelectionUsesNewlyIntroducedMode() {
        let entryID = UUID()
        let segmentID = UUID()
        let viewModel = ActivityTimelineViewModel()
        let previous: Set<ActivityTimelineSelection> = [.entry(entryID)]
        let proposed: Set<ActivityTimelineSelection> = previous.union([.segment(segmentID)])

        viewModel.normalizeSelection(from: previous, to: proposed)

        XCTAssertTrue(viewModel.selectedEntryIDs.isEmpty)
        XCTAssertEqual(viewModel.selectedSegmentIDs, [segmentID])
    }

    func testNormalizeSelectionPreservesSegmentModeForMixedShiftRange() {
        let firstSegmentID = UUID()
        let secondSegmentID = UUID()
        let entryID = UUID()
        let previous: Set<ActivityTimelineSelection> = [.segment(firstSegmentID)]
        let proposed: Set<ActivityTimelineSelection> = [
            .segment(firstSegmentID),
            .entry(entryID),
            .segment(secondSegmentID),
        ]
        let viewModel = ActivityTimelineViewModel()

        viewModel.normalizeSelection(from: previous, to: proposed)

        XCTAssertTrue(viewModel.selectedEntryIDs.isEmpty)
        XCTAssertEqual(viewModel.selectedSegmentIDs, [firstSegmentID, secondSegmentID])
    }

    func testNormalizeSelectionSwitchesToNewlyIntroducedEntryMode() {
        let entryID = UUID()
        let segmentID = UUID()
        let viewModel = ActivityTimelineViewModel()
        let previous: Set<ActivityTimelineSelection> = [.segment(segmentID)]
        let proposed: Set<ActivityTimelineSelection> = previous.union([.entry(entryID)])

        viewModel.normalizeSelection(from: previous, to: proposed)

        XCTAssertEqual(viewModel.selectedEntryIDs, [entryID])
        XCTAssertTrue(viewModel.selectedSegmentIDs.isEmpty)
    }

    func testSegmentsForSelectedDaySortsAndClipsToDay() {
        let calendar = utcCalendar()
        let day = date(2026, 6, 30, 12, calendar: calendar)
        let viewModel = ActivityTimelineViewModel(selectedDay: day, calendar: calendar)
        let owner = entry(
            date(2026, 6, 29, 23, calendar: calendar),
            date(2026, 7, 1, 1, calendar: calendar)
        )
        let later = segment(
            date(2026, 6, 30, 12, calendar: calendar),
            date(2026, 6, 30, 13, calendar: calendar),
            owner: owner
        )
        let crossing = segment(
            date(2026, 6, 29, 23, 30, calendar: calendar),
            date(2026, 6, 30, 0, 30, calendar: calendar),
            owner: owner
        )
        _ = segment(
            date(2026, 7, 1, 0, calendar: calendar),
            date(2026, 7, 1, 0, 30, calendar: calendar),
            owner: owner
        )

        XCTAssertEqual(viewModel.segmentsForSelectedDay(in: owner).map(\.id), [crossing.id, later.id])
        XCTAssertEqual(
            viewModel.displayInterval(for: crossing),
            DateInterval(
                start: date(2026, 6, 30, 0, calendar: calendar),
                end: date(2026, 6, 30, 0, 30, calendar: calendar)
            )
        )
    }

    func testPruneSelectionRemovesUnavailableAndOffDaySegments() {
        let calendar = utcCalendar()
        let viewModel = ActivityTimelineViewModel(
            selectedDay: date(2026, 6, 30, 12, calendar: calendar),
            calendar: calendar
        )
        let owner = entry(
            date(2026, 6, 30, 0, calendar: calendar),
            date(2026, 7, 1, 1, calendar: calendar)
        )
        let visible = segment(
            date(2026, 6, 30, 1, calendar: calendar),
            date(2026, 6, 30, 2, calendar: calendar),
            owner: owner
        )
        let offDay = segment(
            date(2026, 7, 1, 0, calendar: calendar),
            date(2026, 7, 1, 1, calendar: calendar),
            owner: owner
        )
        viewModel.selection = [
            .entry(owner.id),
            .segment(visible.id),
            .segment(offDay.id),
            .segment(UUID()),
        ]

        viewModel.pruneSelection(to: [owner])

        XCTAssertEqual(viewModel.selection, [.entry(owner.id), .segment(visible.id)])
    }

    func testAssignSelectedSegmentsRoutesSelectionToService() throws {
        let context = try makeContext()
        let oldProject = Project(name: "Old", colorHex: "#111111")
        let newProject = Project(name: "New", colorHex: "#222222")
        let owner = entry(Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 10))
        owner.project = oldProject
        let selectedSegment = segment(
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 10),
            owner: owner
        )
        context.insert(oldProject)
        context.insert(newProject)
        context.insert(owner)
        context.insert(selectedSegment)
        try context.save()
        let viewModel = ActivityTimelineViewModel()
        viewModel.selectedSegmentIDs = [selectedSegment.id]

        viewModel.assignSelectedSegments(to: newProject, in: context)

        let entries = try context.fetch(FetchDescriptor<TimeEntry>())
        XCTAssertFalse(viewModel.isShowingError)
        XCTAssertTrue(viewModel.selection.isEmpty)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].project?.id, newProject.id)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func entry(_ start: Date, _ end: Date) -> TimeEntry {
        TimeEntry(startDate: start, endDate: end, source: .manual)
    }

    private func segment(_ start: Date, _ end: Date, owner: TimeEntry) -> ActivitySegment {
        let segment = ActivitySegment(
            appBundleId: "com.example.app",
            appName: "Example",
            startDate: start,
            endDate: end,
            timeEntry: owner
        )
        owner.activitySegments.append(segment)
        return segment
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Project.self,
            TimeEntry.self,
            ActivitySegment.self,
            AssignmentRule.self,
            AppSettings.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}
