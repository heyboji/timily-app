import SwiftData
import SwiftUI

struct ActivityView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \TimeEntry.startDate, order: .reverse)
    private var entries: [TimeEntry]

    @Query(sort: \Project.name)
    private var projects: [Project]

    @State private var viewModel = ManualEntriesViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Time Entries", systemImage: "clock")
                } description: {
                    Text("Add time manually when you forgot to start a timer.")
                } actions: {
                    Button(
                        "New Entry",
                        systemImage: "plus",
                        action: { viewModel.presentNewEntry() }
                    )
                }
            } else {
                List(entries) { entry in
                    TimeEntryRowView(
                        entry: entry,
                        onEdit: { viewModel.presentEditor(for: entry) },
                        onDelete: { viewModel.delete(entry, in: modelContext) }
                    )
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(
                    "New Entry",
                    systemImage: "plus",
                    action: { viewModel.presentNewEntry() }
                )
            }
        }
        .sheet(item: $viewModel.editorState) { state in
            ManualEntryEditorView(
                state: state,
                projects: projects,
                onCancel: viewModel.dismissEditor,
                onSave: { state, replacingConflicts in
                    viewModel.save(
                        state,
                        replacingConflicts: replacingConflicts,
                        projects: projects,
                        in: modelContext
                    )
                }
            )
        }
        .alert("Couldn’t Update Entry", isPresented: $viewModel.isShowingError) {
        } message: {
            Text(viewModel.errorMessage)
        }
    }
}
