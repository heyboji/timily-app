import SwiftUI

struct TimeEntryRowView: View {
    let entry: TimeEntry
    let displayInterval: DateInterval
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isConfirmingDeletion = false

    var body: some View {
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

                HStack(spacing: 8) {
                    Text(timeRangeText)

                    if let applicationText {
                        Text(applicationText)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(durationText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onEdit)
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
        let start = displayInterval.start.formatted(
            .dateTime.month(.abbreviated).day().hour().minute()
        )
        let end = displayInterval.end.formatted(
            .dateTime.month(.abbreviated).day().hour().minute()
        )
        return entry.endDate == nil ? "\(start) – \(end) · Running" : "\(start) – \(end)"
    }

    private var durationText: String {
        let totalMinutes = max(0, Int(displayInterval.duration / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private var applicationText: String? {
        let names = entry.activitySegments
            .filter {
                $0.startDate < displayInterval.end && $0.endDate > displayInterval.start
            }
            .map(\.appName)
            .reduce(into: [String]()) { result, name in
                if !result.contains(name) {
                    result.append(name)
                }
            }
        guard !names.isEmpty else { return nil }
        let visible = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(visible) +\(names.count - 2)" : visible
    }
}
