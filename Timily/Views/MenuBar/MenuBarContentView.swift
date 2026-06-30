import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimerControlView(layout: .compact)

        Divider()

        Button("Open Timily", action: openMainWindow)

        Button("Quit Timily", action: quit)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
