import SwiftData
import SwiftUI

struct MainWindowView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Project.name)
    private var projects: [Project]

    @State private var selection: SidebarDestination? = .dashboard
    @State private var activityTimelineViewModel = ActivityTimelineViewModel()
    @State private var dropErrorMessage = ""
    @State private var isShowingDropError = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarDestination.allCases) { destination in
                        Label(destination.rawValue, systemImage: destination.systemImage)
                            .tag(destination)
                    }
                }

                Section("Assign by Drop") {
                    projectDropTarget(nil)

                    ForEach(activeProjects) { project in
                        projectDropTarget(project)
                    }
                }
            }
            .navigationTitle("Timily")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            switch selection {
            case .dashboard:
                TimerControlView(layout: .normal)
                    .navigationTitle("Dashboard")
            case .activity:
                ActivityView()
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
        .environment(activityTimelineViewModel)
        .alert("Couldn’t Assign Activity", isPresented: $isShowingDropError) {
        } message: {
            Text(dropErrorMessage)
        }
    }

    private var activeProjects: [Project] {
        projects.filter { !$0.isArchived }
    }

    private func projectDropTarget(_ project: Project?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .foregroundStyle(projectColor(project))
                .accessibilityHidden(true)

            Text(project?.name ?? "Unassigned")
                .lineLimit(1)
        }
        .dropDestination(for: ActivitySelectionTransfer.self) { transfers, _ in
            assign(transfers, to: project)
        }
        .selectionDisabled()
        .accessibilityLabel("Assign to \(project?.name ?? "Unassigned")")
    }

    private func projectColor(_ project: Project?) -> Color {
        guard let project else { return .secondary }
        return Color(projectHex: project.colorHex)
    }

    private func assign(
        _ transfers: [ActivitySelectionTransfer],
        to project: Project?
    ) -> Bool {
        let entryIDs = Set(transfers.flatMap(\.entryIDs))
        let segmentIDs = Set(transfers.flatMap(\.segmentIDs))

        do {
            guard entryIDs.isEmpty != segmentIDs.isEmpty else {
                throw ActivityDropError.invalidSelection
            }
            if let project, project.isArchived {
                throw ActivityDropError.archivedProject
            }

            let service = ActivityTimelineService()
            if !segmentIDs.isEmpty {
                try service.assign(segmentIDs: segmentIDs, to: project, in: modelContext)
            } else {
                let entries = try modelContext.fetch(FetchDescriptor<TimeEntry>())
                    .filter { entryIDs.contains($0.id) }
                guard entries.count == entryIDs.count else {
                    throw ActivityDropError.missingEntry
                }
                try service.assign(entries, to: project, in: modelContext)
            }
            activityTimelineViewModel.selection.removeAll()
            return true
        } catch {
            dropErrorMessage = error.localizedDescription
            isShowingDropError = true
            return false
        }
    }
}

private enum ActivityDropError: LocalizedError {
    case archivedProject
    case invalidSelection
    case missingEntry

    var errorDescription: String? {
        switch self {
        case .archivedProject:
            "Archived projects cannot receive activity."
        case .invalidSelection:
            "Drag either time entries or activity segments."
        case .missingEntry:
            "One or more dragged time entries no longer exist."
        }
    }
}

#Preview {
    MainWindowView()
        .environment(TimerViewModel())
        .modelContainer(
            for: [
                Project.self,
                TimeEntry.self,
                ActivitySegment.self,
                AssignmentRule.self,
                AppSettings.self,
            ],
            inMemory: true
        )
}
