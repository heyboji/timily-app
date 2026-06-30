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

    func testAssignSegmentSplitsOwnerAndPreservesSiblingAssignments() throws {
        let context = try makeContext()
        let oldProject = Project(name: "Old", colorHex: "#111111")
        let newProject = Project(name: "New", colorHex: "#222222")
        let rule = AssignmentRule(
            kind: .application,
            matchValue: "com.example.app",
            project: oldProject
        )
        let owner = entry(0, 30, description: "Focus", project: oldProject, matchedRule: rule)
        let first = segment(0, 10, entry: owner)
        let selected = segment(10, 20, entry: owner)
        let last = segment(20, 30, entry: owner)
        context.insert(oldProject)
        context.insert(newProject)
        context.insert(rule)
        context.insert(owner)
        [first, selected, last].forEach(context.insert)
        try context.save()

        try ActivityTimelineService().assign(
            segmentIDs: [selected.id],
            to: newProject,
            in: context
        )

        let entries = try fetchedEntries(in: context)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.startDate), [date(0), date(10), date(20)])
        XCTAssertEqual(entries.map(\.endDate), [date(10), date(20), date(30)])
        XCTAssertEqual(entries[0].project?.id, oldProject.id)
        XCTAssertEqual(entries[0].matchedRule?.id, rule.id)
        XCTAssertEqual(entries[1].project?.id, newProject.id)
        XCTAssertNil(entries[1].matchedRule)
        XCTAssertEqual(entries[2].project?.id, oldProject.id)
        XCTAssertEqual(entries[2].matchedRule?.id, rule.id)
        XCTAssertEqual(first.timeEntry?.id, entries[0].id)
        XCTAssertEqual(selected.timeEntry?.id, entries[1].id)
        XCTAssertEqual(last.timeEntry?.id, entries[2].id)
    }

    func testAssignSegmentsRejectsEmptySelection() throws {
        let context = try makeContext()

        XCTAssertThrowsError(
            try ActivityTimelineService().assign(
                segmentIDs: [],
                to: nil,
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? ActivityTimelineError, .emptySelection)
        }
    }

    func testAssignAdjacentSegmentsKeepsSeparateSelectedEntries() throws {
        let context = try makeContext()
        let project = Project(name: "Selected", colorHex: "#222222")
        let owner = entry(0, 30)
        let first = segment(0, 10, entry: owner)
        let second = segment(10, 20, entry: owner)
        let last = segment(20, 30, entry: owner)
        context.insert(project)
        context.insert(owner)
        [first, second, last].forEach(context.insert)
        try context.save()

        try ActivityTimelineService().assign(
            segmentIDs: [first.id, second.id],
            to: project,
            in: context
        )

        let entries = try fetchedEntries(in: context)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].project?.id, project.id)
        XCTAssertEqual(entries[1].project?.id, project.id)
        XCTAssertNotEqual(entries[0].id, entries[1].id)
        XCTAssertNil(entries[2].project)
        XCTAssertEqual(first.timeEntry?.id, entries[0].id)
        XCTAssertEqual(second.timeEntry?.id, entries[1].id)
    }

    func testAssignSegmentToNilMakesOnlySelectedIntervalUnassigned() throws {
        let context = try makeContext()
        let project = Project(name: "Old", colorHex: "#111111")
        let owner = entry(0, 20, project: project)
        let selected = segment(0, 10, entry: owner)
        let sibling = segment(10, 20, entry: owner)
        context.insert(project)
        context.insert(owner)
        context.insert(selected)
        context.insert(sibling)
        try context.save()

        try ActivityTimelineService().assign(
            segmentIDs: [selected.id],
            to: nil,
            in: context
        )

        let entries = try fetchedEntries(in: context)
        XCTAssertNil(entries[0].project)
        XCTAssertEqual(entries[1].project?.id, project.id)
    }

    func testAssignSegmentsRejectsMissingIDWithoutChangingOwner() throws {
        let context = try makeContext()
        let project = Project(name: "Old", colorHex: "#111111")
        let replacement = Project(name: "New", colorHex: "#222222")
        let owner = entry(0, 10, project: project)
        let selected = segment(0, 10, entry: owner)
        context.insert(project)
        context.insert(replacement)
        context.insert(owner)
        context.insert(selected)
        try context.save()

        XCTAssertThrowsError(
            try ActivityTimelineService().assign(
                segmentIDs: [selected.id, UUID()],
                to: replacement,
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? ActivityTimelineError, .missingSegment)
        }

        let entries = try fetchedEntries(in: context)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, owner.id)
        XCTAssertEqual(entries[0].project?.id, project.id)
        XCTAssertEqual(selected.timeEntry?.id, owner.id)
    }

    func testAssignSegmentsRejectsOrphanAtomically() throws {
        let context = try makeContext()
        let replacement = Project(name: "New", colorHex: "#222222")
        let owner = entry(0, 10)
        let owned = segment(0, 10, entry: owner)
        let orphan = ActivitySegment(
            appBundleId: "com.example.other",
            appName: "Other",
            startDate: date(20),
            endDate: date(30)
        )
        context.insert(replacement)
        context.insert(owner)
        context.insert(owned)
        context.insert(orphan)
        try context.save()

        XCTAssertThrowsError(
            try ActivityTimelineService().assign(
                segmentIDs: [owned.id, orphan.id],
                to: replacement,
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? ActivityTimelineError, .orphanSegment)
        }

        let entries = try fetchedEntries(in: context)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, owner.id)
        XCTAssertNil(entries[0].project)
        XCTAssertNil(orphan.timeEntry)
    }

    func testAssignSegmentsRejectsRunningOwnerAtomically() throws {
        let context = try makeContext()
        let replacement = Project(name: "New", colorHex: "#222222")
        let running = TimeEntry(startDate: date(0), source: .timer)
        let selected = segment(0, 10, entry: running)
        context.insert(replacement)
        context.insert(running)
        context.insert(selected)
        try context.save()

        XCTAssertThrowsError(
            try ActivityTimelineService().assign(
                segmentIDs: [selected.id],
                to: replacement,
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? ActivityTimelineError, .runningEntry)
        }

        let entries = try fetchedEntries(in: context)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, running.id)
        XCTAssertNil(entries[0].endDate)
        XCTAssertNil(entries[0].project)
    }

    func testAssignSegmentsRejectsOutOfOwnerRange() throws {
        try assertInvalidSegmentSelection([(20, 40)])
    }

    func testAssignSegmentsRejectsZeroAndReversedRanges() throws {
        try assertInvalidSegmentSelection([(10, 10)])
        try assertInvalidSegmentSelection([(20, 10)])
    }

    func testAssignSegmentsRejectsOverlappingRanges() throws {
        try assertInvalidSegmentSelection([(0, 20), (10, 30)])
    }

    func testAssignSegmentPreservesEntryAndActivityMetadata() throws {
        let context = try makeContext()
        let oldProject = Project(name: "Old", colorHex: "#111111")
        let newProject = Project(name: "New", colorHex: "#222222")
        let rule = AssignmentRule(
            kind: .application,
            matchValue: "com.example.app",
            project: oldProject
        )
        let createdAt = date(-100)
        let heartbeat = date(9)
        let owner = TimeEntry(
            startDate: date(0),
            endDate: date(20),
            entryDescription: "Original",
            source: .timer,
            project: oldProject,
            matchedRule: rule,
            lastHeartbeatDate: heartbeat,
            createdAt: createdAt
        )
        let selected = ActivitySegment(
            appBundleId: "com.example.app",
            appName: "Example",
            windowTitle: "Timeline",
            documentPath: "/tmp/timeline",
            url: "https://example.com/timeline",
            startDate: date(5),
            endDate: date(15),
            timeEntry: owner,
            note: "Raw note"
        )
        context.insert(oldProject)
        context.insert(newProject)
        context.insert(rule)
        context.insert(owner)
        context.insert(selected)
        try context.save()

        try ActivityTimelineService().assign(
            segmentIDs: [selected.id],
            to: newProject,
            in: context
        )

        let entries = try fetchedEntries(in: context)
        XCTAssertEqual(entries.count, 3)
        for entry in entries {
            XCTAssertEqual(entry.entryDescription, "Original")
            XCTAssertEqual(entry.source, .timer)
            XCTAssertEqual(entry.lastHeartbeatDate, heartbeat)
            XCTAssertEqual(entry.createdAt, createdAt)
        }
        XCTAssertEqual(entries[0].project?.id, oldProject.id)
        XCTAssertEqual(entries[0].matchedRule?.id, rule.id)
        XCTAssertEqual(entries[1].project?.id, newProject.id)
        XCTAssertNil(entries[1].matchedRule)
        XCTAssertEqual(entries[2].project?.id, oldProject.id)
        XCTAssertEqual(entries[2].matchedRule?.id, rule.id)
        XCTAssertEqual(selected.appBundleId, "com.example.app")
        XCTAssertEqual(selected.appName, "Example")
        XCTAssertEqual(selected.windowTitle, "Timeline")
        XCTAssertEqual(selected.documentPath, "/tmp/timeline")
        XCTAssertEqual(selected.url, "https://example.com/timeline")
        XCTAssertEqual(selected.note, "Raw note")
        XCTAssertEqual(selected.timeEntry?.id, entries[1].id)
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

    private func fetchedEntries(in context: ModelContext) throws -> [TimeEntry] {
        try context.fetch(FetchDescriptor<TimeEntry>()).sorted {
            if $0.startDate != $1.startDate {
                return $0.startDate < $1.startDate
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func assertInvalidSegmentSelection(
        _ ranges: [(TimeInterval, TimeInterval)]
    ) throws {
        let context = try makeContext()
        let owner = entry(0, 30)
        context.insert(owner)
        let segments = ranges.map { range in
            segment(range.0, range.1, entry: owner)
        }
        segments.forEach(context.insert)
        try context.save()

        XCTAssertThrowsError(
            try ActivityTimelineService().assign(
                segmentIDs: Set(segments.map(\.id)),
                to: nil,
                in: context
            )
        ) { error in
            XCTAssertEqual(error as? ActivityTimelineError, .invalidSegmentRange)
        }

        let entries = try fetchedEntries(in: context)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, owner.id)
        XCTAssertTrue(segments.allSatisfy { $0.timeEntry?.id == owner.id })
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
