import SwiftData

@MainActor
enum PersistenceController {
    static let schema = Schema([
        Project.self,
        TimeEntry.self,
        ActivitySegment.self,
        AssignmentRule.self,
        AppSettings.self,
    ])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Timily",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @discardableResult
    static func bootstrapSettings(in context: ModelContext) throws -> AppSettings {
        var descriptor = FetchDescriptor<AppSettings>()
        descriptor.fetchLimit = 1

        if let settings = try context.fetch(descriptor).first {
            return settings
        }

        let settings = AppSettings()
        context.insert(settings)
        try context.save()
        return settings
    }
}
