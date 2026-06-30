import SwiftData
import XCTest
@testable import Timily

// MARK: - Test clock

/// Reference-type clock that tests advance between calls.
///
/// `@unchecked Sendable` is safe here because all mutation happens on `@MainActor`
/// within these test methods (same rationale as `MockIdleTimeSource`).
private final class MutableClock: TimerClock, @unchecked Sendable {
    nonisolated(unsafe) var now: Date
    init(_ start: Date) { now = start }
}

// MARK: - TimerServiceTests

@MainActor
final class TimerServiceTests: XCTestCase {

    // MARK: Fixtures

    private func makeContext() throws -> ModelContext {
        let container = try PersistenceController.makeContainer(inMemory: true)
        addTeardownBlock { _ = container }
        return container.mainContext
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    @discardableResult
    private func makeProject(
        _ name: String,
        archived: Bool = false,
        in context: ModelContext
    ) -> Project {
        let project = Project(name: name, colorHex: "#112233", isArchived: archived)
        context.insert(project)
        return project
    }

    private func entryCount(in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<TimeEntry>())
    }

    private func sortedEntries(in context: ModelContext) throws -> [TimeEntry] {
        try context.fetch(
            FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startDate)])
        )
    }

    private func sortedSegments(in context: ModelContext) throws -> [ActivitySegment] {
        try context.fetch(
            FetchDescriptor<ActivitySegment>(sortBy: [SortDescriptor(\.startDate)])
        )
    }

    private func assertNoOverlaps(
        _ entries: [TimeEntry],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for pair in zip(entries, entries.dropFirst()) {
            guard let leftEnd = pair.0.endDate else {
                XCTFail("entry is still running", file: file, line: line)
                continue
            }
            XCTAssertLessThanOrEqual(leftEnd, pair.1.startDate, file: file, line: line)
        }
    }

    private func assertSegmentsAreContained(
        _ segments: [ActivitySegment],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for segment in segments {
            guard let owner = segment.timeEntry, let ownerEnd = owner.endDate else {
                XCTFail("segment has no completed owner", file: file, line: line)
                continue
            }
            XCTAssertLessThanOrEqual(owner.startDate, segment.startDate, file: file, line: line)
            XCTAssertGreaterThanOrEqual(ownerEnd, segment.endDate, file: file, line: line)
        }
    }

    // MARK: - Start

    func testStartCreatesRunningTimer() throws {
        let context = try makeContext()
        let clock = MutableClock(date(100))
        let service = TimerService(clock: clock)

        let entry = try service.start(in: context)

        XCTAssertEqual(entry.source, .timer)
        XCTAssertEqual(entry.startDate, date(100))
        XCTAssertNil(entry.endDate, "a freshly started timer has no end date")
        XCTAssertNil(entry.project)
        XCTAssertNil(entry.entryDescription)
        XCTAssertEqual(try entryCount(in: context), 1)
    }

    func testStartWithProjectAndDescription() throws {
        let context = try makeContext()
        let project = makeProject("Work", in: context)
        let service = TimerService(clock: MutableClock(date(0)))

        let entry = try service.start(project: project, description: "Deep work", in: context)

        XCTAssertEqual(entry.project?.id, project.id)
        XCTAssertEqual(entry.entryDescription, "Deep work")
    }

    func testStartRejectsSecondTimer() throws {
        let context = try makeContext()
        let service = TimerService(clock: MutableClock(date(0)))

        _ = try service.start(in: context)
        XCTAssertThrowsError(try service.start(in: context)) { error in
            XCTAssertEqual(error as? TimerError, .timerAlreadyRunning)
        }
        // The rejected start must not create a second entry.
        XCTAssertEqual(try entryCount(in: context), 1)
    }

    func testStartAllowedAfterStop() throws {
        let context = try makeContext()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)

        _ = try service.start(in: context)
        clock.now = date(50)
        _ = try service.stop(in: context)
        // A new timer may start once the previous one is stopped.
        clock.now = date(60)
        let second = try service.start(in: context)

        XCTAssertNil(second.endDate)
        XCTAssertEqual(try entryCount(in: context), 2)
    }

    // MARK: - Stop

    func testStopSetsEndDateAndClearsHeartbeat() throws {
        let context = try makeContext()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)

        _ = try service.start(in: context)
        clock.now = date(30)
        _ = try service.heartbeat(in: context)
        clock.now = date(90)
        let stopped = try service.stop(in: context)

        XCTAssertEqual(stopped?.endDate, date(90))
        XCTAssertNil(stopped?.lastHeartbeatDate, "stop clears the heartbeat")
        XCTAssertNil(try service.activeTimer(in: context))
    }

    func testStopWithNoActiveTimerReturnsNil() throws {
        let context = try makeContext()
        let service = TimerService(clock: MutableClock(date(0)))
        XCTAssertNil(try service.stop(in: context))
    }

    func testStopClampsEndDateToStartWhenClockMovesBackward() throws {
        let context = try makeContext()
        let clock = MutableClock(date(100))
        let service = TimerService(clock: clock)

        _ = try service.start(in: context)
        clock.now = date(50)
        let stopped = try service.stop(in: context)

        XCTAssertEqual(stopped?.endDate, date(100))
    }

    func testStopWithConflictThrowsWithoutMutatingTimer() throws {
        let context = try makeContext()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)
        let timer = try service.start(in: context)
        clock.now = date(30)
        _ = try service.heartbeat(in: context)
        let existing = TimeEntry(startDate: date(40), endDate: date(60), source: .manual)
        context.insert(existing)
        try context.save()

        clock.now = date(100)
        XCTAssertThrowsError(try service.stop(in: context)) { error in
            XCTAssertEqual(error as? TimerError, .stopConflictsWithExistingEntries)
        }

        XCTAssertNil(timer.endDate)
        XCTAssertEqual(timer.lastHeartbeatDate, date(30))
        XCTAssertEqual(try service.activeTimer(in: context)?.id, timer.id)
        XCTAssertEqual(existing.startDate, date(40))
        XCTAssertEqual(existing.endDate, date(60))
    }

    func testStopReplacingExistingSplitsEnclosingEntry() throws {
        let context = try makeContext()
        context.insert(TimeEntry(startDate: date(0), endDate: date(100), source: .manual))
        try context.save()
        let clock = MutableClock(date(30))
        let service = TimerService(clock: clock)
        _ = try service.start(in: context)

        clock.now = date(70)
        let stopped = try service.stop(resolving: .replaceExisting, in: context)
        let entries = try sortedEntries(in: context)

        XCTAssertEqual(stopped.count, 1)
        XCTAssertEqual(entries.map(\.startDate), [date(0), date(30), date(70)])
        XCTAssertEqual(entries.compactMap(\.endDate), [date(30), date(70), date(100)])
        assertNoOverlaps(entries)
    }

    func testStopReplacingExistingTrimsAndDeletesConflicts() throws {
        let context = try makeContext()
        context.insert(TimeEntry(startDate: date(-20), endDate: date(10), source: .manual))
        context.insert(TimeEntry(startDate: date(20), endDate: date(30), source: .manual))
        context.insert(TimeEntry(startDate: date(90), endDate: date(120), source: .manual))
        try context.save()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)
        _ = try service.start(in: context)

        clock.now = date(100)
        _ = try service.stop(resolving: .replaceExisting, in: context)
        let entries = try sortedEntries(in: context)

        XCTAssertEqual(entries.map(\.startDate), [date(-20), date(0), date(100)])
        XCTAssertEqual(entries.compactMap(\.endDate), [date(0), date(100), date(120)])
        assertNoOverlaps(entries)
    }

    func testStopReplacingExistingPreservesTimerIdentityAndMetadata() throws {
        let context = try makeContext()
        let project = makeProject("Work", in: context)
        let rule = AssignmentRule(kind: .application, matchValue: "Editor", project: project)
        context.insert(rule)
        context.insert(TimeEntry(startDate: date(40), endDate: date(60), source: .manual))
        try context.save()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)
        let timer = try service.start(project: project, description: "Focus", in: context)
        timer.matchedRule = rule
        timer.createdAt = date(-100)
        timer.lastHeartbeatDate = date(20)
        try context.save()

        clock.now = date(100)
        let stopped = try service.stop(resolving: .replaceExisting, in: context)

        XCTAssertEqual(stopped.count, 1)
        XCTAssertEqual(stopped[0].id, timer.id)
        XCTAssertEqual(stopped[0].project?.id, project.id)
        XCTAssertEqual(stopped[0].entryDescription, "Focus")
        XCTAssertEqual(stopped[0].source, .timer)
        XCTAssertEqual(stopped[0].createdAt, date(-100))
        XCTAssertEqual(stopped[0].matchedRule?.id, rule.id)
        XCTAssertNil(stopped[0].lastHeartbeatDate)
        assertNoOverlaps(try sortedEntries(in: context))
    }

    func testStopKeepingExistingRemovesFullyCoveredTimer() throws {
        let context = try makeContext()
        let existing = TimeEntry(startDate: date(0), endDate: date(100), source: .manual)
        context.insert(existing)
        try context.save()
        let clock = MutableClock(date(20))
        let service = TimerService(clock: clock)
        let timer = try service.start(in: context)
        let timerID = timer.id

        clock.now = date(80)
        let stopped = try service.stop(resolving: .keepExisting, in: context)
        let entries = try sortedEntries(in: context)

        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, existing.id)
        XCTAssertFalse(entries.contains { $0.id == timerID })
        XCTAssertNil(try service.activeTimer(in: context))
    }

    func testStopKeepingExistingSplitsTimerAndPreservesMetadata() throws {
        let context = try makeContext()
        let project = makeProject("Work", in: context)
        let rule = AssignmentRule(kind: .application, matchValue: "Editor", project: project)
        context.insert(rule)
        context.insert(TimeEntry(startDate: date(40), endDate: date(60), source: .manual))
        try context.save()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)
        let timer = try service.start(project: project, description: "Focus", in: context)
        timer.matchedRule = rule
        timer.createdAt = date(-100)
        timer.lastHeartbeatDate = date(20)
        try context.save()

        clock.now = date(100)
        let stopped = try service.stop(resolving: .keepExisting, in: context)

        XCTAssertEqual(stopped.map(\.startDate), [date(0), date(60)])
        XCTAssertEqual(stopped.compactMap(\.endDate), [date(40), date(100)])
        for fragment in stopped {
            XCTAssertEqual(fragment.project?.id, project.id)
            XCTAssertEqual(fragment.entryDescription, "Focus")
            XCTAssertEqual(fragment.source, .timer)
            XCTAssertEqual(fragment.matchedRule?.id, rule.id)
            XCTAssertEqual(fragment.createdAt, date(-100))
            XCTAssertNil(fragment.lastHeartbeatDate)
        }
        assertNoOverlaps(try sortedEntries(in: context))
    }

    func testStopKeepingExistingCreatesMultipleGaps() throws {
        let context = try makeContext()
        for (start, end) in [(10.0, 20.0), (40.0, 50.0), (70.0, 90.0)] {
            context.insert(TimeEntry(startDate: date(start), endDate: date(end), source: .manual))
        }
        try context.save()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)
        _ = try service.start(in: context)

        clock.now = date(100)
        let stopped = try service.stop(resolving: .keepExisting, in: context)

        XCTAssertEqual(stopped.map(\.startDate), [date(0), date(20), date(50), date(90)])
        XCTAssertEqual(stopped.compactMap(\.endDate), [date(10), date(40), date(70), date(100)])
        assertNoOverlaps(try sortedEntries(in: context))
    }

    func testStopKeepingExistingRedistributesTimerActivitySegments() throws {
        let context = try makeContext()
        let existing = TimeEntry(startDate: date(40), endDate: date(60), source: .manual)
        context.insert(existing)
        try context.save()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)
        let timer = try service.start(in: context)
        context.insert(
            ActivitySegment(
                appBundleId: "com.example.editor",
                appName: "Editor",
                startDate: date(20),
                endDate: date(80),
                timeEntry: timer
            )
        )
        try context.save()

        clock.now = date(100)
        let timerFragments = try service.stop(resolving: .keepExisting, in: context)
        let segments = try sortedSegments(in: context)

        XCTAssertEqual(segments.map(\.startDate), [date(20), date(40), date(60)])
        XCTAssertEqual(segments.map(\.endDate), [date(40), date(60), date(80)])
        XCTAssertEqual(segments[0].timeEntry?.id, timerFragments[0].id)
        XCTAssertEqual(segments[1].timeEntry?.id, existing.id)
        XCTAssertEqual(segments[2].timeEntry?.id, timerFragments[1].id)
        assertSegmentsAreContained(segments)
    }

    func testStopReplacingExistingRedistributesEnclosingEntrySegments() throws {
        let context = try makeContext()
        let existing = TimeEntry(startDate: date(-20), endDate: date(120), source: .manual)
        context.insert(existing)
        context.insert(
            ActivitySegment(
                appBundleId: "com.example.editor",
                appName: "Editor",
                startDate: date(-10),
                endDate: date(110),
                timeEntry: existing
            )
        )
        try context.save()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)
        let timer = try service.start(in: context)

        clock.now = date(100)
        _ = try service.stop(resolving: .replaceExisting, in: context)
        let entries = try sortedEntries(in: context)
        let segments = try sortedSegments(in: context)

        XCTAssertEqual(entries.map(\.startDate), [date(-20), date(0), date(100)])
        XCTAssertEqual(entries.compactMap(\.endDate), [date(0), date(100), date(120)])
        XCTAssertEqual(segments.map(\.startDate), [date(-10), date(0), date(100)])
        XCTAssertEqual(segments.map(\.endDate), [date(0), date(100), date(110)])
        XCTAssertEqual(segments[1].timeEntry?.id, timer.id)
        assertSegmentsAreContained(segments)
        assertNoOverlaps(entries)
    }

    func testReconciliationFailureRollsBackTimerAndSegment() throws {
        let context = try makeContext()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)
        let timer = try service.start(in: context)
        let segment = ActivitySegment(
            appBundleId: "com.example.editor",
            appName: "Editor",
            startDate: date(-10),
            endDate: date(10),
            timeEntry: timer
        )
        context.insert(segment)
        try context.save()

        clock.now = date(20)
        XCTAssertThrowsError(
            try service.stop(resolving: .replaceExisting, in: context)
        )

        let restoredTimer = try XCTUnwrap(try service.activeTimer(in: context))
        let restoredSegment = try XCTUnwrap(try sortedSegments(in: context).first)
        XCTAssertEqual(restoredTimer.id, timer.id)
        XCTAssertNil(restoredTimer.endDate)
        XCTAssertEqual(restoredSegment.id, segment.id)
        XCTAssertEqual(restoredSegment.startDate, date(-10))
        XCTAssertEqual(restoredSegment.endDate, date(10))
        XCTAssertEqual(restoredSegment.timeEntry?.id, restoredTimer.id)
        XCTAssertEqual(restoredTimer.activitySegments.map(\.id), [restoredSegment.id])
    }

    // MARK: - Heartbeat

    func testHeartbeatUpdatesLastHeartbeatDate() throws {
        let context = try makeContext()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)

        let entry = try service.start(in: context)
        XCTAssertNil(entry.lastHeartbeatDate)

        clock.now = date(45)
        _ = try service.heartbeat(in: context)
        XCTAssertEqual(entry.lastHeartbeatDate, date(45))

        clock.now = date(90)
        _ = try service.heartbeat(in: context)
        XCTAssertEqual(entry.lastHeartbeatDate, date(90))
    }

    func testHeartbeatWithNoActiveTimerReturnsNil() throws {
        let context = try makeContext()
        let service = TimerService(clock: MutableClock(date(0)))
        XCTAssertNil(try service.heartbeat(in: context))
    }

    func testHeartbeatDoesNotRegressWhenClockMovesBackward() throws {
        let context = try makeContext()
        let clock = MutableClock(date(100))
        let service = TimerService(clock: clock)

        let entry = try service.start(in: context)
        clock.now = date(150)
        _ = try service.heartbeat(in: context)
        clock.now = date(120)
        _ = try service.heartbeat(in: context)

        XCTAssertEqual(entry.lastHeartbeatDate, date(150))
    }

    // MARK: - Recovery

    func testRecoverStopsAtLastHeartbeat() throws {
        let context = try makeContext()
        // Simulate a timer left running from a previous launch.
        let timer = TimeEntry(startDate: date(0), source: .timer, lastHeartbeatDate: date(120))
        context.insert(timer)
        try context.save()

        // A fresh clock at relaunch time must not influence the recovered end date.
        let service = TimerService(clock: MutableClock(date(9999)))
        let recovered = try service.recover(in: context)

        XCTAssertEqual(recovered?.endDate, date(120))
        XCTAssertNil(recovered?.lastHeartbeatDate)
        XCTAssertNil(try service.activeTimer(in: context))
    }

    func testRecoverClipsActivitySegmentAtLastHeartbeat() throws {
        let context = try makeContext()
        let timer = TimeEntry(
            startDate: date(0),
            source: .timer,
            lastHeartbeatDate: date(30)
        )
        let segment = ActivitySegment(
            appBundleId: "com.example.editor",
            appName: "Editor",
            startDate: date(20),
            endDate: date(40),
            timeEntry: timer
        )
        context.insert(timer)
        context.insert(segment)
        try context.save()

        let recovered = try TimerService(clock: MutableClock(date(999))).recover(in: context)

        XCTAssertEqual(recovered?.endDate, date(30))
        XCTAssertEqual(segment.startDate, date(20))
        XCTAssertEqual(segment.endDate, date(30))
        XCTAssertEqual(segment.timeEntry?.id, timer.id)
    }

    func testRecoverDeletesActivityWhollyAfterLastHeartbeat() throws {
        let context = try makeContext()
        let timer = TimeEntry(
            startDate: date(0),
            source: .timer,
            lastHeartbeatDate: date(30)
        )
        context.insert(timer)
        context.insert(
            ActivitySegment(
                appBundleId: "com.example.editor",
                appName: "Editor",
                startDate: date(35),
                endDate: date(40),
                timeEntry: timer
            )
        )
        try context.save()

        _ = try TimerService(clock: MutableClock(date(999))).recover(in: context)

        XCTAssertTrue(try sortedSegments(in: context).isEmpty)
    }

    func testRecoverStopsAtStartWhenNoHeartbeat() throws {
        let context = try makeContext()
        let timer = TimeEntry(startDate: date(50), source: .timer, lastHeartbeatDate: nil)
        context.insert(timer)
        try context.save()

        let service = TimerService(clock: MutableClock(date(9999)))
        let recovered = try service.recover(in: context)

        XCTAssertEqual(recovered?.endDate, date(50), "no heartbeat falls back to startDate")
        XCTAssertNil(recovered?.lastHeartbeatDate)
    }

    func testRecoverWithNoActiveTimerReturnsNil() throws {
        let context = try makeContext()
        // A finished entry must not be treated as recoverable.
        let finished = TimeEntry(startDate: date(0), endDate: date(10), source: .timer)
        context.insert(finished)
        try context.save()

        let service = TimerService(clock: MutableClock(date(100)))
        XCTAssertNil(try service.recover(in: context))
        XCTAssertEqual(finished.endDate, date(10), "finished entries are untouched")
    }

    func testRecoverClampsPreStartHeartbeatToStartDate() throws {
        let context = try makeContext()
        let timer = TimeEntry(startDate: date(100), source: .timer, lastHeartbeatDate: date(50))
        context.insert(timer)
        try context.save()

        let service = TimerService(clock: MutableClock(date(9999)))
        let recovered = try service.recover(in: context)

        XCTAssertEqual(recovered?.endDate, date(100))
        XCTAssertNil(recovered?.lastHeartbeatDate)
    }

    func testRecoverKeepsExistingEntryAndSavesOnlyFreeTimerTime() throws {
        let context = try makeContext()
        let existing = TimeEntry(startDate: date(40), endDate: date(60), source: .manual)
        let timer = TimeEntry(startDate: date(0), source: .timer, lastHeartbeatDate: date(100))
        context.insert(existing)
        context.insert(timer)
        try context.save()

        let service = TimerService(clock: MutableClock(date(9999)))
        let recovered = try service.recover(in: context)
        let entries = try sortedEntries(in: context)
        let timerEntries = entries.filter { $0.source == .timer }

        XCTAssertEqual(recovered?.startDate, date(0))
        XCTAssertEqual(recovered?.endDate, date(40))
        XCTAssertEqual(timerEntries.map(\.startDate), [date(0), date(60)])
        XCTAssertEqual(timerEntries.compactMap(\.endDate), [date(40), date(100)])
        XCTAssertEqual(existing.startDate, date(40))
        XCTAssertEqual(existing.endDate, date(60))
        assertNoOverlaps(entries)
    }

    func testRecoverRemovesTimerFullyCoveredByExistingEntry() throws {
        let context = try makeContext()
        let existing = TimeEntry(startDate: date(0), endDate: date(100), source: .manual)
        let timer = TimeEntry(startDate: date(20), source: .timer, lastHeartbeatDate: date(80))
        let timerID = timer.id
        context.insert(existing)
        context.insert(timer)
        try context.save()

        let service = TimerService(clock: MutableClock(date(9999)))
        let recovered = try service.recover(in: context)
        let entries = try sortedEntries(in: context)

        XCTAssertNil(recovered)
        XCTAssertNil(try service.activeTimer(in: context))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, existing.id)
        XCTAssertFalse(entries.contains { $0.id == timerID })
        XCTAssertEqual(existing.startDate, date(0))
        XCTAssertEqual(existing.endDate, date(100))
        assertNoOverlaps(entries)
    }

    // MARK: - Presets

    func testPresetsDeduplicateIdenticalPairs() throws {
        let context = try makeContext()
        let project = makeProject("Work", in: context)
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)

        // Three entries, two of which share the same project + description pair.
        try addFinished(project: project, description: "Email", clock: clock, service: service, in: context)
        try addFinished(project: project, description: "Email", clock: clock, service: service, in: context)
        try addFinished(project: project, description: "Coding", clock: clock, service: service, in: context)

        let presets = try service.presets(in: context)
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets, [
            TimerPreset(project: project, description: "Coding"),
            TimerPreset(project: project, description: "Email"),
        ])
    }

    func testPresetsIncludeUnassignedWithDescription() throws {
        let context = try makeContext()
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)

        // Unassigned (no project) but with a description — a valid preset.
        try addFinished(project: nil, description: "Reading", clock: clock, service: service, in: context)
        // Fully empty pair — must be skipped.
        try addFinished(project: nil, description: nil, clock: clock, service: service, in: context)

        let presets = try service.presets(in: context)
        XCTAssertEqual(presets, [TimerPreset(project: nil, description: "Reading")])
    }

    func testPresetsExcludeArchivedProjects() throws {
        let context = try makeContext()
        let active = makeProject("Active", in: context)
        let archived = makeProject("Archived", archived: true, in: context)
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)

        try addFinished(project: active, description: "Task", clock: clock, service: service, in: context)
        try addFinished(project: archived, description: "Old", clock: clock, service: service, in: context)

        let presets = try service.presets(in: context)
        XCTAssertEqual(presets, [TimerPreset(project: active, description: "Task")])
    }

    func testPresetsExcludeNonTimerEntries() throws {
        let context = try makeContext()
        let project = makeProject("Work", in: context)
        context.insert(TimeEntry(
            startDate: date(0),
            endDate: date(10),
            entryDescription: "Manual",
            source: .manual,
            project: project
        ))
        context.insert(TimeEntry(
            startDate: date(20),
            endDate: date(30),
            entryDescription: "Activity",
            source: .fromActivity,
            project: project
        ))
        try context.save()

        XCTAssertEqual(try TimerService(clock: MutableClock(date(0))).presets(in: context), [])
    }

    func testPresetsDeduplicateNilAndEmptyDescriptions() throws {
        let context = try makeContext()
        let project = makeProject("Work", in: context)
        let clock = MutableClock(date(0))
        let service = TimerService(clock: clock)

        try addFinished(project: project, description: nil, clock: clock, service: service, in: context)
        try addFinished(project: project, description: "", clock: clock, service: service, in: context)

        XCTAssertEqual(try service.presets(in: context), [
            TimerPreset(project: project, description: nil),
        ])
    }

    func testSelectingPresetReturnsValuesWithoutStartingTimer() throws {
        let context = try makeContext()
        let project = makeProject("Work", in: context)
        let service = TimerService(clock: MutableClock(date(0)))
        let preset = TimerPreset(project: project, description: "Planning")

        let values = service.fill(from: preset)

        XCTAssertEqual(values.project?.id, project.id)
        XCTAssertEqual(values.description, "Planning")
        // Selecting a preset must never create or start a timer.
        XCTAssertEqual(try entryCount(in: context), 0)
        XCTAssertNil(try service.activeTimer(in: context))
    }

    // MARK: - Helpers

    /// Starts and immediately stops a timer to produce a finished entry, advancing
    /// the injected clock so successive entries do not collide on timestamps.
    private func addFinished(
        project: Project?,
        description: String?,
        clock: MutableClock,
        service: TimerService,
        in context: ModelContext
    ) throws {
        _ = try service.start(project: project, description: description, in: context)
        clock.now = clock.now.addingTimeInterval(10)
        _ = try service.stop(in: context)
        clock.now = clock.now.addingTimeInterval(10)
    }
}
