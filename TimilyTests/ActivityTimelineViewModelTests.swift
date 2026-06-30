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
        viewModel.selectedEntryIDs = [UUID()]

        viewModel.moveDay(by: 1)
        let dstDuration = viewModel.dayInterval.duration
        viewModel.moveDay(by: 1)
        let followingDuration = viewModel.dayInterval.duration

        XCTAssertTrue(viewModel.selectedEntryIDs.isEmpty)
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
}
