import SwiftData
import SwiftUI

@main
struct TimilyApp: App {
    private let modelContainer: ModelContainer
    private let timerViewModel: TimerViewModel

    init() {
        do {
            let container = try PersistenceController.makeContainer()
            try PersistenceController.bootstrapSettings(in: container.mainContext)
            _ = try TimerService().recover(in: container.mainContext)

            let timerViewModel = TimerViewModel()
            timerViewModel.refresh(in: container.mainContext)

            modelContainer = container
            self.timerViewModel = timerViewModel
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(timerViewModel)
        } label: {
            TimerMenuBarLabel(viewModel: timerViewModel)
        }
        .modelContainer(modelContainer)

        WindowGroup("Timily", id: "main") {
            MainWindowView()
                .environment(timerViewModel)
        }
        .modelContainer(modelContainer)
    }
}
