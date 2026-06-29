import SwiftData
import XCTest
@testable import Timily

final class TimilyTests: XCTestCase {
    @MainActor
    func testCRUDForAllEntities() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(name: "Website", colorHex: "#5E5CE6")
        let startDate = Date(timeIntervalSince1970: 100)
        let endDate = Date(timeIntervalSince1970: 200)
        let entry = TimeEntry(
            startDate: startDate,
            endDate: endDate,
            source: .manual,
            project: project
        )
        let segment = ActivitySegment(
            appBundleId: "com.apple.dt.Xcode",
            appName: "Xcode",
            startDate: startDate,
            endDate: endDate,
            timeEntry: entry
        )
        let rule = AssignmentRule(
            kind: .application,
            matchValue: "com.apple.dt.Xcode",
            project: project
        )
        let settings = AppSettings()

        context.insert(project)
        context.insert(entry)
        context.insert(segment)
        context.insert(rule)
        context.insert(settings)
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TimeEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivitySegment>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AssignmentRule>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 1)
    }

    @MainActor
    func testDeletingProjectNullifiesEntriesAndDeletesRules() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(name: "Website", colorHex: "#5E5CE6")
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

        context.delete(project)
        try context.save()

        let entries = try context.fetch(FetchDescriptor<TimeEntry>())
        XCTAssertNil(try XCTUnwrap(entries.first).project)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AssignmentRule>()), 0)
    }

    @MainActor
    func testSettingsBootstrapCreatesExactlyOneSettingsObject() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext

        let first = try PersistenceController.bootstrapSettings(in: context)
        let second = try PersistenceController.bootstrapSettings(in: context)

        XCTAssertEqual(first.persistentModelID, second.persistentModelID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 1)
    }
}
