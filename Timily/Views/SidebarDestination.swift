import Foundation

enum SidebarDestination: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case activity = "Activity"
    case projects = "Projects"
    case settings = "Settings"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .dashboard: "chart.bar.xaxis"
        case .activity: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .projects: "folder"
        case .settings: "gearshape"
        }
    }
}
