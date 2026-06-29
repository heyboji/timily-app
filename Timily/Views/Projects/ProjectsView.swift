import SwiftData
import SwiftUI

struct ProjectsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<Project> { !$0.isArchived },
        sort: \Project.name
    ) private var activeProjects: [Project]

    @Query(
        filter: #Predicate<Project> { $0.isArchived },
        sort: \Project.name
    ) private var archivedProjects: [Project]

    @State private var viewModel = ProjectsViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        Group {
            if activeProjects.isEmpty && archivedProjects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Create a project to start organizing your time.")
                } actions: {
                    Button(
                        "New Project",
                        systemImage: "plus",
                        action: viewModel.presentNewProject
                    )
                }
            } else {
                List {
                    if !activeProjects.isEmpty {
                        Section("Active") {
                            ForEach(activeProjects) { project in
                                ProjectRowView(
                                    project: project,
                                    onEdit: { viewModel.presentEditor(for: project) },
                                    onToggleArchive: {
                                        viewModel.toggleArchive(project, in: modelContext)
                                    },
                                    onDelete: { viewModel.delete(project, in: modelContext) }
                                )
                            }
                        }
                    }

                    if !archivedProjects.isEmpty {
                        Section("Archived") {
                            ForEach(archivedProjects) { project in
                                ProjectRowView(
                                    project: project,
                                    onEdit: { viewModel.presentEditor(for: project) },
                                    onToggleArchive: {
                                        viewModel.toggleArchive(project, in: modelContext)
                                    },
                                    onDelete: { viewModel.delete(project, in: modelContext) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(
                    "New Project",
                    systemImage: "plus",
                    action: viewModel.presentNewProject
                )
            }
        }
        .sheet(item: $viewModel.editorState) { state in
            ProjectEditorView(
                state: state,
                onCancel: viewModel.dismissEditor,
                onSave: { state in
                    viewModel.save(state, in: modelContext)
                }
            )
        }
        .alert("Couldn’t Update Project", isPresented: $viewModel.isShowingError) {
        } message: {
            Text(viewModel.errorMessage)
        }
    }
}
