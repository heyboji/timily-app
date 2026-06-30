import SwiftData
import SwiftUI

struct ActivityView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \TimeEntry.startDate, order: .reverse)
    private var entries: [TimeEntry]

    @Query(sort: \Project.name)
    private var projects: [Project]

    @State private var viewModel = ManualEntriesViewModel()
    @State private var timelineViewModel = ActivityTimelineViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel
        @Bindable var timelineViewModel = timelineViewModel

        dayContent
        .navigationTitle("Activity")
        .toolbar {
            activityToolbar
        }
        .safeAreaInset(edge: .bottom) {
            if !timelineViewModel.selectedEntryIDs.isEmpty {
                selectionBar
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
        .alert("Couldn’t Update Activity", isPresented: $timelineViewModel.isShowingError) {
        } message: {
            Text(timelineViewModel.errorMessage)
        }
        .onChange(of: dayEntries.map(\.id)) {
            timelineViewModel.pruneSelection(to: dayEntries)
        }
    }

    private var dayEntries: [TimeEntry] {
        timelineViewModel.entriesForSelectedDay(entries)
    }

    @ViewBuilder
    private var dayContent: some View {
        if dayEntries.isEmpty {
            emptyState
        } else {
            entryList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Activity This Day", systemImage: "clock")
        } description: {
            Text("Track an app or add time manually.")
        } actions: {
            Button("New Entry", systemImage: "plus", action: presentNewEntry)
        }
    }

    private var entryList: some View {
        @Bindable var timelineViewModel = timelineViewModel

        return List(selection: $timelineViewModel.selectedEntryIDs) {
            ForEach(dayEntries) { entry in
                entryRow(for: entry)
                    .tag(entry.id)
            }
        }
    }

    @ViewBuilder
    private func entryRow(for entry: TimeEntry) -> some View {
        if let displayInterval = timelineViewModel.displayInterval(for: entry) {
            TimeEntryRowView(
                entry: entry,
                displayInterval: displayInterval,
                onEdit: { viewModel.presentEditor(for: entry) },
                onDelete: { viewModel.delete(entry, in: modelContext) }
            )
        }
    }

    private var activeProjects: [Project] {
        projects.filter { !$0.isArchived }
    }

    @ToolbarContentBuilder
    private var activityToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Previous Day", systemImage: "chevron.left") {
                timelineViewModel.moveDay(by: -1)
            }
            .labelStyle(.iconOnly)

            Text(selectedDayText)
                .frame(minWidth: 150)

            Button("Next Day", systemImage: "chevron.right") {
                timelineViewModel.moveDay(by: 1)
            }
            .labelStyle(.iconOnly)

            Button("Today") {
                timelineViewModel.goToToday()
            }
            .disabled(timelineViewModel.isToday)
        }

        ToolbarItem(placement: .primaryAction) {
            Button(
                "New Entry",
                systemImage: "plus",
                action: presentNewEntry
            )
        }
    }

    private var selectedDayText: String {
        timelineViewModel.selectedDay.formatted(
            .dateTime.weekday().month().day()
        )
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(timelineViewModel.selectedEntryIDs.count) selected")
                .foregroundStyle(.secondary)

            Spacer()

            Menu("Assign Project", systemImage: "folder") {
                Button("Unassigned") {
                    timelineViewModel.assignSelected(from: dayEntries, to: nil, in: modelContext)
                }

                if !activeProjects.isEmpty {
                    Divider()
                }

                ForEach(activeProjects) { project in
                    Button(project.name) {
                        timelineViewModel.assignSelected(
                            from: dayEntries,
                            to: project,
                            in: modelContext
                        )
                    }
                }
            }

            Button("Merge", systemImage: "arrow.triangle.merge") {
                timelineViewModel.mergeSelected(from: dayEntries, in: modelContext)
            }
            .disabled(timelineViewModel.selectedEntryIDs.count < 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func presentNewEntry() {
        let anchor = timelineViewModel.isToday
            ? Date.now
            : Calendar.current.date(byAdding: .hour, value: 12, to: timelineViewModel.selectedDay)
                ?? timelineViewModel.selectedDay
        viewModel.presentNewEntry(now: anchor)
    }
}
