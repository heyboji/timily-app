import SwiftUI

struct MainWindowView: View {
    @State private var selection: SidebarDestination? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarDestination.allCases, selection: $selection) { destination in
                Label(destination.rawValue, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle("Timily")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            switch selection {
            case .projects:
                ProjectsView()
            case let destination?:
                ContentUnavailableView(
                    destination.rawValue,
                    systemImage: destination.systemImage
                )
            case nil:
                ContentUnavailableView("Timily", systemImage: "clock")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

#Preview {
    MainWindowView()
}
