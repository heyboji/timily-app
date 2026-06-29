import SwiftUI

struct ManualEntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: TimeEntryEditorState
    @State private var isConfirmingReplace = false

    let projects: [Project]
    let onCancel: () -> Void
    let onSave: (TimeEntryEditorState, Bool) -> ManualEntrySaveResult

    init(
        state: TimeEntryEditorState,
        projects: [Project],
        onCancel: @escaping () -> Void,
        onSave: @escaping (TimeEntryEditorState, Bool) -> ManualEntrySaveResult
    ) {
        _state = State(initialValue: state)
        self.projects = projects
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Project", selection: $state.projectID) {
                    Text("Unassigned").tag(UUID?.none)

                    ForEach(availableProjects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }

                TextField("Description", text: $state.entryDescription)

                DatePicker(
                    "Start",
                    selection: $state.startDate,
                    displayedComponents: [.date, .hourAndMinute]
                )

                DatePicker(
                    "End",
                    selection: $state.endDate,
                    displayedComponents: [.date, .hourAndMinute]
                )

                if !state.canSave {
                    Label("End must not be before start.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(state.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!state.canSave)
                }
            }
        }
        .frame(width: 480)
        .confirmationDialog(
            "Replace Overlapping Entries?",
            isPresented: $isConfirmingReplace
        ) {
            Button("Replace", role: .destructive, action: replace)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Overlapping entries will be trimmed, split, or removed.")
        }
    }

    private var availableProjects: [Project] {
        projects.filter { !$0.isArchived || $0.id == state.projectID }
    }

    private func cancel() {
        onCancel()
        dismiss()
    }

    private func save() {
        switch onSave(state, false) {
        case .saved:
            dismiss()
        case .conflict:
            isConfirmingReplace = true
        case .failed:
            break
        }
    }

    private func replace() {
        if onSave(state, true) == .saved {
            dismiss()
        }
    }
}
