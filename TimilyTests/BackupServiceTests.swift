import SwiftData
import XCTest
@testable import Timily

final class BackupServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Shared ISO 8601 decoder for inspecting exported data inside tests.
    private var decoder: JSONDecoder {
        BackupService.decoder
    }

    // MARK: - Round-trip

    /// Full round-trip: populate → export → wipe+import → verify 1:1 parity.
    @MainActor
    func testRoundTripRestoresAllEntitiesAndRelationships() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context   = container.mainContext

        // --- Populate ---
        let projectID  = UUID()
        let entryID    = UUID()
        let segmentID  = UUID()
        let ruleID     = UUID()

        let project = Project(
            id: projectID,
            name: "Website",
            colorHex: "#5E5CE6",
            note: "Homepage",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        // Entry linked to project, with a matched rule.
        let entry = TimeEntry(
            id: entryID,
            startDate: Date(timeIntervalSince1970: 1_000.125),
            endDate:   Date(timeIntervalSince1970: 2_000.875),
            entryDescription: "Design work",
            source: .manual,
            project: project,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        // Unassigned entry (no project, no rule).
        let unassignedEntry = TimeEntry(
            startDate: Date(timeIntervalSince1970: 3_000),
            endDate:   Date(timeIntervalSince1970: 4_000),
            source: .fromActivity,
            createdAt: Date(timeIntervalSince1970: 3_000)
        )

        // Segment linked to the first entry.
        let segment = ActivitySegment(
            id: segmentID,
            appBundleId: "com.apple.dt.Xcode",
            appName: "Xcode",
            windowTitle: "BackupService.swift",
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate:   Date(timeIntervalSince1970: 2_000),
            timeEntry: entry
        )

        let rule = AssignmentRule(
            id: ruleID,
            kind: .application,
            matchValue: "com.apple.dt.Xcode",
            project: project,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let settings = AppSettings(idleThresholdSeconds: 600, launchAtLogin: true)

        context.insert(project)
        context.insert(entry)
        context.insert(unassignedEntry)
        context.insert(segment)
        context.insert(rule)
        context.insert(settings)
        try context.save()

        // --- Export ---
        let service     = BackupService(context: context)
        let archiveData = try service.exportArchive()

        // --- Import (wipes + recreates) ---
        let safetyData = try service.importArchive(archiveData)
        XCTAssertFalse(safetyData.isEmpty, "Safety backup must be non-empty")

        // --- Verify counts ---
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()),         1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TimeEntry>()),        2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ActivitySegment>()),  1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AssignmentRule>()),   1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()),      1)

        // --- Verify field values ---
        let restoredProject = try XCTUnwrap(
            context.fetch(FetchDescriptor<Project>()).first
        )
        XCTAssertEqual(restoredProject.id,        projectID)
        XCTAssertEqual(restoredProject.name,      "Website")
        XCTAssertEqual(restoredProject.colorHex,  "#5E5CE6")
        XCTAssertEqual(restoredProject.note,      "Homepage")

        // --- Verify TimeEntry → Project relationship ---
        let entries = try context.fetch(FetchDescriptor<TimeEntry>())
        let restoredEntry = try XCTUnwrap(entries.first { $0.id == entryID })
        XCTAssertEqual(restoredEntry.id,                 entryID)
        XCTAssertEqual(restoredEntry.entryDescription,   "Design work")
        XCTAssertEqual(restoredEntry.source,             .manual)
        XCTAssertEqual(restoredEntry.startDate,          Date(timeIntervalSince1970: 1_000.125))
        XCTAssertEqual(restoredEntry.endDate,            Date(timeIntervalSince1970: 2_000.875))
        XCTAssertEqual(restoredEntry.project?.id,        projectID,
                       "TimeEntry must be re-linked to its project by UUID")

        let restoredUnassigned = try XCTUnwrap(entries.first { $0.id != entryID })
        XCTAssertNil(restoredUnassigned.project, "Unassigned entry must have no project")

        // --- Verify ActivitySegment → TimeEntry relationship ---
        let restoredSegment = try XCTUnwrap(
            context.fetch(FetchDescriptor<ActivitySegment>()).first
        )
        XCTAssertEqual(restoredSegment.id,              segmentID)
        XCTAssertEqual(restoredSegment.appBundleId,     "com.apple.dt.Xcode")
        XCTAssertEqual(restoredSegment.windowTitle,     "BackupService.swift")
        XCTAssertEqual(restoredSegment.timeEntry?.id,   entryID,
                       "Segment must be re-linked to its TimeEntry by UUID")

        // --- Verify AssignmentRule → Project relationship ---
        let restoredRule = try XCTUnwrap(
            context.fetch(FetchDescriptor<AssignmentRule>()).first
        )
        XCTAssertEqual(restoredRule.id,            ruleID)
        XCTAssertEqual(restoredRule.kind,          .application)
        XCTAssertEqual(restoredRule.matchValue,    "com.apple.dt.Xcode")
        XCTAssertEqual(restoredRule.project.id,    projectID,
                       "AssignmentRule must be re-linked to its project by UUID")

        // --- Verify AppSettings field values ---
        let restoredSettings = try XCTUnwrap(
            context.fetch(FetchDescriptor<AppSettings>()).first
        )
        XCTAssertEqual(restoredSettings.idleThresholdSeconds, 600)
        XCTAssertTrue(restoredSettings.launchAtLogin)
    }

    // MARK: - Schema version rejection

    @MainActor
    func testIncompatibleSchemaVersionThrows() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context   = container.mainContext
        let service   = BackupService(context: context)

        // Craft an archive with an unsupported version.
        let badJSON = """
        {
          "activitySegments": [],
          "appSettings": [],
          "assignmentRules": [],
          "exportedAt": 0,
          "projects": [],
          "schemaVersion": 99,
          "timeEntries": []
        }
        """
        let data = try XCTUnwrap(badJSON.data(using: .utf8))

        XCTAssertThrowsError(try service.importArchive(data)) { error in
            guard case BackupError.incompatibleSchemaVersion(
                let archiveVersion,
                let supported
            ) = error else {
                XCTFail("Expected BackupError.incompatibleSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(archiveVersion, 99)
            XCTAssertEqual(supported, BackupService.currentSchemaVersion)
        }
    }

    @MainActor
    func testOrphanedRuleIsRejectedBeforeCurrentDataIsChanged() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let existingProject = Project(name: "Current", colorHex: "#5E5CE6")
        context.insert(existingProject)
        try context.save()

        let ruleID = UUID()
        let missingProjectID = UUID()
        let invalidJSON = """
        {
          "activitySegments": [],
          "appSettings": [],
          "assignmentRules": [{
            "createdAt": 0,
            "id": "\(ruleID.uuidString)",
            "kind": "application",
            "matchValue": "com.apple.dt.Xcode",
            "projectID": "\(missingProjectID.uuidString)"
          }],
          "exportedAt": 0,
          "projects": [],
          "schemaVersion": 1,
          "timeEntries": []
        }
        """
        let data = try XCTUnwrap(invalidJSON.data(using: .utf8))

        let service = BackupService(context: context)
        XCTAssertThrowsError(try service.importArchive(data)) { error in
            guard case BackupError.invalidArchive = error else {
                return XCTFail("Expected BackupError.invalidArchive, got \(error)")
            }
        }

        let projects = try context.fetch(FetchDescriptor<Project>())
        XCTAssertEqual(projects.map(\.name), ["Current"])
    }

    // MARK: - Safety backup

    /// Safety backup must capture the pre-wipe state and be decodable.
    @MainActor
    func testSafetyBackupCapturesStateBeforeWipe() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context   = container.mainContext

        // Seed the DB.
        let project = Project(name: "Original", colorHex: "#FF9500")
        context.insert(project)
        try context.save()

        let service = BackupService(context: context)

        // Build an empty (but valid) archive to import.
        let emptyArchive = BackupArchive(
            schemaVersion:    BackupService.currentSchemaVersion,
            exportedAt:       Date(timeIntervalSince1970: 0),
            projects:         [],
            timeEntries:      [],
            activitySegments: [],
            assignmentRules:  [],
            appSettings:      []
        )
        let emptyData = try BackupService.encoder.encode(emptyArchive)

        // Import wipes the DB; safety backup should contain the original project.
        let safetyData = try service.importArchive(emptyData)

        let safetyArchive = try decoder.decode(BackupArchive.self, from: safetyData)
        XCTAssertEqual(safetyArchive.projects.count, 1)
        XCTAssertEqual(safetyArchive.projects.first?.name, "Original")
        XCTAssertEqual(safetyArchive.schemaVersion, BackupService.currentSchemaVersion)

        // After import, DB has no projects (empty archive was imported).
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 0)
        // AppSettings bootstrapped from empty archive.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 1)
    }

    // MARK: - Idempotence

    /// A second export after an import must produce the same entity UUIDs and counts.
    @MainActor
    func testIdempotentRoundTrip() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context   = container.mainContext

        let project = Project(name: "Idempotent", colorHex: "#30D158", note: "Test note")
        context.insert(project)
        try context.save()

        let service = BackupService(context: context)

        // First export.
        let archive1Data = try service.exportArchive()
        let archive1     = try decoder.decode(BackupArchive.self, from: archive1Data)

        // Import → export again.
        try service.importArchive(archive1Data)
        let archive2Data = try service.exportArchive()
        let archive2     = try decoder.decode(BackupArchive.self, from: archive2Data)

        // Entity counts and UUIDs must be identical across both exports.
        XCTAssertEqual(archive1.schemaVersion,          archive2.schemaVersion)
        XCTAssertEqual(archive1.projects.count,         archive2.projects.count)
        XCTAssertEqual(archive1.projects.first?.id,     archive2.projects.first?.id)
        XCTAssertEqual(archive1.projects.first?.name,   archive2.projects.first?.name)
        XCTAssertEqual(archive1.projects.first?.note,   archive2.projects.first?.note)
    }
}
