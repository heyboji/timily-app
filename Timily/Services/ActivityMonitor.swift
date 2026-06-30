import AppKit
import Foundation
import Observation
import SwiftData

nonisolated struct TrackedApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
}

nonisolated struct CompletedActivitySegment: Equatable, Sendable {
    let application: TrackedApplication
    let startDate: Date
    let endDate: Date
}

nonisolated enum ActivitySuspensionReason: Hashable, Sendable {
    case sleep
    case session
}

@MainActor
protocol ActivityWorkspaceSource: AnyObject {
    var frontmostApplication: TrackedApplication? { get }

    func start(
        onActivation: @escaping @MainActor (TrackedApplication?) -> Void,
        onSuspend: @escaping @MainActor (ActivitySuspensionReason) -> Void,
        onResume: @escaping @MainActor (ActivitySuspensionReason) -> Void
    )

    func stop()
}

@MainActor
protocol ActivitySegmentSink: AnyObject {
    func record(_ segment: CompletedActivitySegment) throws
}

@MainActor
final class SwiftDataActivitySegmentSink: ActivitySegmentSink {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func record(_ segment: CompletedActivitySegment) throws {
        context.insert(
            ActivitySegment(
                appBundleId: segment.application.bundleIdentifier,
                appName: segment.application.displayName,
                startDate: segment.startDate,
                endDate: segment.endDate
            )
        )

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

@MainActor
final class SystemActivityWorkspaceSource: ActivityWorkspaceSource {
    private let notificationCenter: NotificationCenter
    private let frontmostApplicationProvider: () -> NSRunningApplication?
    private var observers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmostApplicationProvider: @escaping () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        }
    ) {
        self.notificationCenter = notificationCenter
        self.frontmostApplicationProvider = frontmostApplicationProvider
    }

    var frontmostApplication: TrackedApplication? {
        Self.trackedApplication(from: frontmostApplicationProvider())
    }

    func start(
        onActivation: @escaping @MainActor (TrackedApplication?) -> Void,
        onSuspend: @escaping @MainActor (ActivitySuspensionReason) -> Void,
        onResume: @escaping @MainActor (ActivitySuspensionReason) -> Void
    ) {
        stop()
        let center = notificationCenter

        observers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                let runningApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                let application = Self.trackedApplication(from: runningApplication)
                MainActor.assumeIsolated {
                    onActivation(application)
                }
            }
        )

        observe(
            NSWorkspace.willSleepNotification,
            center: center
        ) { onSuspend(.sleep) }
        observe(
            NSWorkspace.didWakeNotification,
            center: center
        ) { onResume(.sleep) }
        observe(
            NSWorkspace.sessionDidResignActiveNotification,
            center: center
        ) { onSuspend(.session) }
        observe(
            NSWorkspace.sessionDidBecomeActiveNotification,
            center: center
        ) { onResume(.session) }
    }

    func stop() {
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
    }

    private func observe(
        _ name: NSNotification.Name,
        center: NotificationCenter,
        handler: @escaping @MainActor () -> Void
    ) {
        observers.append(
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    handler()
                }
            }
        )
    }

    nonisolated private static func trackedApplication(
        from runningApplication: NSRunningApplication?
    ) -> TrackedApplication? {
        guard let bundleIdentifier = runningApplication?.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              let displayName = runningApplication?.localizedName,
              !displayName.isEmpty else {
            return nil
        }

        return TrackedApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        )
    }
}

@MainActor
@Observable
final class ActivityMonitor {
    private struct OpenSegment {
        let application: TrackedApplication
        let startDate: Date
    }

    private(set) var isStarted = false
    private(set) var isPaused: Bool
    private(set) var isAutoTrackingEnabled: Bool

    private let settings: AppSettings
    private let idleDetector: IdleDetector
    private let workspaceSource: any ActivityWorkspaceSource
    private let segmentSink: any ActivitySegmentSink
    private let logger: DiagnosticLogger
    private let clock: () -> Date
    private let saveSettings: () throws -> Void
    private let pollingInterval: TimeInterval
    private let terminationCenter: NotificationCenter

    private var frontmostApplication: TrackedApplication?
    private var openSegment: OpenSegment?
    private var isIdle = false
    private var suspensionReasons: Set<ActivitySuspensionReason> = []
    private var pollingTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var pendingSegments: [CompletedActivitySegment] = []

    init(
        settings: AppSettings,
        idleDetector: IdleDetector,
        workspaceSource: any ActivityWorkspaceSource,
        segmentSink: any ActivitySegmentSink,
        logger: DiagnosticLogger = .shared,
        pollingInterval: TimeInterval = 5,
        clock: @escaping () -> Date = { .now },
        saveSettings: @escaping () throws -> Void = {},
        terminationCenter: NotificationCenter = .default
    ) {
        self.settings = settings
        self.idleDetector = idleDetector
        self.workspaceSource = workspaceSource
        self.segmentSink = segmentSink
        self.logger = logger
        self.pollingInterval = pollingInterval
        self.clock = clock
        self.saveSettings = saveSettings
        self.terminationCenter = terminationCenter
        isPaused = settings.trackingPaused
        isAutoTrackingEnabled = settings.autoTrackingEnabled
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        suspensionReasons.removeAll()
        frontmostApplication = workspaceSource.frontmostApplication

        workspaceSource.start(
            onActivation: { [weak self] application in
                self?.applicationDidActivate(application)
            },
            onSuspend: { [weak self] reason in
                self?.suspend(for: reason)
            },
            onResume: { [weak self] reason in
                self?.resume(from: reason)
            }
        )

        terminationObserver = terminationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }

        idleDetector.poll()
        isIdle = idleDetector.isIdle
        flushPendingSegments()
        openCurrentApplicationIfAllowed(at: clock())
        reconcilePolling()
        log(.info, "activity monitor started")
    }

    func stop() {
        guard isStarted else { return }
        closeOpenSegment(at: clock())
        flushPendingSegments()
        isStarted = false
        pollingTask?.cancel()
        pollingTask = nil
        workspaceSource.stop()
        if let terminationObserver {
            terminationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        suspensionReasons.removeAll()
        log(.info, "activity monitor stopped")
    }

    func pause() {
        guard !isPaused else { return }
        let previousPaused = isPaused
        let previousEnabled = isAutoTrackingEnabled
        isPaused = true
        settings.trackingPaused = true
        guard persistSettings(
            previousPaused: previousPaused,
            previousEnabled: previousEnabled
        ) else { return }
        closeOpenSegment(at: clock())
        reconcilePolling()
        log(.info, "activity tracking paused")
    }

    func resume() {
        guard isPaused else { return }
        let previousPaused = isPaused
        let previousEnabled = isAutoTrackingEnabled
        isPaused = false
        settings.trackingPaused = false
        guard persistSettings(
            previousPaused: previousPaused,
            previousEnabled: previousEnabled
        ) else { return }
        refreshIdleState()
        openCurrentApplicationIfAllowed(at: clock())
        reconcilePolling()
        log(.info, "activity tracking resumed")
    }

    func setAutoTrackingEnabled(_ enabled: Bool) {
        guard isAutoTrackingEnabled != enabled else { return }
        let previousPaused = isPaused
        let previousEnabled = isAutoTrackingEnabled
        isAutoTrackingEnabled = enabled
        settings.autoTrackingEnabled = enabled
        guard persistSettings(
            previousPaused: previousPaused,
            previousEnabled: previousEnabled
        ) else { return }

        if enabled {
            refreshIdleState()
            frontmostApplication = workspaceSource.frontmostApplication
            openCurrentApplicationIfAllowed(at: clock())
        } else {
            closeOpenSegment(at: clock())
        }

        reconcilePolling()
        log(.info, enabled ? "activity tracking enabled" : "activity tracking disabled")
    }

    func pollIdleNow() {
        guard isStarted, isAutoTrackingEnabled, !isPaused, suspensionReasons.isEmpty else {
            return
        }

        let wasIdle = isIdle
        idleDetector.poll()
        isIdle = idleDetector.isIdle
        guard wasIdle != isIdle else { return }

        let now = clock()
        if isIdle {
            let idleStart = min(idleDetector.lastInputDate, now)
            closeOpenSegment(at: idleStart)
            log(.info, "activity idle entered")
        } else {
            frontmostApplication = workspaceSource.frontmostApplication
            openCurrentApplicationIfAllowed(at: now)
            log(.info, "activity idle exited")
        }
    }

    private var trackingIsAllowed: Bool {
        isStarted
            && isAutoTrackingEnabled
            && !isPaused
            && !isIdle
            && suspensionReasons.isEmpty
    }

    private func applicationDidActivate(_ application: TrackedApplication?) {
        frontmostApplication = application
        guard trackingIsAllowed else { return }

        if openSegment?.application.bundleIdentifier == application?.bundleIdentifier {
            return
        }

        let boundary = clock()
        closeOpenSegment(at: boundary)
        openCurrentApplicationIfAllowed(at: boundary)
    }

    private func suspend(for reason: ActivitySuspensionReason) {
        guard suspensionReasons.insert(reason).inserted else { return }
        closeOpenSegment(at: clock())
        reconcilePolling()
        log(.info, "activity monitor suspended")
    }

    private func resume(from reason: ActivitySuspensionReason) {
        guard suspensionReasons.remove(reason) != nil else { return }
        guard suspensionReasons.isEmpty else { return }
        refreshIdleState()
        frontmostApplication = workspaceSource.frontmostApplication
        openCurrentApplicationIfAllowed(at: clock())
        reconcilePolling()
        log(.info, "activity monitor resumed")
    }

    private func refreshIdleState() {
        guard isStarted, isAutoTrackingEnabled, !isPaused, suspensionReasons.isEmpty else {
            return
        }
        idleDetector.poll()
        isIdle = idleDetector.isIdle
    }

    private func openCurrentApplicationIfAllowed(at date: Date) {
        guard trackingIsAllowed,
              openSegment == nil,
              let application = frontmostApplication else {
            return
        }
        openSegment = OpenSegment(application: application, startDate: date)
    }

    private func closeOpenSegment(at proposedEndDate: Date) {
        guard let segment = openSegment else { return }
        openSegment = nil
        let endDate = max(segment.startDate, proposedEndDate)
        guard endDate > segment.startDate else { return }

        pendingSegments.append(
            CompletedActivitySegment(
                application: segment.application,
                startDate: segment.startDate,
                endDate: endDate
            )
        )
        flushPendingSegments()
    }

    private func flushPendingSegments() {
        while let segment = pendingSegments.first {
            do {
                try segmentSink.record(segment)
                pendingSegments.removeFirst()
            } catch {
                log(.error, "activity segment persistence failed")
                return
            }
        }
    }

    private func persistSettings(
        previousPaused: Bool,
        previousEnabled: Bool
    ) -> Bool {
        do {
            try saveSettings()
            return true
        } catch {
            isPaused = previousPaused
            isAutoTrackingEnabled = previousEnabled
            settings.trackingPaused = previousPaused
            settings.autoTrackingEnabled = previousEnabled
            log(.error, "activity settings persistence failed")
            return false
        }
    }

    private func reconcilePolling() {
        let shouldPoll = isStarted
            && isAutoTrackingEnabled
            && !isPaused
            && suspensionReasons.isEmpty

        guard shouldPoll else {
            pollingTask?.cancel()
            pollingTask = nil
            return
        }

        guard pollingTask == nil else { return }
        let interval = pollingInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                self?.pollIdleNow()
            }
        }
    }

    private func log(_ level: DiagnosticLogLevel, _ message: String) {
        Task {
            await logger.log(level: level, category: .activity, message: message)
        }
    }
}
