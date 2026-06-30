import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(ActivityMonitor.self) private var activityMonitor

    var body: some View {
        TimerControlView(layout: .compact)

        Divider()

        if activityMonitor.isAutoTrackingEnabled {
            Button(
                activityMonitor.isPaused ? "Resume Tracking" : "Pause Tracking",
                action: toggleTrackingPause
            )
        } else {
            Button("Enable Auto Tracking") {
                activityMonitor.setAutoTrackingEnabled(true)
            }
        }

        Divider()

        Button("Open Timily", action: openMainWindow)

        Button("Quit Timily", action: quit)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func quit() {
        activityMonitor.stop()
        NSApplication.shared.terminate(nil)
    }

    private func toggleTrackingPause() {
        if activityMonitor.isPaused {
            activityMonitor.resume()
        } else {
            activityMonitor.pause()
        }
    }
}
