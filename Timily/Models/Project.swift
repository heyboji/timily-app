import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    var note: String?
    var isArchived: Bool
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \TimeEntry.project)
    var entries: [TimeEntry]

    @Relationship(deleteRule: .cascade, inverse: \AssignmentRule.project)
    var rules: [AssignmentRule]

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        note: String? = nil,
        isArchived: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.note = note
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.entries = []
        self.rules = []
    }
}
