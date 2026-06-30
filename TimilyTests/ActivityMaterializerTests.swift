import SwiftData
import XCTest
@testable import Timily

@MainActor
final class ActivityMaterializerTests: XCTestCase {
    private let application = TrackedApplication(
        bundleIdentifier: "com.example.editor",
        displayName: "Editor"
    )

    func testCaptureWithoutExistingEntryCreatesLinkedUnassignedEntry() throws {
        let context = try makeContext()
        try materializer(context).record(capture(0, 30))

        let entries = try sortedEntries(context)
        let segments = try sortedSegments(context)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].source, .fromActivity)
        XCTAssertNil(entries[0].project)
        assertRange(entries[0], 0, 30)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].timeEntry?.id, entries[0].id)
        XCTAssertEqual(entries[0].activitySegments.map(\.id), [segments[0].id])
    }

    func testCaptureInsideActiveTimerAttachesWithoutCreatingEntry() throws {
        let context = try makeContext()
        let timer = insertEntry(0, nil, source: .timer, in: context)
        try context.save()

        try materializer(context).record(capture(10, 20))

        XCTAssertEqual(try sortedEntries(context).count, 1)
        let segment = try XCTUnwrap(try sortedSegments(context).first)
        XCTAssertEqual(segment.timeEntry?.id, timer.id)
        assertRange(segment, 10, 20)
    }

    func testTimerStartingInsideCaptureSplitsPrefixFromTimerPortion() throws {
        let context = try makeContext()
        let timer = insertEntry(10, nil, source: .timer, in: context)
        try context.save()

        try materializer(context).record(capture(0, 20))

        let segments = try sortedSegments(context)
        XCTAssertEqual(segments.count, 2)
        assertRange(segments[0], 0, 10)
        XCTAssertEqual(segments[0].timeEntry?.source, .fromActivity)
        assertRange(segments[1], 10, 20)
        XCTAssertEqual(segments[1].timeEntry?.id, timer.id)
        assertNoCompletedEntryOverlaps(try sortedEntries(context))
    }

    func testInteriorManualEntryCreatesPrefixOwnerAndSuffixPieces() throws {
        let context = try makeContext()
        let manual = insertEntry(10, 20, source: .manual, in: context)
        try context.save()

        try materializer(context).record(capture(0, 30))

        let segments = try sortedSegments(context)
        XCTAssertEqual(segments.count, 3)
        assertRange(segments[0], 0, 10)
        assertRange(segments[1], 10, 20)
        assertRange(segments[2], 20, 30)
        XCTAssertEqual(segments[1].timeEntry?.id, manual.id)
        XCTAssertEqual(segments[0].timeEntry?.source, .fromActivity)
        XCTAssertEqual(segments[2].timeEntry?.source, .fromActivity)
        assertNoCompletedEntryOverlaps(try sortedEntries(context))
    }

    func testMultipleExistingEntriesPartitionEveryGap() throws {
        let context = try makeContext()
        insertEntry(5, 10, source: .manual, in: context)
        insertEntry(15, 20, source: .manual, in: context)
        try context.save()

        try materializer(context).record(capture(0, 25))

        let segments = try sortedSegments(context)
        XCTAssertEqual(segments.count, 5)
        XCTAssertEqual(segments.map(\.startDate), [date(0), date(5), date(10), date(15), date(20)])
        XCTAssertEqual(segments.map(\.endDate), [date(5), date(10), date(15), date(20), date(25)])
        XCTAssertEqual(try sortedEntries(context).count, 5)
        assertNoCompletedEntryOverlaps(try sortedEntries(context))
    }

    func testSameCaptureIDIsIdempotent() throws {
        let context = try makeContext()
        let id = UUID()
        let completed = capture(0, 30, id: id)

        try materializer(context).record(completed)
        try materializer(context).record(completed)

        XCTAssertEqual(try sortedEntries(context).count, 1)
        let segments = try sortedSegments(context)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].id, id)
    }

    func testSaveFailureRollsBackAndRetryMaterializesExactlyOnce() throws {
        let context = try makeContext()
        let completed = capture(0, 30)
        var shouldFail = true
        let materializer = ActivityMaterializer(
            context: context,
            save: {
                if shouldFail {
                    shouldFail = false
                    throw TestError.saveFailed
                }
                try context.save()
            }
        )

        XCTAssertThrowsError(try materializer.record(completed))
        XCTAssertTrue(try sortedEntries(context).isEmpty)
        XCTAssertTrue(try sortedSegments(context).isEmpty)

        try materializer.record(completed)
        XCTAssertEqual(try sortedEntries(context).count, 1)
        XCTAssertEqual(try sortedSegments(context).count, 1)
    }

    func testExistingRawMarkerIsReusedAndLinked() throws {
        let context = try makeContext()
        let completed = capture(0, 30)
        context.insert(
            ActivitySegment(
                id: completed.id,
                appBundleId: application.bundleIdentifier,
                appName: application.displayName,
                startDate: completed.startDate,
                endDate: completed.endDate
            )
        )
        try context.save()

        try materializer(context).record(completed)

        let segments = try sortedSegments(context)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].id, completed.id)
        XCTAssertNotNil(segments[0].timeEntry)
    }

    func testUniqueRuleAssignsOnlyNewGapEntry() throws {
        let context = try makeContext()
        let manualProject = Project(name: "Manual", colorHex: "#111111")
        let ruleProject = Project(name: "Rule", colorHex: "#222222")
        let manual = TimeEntry(
            startDate: date(10),
            endDate: date(20),
            source: .manual,
            project: manualProject
        )
        let rule = AssignmentRule(
            kind: .application,
            matchValue: application.bundleIdentifier,
            project: ruleProject
        )
        context.insert(manualProject)
        context.insert(ruleProject)
        context.insert(manual)
        context.insert(rule)
        try context.save()

        try materializer(context).record(capture(0, 20))

        let gap = try XCTUnwrap(
            try sortedEntries(context).first { $0.source == .fromActivity }
        )
        XCTAssertEqual(gap.project?.id, ruleProject.id)
        XCTAssertEqual(gap.matchedRule?.id, rule.id)
        XCTAssertEqual(manual.project?.id, manualProject.id)
        XCTAssertNil(manual.matchedRule)
    }

    func testConflictingRulesLeaveNewEntryUnassigned() throws {
        let context = try makeContext()
        for name in ["One", "Two"] {
            let project = Project(name: name, colorHex: "#111111")
            context.insert(project)
            context.insert(
                AssignmentRule(
                    kind: .application,
                    matchValue: application.bundleIdentifier,
                    project: project
                )
            )
        }
        try context.save()

        try materializer(context).record(capture(0, 10))

        let entry = try XCTUnwrap(try sortedEntries(context).first)
        XCTAssertNil(entry.project)
        XCTAssertNil(entry.matchedRule)
    }

    func testZeroDurationCaptureIsIgnored() throws {
        let context = try makeContext()
        try materializer(context).record(capture(10, 10))
        XCTAssertTrue(try sortedEntries(context).isEmpty)
        XCTAssertTrue(try sortedSegments(context).isEmpty)
    }

    func testReversedCaptureIsRejected() throws {
        let context = try makeContext()

        XCTAssertThrowsError(try materializer(context).record(capture(20, 10))) { error in
            XCTAssertEqual(error as? TimeEntryError, .endBeforeStart)
        }
        XCTAssertTrue(try sortedEntries(context).isEmpty)
        XCTAssertTrue(try sortedSegments(context).isEmpty)
    }

    func testAdjacentExistingEntryDoesNotCreateZeroLengthPiece() throws {
        let context = try makeContext()
        insertEntry(0, 10, source: .manual, in: context)
        try context.save()

        try materializer(context).record(capture(10, 20))

        let segments = try sortedSegments(context)
        XCTAssertEqual(segments.count, 1)
        assertRange(segments[0], 10, 20)
        XCTAssertEqual(segments[0].timeEntry?.source, .fromActivity)
        assertNoCompletedEntryOverlaps(try sortedEntries(context))
    }

    private func makeContext() throws -> ModelContext {
        let container = try PersistenceController.makeContainer(inMemory: true)
        addTeardownBlock { _ = container }
        return container.mainContext
    }

    private func materializer(_ context: ModelContext) -> ActivityMaterializer {
        ActivityMaterializer(context: context)
    }

    @discardableResult
    private func insertEntry(
        _ start: TimeInterval,
        _ end: TimeInterval?,
        source: EntrySource,
        in context: ModelContext
    ) -> TimeEntry {
        let entry = TimeEntry(
            startDate: date(start),
            endDate: end.map { date($0) },
            source: source
        )
        context.insert(entry)
        return entry
    }

    private func capture(
        _ start: TimeInterval,
        _ end: TimeInterval,
        id: UUID = UUID()
    ) -> CompletedActivitySegment {
        CompletedActivitySegment(
            id: id,
            application: application,
            startDate: date(start),
            endDate: date(end)
        )
    }

    private func sortedEntries(_ context: ModelContext) throws -> [TimeEntry] {
        try context.fetch(FetchDescriptor<TimeEntry>()).sorted { $0.startDate < $1.startDate }
    }

    private func sortedSegments(_ context: ModelContext) throws -> [ActivitySegment] {
        try context.fetch(FetchDescriptor<ActivitySegment>()).sorted { $0.startDate < $1.startDate }
    }

    private func assertRange(
        _ entry: TimeEntry,
        _ start: TimeInterval,
        _ end: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(entry.startDate, date(start), file: file, line: line)
        XCTAssertEqual(entry.endDate, date(end), file: file, line: line)
    }

    private func assertRange(
        _ segment: ActivitySegment,
        _ start: TimeInterval,
        _ end: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(segment.startDate, date(start), file: file, line: line)
        XCTAssertEqual(segment.endDate, date(end), file: file, line: line)
    }

    private func assertNoCompletedEntryOverlaps(
        _ entries: [TimeEntry],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (left, right) in zip(entries, entries.dropFirst()) {
            guard let leftEnd = left.endDate else { continue }
            XCTAssertLessThanOrEqual(leftEnd, right.startDate, file: file, line: line)
        }
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private enum TestError: Error {
        case saveFailed
    }
}
