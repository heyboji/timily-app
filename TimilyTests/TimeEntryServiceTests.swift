import SwiftData
import XCTest
@testable import Timily

// MARK: - TimeRange pure-logic tests

/// Tests for `TimeRange` and `TimeEntryError` — no SwiftData required.
final class TimeRangeTests: XCTestCase {

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    // MARK: Initialiser validation

    func testInitRejectsEndBeforeStart() {
        XCTAssertThrowsError(try TimeRange(start: date(10), end: date(5))) { error in
            XCTAssertEqual(error as? TimeEntryError, .endBeforeStart)
        }
    }

    func testInitAcceptsZeroDuration() throws {
        let r = try TimeRange(start: date(5), end: date(5))
        XCTAssertEqual(r.start, r.end)
    }

    func testInitAcceptsPositiveDuration() throws {
        let r = try TimeRange(start: date(0), end: date(10))
        XCTAssertEqual(r.start, date(0))
        XCTAssertEqual(r.end, date(10))
    }

    // MARK: overlaps(_:)

    func testOverlapsReturnsTrueForIntersectingRanges() throws {
        let a = try TimeRange(start: date(0), end: date(10))
        let b = try TimeRange(start: date(5), end: date(15))
        XCTAssertTrue(a.overlaps(b))
        XCTAssertTrue(b.overlaps(a))
    }

    func testOverlapsReturnsTrueForContainedRange() throws {
        let outer = try TimeRange(start: date(0), end: date(20))
        let inner = try TimeRange(start: date(5), end: date(15))
        XCTAssertTrue(outer.overlaps(inner))
        XCTAssertTrue(inner.overlaps(outer))
    }

    func testAdjacentRangesDoNotOverlap() throws {
        let a = try TimeRange(start: date(0), end: date(10))
        let b = try TimeRange(start: date(10), end: date(20))
        XCTAssertFalse(a.overlaps(b), "adjacent ranges must not overlap")
        XCTAssertFalse(b.overlaps(a))
    }

    func testZeroDurationRangeDoesNotOverlapContainingRange() throws {
        let point = try TimeRange(start: date(5), end: date(5))
        let containing = try TimeRange(start: date(0), end: date(10))
        XCTAssertFalse(point.overlaps(containing))
        XCTAssertFalse(containing.overlaps(point))
    }

    func testSeparatedRangesDoNotOverlap() throws {
        let a = try TimeRange(start: date(0), end: date(5))
        let b = try TimeRange(start: date(10), end: date(15))
        XCTAssertFalse(a.overlaps(b))
        XCTAssertFalse(b.overlaps(a))
    }

    // MARK: subtracting(_:)

    func testSubtractingFullCoverageReturnsEmpty() throws {
        let inner = try TimeRange(start: date(2), end: date(8))
        let outer = try TimeRange(start: date(0), end: date(10))
        XCTAssertTrue(inner.subtracting(outer).isEmpty)
    }

    func testSubtractingLeftOverlapReturnsSingleRightPiece() throws {
        let existing = try TimeRange(start: date(0), end: date(10))
        let newRange = try TimeRange(start: date(0), end: date(5))
        let pieces = existing.subtracting(newRange)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0], try TimeRange(start: date(5), end: date(10)))
    }

    func testSubtractingRightOverlapReturnsSingleLeftPiece() throws {
        let existing = try TimeRange(start: date(0), end: date(10))
        let newRange = try TimeRange(start: date(5), end: date(10))
        let pieces = existing.subtracting(newRange)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0], try TimeRange(start: date(0), end: date(5)))
    }

    func testSubtractingInteriorReturnsTwoPieces() throws {
        let existing = try TimeRange(start: date(0), end: date(10))
        let newRange = try TimeRange(start: date(3), end: date(7))
        let pieces = existing.subtracting(newRange)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0], try TimeRange(start: date(0), end: date(3)))
        XCTAssertEqual(pieces[1], try TimeRange(start: date(7), end: date(10)))
    }

    func testSubtractingNonOverlappingReturnsSelf() throws {
        let existing = try TimeRange(start: date(0), end: date(5))
        let other = try TimeRange(start: date(10), end: date(15))
        let pieces = existing.subtracting(other)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0], existing)
    }

    // MARK: split(at:)

    func testSplitAtValidBoundaryProducesTwoPieces() throws {
        let range = try TimeRange(start: date(0), end: date(10))
        let (left, right) = try range.split(at: date(6))
        XCTAssertEqual(left, try TimeRange(start: date(0), end: date(6)))
        XCTAssertEqual(right, try TimeRange(start: date(6), end: date(10)))
    }

    func testSplitAtStartThrows() throws {
        let range = try TimeRange(start: date(0), end: date(10))
        XCTAssertThrowsError(try range.split(at: date(0))) { error in
            XCTAssertEqual(error as? TimeEntryError, .splitPointOutsideEntry)
        }
    }

    func testSplitAtEndThrows() throws {
        let range = try TimeRange(start: date(0), end: date(10))
        XCTAssertThrowsError(try range.split(at: date(10))) { error in
            XCTAssertEqual(error as? TimeEntryError, .splitPointOutsideEntry)
        }
    }

    func testSplitOutsideRangeThrows() throws {
        let range = try TimeRange(start: date(0), end: date(10))
        XCTAssertThrowsError(try range.split(at: date(20))) { error in
            XCTAssertEqual(error as? TimeEntryError, .splitPointOutsideEntry)
        }
    }
}

// MARK: - TimeEntryService SwiftData-backed tests

final class TimeEntryServiceTests: XCTestCase {

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try PersistenceController.makeContainer(inMemory: true)
        addTeardownBlock {
            _ = container
        }
        return container.mainContext
    }

    // MARK: add(_:)

    @MainActor
    func testAddSucceedsWithNoConflict() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        let entry = try service.add(start: date(0), end: date(100), source: .manual, in: context)
        XCTAssertEqual(entry.startDate, date(0))
        XCTAssertEqual(entry.endDate, date(100))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TimeEntry>()), 1)
    }

    @MainActor
    func testAddRejectsEndBeforeStart() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        XCTAssertThrowsError(
            try service.add(start: date(100), end: date(50), source: .manual, in: context)
        ) { error in
            XCTAssertEqual(error as? TimeEntryError, .endBeforeStart)
        }
    }

    @MainActor
    func testAddThrowsOnOverlap() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        _ = try service.add(start: date(0), end: date(100), source: .manual, in: context)
        XCTAssertThrowsError(
            try service.add(start: date(50), end: date(150), source: .manual, in: context)
        ) { error in
            XCTAssertEqual(error as? TimeEntryError, .overlapsExistingEntry)
        }
    }

    @MainActor
    func testAddAllowsAdjacentEntry() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        _ = try service.add(start: date(0), end: date(100), source: .manual, in: context)
        // Adjacent entry starts exactly at the previous entry's end — must not throw.
        let second = try service.add(start: date(100), end: date(200), source: .manual, in: context)
        XCTAssertEqual(second.startDate, date(100))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TimeEntry>()), 2)
    }

    @MainActor
    func testAddRejectsRangeOverlappingRunningTimer() throws {
        let context = try makeContext()
        let timer = TimeEntry(startDate: date(50), source: .timer)
        context.insert(timer)
        try context.save()

        let service = TimeEntryService()
        XCTAssertThrowsError(
            try service.add(start: date(40), end: date(60), source: .manual, in: context)
        ) { error in
            XCTAssertEqual(error as? TimeEntryError, .overlapsExistingEntry)
        }
    }

    // MARK: replace(_:)

    @MainActor
    func testReplaceTruncatesNeighborOverlappingOnRight() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        // Existing: [0, 100]
        _ = try service.add(start: date(0), end: date(100), source: .manual, in: context)
        // New range overlaps the right half of the existing entry.
        _ = try service.replace(start: date(50), end: date(150), source: .manual, in: context)

        let entries = try context.fetch(
            FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startDate)])
        )
        XCTAssertEqual(entries.count, 2)
        // Existing entry truncated to [0, 50].
        XCTAssertEqual(entries[0].startDate, date(0))
        XCTAssertEqual(entries[0].endDate, date(50))
        // New entry [50, 150].
        XCTAssertEqual(entries[1].startDate, date(50))
        XCTAssertEqual(entries[1].endDate, date(150))
    }

    @MainActor
    func testReplaceTruncatesNeighborOverlappingOnLeft() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        // Existing: [50, 150]
        _ = try service.add(start: date(50), end: date(150), source: .manual, in: context)
        // New range overlaps the left part of the existing entry.
        _ = try service.replace(start: date(0), end: date(100), source: .manual, in: context)

        let entries = try context.fetch(
            FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startDate)])
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].startDate, date(0))
        XCTAssertEqual(entries[0].endDate, date(100))
        XCTAssertEqual(entries[1].startDate, date(100))
        XCTAssertEqual(entries[1].endDate, date(150))
    }

    @MainActor
    func testReplaceSplitsEnclosingEntry() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        // Existing entry fully encloses the new range: [0, 100] vs new [30, 70].
        _ = try service.add(start: date(0), end: date(100), source: .manual, in: context)
        _ = try service.replace(start: date(30), end: date(70), source: .manual, in: context)

        let entries = try context.fetch(
            FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startDate)])
        )
        // Expect three entries: [0,30], [30,70], [70,100].
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].startDate, date(0))
        XCTAssertEqual(entries[0].endDate, date(30))
        XCTAssertEqual(entries[1].startDate, date(30))
        XCTAssertEqual(entries[1].endDate, date(70))
        XCTAssertEqual(entries[2].startDate, date(70))
        XCTAssertEqual(entries[2].endDate, date(100))
    }

    @MainActor
    func testReplaceDeletesFullyCoveredEntry() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        // Existing: [20, 80]. New: [0, 100] — fully covers existing.
        _ = try service.add(start: date(20), end: date(80), source: .manual, in: context)
        _ = try service.replace(start: date(0), end: date(100), source: .manual, in: context)

        let entries = try context.fetch(FetchDescriptor<TimeEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].startDate, date(0))
        XCTAssertEqual(entries[0].endDate, date(100))
    }

    @MainActor
    func testReplaceHandlesMultipleConflicts() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        // Two existing entries: [0, 40] and [60, 100].
        _ = try service.add(start: date(0), end: date(40), source: .manual, in: context)
        _ = try service.add(start: date(60), end: date(100), source: .manual, in: context)
        // New range covers the middle and parts of both: [20, 80].
        _ = try service.replace(start: date(20), end: date(80), source: .manual, in: context)

        let entries = try context.fetch(
            FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startDate)])
        )
        // Expected: [0,20], [20,80], [80,100]
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].endDate, date(20))
        XCTAssertEqual(entries[1].startDate, date(20))
        XCTAssertEqual(entries[1].endDate, date(80))
        XCTAssertEqual(entries[2].startDate, date(80))
    }

    @MainActor
    func testReplaceTruncatesRunningTimerThatStartedEarlier() throws {
        let context = try makeContext()
        let timer = TimeEntry(startDate: date(0), source: .timer)
        context.insert(timer)
        try context.save()

        let service = TimeEntryService()
        _ = try service.replace(start: date(50), end: date(100), source: .manual, in: context)

        XCTAssertEqual(timer.endDate, date(50))
    }

    @MainActor
    func testReplaceDeletesRunningTimerThatStartsInsideRange() throws {
        let context = try makeContext()
        let timer = TimeEntry(startDate: date(50), source: .timer)
        context.insert(timer)
        try context.save()
        let timerID = timer.id

        let service = TimeEntryService()
        _ = try service.replace(start: date(40), end: date(100), source: .manual, in: context)

        let entries = try context.fetch(FetchDescriptor<TimeEntry>())
        XCTAssertFalse(entries.contains { $0.id == timerID })
    }

    // MARK: split(entry:at:)

    @MainActor
    func testSplitEntryAtValidBoundary() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        let entry = try service.add(start: date(0), end: date(100), source: .manual, in: context)
        let (left, right) = try service.split(entry: entry, at: date(60), in: context)

        XCTAssertEqual(left.startDate, date(0))
        XCTAssertEqual(left.endDate, date(60))
        XCTAssertEqual(right.startDate, date(60))
        XCTAssertEqual(right.endDate, date(100))
        // Original deleted, two replacements.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TimeEntry>()), 2)
    }

    @MainActor
    func testSplitThrowsAtStartBoundary() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        let entry = try service.add(start: date(0), end: date(100), source: .manual, in: context)
        XCTAssertThrowsError(try service.split(entry: entry, at: date(0), in: context)) { error in
            XCTAssertEqual(error as? TimeEntryError, .splitPointOutsideEntry)
        }
    }

    @MainActor
    func testSplitThrowsAtEndBoundary() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        let entry = try service.add(start: date(0), end: date(100), source: .manual, in: context)
        XCTAssertThrowsError(try service.split(entry: entry, at: date(100), in: context)) { error in
            XCTAssertEqual(error as? TimeEntryError, .splitPointOutsideEntry)
        }
    }

    @MainActor
    func testSplitThrowsForRunningTimer() throws {
        let context = try makeContext()
        // Create a running timer entry (endDate == nil) directly.
        let entry = TimeEntry(startDate: date(0), endDate: nil, source: .timer)
        context.insert(entry)
        try context.save()

        let service = TimeEntryService()
        XCTAssertThrowsError(try service.split(entry: entry, at: date(50), in: context)) { error in
            XCTAssertEqual(error as? TimeEntryError, .splitPointOutsideEntry)
        }
    }

    @MainActor
    func testSplitPreservesMetadata() throws {
        let context = try makeContext()
        let project = Project(name: "Work", colorHex: "#FF0000")
        let rule = AssignmentRule(kind: .application, matchValue: "com.apple.dt.Xcode", project: project)
        context.insert(project)
        context.insert(rule)
        try context.save()

        let service = TimeEntryService()
        let entry = try service.add(
            start: date(0),
            end: date(100),
            description: "Deep work",
            source: .manual,
            project: project,
            in: context
        )
        let heartbeat = date(90)
        entry.matchedRule = rule
        entry.lastHeartbeatDate = heartbeat
        try context.save()
        let createdAt = entry.createdAt
        let (left, right) = try service.split(entry: entry, at: date(50), in: context)

        XCTAssertEqual(left.entryDescription, "Deep work")
        XCTAssertEqual(right.entryDescription, "Deep work")
        XCTAssertEqual(left.project?.name, "Work")
        XCTAssertEqual(right.project?.name, "Work")
        XCTAssertEqual(left.source, .manual)
        XCTAssertEqual(right.source, .manual)
        XCTAssertEqual(left.matchedRule?.id, rule.id)
        XCTAssertEqual(right.matchedRule?.id, rule.id)
        XCTAssertEqual(left.lastHeartbeatDate, heartbeat)
        XCTAssertEqual(right.lastHeartbeatDate, heartbeat)
        XCTAssertEqual(left.createdAt, createdAt)
        XCTAssertEqual(right.createdAt, createdAt)
    }

    // MARK: Boundary / edge cases

    @MainActor
    func testSingleInstantEntryCannotBeSplit() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        let entry = try service.add(start: date(5), end: date(5), source: .manual, in: context)
        // Any split point on a zero-duration entry is "outside" (start == end).
        XCTAssertThrowsError(try service.split(entry: entry, at: date(5), in: context))
    }

    @MainActor
    func testAdjacentEntriesAfterReplaceTouchAtOnePoint() throws {
        let context = try makeContext()
        let service = TimeEntryService()
        _ = try service.add(start: date(0), end: date(100), source: .manual, in: context)
        _ = try service.replace(start: date(40), end: date(60), source: .manual, in: context)

        let entries = try context.fetch(
            FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startDate)])
        )
        XCTAssertEqual(entries.count, 3)
        // Verify adjacency: end of one == start of next — no gap, no overlap.
        XCTAssertEqual(entries[0].endDate, entries[1].startDate)
        XCTAssertEqual(entries[1].endDate, entries[2].startDate)
    }
}
