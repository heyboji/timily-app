import SwiftData
import SwiftUI

@main
struct TimilyApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            let container = try PersistenceController.makeContainer()
            try PersistenceController.bootstrapSettings(in: container.mainContext)
            modelContainer = container
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra("Timily", systemImage: "clock") {
            MenuBarContentView()
        }
        .modelContainer(modelContainer)

        WindowGroup("Timily", id: "main") {
            MainWindowView()
        }
        .modelContainer(modelContainer)
    }
}
