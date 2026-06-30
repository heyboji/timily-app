import AppKit
import SwiftData
import XCTest
@testable import Timily

private final class ActivityMonitorIdleSource: IdleTimeSource, @unchecked Sendable {
    nonisolated(unsafe) var idleSeconds: TimeInterval = 0
}

@MainActor
private final class ActivityMonitorWorkspaceSource: ActivityWorkspaceSource {
    var frontmostApplication: TrackedApplication?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    private var onActivation: ((TrackedApplication?) -> Void)?
    private var onSuspend: ((ActivitySuspensionReason) -> Void)?
    private var onResume: ((ActivitySuspensionReason) -> Void)?

    func start(
        onActivation: @escaping @MainActor (TrackedApplication?) -> Void,
        onSuspend: @escaping @MainActor (ActivitySuspensionReason) -> Void,
        onResume: @escaping @MainActor (ActivitySuspensionReason) -> Void
    ) {
        startCount += 1
        self.onActivation = onActivation
        self.onSuspend = onSuspend
        self.onResume = onResume
    }

    func stop() {
        stopCount += 1
        onActivation = nil
        onSuspend = nil
        onResume = nil
    }

    func activate(_ application: TrackedApplication?) {
        frontmostApplication = application
        onActivation?(application)
    }

    func suspend(for reason: ActivitySuspensionReason) {
        onSuspend?(reason)
    }

    func resume(from reason: ActivitySuspensionReason) {
        onResume?(reason)
    }
}

@MainActor
private final class ActivityMonitorSink: ActivitySegmentSink {
    var segments: [CompletedActivitySegment] = []
    var failuresRemaining = 0

    func record(_ segment: CompletedActivitySegment) throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TestError.failed
        }
        segments.append(segment)
    }

    private enum TestError: Error {
        case failed
    }
}

private final class ActivityMonitorClock: @unchecked Sendable {
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
}

@MainActor
private final class ActivityMonitorSettingsSaver {
    var failuresRemaining = 0

    func save() throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TestError.failed
        }
    }

    private enum TestError: Error {
        case failed
    }
}

@MainActor
final class ActivityMonitorTests: XCTestCase {
    private let appA = TrackedApplication(bundleIdentifier: "test.a", displayName: "A")
    private let appB = TrackedApplication(bundleIdentifier: "test.b", displayName: "B")
    private let appC = TrackedApplication(bundleIdentifier: "test.c", displayName: "C")

    private struct Harness {
        let monitor: ActivityMonitor
        let settings: AppSettings
        let workspace: ActivityMonitorWorkspaceSource
        let sink: ActivityMonitorSink
        let idleSource: ActivityMonitorIdleSource
        let clock: ActivityMonitorClock
        let settingsSaver: ActivityMonitorSettingsSaver
        let terminationCenter: NotificationCenter
    }

    private func makeHarness(
        enabled: Bool = true,
        paused: Bool = false,
        frontmostApplication: TrackedApplication? = nil
    ) -> Harness {
        let settings = AppSettings(
            autoTrackingEnabled: enabled,
            trackingPaused: paused
        )
        let workspace = ActivityMonitorWorkspaceSource()
        workspace.frontmostApplication = frontmostApplication
        let sink = ActivityMonitorSink()
        let idleSource = ActivityMonitorIdleSource()
        let clock = ActivityMonitorClock()
        let settingsSaver = ActivityMonitorSettingsSaver()
        let terminationCenter = NotificationCenter()
        let detector = IdleDetector(
            source: idleSource,
            threshold: 60,
            clock: { clock.now }
        )
        let monitor = ActivityMonitor(
            settings: settings,
            idleDetector: detector,
            workspaceSource: workspace,
            segmentSink: sink,
            pollingInterval: 86_400,
            clock: { clock.now },
            saveSettings: { try settingsSaver.save() },
            terminationCenter: terminationCenter
        )
        return Harness(
            monitor: monitor,
            settings: settings,
            workspace: workspace,
            sink: sink,
            idleSource: idleSource,
            clock: clock,
            settingsSaver: settingsSaver,
            terminationCenter: terminationCenter
        )
    }

    func testActivationSequenceCreatesAdjacentNonOverlappingSegments() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.monitor.start()
        harness.clock.now = date(10)
        harness.workspace.activate(appB)
        harness.clock.now = date(20)
        harness.monitor.stop()

        XCTAssertEqual(
            harness.sink.segments,
            [segment(appA, 0, 10), segment(appB, 10, 20)]
        )
        XCTAssertLessThanOrEqual(
            harness.sink.segments[0].endDate,
            harness.sink.segments[1].startDate
        )
    }

    func testRepeatedActivationOfSameBundleDoesNotSplitSegment() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.monitor.start()
        harness.clock.now = date(10)
        harness.workspace.activate(
            TrackedApplication(bundleIdentifier: appA.bundleIdentifier, displayName: "Renamed")
        )
        harness.clock.now = date(20)
        harness.monitor.stop()

        XCTAssertEqual(harness.sink.segments, [segment(appA, 0, 20)])
    }

    func testSameTimestampSwitchDiscardsZeroDurationSegment() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.monitor.start()
        harness.workspace.activate(appB)
        harness.clock.now = date(10)
        harness.monitor.stop()

        XCTAssertEqual(harness.sink.segments, [segment(appB, 0, 10)])
    }

    func testIdleCreatesGapAndUsesLatestFrontmostApplicationOnReturn() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.monitor.start()
        harness.clock.now = date(400)
        harness.idleSource.idleSeconds = 120
        harness.monitor.pollIdleNow()

        harness.clock.now = date(450)
        harness.workspace.activate(appB)
        harness.clock.now = date(500)
        harness.idleSource.idleSeconds = 0
        harness.monitor.pollIdleNow()
        harness.clock.now = date(550)
        harness.monitor.stop()

        XCTAssertEqual(
            harness.sink.segments,
            [segment(appA, 0, 280), segment(appB, 500, 550)]
        )
    }

    func testPauseAndResumeUseCurrentApplicationWithoutCountingGap() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.monitor.start()
        harness.clock.now = date(10)
        harness.monitor.pause()
        harness.workspace.activate(appB)
        harness.workspace.activate(appC)
        harness.clock.now = date(30)
        harness.monitor.resume()
        harness.clock.now = date(40)
        harness.monitor.stop()

        XCTAssertTrue(harness.settings.trackingPaused == false)
        XCTAssertEqual(
            harness.sink.segments,
            [segment(appA, 0, 10), segment(appC, 30, 40)]
        )
    }

    func testPersistedPauseKeepsLaunchDormant() {
        let harness = makeHarness(paused: true, frontmostApplication: appA)
        harness.monitor.start()
        harness.clock.now = date(10)
        harness.monitor.stop()

        XCTAssertTrue(harness.monitor.isPaused)
        XCTAssertTrue(harness.sink.segments.isEmpty)
    }

    func testDisabledTrackingStaysDormantUntilEnabledAndClosesWhenDisabled() {
        let harness = makeHarness(enabled: false, frontmostApplication: appA)
        harness.monitor.start()
        harness.workspace.activate(appB)
        harness.clock.now = date(10)
        harness.monitor.setAutoTrackingEnabled(true)
        harness.clock.now = date(20)
        harness.monitor.setAutoTrackingEnabled(false)
        harness.clock.now = date(30)
        harness.monitor.stop()

        XCTAssertFalse(harness.settings.autoTrackingEnabled)
        XCTAssertEqual(harness.sink.segments, [segment(appB, 10, 20)])
    }

    func testSleepAndSessionSuspensionsMustBothEndBeforeResuming() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.monitor.start()
        harness.clock.now = date(10)
        harness.workspace.suspend(for: .sleep)
        harness.workspace.suspend(for: .session)
        harness.workspace.activate(appB)
        harness.clock.now = date(50)
        harness.workspace.resume(from: .sleep)
        harness.clock.now = date(100)
        harness.workspace.resume(from: .session)
        harness.clock.now = date(110)
        harness.monitor.stop()

        XCTAssertEqual(
            harness.sink.segments,
            [segment(appA, 0, 10), segment(appB, 100, 110)]
        )
    }

    func testSystemWorkspaceSourceDeliversSuspensionEventsSynchronouslyInOrder() {
        let center = NotificationCenter()
        let source = SystemActivityWorkspaceSource(
            notificationCenter: center,
            frontmostApplicationProvider: { nil }
        )
        var events: [String] = []
        source.start(
            onActivation: { _ in events.append("activation") },
            onSuspend: { reason in events.append("suspend-\(reason)") },
            onResume: { reason in events.append("resume-\(reason)") }
        )

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        XCTAssertEqual(
            events,
            ["suspend-sleep", "suspend-session", "resume-sleep", "resume-session"]
        )
        source.stop()
    }

    func testStartAndStopAreIdempotent() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.monitor.start()
        harness.monitor.start()
        harness.clock.now = date(10)
        harness.monitor.stop()
        harness.monitor.stop()

        XCTAssertEqual(harness.workspace.startCount, 1)
        XCTAssertEqual(harness.workspace.stopCount, 1)
        XCTAssertEqual(harness.sink.segments, [segment(appA, 0, 10)])
    }

    func testTerminationClosesCurrentSegmentExactlyOnce() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.monitor.start()
        harness.clock.now = date(10)
        harness.terminationCenter.post(name: NSApplication.willTerminateNotification, object: nil)
        harness.terminationCenter.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertFalse(harness.monitor.isStarted)
        XCTAssertEqual(harness.workspace.stopCount, 1)
        XCTAssertEqual(harness.sink.segments, [segment(appA, 0, 10)])
    }

    func testPersistenceFailureRetriesSegmentsInOrderAndContinuesTracking() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.sink.failuresRemaining = 1
        harness.monitor.start()
        harness.clock.now = date(10)
        harness.workspace.activate(appB)
        harness.clock.now = date(20)
        harness.workspace.activate(appC)
        harness.clock.now = date(30)
        harness.monitor.stop()

        XCTAssertEqual(
            harness.sink.segments,
            [segment(appA, 0, 10), segment(appB, 10, 20), segment(appC, 20, 30)]
        )
    }

    func testFailedPauseSaveRestoresRunningState() {
        let harness = makeHarness(frontmostApplication: appA)
        harness.monitor.start()
        harness.settingsSaver.failuresRemaining = 1
        harness.clock.now = date(10)
        harness.monitor.pause()
        harness.clock.now = date(20)
        harness.monitor.stop()

        XCTAssertFalse(harness.monitor.isPaused)
        XCTAssertFalse(harness.settings.trackingPaused)
        XCTAssertEqual(harness.sink.segments, [segment(appA, 0, 20)])
    }

    func testFailedResumeSaveKeepsMonitorPaused() {
        let harness = makeHarness(paused: true, frontmostApplication: appA)
        harness.monitor.start()
        harness.settingsSaver.failuresRemaining = 1
        harness.monitor.resume()

        XCTAssertTrue(harness.monitor.isPaused)
        XCTAssertTrue(harness.settings.trackingPaused)
        XCTAssertTrue(harness.sink.segments.isEmpty)
    }

    func testFailedEnableSaveKeepsMonitorDisabled() {
        let harness = makeHarness(enabled: false, frontmostApplication: appA)
        harness.monitor.start()
        harness.settingsSaver.failuresRemaining = 1
        harness.monitor.setAutoTrackingEnabled(true)
        harness.clock.now = date(10)
        harness.monitor.stop()

        XCTAssertFalse(harness.monitor.isAutoTrackingEnabled)
        XCTAssertFalse(harness.settings.autoTrackingEnabled)
        XCTAssertTrue(harness.sink.segments.isEmpty)
    }

    func testSwiftDataSinkPersistsRawSegment() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let sink = SwiftDataActivitySegmentSink(context: container.mainContext)

        try sink.record(segment(appA, 10, 20))

        let saved = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<ActivitySegment>()).first
        )
        XCTAssertEqual(saved.appBundleId, appA.bundleIdentifier)
        XCTAssertEqual(saved.appName, appA.displayName)
        XCTAssertEqual(saved.startDate, date(10))
        XCTAssertEqual(saved.endDate, date(20))
        XCTAssertNil(saved.timeEntry)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func segment(
        _ application: TrackedApplication,
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> CompletedActivitySegment {
        CompletedActivitySegment(
            application: application,
            startDate: date(start),
            endDate: date(end)
        )
    }
}
