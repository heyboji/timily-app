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
    @State private var pendingActivityDeletionID: UUID?

    var body: some View {
        @Bindable var viewModel = viewModel
        @Bindable var timelineViewModel = timelineViewModel

        dayContent
        .navigationTitle("Activity")
        .toolbar {
            activityToolbar
        }
        .safeAreaInset(edge: .bottom) {
            if !timelineViewModel.selection.isEmpty {
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
        .confirmationDialog(
            "Delete This Activity?",
            isPresented: isConfirmingActivityDeletion
        ) {
            Button("Delete Activity", role: .destructive, action: deletePendingActivity)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the captured activity and its Unassigned entry.")
        }
        .onChange(of: selectionSnapshot) {
            timelineViewModel.pruneSelection(to: dayEntries)
        }
        .onChange(of: timelineViewModel.selection) { previous, proposed in
            timelineViewModel.normalizeSelection(from: previous, to: proposed)
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

        return List(selection: $timelineViewModel.selection) {
            ForEach(dayEntries) { entry in
                entryGroup(for: entry)
            }
        }
    }

    @ViewBuilder
    private func entryGroup(for entry: TimeEntry) -> some View {
        let segments = timelineViewModel.segmentsForSelectedDay(in: entry)

        if segments.isEmpty {
            entryRow(for: entry)
                .tag(ActivityTimelineSelection.entry(entry.id))
        } else {
            DisclosureGroup {
                ForEach(segments) { segment in
                    segmentRow(for: segment)
                        .tag(ActivityTimelineSelection.segment(segment.id))
                }
            } label: {
                entryRow(for: entry)
            }
            .tag(ActivityTimelineSelection.entry(entry.id))
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

    @ViewBuilder
    private func segmentRow(for segment: ActivitySegment) -> some View {
        if let displayInterval = timelineViewModel.displayInterval(for: segment) {
            ActivitySegmentRowView(
                segment: segment,
                displayInterval: displayInterval,
                canDeleteActivity: timelineViewModel.canDeleteActivity(segment),
                onDeleteActivity: { pendingActivityDeletionID = segment.id }
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

    private var selectionSnapshot: [ActivityTimelineSelection] {
        dayEntries.flatMap { entry in
            [ActivityTimelineSelection.entry(entry.id)]
                + timelineViewModel.segmentsForSelectedDay(in: entry).map {
                    ActivityTimelineSelection.segment($0.id)
                }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(selectionSummary)
                .foregroundStyle(.secondary)

            Spacer()

            Menu("Assign Project", systemImage: "folder") {
                Button("Unassigned") {
                    assign(to: nil)
                }

                if !activeProjects.isEmpty {
                    Divider()
                }

                ForEach(activeProjects) { project in
                    Button(project.name) {
                        assign(to: project)
                    }
                }
            }

            if timelineViewModel.selectedSegmentIDs.isEmpty {
                Button("Merge", systemImage: "arrow.triangle.merge") {
                    timelineViewModel.mergeSelected(from: dayEntries, in: modelContext)
                }
                .disabled(timelineViewModel.selectedEntryIDs.count < 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionSummary: String {
        let segmentCount = timelineViewModel.selectedSegmentIDs.count
        if segmentCount > 0 {
            return "\(segmentCount) \(segmentCount == 1 ? "segment" : "segments") selected"
        }
        let entryCount = timelineViewModel.selectedEntryIDs.count
        return "\(entryCount) \(entryCount == 1 ? "entry" : "entries") selected"
    }

    private var isConfirmingActivityDeletion: Binding<Bool> {
        Binding(
            get: { pendingActivityDeletionID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingActivityDeletionID = nil
                }
            }
        )
    }

    private func assign(to project: Project?) {
        if timelineViewModel.selectedSegmentIDs.isEmpty {
            timelineViewModel.assignSelected(from: dayEntries, to: project, in: modelContext)
        } else {
            timelineViewModel.assignSelectedSegments(to: project, in: modelContext)
        }
    }

    private func deletePendingActivity() {
        defer { pendingActivityDeletionID = nil }
        guard let pendingActivityDeletionID,
              let segment = dayEntries
                .flatMap(\.activitySegments)
                .first(where: { $0.id == pendingActivityDeletionID }) else {
            return
        }
        timelineViewModel.deleteActivity(segment, in: modelContext)
    }

    private func presentNewEntry() {
        let anchor = timelineViewModel.isToday
            ? Date.now
            : Calendar.current.date(byAdding: .hour, value: 12, to: timelineViewModel.selectedDay)
                ?? timelineViewModel.selectedDay
        viewModel.presentNewEntry(now: anchor)
    }
}
