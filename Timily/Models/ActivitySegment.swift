import Foundation
import SwiftData

@Model
final class ActivitySegment {
    @Attribute(.unique) var id: UUID
    var appBundleId: String
    var appName: String
    var windowTitle: String?
    var documentPath: String?
    var url: String?
    var startDate: Date
    var endDate: Date
    var timeEntry: TimeEntry?
    var note: String?

    init(
        id: UUID = UUID(),
        appBundleId: String,
        appName: String,
        windowTitle: String? = nil,
        documentPath: String? = nil,
        url: String? = nil,
        startDate: Date,
        endDate: Date,
        timeEntry: TimeEntry? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.appBundleId = appBundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.documentPath = documentPath
        self.url = url
        self.startDate = startDate
        self.endDate = endDate
        self.timeEntry = timeEntry
        self.note = note
    }

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }
}
