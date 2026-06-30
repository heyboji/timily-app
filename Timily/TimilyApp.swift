import SwiftData
import SwiftUI

@main
struct TimilyApp: App {
    private let modelContainer: ModelContainer
    private let timerViewModel: TimerViewModel
    private let activityMonitor: ActivityMonitor

    init() {
        do {
            let container = try PersistenceController.makeContainer()
            let settings = try PersistenceController.bootstrapSettings(in: container.mainContext)

            let activityMaterializer = ActivityMaterializer(context: container.mainContext)
            try activityMaterializer.materializePendingSegments()
            _ = try TimerService().recover(in: container.mainContext)

            let timerViewModel = TimerViewModel()
            timerViewModel.refresh(in: container.mainContext)

            let activityMonitor = ActivityMonitor(
                settings: settings,
                idleDetector: IdleDetector(
                    source: SystemIdleTimeSource(),
                    threshold: TimeInterval(settings.idleThresholdSeconds)
                ),
                workspaceSource: SystemActivityWorkspaceSource(),
                segmentSink: activityMaterializer,
                saveSettings: {
                    do {
                        try container.mainContext.save()
                    } catch {
                        container.mainContext.rollback()
                        throw error
                    }
                }
            )
            activityMonitor.start()

            modelContainer = container
            self.timerViewModel = timerViewModel
            self.activityMonitor = activityMonitor
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(timerViewModel)
                .environment(activityMonitor)
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
