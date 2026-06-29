import Foundation

struct ProjectEditorState: Identifiable {
    let id = UUID()
    let project: Project?
    var name: String
    var colorHex: String
    var note: String

    init(project: Project? = nil) {
        self.project = project
        self.name = project?.name ?? ""
        self.colorHex = project?.colorHex ?? ProjectColorOption.default.hex
        self.note = project?.note ?? ""
    }

    var title: String {
        project == nil ? "New Project" : "Edit Project"
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
