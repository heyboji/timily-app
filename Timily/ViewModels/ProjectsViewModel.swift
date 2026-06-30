import Observation
import SwiftData

@MainActor
@Observable
final class ProjectsViewModel {
    var editorState: ProjectEditorState?
    var errorMessage = ""
    var isShowingError = false

    func presentNewProject() {
        editorState = ProjectEditorState()
    }

    func presentEditor(for project: Project) {
        editorState = ProjectEditorState(project: project)
    }

    func dismissEditor() {
        editorState = nil
    }

    @discardableResult
    func save(_ state: ProjectEditorState, in context: ModelContext) -> Bool {
        saveProject(state, in: context) != nil
    }

    @discardableResult
    func saveProject(_ state: ProjectEditorState, in context: ModelContext) -> Project? {
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let note = state.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let project: Project

        if let existingProject = state.project {
            project = existingProject
            project.name = name
            project.colorHex = state.colorHex
            project.note = note.isEmpty ? nil : note
        } else {
            project = Project(
                name: name,
                colorHex: state.colorHex,
                note: note.isEmpty ? nil : note
            )
            context.insert(project)
        }

        guard save(context) else { return nil }
        editorState = nil
        return project
    }

    func toggleArchive(_ project: Project, in context: ModelContext) {
        project.isArchived.toggle()
        save(context)
    }

    func delete(_ project: Project, in context: ModelContext) {
        context.delete(project)
        save(context)
    }

    @discardableResult
    private func save(_ context: ModelContext) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            isShowingError = true
            return false
        }
    }
}
