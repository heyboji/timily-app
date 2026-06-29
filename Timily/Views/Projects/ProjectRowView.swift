import SwiftUI

struct ProjectRowView: View {
    let project: Project
    let onEdit: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void

    @State private var isConfirmingDeletion = false

    var body: some View {
        Button(action: onEdit) {
            HStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(Color(projectHex: project.colorHex))
                    .accessibilityHidden(true)

                VStack(alignment: .leading) {
                    Text(project.name)

                    if let note = project.note, !note.isEmpty {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if project.isArchived {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Archived")
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: onEdit)
            Button(
                project.isArchived ? "Unarchive" : "Archive",
                systemImage: project.isArchived ? "arrow.uturn.backward" : "archivebox",
                action: onToggleArchive
            )

            Divider()

            Button("Delete Project", systemImage: "trash", role: .destructive) {
                isConfirmingDeletion = true
            }
        }
        .confirmationDialog(
            "Delete \(project.name)?",
            isPresented: $isConfirmingDeletion
        ) {
            Button("Delete Project", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Time entries become Unassigned and project rules are deleted.")
        }
    }
}
