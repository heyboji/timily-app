import Foundation
import SwiftData
import SwiftUI

struct TimerMenuBarLabel: View {
    let viewModel: TimerViewModel

    var body: some View {
        if let timer = viewModel.activeTimer {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Label(
                    "Timily \(formattedElapsedTime(for: timer, at: timeline.date))",
                    systemImage: "clock"
                )
            }
        } else {
            Label("Timily", systemImage: "clock")
        }
    }
}

struct TimerControlView: View {
    enum Layout {
        case compact
        case normal
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(TimerViewModel.self) private var viewModel

    @Query(
        filter: #Predicate<Project> { !$0.isArchived },
        sort: \Project.name
    ) private var activeProjects: [Project]

    let layout: Layout

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(alignment: .leading, spacing: layout == .compact ? 10 : 16) {
            if let timer = viewModel.activeTimer {
                activeTimerContent(timer)
            } else {
                startTimerContent
            }
        }
        .padding(layout == .compact ? 12 : 24)
        .frame(width: layout == .compact ? 300 : nil)
        .frame(maxWidth: layout == .normal ? 520 : nil, alignment: .leading)
        .task {
            viewModel.refresh(in: modelContext)
        }
        .onChange(of: activeProjects.map(\.id)) { _, activeProjectIDs in
            if let projectID = viewModel.projectID,
               !activeProjectIDs.contains(projectID) {
                viewModel.projectID = nil
            }
        }
        .alert("Couldn’t Update Timer", isPresented: $viewModel.isShowingError) {
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    @ViewBuilder
    private func activeTimerContent(_ timer: TimeEntry) -> some View {
        Text(timer.project?.name ?? "Unassigned")
            .font(.headline)

        if let description = timer.entryDescription, !description.isEmpty {
            Text(description)
                .foregroundStyle(.secondary)
        }

        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(formattedElapsedTime(for: timer, at: timeline.date))
                .font(.system(.title2, design: .monospaced))
                .contentTransition(.numericText())
        }

        Button("Stop", systemImage: "stop.fill", role: .destructive) {
            viewModel.stop(in: modelContext)
        }
        .buttonStyle(.borderedProminent)
    }

    private var startTimerContent: some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: layout == .compact ? 8 : 12) {
            Picker("Project", selection: $viewModel.projectID) {
                Text("Unassigned").tag(nil as UUID?)
                ForEach(activeProjects) { project in
                    Text(project.name).tag(project.id as UUID?)
                }
            }

            TextField("Description", text: $viewModel.entryDescription)

            Menu("Presets") {
                ForEach(Array(viewModel.presets.enumerated()), id: \.offset) { _, preset in
                    Button(presetLabel(for: preset)) {
                        viewModel.applyPreset(preset)
                    }
                }
            }
            .disabled(viewModel.presets.isEmpty)

            Button("Start", systemImage: "play.fill") {
                viewModel.start(projects: activeProjects, in: modelContext)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func presetLabel(for preset: TimerPreset) -> String {
        let project = preset.project?.name ?? "Unassigned"
        guard let description = preset.description, !description.isEmpty else {
            return project
        }
        return "\(project) — \(description)"
    }
}

private func formattedElapsedTime(for timer: TimeEntry, at date: Date) -> String {
    let totalSeconds = max(0, Int(timer.duration(at: date)))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}
