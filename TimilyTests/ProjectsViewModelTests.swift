import SwiftData
import XCTest
@testable import Timily

final class ProjectsViewModelTests: XCTestCase {
    @MainActor
    func testCreateEditAndArchiveProject() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let viewModel = ProjectsViewModel()
        var editor = ProjectEditorState()
        editor.name = "  Client Website  "
        editor.colorHex = "#0A84FF"
        editor.note = "  Homepage redesign  "

        let createdProject = try XCTUnwrap(viewModel.saveProject(editor, in: context))

        let project = try XCTUnwrap(context.fetch(FetchDescriptor<Project>()).first)
        XCTAssertEqual(createdProject.id, project.id)
        XCTAssertEqual(project.name, "Client Website")
        XCTAssertEqual(project.colorHex, "#0A84FF")
        XCTAssertEqual(project.note, "Homepage redesign")

        var editState = ProjectEditorState(project: project)
        editState.name = "Client App"
        editState.note = ""
        XCTAssertTrue(viewModel.save(editState, in: context))
        XCTAssertEqual(project.name, "Client App")
        XCTAssertNil(project.note)

        viewModel.toggleArchive(project, in: context)
        XCTAssertTrue(project.isArchived)

        let active = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived }
        )
        XCTAssertEqual(try context.fetchCount(active), 0)
    }

    @MainActor
    func testDeleteProjectLeavesEntriesUnassignedAndDeletesRules() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let viewModel = ProjectsViewModel()
        let project = Project(name: "Client", colorHex: "#5E5CE6")
        let entry = TimeEntry(
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            source: .manual,
            project: project
        )
        let rule = AssignmentRule(
            kind: .application,
            matchValue: "com.apple.dt.Xcode",
            project: project
        )

        context.insert(project)
        context.insert(entry)
        context.insert(rule)
        try context.save()

        viewModel.delete(project, in: context)

        XCTAssertNil(try XCTUnwrap(context.fetch(FetchDescriptor<TimeEntry>()).first).project)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AssignmentRule>()), 0)
    }
}
