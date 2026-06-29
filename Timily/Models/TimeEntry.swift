import Foundation
import SwiftData

@Model
final class TimeEntry {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var endDate: Date?
    var entryDescription: String?
    var source: EntrySource
    var project: Project?
    var matchedRule: AssignmentRule?
    var lastHeartbeatDate: Date?
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \ActivitySegment.timeEntry)
    var activitySegments: [ActivitySegment]

    init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date? = nil,
        entryDescription: String? = nil,
        source: EntrySource,
        project: Project? = nil,
        matchedRule: AssignmentRule? = nil,
        lastHeartbeatDate: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.entryDescription = entryDescription
        self.source = source
        self.project = project
        self.matchedRule = matchedRule
        self.lastHeartbeatDate = lastHeartbeatDate
        self.createdAt = createdAt
        self.activitySegments = []
    }

    func duration(at date: Date = .now) -> TimeInterval {
        (endDate ?? date).timeIntervalSince(startDate)
    }
}
