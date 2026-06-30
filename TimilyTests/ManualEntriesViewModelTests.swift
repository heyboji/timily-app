import SwiftData
import XCTest
@testable import Timily

final class ManualEntriesViewModelTests: XCTestCase {
    @MainActor
    func testEditorStateUsesMinutePrecision() {
        let state = TimeEntryEditorState(
            now: Date(timeIntervalSince1970: 3_661.987),
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertEqual(state.endDate.timeIntervalSince1970, 3_660)
        XCTAssertEqual(state.startDate.timeIntervalSince1970, 60)
    }

    @MainActor
    func testSelectedRangePrefillsNewEntry() throws {
        let start = Date(timeIntervalSince1970: 1_800)
        let end = Date(timeIntervalSince1970: 3_600)
        let viewModel = ManualEntriesViewModel()

        viewModel.presentNewEntry(startDate: start, endDate: end)

        let state = try XCTUnwrap(viewModel.editorState)
        XCTAssertNil(state.entry)
        XCTAssertEqual(state.startDate, start)
        XCTAssertEqual(state.endDate, end)
    }

    @MainActor
    func testCreateAndEditManualEntry() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(name: "Client", colorHex: "#5E5CE6")
        context.insert(project)
        try context.save()
        let viewModel = ManualEntriesViewModel()

        var state = TimeEntryEditorState(now: Date(timeIntervalSince1970: 3_600))
        state.projectID = project.id
        state.entryDescription = "  Planning  "
        XCTAssertEqual(
            viewModel.save(state, replacingConflicts: false, projects: [project], in: context),
            .saved
        )

        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<TimeEntry>()).first)
        XCTAssertEqual(entry.startDate, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(entry.endDate, Date(timeIntervalSince1970: 3_600))
        XCTAssertEqual(entry.entryDescription, "Planning")
        XCTAssertEqual(entry.project?.id, project.id)

        var editState = TimeEntryEditorState(entry: entry)
        editState.entryDescription = "Review"
        editState.projectID = nil
        XCTAssertEqual(
            viewModel.save(editState, replacingConflicts: false, projects: [project], in: context),
            .saved
        )
        XCTAssertEqual(entry.entryDescription, "Review")
        XCTAssertNil(entry.project)
    }

    @MainActor
    func testConflictCanBeReplaced() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let service = TimeEntryService()
        _ = try service.add(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 3_600),
            source: .manual,
            in: context
        )
        let viewModel = ManualEntriesViewModel()
        var state = TimeEntryEditorState(now: Date(timeIntervalSince1970: 5_400))
        state.startDate = Date(timeIntervalSince1970: 1_800)

        XCTAssertEqual(
            viewModel.save(state, replacingConflicts: false, projects: [], in: context),
            .conflict
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TimeEntry>()), 1)

        XCTAssertEqual(
            viewModel.save(state, replacingConflicts: true, projects: [], in: context),
            .saved
        )
        let entries = try context.fetch(
            FetchDescriptor<TimeEntry>(sortBy: [SortDescriptor(\.startDate)])
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].endDate, Date(timeIntervalSince1970: 1_800))
        XCTAssertEqual(entries[1].startDate, Date(timeIntervalSince1970: 1_800))
        XCTAssertEqual(entries[1].endDate, Date(timeIntervalSince1970: 5_400))
    }
}
