import Foundation

// MARK: - Top-level archive

/// The JSON container written by `BackupService.exportArchive()`.
///
/// Top-level keys (stable, sorted by JSONEncoder.OutputFormatting.sortedKeys):
/// `activitySegments`, `appSettings`, `assignmentRules`, `exportedAt`,
/// `projects`, `schemaVersion`, `timeEntries`.
///
/// Relationships are encoded as UUID references:
/// - `TimeEntryDTO.projectID`     → `ProjectDTO.id`
/// - `TimeEntryDTO.matchedRuleID` → `AssignmentRuleDTO.id`
/// - `ActivitySegmentDTO.timeEntryID` → `TimeEntryDTO.id`
/// - `AssignmentRuleDTO.projectID`    → `ProjectDTO.id`
struct BackupArchive: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let projects: [ProjectDTO]
    let timeEntries: [TimeEntryDTO]
    let activitySegments: [ActivitySegmentDTO]
    let assignmentRules: [AssignmentRuleDTO]
    /// Usually contains exactly one element (AppSettings is a singleton).
    let appSettings: [AppSettingsDTO]
}

// MARK: - ProjectDTO

struct ProjectDTO: Codable {
    let id: UUID
    let name: String
    let colorHex: String
    let note: String?
    let isArchived: Bool
    let createdAt: Date

    init(from model: Project) {
        id = model.id
        name = model.name
        colorHex = model.colorHex
        note = model.note
        isArchived = model.isArchived
        createdAt = model.createdAt
    }

    func toModel() -> Project {
        Project(
            id: id,
            name: name,
            colorHex: colorHex,
            note: note,
            isArchived: isArchived,
            createdAt: createdAt
        )
    }
}

// MARK: - TimeEntryDTO

struct TimeEntryDTO: Codable {
    let id: UUID
    let startDate: Date
    let endDate: Date?
    let entryDescription: String?
    let source: EntrySource
    /// `nil` when the entry is Unassigned.
    let projectID: UUID?
    /// `nil` when assigned manually or Unassigned.
    let matchedRuleID: UUID?
    let lastHeartbeatDate: Date?
    let createdAt: Date

    init(from model: TimeEntry) {
        id = model.id
        startDate = model.startDate
        endDate = model.endDate
        entryDescription = model.entryDescription
        source = model.source
        projectID = model.project?.id
        matchedRuleID = model.matchedRule?.id
        lastHeartbeatDate = model.lastHeartbeatDate
        createdAt = model.createdAt
    }

    func toModel(project: Project?, matchedRule: AssignmentRule?) -> TimeEntry {
        TimeEntry(
            id: id,
            startDate: startDate,
            endDate: endDate,
            entryDescription: entryDescription,
            source: source,
            project: project,
            matchedRule: matchedRule,
            lastHeartbeatDate: lastHeartbeatDate,
            createdAt: createdAt
        )
    }
}

// MARK: - ActivitySegmentDTO

struct ActivitySegmentDTO: Codable {
    let id: UUID
    let appBundleId: String
    let appName: String
    let windowTitle: String?
    let documentPath: String?
    let url: String?
    let startDate: Date
    let endDate: Date
    /// `nil` when the segment is not yet linked to an entry (transient state).
    let timeEntryID: UUID?
    let note: String?

    init(from model: ActivitySegment) {
        id = model.id
        appBundleId = model.appBundleId
        appName = model.appName
        windowTitle = model.windowTitle
        documentPath = model.documentPath
        url = model.url
        startDate = model.startDate
        endDate = model.endDate
        timeEntryID = model.timeEntry?.id
        note = model.note
    }

    func toModel(timeEntry: TimeEntry?) -> ActivitySegment {
        ActivitySegment(
            id: id,
            appBundleId: appBundleId,
            appName: appName,
            windowTitle: windowTitle,
            documentPath: documentPath,
            url: url,
            startDate: startDate,
            endDate: endDate,
            timeEntry: timeEntry,
            note: note
        )
    }
}

// MARK: - AssignmentRuleDTO

struct AssignmentRuleDTO: Codable {
    let id: UUID
    let kind: RuleKind
    let matchValue: String
    let projectID: UUID
    let createdAt: Date

    init(from model: AssignmentRule) {
        id = model.id
        kind = model.kind
        matchValue = model.matchValue
        projectID = model.project.id
        createdAt = model.createdAt
    }

    func toModel(project: Project) -> AssignmentRule {
        AssignmentRule(
            id: id,
            kind: kind,
            matchValue: matchValue,
            project: project,
            createdAt: createdAt
        )
    }
}

// MARK: - AppSettingsDTO

struct AppSettingsDTO: Codable {
    let idleThresholdSeconds: Int
    let launchAtLogin: Bool
    let showInDock: Bool
    let autoTrackingEnabled: Bool
    let trackingPaused: Bool

    init(from model: AppSettings) {
        idleThresholdSeconds = model.idleThresholdSeconds
        launchAtLogin = model.launchAtLogin
        showInDock = model.showInDock
        autoTrackingEnabled = model.autoTrackingEnabled
        trackingPaused = model.trackingPaused
    }

    func toModel() -> AppSettings {
        AppSettings(
            idleThresholdSeconds: idleThresholdSeconds,
            launchAtLogin: launchAtLogin,
            showInDock: showInDock,
            autoTrackingEnabled: autoTrackingEnabled,
            trackingPaused: trackingPaused
        )
    }
}
