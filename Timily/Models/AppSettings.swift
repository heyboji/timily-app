import Foundation
import SwiftData

@Model
final class AppSettings {
    var idleThresholdSeconds: Int
    var launchAtLogin: Bool
    var showInDock: Bool
    var autoTrackingEnabled: Bool
    var trackingPaused: Bool

    init(
        idleThresholdSeconds: Int = 300,
        launchAtLogin: Bool = false,
        showInDock: Bool = false,
        autoTrackingEnabled: Bool = false,
        trackingPaused: Bool = false
    ) {
        self.idleThresholdSeconds = idleThresholdSeconds
        self.launchAtLogin = launchAtLogin
        self.showInDock = showInDock
        self.autoTrackingEnabled = autoTrackingEnabled
        self.trackingPaused = trackingPaused
    }
}
