import Foundation
import SwiftData

@Model
final class AssignmentRule {
    @Attribute(.unique) var id: UUID
    var kind: RuleKind
    var matchValue: String
    var project: Project
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \TimeEntry.matchedRule)
    var entries: [TimeEntry]

    init(
        id: UUID = UUID(),
        kind: RuleKind,
        matchValue: String,
        project: Project,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.matchValue = matchValue
        self.project = project
        self.createdAt = createdAt
        self.entries = []
    }
}
