import SwiftData
import XCTest
@testable import Timily

private final class ViewModelClock: TimerClock, @unchecked Sendable {
    nonisolated(unsafe) var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
final class TimerViewModelTests: XCTestCase {
    func testApplyPresetOnlyFillsDraft() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(name: "Client", colorHex: "#112233")
        context.insert(project)
        try context.save()
        let viewModel = TimerViewModel()

        viewModel.applyPreset(
            TimerPreset(project: project, description: "Planning")
        )

        XCTAssertEqual(viewModel.projectID, project.id)
        XCTAssertEqual(viewModel.entryDescription, "Planning")
        XCTAssertNil(viewModel.activeTimer)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TimeEntry>()), 0)
    }

    func testStartAndStopUpdateSharedState() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(name: "Client", colorHex: "#112233")
        context.insert(project)
        try context.save()
        let clock = ViewModelClock(Date(timeIntervalSince1970: 100))
        let service = TimerService(clock: clock)
        let viewModel = TimerViewModel(service: service)
        viewModel.projectID = project.id
        viewModel.entryDescription = "Planning"

        viewModel.start(projects: [project], in: context)

        let activeTimer = try XCTUnwrap(viewModel.activeTimer)
        XCTAssertEqual(activeTimer.id, try service.activeTimer(in: context)?.id)
        XCTAssertEqual(activeTimer.project?.id, project.id)
        XCTAssertEqual(activeTimer.entryDescription, "Planning")

        clock.now = Date(timeIntervalSince1970: 160)
        viewModel.stop(in: context)

        XCTAssertNil(viewModel.activeTimer)
        XCTAssertNil(try service.activeTimer(in: context))
        XCTAssertEqual(activeTimer.endDate, clock.now)
    }

    func testArchivedProjectCannotBeAssignedWhenStarting() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let archivedProject = Project(
            name: "Old Client",
            colorHex: "#112233",
            isArchived: true
        )
        context.insert(archivedProject)
        try context.save()
        let viewModel = TimerViewModel(
            service: TimerService(clock: ViewModelClock(.now))
        )
        viewModel.projectID = archivedProject.id

        viewModel.start(projects: [archivedProject], in: context)

        XCTAssertNil(viewModel.activeTimer?.project)
        viewModel.stop(in: context)
    }

    func testRefreshLoadsPresetsAndActiveTimer() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(name: "Client", colorHex: "#112233")
        let finished = TimeEntry(
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 60),
            entryDescription: "Planning",
            source: .timer,
            project: project
        )
        let active = TimeEntry(
            startDate: Date(timeIntervalSince1970: 120),
            entryDescription: "Review",
            source: .timer,
            project: project
        )
        context.insert(project)
        context.insert(finished)
        context.insert(active)
        try context.save()
        let viewModel = TimerViewModel()

        viewModel.refresh(in: context)

        XCTAssertEqual(viewModel.activeTimer?.id, active.id)
        XCTAssertTrue(
            viewModel.presets.contains(
                TimerPreset(project: project, description: "Planning")
            )
        )
        viewModel.stop(in: context)
    }

    func testRefreshAfterRecoveryHasNoActiveTimer() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let active = TimeEntry(
            startDate: Date(timeIntervalSince1970: 100),
            source: .timer,
            lastHeartbeatDate: Date(timeIntervalSince1970: 130)
        )
        context.insert(active)
        try context.save()
        _ = try TimerService().recover(in: context)
        let viewModel = TimerViewModel()

        viewModel.refresh(in: context)

        XCTAssertNil(viewModel.activeTimer)
        XCTAssertEqual(active.endDate, Date(timeIntervalSince1970: 130))
    }
}
