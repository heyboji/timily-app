import SwiftData
import XCTest
@testable import Timily

@MainActor
final class ActivityTimelineServiceTests: XCTestCase {
    func testAssignUpdatesSelectedEntriesAndClearsMatchedRules() throws {
        let context = try makeContext()
        let oldProject = Project(name: "Old", colorHex: "#111111")
        let newProject = Project(name: "New", colorHex: "#222222")
        let rule = AssignmentRule(
            kind: .application,
            matchValue: "com.example.app",
            project: oldProject
        )
        let first = entry(0, 10, project: oldProject, matchedRule: rule)
        let second = entry(20, 30, project: oldProject, matchedRule: rule)
        context.insert(oldProject)
        context.insert(newProject)
        context.insert(rule)
        context.insert(first)
        context.insert(second)
        try context.save()

        try ActivityTimelineService().assign([first, second], to: newProject, in: context)

        XCTAssertEqual(first.project?.id, newProject.id)
        XCTAssertEqual(second.project?.id, newProject.id)
        XCTAssertNil(first.matchedRule)
        XCTAssertNil(second.matchedRule)
    }

    func testMergeSpansGapAndRetainsSegments() throws {
        let context = try makeContext()
        let project = Project(name: "Project", colorHex: "#111111")
        let first = entry(0, 10, description: "Work", project: project)
        let second = entry(20, 30, description: "Work", project: project)
        let firstSegment = segment(0, 5, entry: first)
        let adjacentSegment = segment(5, 10, entry: first)
        let secondSegment = segment(20, 30, entry: second)
        context.insert(project)
        context.insert(first)
        context.insert(second)
        context.insert(firstSegment)
        context.insert(adjacentSegment)
        context.insert(secondSegment)
        try context.save()

        let merged = try ActivityTimelineService().merge([second, first], in: context)

        XCTAssertEqual(merged.startDate, date(0))
        XCTAssertEqual(merged.endDate, date(30))
        XCTAssertEqual(merged.source, .manual)
        XCTAssertEqual(merged.project?.id, project.id)
        XCTAssertEqual(merged.entryDescription, "Work")
        XCTAssertEqual(
            Set(merged.activitySegments.map(\.id)),
            Set([firstSegment.id, adjacentSegment.id, secondSegment.id])
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TimeEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivitySegment>()), 3)
    }

    func testMergeMixedMetadataBecomesUnassignedWithoutDescription() throws {
        let context = try makeContext()
        let firstProject = Project(name: "First", colorHex: "#111111")
        let secondProject = Project(name: "Second", colorHex: "#222222")
        let first = entry(0, 10, description: "One", project: firstProject)
        let second = entry(10, 20, description: "Two", project: secondProject)
        context.insert(firstProject)
        context.insert(secondProject)
        context.insert(first)
        context.insert(second)
        try context.save()

        let merged = try ActivityTimelineService().merge([first, second], in: context)

        XCTAssertNil(merged.project)
        XCTAssertNil(merged.entryDescription)
    }

    func testMergeRejectsUnselectedOverlapWithoutChangingEntries() throws {
        let context = try makeContext()
        let first = entry(0, 10)
        let middle = entry(10, 20)
        let last = entry(20, 30)
        [first, middle, last].forEach(context.insert)
        try context.save()

        XCTAssertThrowsError(try ActivityTimelineService().merge([first, last], in: context)) { error in
            XCTAssertEqual(error as? ActivityTimelineError, .overlapsUnselectedEntry)
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TimeEntry>()), 3)
    }

    func testMergeRejectsRunningEntry() throws {
        let context = try makeContext()
        let completed = entry(0, 10)
        let running = TimeEntry(startDate: date(20), source: .timer)
        [completed, running].forEach(context.insert)
        try context.save()

        XCTAssertThrowsError(try ActivityTimelineService().merge([completed, running], in: context)) { error in
            XCTAssertEqual(error as? ActivityTimelineError, .runningEntry)
        }
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

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func entry(
        _ start: TimeInterval,
        _ end: TimeInterval,
        description: String? = nil,
        project: Project? = nil,
        matchedRule: AssignmentRule? = nil
    ) -> TimeEntry {
        TimeEntry(
            startDate: date(start),
            endDate: date(end),
            entryDescription: description,
            source: .fromActivity,
            project: project,
            matchedRule: matchedRule
        )
    }

    private func segment(
        _ start: TimeInterval,
        _ end: TimeInterval,
        entry: TimeEntry
    ) -> ActivitySegment {
        ActivitySegment(
            appBundleId: "com.example.app",
            appName: "Example",
            startDate: date(start),
            endDate: date(end),
            timeEntry: entry
        )
    }
}
