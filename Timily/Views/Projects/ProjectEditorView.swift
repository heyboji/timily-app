import SwiftUI

struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: ProjectEditorState

    let onCancel: () -> Void
    let onSave: (ProjectEditorState) -> Bool

    init(
        state: ProjectEditorState,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ProjectEditorState) -> Bool
    ) {
        _state = State(initialValue: state)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $state.name)

                TextField("Notes", text: $state.note, axis: .vertical)
                    .lineLimit(3...6)

                LabeledContent("Color") {
                    HStack {
                        ForEach(ProjectColorOption.all) { option in
                            Button(
                                option.name,
                                systemImage: state.colorHex == option.hex
                                    ? "checkmark.circle.fill"
                                    : "circle.fill"
                            ) {
                                state.colorHex = option.hex
                            }
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .foregroundStyle(Color(projectHex: option.hex))
                            .help(option.name)
                        }
                    }
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
        .frame(width: 460)
    }

    private func cancel() {
        onCancel()
        dismiss()
    }

    private func save() {
        if onSave(state) {
            dismiss()
        }
    }
}
