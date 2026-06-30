import Foundation
import Observation
import SwiftData

enum ManualEntrySaveResult: Equatable {
    case saved
    case conflict
    case failed
}

@MainActor
@Observable
final class ManualEntriesViewModel {
    var editorState: TimeEntryEditorState?
    var errorMessage = ""
    var isShowingError = false

    private let service = TimeEntryService()

    func presentNewEntry(now: Date = .now) {
        editorState = TimeEntryEditorState(now: now)
    }

    func presentNewEntry(startDate: Date, endDate: Date) {
        editorState = TimeEntryEditorState(startDate: startDate, endDate: endDate)
    }

    func presentEditor(for entry: TimeEntry) {
        editorState = TimeEntryEditorState(entry: entry)
    }

    func dismissEditor() {
        editorState = nil
    }

    @discardableResult
    func save(
        _ state: TimeEntryEditorState,
        replacingConflicts: Bool,
        projects: [Project],
        in context: ModelContext
    ) -> ManualEntrySaveResult {
        let project = state.projectID.flatMap { projectID in
            projects.first { $0.id == projectID }
        }

        do {
            if let entry = state.entry {
                try service.update(
                    entry,
                    start: state.normalizedStartDate,
                    end: state.normalizedEndDate,
                    description: state.normalizedDescription,
                    project: project,
                    replacingConflicts: replacingConflicts,
                    in: context
                )
            } else if replacingConflicts {
                try service.replace(
                    start: state.normalizedStartDate,
                    end: state.normalizedEndDate,
                    description: state.normalizedDescription,
                    source: .manual,
                    project: project,
                    in: context
                )
            } else {
                try service.add(
                    start: state.normalizedStartDate,
                    end: state.normalizedEndDate,
                    description: state.normalizedDescription,
                    source: .manual,
                    project: project,
                    in: context
                )
            }

            editorState = nil
            return .saved
        } catch TimeEntryError.overlapsExistingEntry {
            return .conflict
        } catch {
            show(error)
            return .failed
        }
    }

    func delete(_ entry: TimeEntry, in context: ModelContext) {
        do {
            try service.delete(entry, in: context)
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}
