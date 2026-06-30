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
