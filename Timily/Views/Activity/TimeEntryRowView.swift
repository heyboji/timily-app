import SwiftUI

struct TimeEntryRowView: View {
    let entry: TimeEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isConfirmingDeletion = false

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(projectColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.project?.name ?? "Unassigned")
                            .fontWeight(.medium)

                        if let description = entry.entryDescription, !description.isEmpty {
                            Text(description)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(timeRangeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(durationText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: onEdit)
            Button("Delete Entry", systemImage: "trash", role: .destructive) {
                isConfirmingDeletion = true
            }
        }
        .confirmationDialog(
            "Delete This Entry?",
            isPresented: $isConfirmingDeletion
        ) {
            Button("Delete Entry", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            if entry.activitySegments.isEmpty {
                Text("This action cannot be undone.")
            } else {
                Text("Linked activity will return as separate Unassigned entries.")
            }
        }
    }

    private var projectColor: Color {
        guard let project = entry.project else { return .secondary }
        return Color(projectHex: project.colorHex)
    }

    private var timeRangeText: String {
        let start = entry.startDate.formatted(
            .dateTime.month(.abbreviated).day().hour().minute()
        )
        guard let endDate = entry.endDate else { return "\(start) – Running" }
        let end = endDate.formatted(
            .dateTime.month(.abbreviated).day().hour().minute()
        )
        return "\(start) – \(end)"
    }

    private var durationText: String {
        let totalMinutes = max(0, Int(entry.duration() / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
