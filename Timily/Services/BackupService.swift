import Foundation
import SwiftData

// MARK: - BackupError

/// Errors thrown by `BackupService`.
enum BackupError: LocalizedError, Equatable {
    /// The archive's `schemaVersion` is not supported by this build.
    case incompatibleSchemaVersion(archiveVersion: Int, supportedVersion: Int)
    /// The archive contains duplicate IDs or a relationship to a missing object.
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case let .incompatibleSchemaVersion(archiveVersion, supportedVersion):
            return """
            Archive schema version \(archiveVersion) is incompatible \
            with the supported version \(supportedVersion).
            """
        case let .invalidArchive(reason):
            return "The backup archive is invalid: \(reason)"
        }
    }
}

// MARK: - BackupService

/// Exports and imports the entire Timily database as a single JSON archive.
///
/// ## Export
/// `exportArchive()` serialises all `Project`, `TimeEntry`, `ActivitySegment`,
/// `AssignmentRule`, and `AppSettings` objects into a `BackupArchive` using
/// plain `Codable` DTOs.  Relationships are stored as UUID references.
/// Keys are sorted and dates retain subsecond precision.
///
/// ## Import (full replace)
/// `importArchive(_:)` performs a full replace:
/// 1. Validates the archive's `schemaVersion`.
/// 2. Creates a **safety export** of the current DB and returns it so the
///    caller can persist it after a successful import.
/// 3. Wipes all existing objects.
/// 4. Recreates every object from the archive, re-linking relationships by UUID.
///
/// Relationship references are validated before the existing database is
/// changed. Corrupt archives are rejected without modifying current data.
@MainActor
final class BackupService {

    /// Schema version embedded in every archive produced by this build.
    static let currentSchemaVersion = 1

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Export

    /// Serialises the entire database to a JSON `Data` blob.
    ///
    /// Keys are alphabetically sorted and dates retain subsecond precision.
    func exportArchive() throws -> Data {
        let projects   = try context.fetch(FetchDescriptor<Project>())
        let entries    = try context.fetch(FetchDescriptor<TimeEntry>())
        let segments   = try context.fetch(FetchDescriptor<ActivitySegment>())
        let rules      = try context.fetch(FetchDescriptor<AssignmentRule>())
        let settings   = try context.fetch(FetchDescriptor<AppSettings>())

        let archive = BackupArchive(
            schemaVersion:    Self.currentSchemaVersion,
            exportedAt:       .now,
            projects: projects
                .map { ProjectDTO(from: $0) }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            timeEntries: entries
                .map { TimeEntryDTO(from: $0) }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            activitySegments: segments
                .map { ActivitySegmentDTO(from: $0) }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            assignmentRules: rules
                .map { AssignmentRuleDTO(from: $0) }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            appSettings:      settings.map  { AppSettingsDTO(from: $0) }
        )

        return try Self.encoder.encode(archive)
    }

    // MARK: - Import

    /// Replaces the entire database with the contents of `data`.
    ///
    /// - Parameter data: JSON produced by `exportArchive()`.
    /// - Returns: A safety export of the database state *before* the wipe, so
    ///   the caller can write it to disk as a rollback point.
    /// - Throws: `BackupError.incompatibleSchemaVersion` when the archive's
    ///   `schemaVersion` differs from `currentSchemaVersion`.
    @discardableResult
    func importArchive(_ data: Data) throws -> Data {
        // 1. Decode and validate schema version before touching the DB.
        let archive = try Self.decoder.decode(BackupArchive.self, from: data)
        guard archive.schemaVersion == Self.currentSchemaVersion else {
            throw BackupError.incompatibleSchemaVersion(
                archiveVersion: archive.schemaVersion,
                supportedVersion: Self.currentSchemaVersion
            )
        }
        try validate(archive)

        // 2. Safety export — captured before any wipe.
        let safetyBackup = try exportArchive()

        do {
            // 3. Wipe existing data in reverse-dependency order. Context-aware
            // deletes preserve SwiftData inverse-relationship invariants.
            try deleteAll(ActivitySegment.self)
            try deleteAll(TimeEntry.self)
            try deleteAll(AssignmentRule.self)
            try deleteAll(Project.self)
            try deleteAll(AppSettings.self)

            // 4. Recreate — build lookup indexes as we go.
            restore(archive)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        return safetyBackup
    }

    private func restore(_ archive: BackupArchive) {
        // Projects (no dependencies).
        var projectIndex: [UUID: Project] = [:]
        for dto in archive.projects {
            let project = dto.toModel()
            context.insert(project)
            projectIndex[dto.id] = project
        }

        // AssignmentRules (depend on Projects).
        var ruleIndex: [UUID: AssignmentRule] = [:]
        for dto in archive.assignmentRules {
            guard let project = projectIndex[dto.projectID] else { continue }
            let rule = dto.toModel(project: project)
            context.insert(rule)
            ruleIndex[dto.id] = rule
        }

        // TimeEntries (depend on Projects + AssignmentRules).
        var entryIndex: [UUID: TimeEntry] = [:]
        for dto in archive.timeEntries {
            let project     = dto.projectID.flatMap     { projectIndex[$0] }
            let matchedRule = dto.matchedRuleID.flatMap { ruleIndex[$0] }
            let entry = dto.toModel(project: project, matchedRule: matchedRule)
            context.insert(entry)
            entryIndex[dto.id] = entry
        }

        // ActivitySegments (depend on TimeEntries).
        for dto in archive.activitySegments {
            let timeEntry = dto.timeEntryID.flatMap { entryIndex[$0] }
            context.insert(dto.toModel(timeEntry: timeEntry))
        }

        // AppSettings — restore archived values; bootstrap default when absent.
        if archive.appSettings.isEmpty {
            context.insert(AppSettings())
        } else {
            for dto in archive.appSettings {
                context.insert(dto.toModel())
            }
        }
    }

    private func deleteAll<Model: PersistentModel>(_ type: Model.Type) throws {
        for model in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(model)
        }
    }

    private func validate(_ archive: BackupArchive) throws {
        try validateUniqueIDs(archive.projects.map(\.id), entity: "project")
        try validateUniqueIDs(archive.assignmentRules.map(\.id), entity: "assignment rule")
        try validateUniqueIDs(archive.timeEntries.map(\.id), entity: "time entry")
        try validateUniqueIDs(archive.activitySegments.map(\.id), entity: "activity segment")

        guard archive.appSettings.count <= 1 else {
            throw BackupError.invalidArchive("multiple AppSettings records")
        }

        let projectIDs = Set(archive.projects.map(\.id))
        let ruleIDs = Set(archive.assignmentRules.map(\.id))
        let entryIDs = Set(archive.timeEntries.map(\.id))

        for rule in archive.assignmentRules where !projectIDs.contains(rule.projectID) {
            throw BackupError.invalidArchive("assignment rule references a missing project")
        }
        for entry in archive.timeEntries {
            if let projectID = entry.projectID, !projectIDs.contains(projectID) {
                throw BackupError.invalidArchive("time entry references a missing project")
            }
            if let ruleID = entry.matchedRuleID, !ruleIDs.contains(ruleID) {
                throw BackupError.invalidArchive("time entry references a missing assignment rule")
            }
        }
        for segment in archive.activitySegments {
            if let entryID = segment.timeEntryID, !entryIDs.contains(entryID) {
                throw BackupError.invalidArchive("activity segment references a missing time entry")
            }
        }
    }

    private func validateUniqueIDs(_ ids: [UUID], entity: String) throws {
        guard Set(ids).count == ids.count else {
            throw BackupError.invalidArchive("duplicate \(entity) identifier")
        }
    }

    // MARK: - Shared encoder / decoder

    /// Stable JSON encoder: keys sorted alphabetically, dates as Unix seconds.
    nonisolated static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        enc.dateEncodingStrategy = .secondsSince1970
        return enc
    }()

    /// Matching decoder: dates as Unix seconds.
    nonisolated static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return dec
    }()
}
