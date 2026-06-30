import SwiftUI

struct ActivitySegmentRowView: View {
    let segment: ActivitySegment
    let displayInterval: DateInterval
    let canDeleteActivity: Bool
    let onDeleteActivity: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(segment.appName)
                        .fontWeight(.medium)

                    if let contextText {
                        Text(contextText)
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
        .padding(.leading, 22)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .contextMenu {
            if canDeleteActivity {
                Button("Delete Activity", systemImage: "trash", role: .destructive) {
                    onDeleteActivity()
                }
            }
        }
    }

    private var contextText: String? {
        for value in [segment.windowTitle, segment.url, segment.documentPath] {
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private var timeRangeText: String {
        let start = displayInterval.start.formatted(.dateTime.hour().minute())
        let end = displayInterval.end.formatted(.dateTime.hour().minute())
        return "\(start) – \(end)"
    }

    private var durationText: String {
        let totalMinutes = max(0, Int(displayInterval.duration / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
