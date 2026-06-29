import CoreGraphics
import Foundation
import Observation

// MARK: - IdleTimeSource

/// Provides the number of seconds the user has been idle.
///
/// The concrete production type is `SystemIdleTimeSource` (a thin
/// CoreGraphics wrapper below). Everything else in this file — and all
/// tests — depend only on this protocol, so idle behaviour is fully testable
/// with a mock source.
nonisolated protocol IdleTimeSource: Sendable {
    /// Seconds elapsed since the last user input event.
    ///
    /// Must be readable without any actor isolation so that the
    /// `@MainActor`-isolated `IdleDetector` can call it freely from `poll()`.
    var idleSeconds: TimeInterval { get }
}

// MARK: - SystemIdleTimeSource

/// Thin CoreGraphics wrapper. This is the **only** non-pure type in this
/// file — keep it minimal; all policy and state live elsewhere.
///
/// `CGEventType(rawValue: ~0)` is `kCGAnyInputEventType`, which covers
/// keyboard, mouse, scroll, tablet, etc. in the current user session.
nonisolated struct SystemIdleTimeSource: IdleTimeSource {
    var idleSeconds: TimeInterval {
        guard let anyInputEventType = CGEventType(rawValue: UInt32.max) else {
            return 0
        }

        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEventType
        )
    }
}

// MARK: - IdleReturnPolicy

/// What to do with the running time entry when the user returns from idle.
///
/// The idle gap is `[idleStart, returnDate]`, where `idleStart` is the
/// inferred date of the last user input before the threshold was crossed.
///
/// - `exclude`: **Default.** Drop the gap; entry is closed at `idleStart`.
///   The caller should begin a fresh entry at `returnDate`.
/// - `keep`: Count idle time as work; extend the entry through `returnDate`.
/// - `editBoundary(date)`: Caller-supplied split point (e.g. from a dialog).
///   The entry ends at `date`, clamped to `[entryStart, returnDate]`.
nonisolated enum IdleReturnPolicy: Sendable, Equatable {
    case exclude
    case keep
    case editBoundary(Date)
}

// MARK: - Pure idle policy functions (Foundation only, no CoreGraphics)

/// Returns the truncated `TimeRange` for a running entry the moment idle is
/// detected.
///
/// Use this to compute the `endDate` to apply to the running `TimeEntry`.
/// `lastInputDate` should be `Date.now − idleSeconds` at the instant the
/// idle threshold is first crossed.
///
/// - Parameters:
///   - start: The `startDate` of the running `TimeEntry`.
///   - lastInputDate: The inferred date of the last user input.
/// - Returns: A `TimeRange` whose `end` equals `lastInputDate`, clamped to
///   be no earlier than `start` (zero-duration when already idle at entry start).
nonisolated func idleTruncatedInterval(start: Date, lastInputDate: Date) -> TimeRange {
    TimeRange.clampingEnd(start: start, end: lastInputDate)
}

/// Resolves the final `TimeRange` for an entry that was open when idle began,
/// given the return-from-idle policy.
///
/// This is a **pure function** — no side effects, no I/O. Pass the three
/// boundary dates and a policy; receive the `[startDate, endDate]` the
/// completed `TimeEntry` should have.
///
/// Invalid or clock-skewed boundaries are clamped to a valid range.
///
/// - Parameters:
///   - entryStart: The original `startDate` of the entry.
///   - idleStart: The `lastInputDate` at which idle was first detected (the
///     moment the running entry was tentatively truncated).
///   - returnDate: `Date.now` when the user was detected as active again.
///   - policy: The return-from-idle policy.
/// - Returns: The resolved `TimeRange` for the completed entry.
nonisolated func resolveIdleEntry(
    entryStart: Date,
    idleStart: Date,
    returnDate: Date,
    policy: IdleReturnPolicy
) -> TimeRange {
    switch policy {
    case .exclude:
        // Drop the idle gap; entry ends at last known user input.
        return TimeRange.clampingEnd(start: entryStart, end: idleStart)

    case .keep:
        // Count idle time as work; entry stretches through returnDate.
        return TimeRange.clampingEnd(start: entryStart, end: returnDate)

    case .editBoundary(let boundary):
        // Clamp caller-supplied boundary to [entryStart, returnDate].
        let effectiveReturnDate = max(returnDate, entryStart)
        let clamped = min(max(boundary, entryStart), effectiveReturnDate)
        return TimeRange.clampingEnd(start: entryStart, end: clamped)
    }
}

// MARK: - IdleDetector

/// Observes system idle time and exposes whether the user is currently idle.
///
/// Confined to `@MainActor`. Read `isIdle` and `lastInputDate` from SwiftUI
/// views or other `@MainActor` services.
///
/// **Typical setup:**
/// ```swift
/// let detector = IdleDetector(
///     source: SystemIdleTimeSource(),
///     threshold: TimeInterval(settings.idleThresholdSeconds)
/// )
/// detector.startPolling()
/// ```
///
/// **Sleep / lock (TODO):** System sleep and screen-lock must not count as
/// activity. The intended approach is for the integrating service (e.g.
/// `ActivityMonitor`) to subscribe to `NSWorkspace.willSleepNotification` /
/// `NSWorkspace.didWakeNotification`, calling `stopPolling()` on sleep and
/// `startPolling()` on wake. The core idle measurement stays pure and does
/// not reference AppKit; sleep/wake wiring belongs in the integration layer.
@MainActor
@Observable
final class IdleDetector {

    // MARK: Observable state

    /// `true` when `source.idleSeconds > threshold`.
    private(set) var isIdle: Bool = false

    // MARK: Configuration

    /// Seconds before the user is considered idle.
    /// Mirror of `AppSettings.idleThresholdSeconds` (default 300).
    let threshold: TimeInterval

    // MARK: Private

    private let source: any IdleTimeSource
    private let clock: @Sendable () -> Date
    private var pollingTask: Task<Void, Never>?

    // MARK: Init

    /// - Parameters:
    ///   - source: Provides raw idle seconds. Pass `SystemIdleTimeSource()`
    ///     in production; inject a mock in tests.
    ///   - threshold: Seconds after which the user is idle. Matches
    ///     `AppSettings.idleThresholdSeconds`; defaults to 300.
    ///   - clock: Returns the current date. Defaults to `Date.now`. Override
    ///     in tests for deterministic `lastInputDate` calculations.
    init(
        source: any IdleTimeSource,
        threshold: TimeInterval = 300,
        clock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.source = source
        self.threshold = threshold
        self.clock = clock
    }

    // MARK: Derived values

    /// The inferred date of the last user input: `now − idleSeconds`.
    ///
    /// Use this with `idleTruncatedInterval(start:lastInputDate:)` to compute
    /// the end date for a running entry when idle is first detected.
    var lastInputDate: Date {
        clock().addingTimeInterval(-source.idleSeconds)
    }

    // MARK: Polling

    /// Starts a background Task that calls `poll()` every `interval` seconds.
    ///
    /// Safe to call multiple times; cancels any existing polling loop first.
    /// Pair `stopPolling()` / `startPolling()` with NSWorkspace sleep/wake hooks.
    func startPolling(interval: TimeInterval = 5.0) {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Cancels the background polling task.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Samples `source.idleSeconds` once and updates `isIdle`.
    ///
    /// Called automatically by the polling loop; also callable directly in
    /// tests to drive state transitions without real timers.
    func poll() {
        isIdle = source.idleSeconds > threshold
    }
}
