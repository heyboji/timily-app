import XCTest
@testable import Timily

// MARK: - Mock

/// Reference-type mock that lets tests mutate `idleSeconds` between `poll()` calls.
///
/// `@unchecked Sendable` is safe here because all mutation happens on
/// `@MainActor` within these test methods.
private final class MockIdleTimeSource: IdleTimeSource, @unchecked Sendable {
    nonisolated(unsafe) var idleSeconds: TimeInterval
    init(_ seconds: TimeInterval = 0) { idleSeconds = seconds }
}

// MARK: - IdleDetectorTests

final class IdleDetectorTests: XCTestCase {

    // MARK: IdleDetector.poll() — threshold transitions

    @MainActor
    func testBelowThresholdIsNotIdle() throws {
        let source = MockIdleTimeSource(60)
        let detector = IdleDetector(source: source, threshold: 300)
        detector.poll()
        XCTAssertFalse(detector.isIdle)
    }

    @MainActor
    func testAboveThresholdIsIdle() throws {
        let source = MockIdleTimeSource(301)
        let detector = IdleDetector(source: source, threshold: 300)
        detector.poll()
        XCTAssertTrue(detector.isIdle)
    }

    @MainActor
    func testExactlyAtThresholdIsNotIdle() throws {
        // Boundary condition: strictly greater-than, not equal.
        let source = MockIdleTimeSource(300)
        let detector = IdleDetector(source: source, threshold: 300)
        detector.poll()
        XCTAssertFalse(detector.isIdle)
    }

    @MainActor
    func testTransitionsFromIdleToActive() throws {
        let source = MockIdleTimeSource(400)
        let detector = IdleDetector(source: source, threshold: 300)

        detector.poll()
        XCTAssertTrue(detector.isIdle, "should be idle at 400s")

        source.idleSeconds = 0
        detector.poll()
        XCTAssertFalse(detector.isIdle, "should be active at 0s")
    }

    @MainActor
    func testTransitionsFromActiveToIdle() throws {
        let source = MockIdleTimeSource(0)
        let detector = IdleDetector(source: source, threshold: 300)

        detector.poll()
        XCTAssertFalse(detector.isIdle)

        source.idleSeconds = 500
        detector.poll()
        XCTAssertTrue(detector.isIdle)
    }

    // MARK: IdleDetector.lastInputDate

    @MainActor
    func testLastInputDateIsNowMinusIdleSeconds() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let source = MockIdleTimeSource(120)
        let detector = IdleDetector(
            source: source,
            threshold: 300,
            clock: { fixedNow }
        )
        XCTAssertEqual(detector.lastInputDate, fixedNow.addingTimeInterval(-120))
    }

    @MainActor
    func testLastInputDateReflectsChangedIdleSeconds() throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000)
        let source = MockIdleTimeSource(60)
        let detector = IdleDetector(source: source, threshold: 300, clock: { fixedNow })

        XCTAssertEqual(detector.lastInputDate, fixedNow.addingTimeInterval(-60))

        source.idleSeconds = 300
        XCTAssertEqual(detector.lastInputDate, fixedNow.addingTimeInterval(-300))
    }

    // MARK: idleTruncatedInterval — pure function

    func testTruncatedIntervalUsesLastInputDate() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let lastInput = Date(timeIntervalSince1970: 1_200)
        let range = idleTruncatedInterval(start: start, lastInputDate: lastInput)
        XCTAssertEqual(range.start, start)
        XCTAssertEqual(range.end, lastInput)
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 200)
    }

    func testTruncatedIntervalClampsWhenLastInputBeforeStart() throws {
        // Degenerate: idle was detected before the entry even started.
        let start = Date(timeIntervalSince1970: 1_000)
        let lastInput = Date(timeIntervalSince1970: 800) // before start
        let range = idleTruncatedInterval(start: start, lastInputDate: lastInput)
        XCTAssertEqual(range.start, start)
        XCTAssertEqual(range.end, start, "should clamp to start, not go before it")
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 0)
    }

    func testTruncatedIntervalAtExactBoundary() throws {
        let start = Date(timeIntervalSince1970: 500)
        let range = idleTruncatedInterval(start: start, lastInputDate: start)
        XCTAssertEqual(range.start, start)
        XCTAssertEqual(range.end, start)
    }

    // MARK: resolveIdleEntry(.exclude)

    func testExcludePolicyEndsAtIdleStart() throws {
        let entryStart = Date(timeIntervalSince1970: 0)
        let idleStart = Date(timeIntervalSince1970: 500)
        let returnDate = Date(timeIntervalSince1970: 900)

        let result = resolveIdleEntry(
            entryStart: entryStart,
            idleStart: idleStart,
            returnDate: returnDate,
            policy: .exclude
        )
        XCTAssertEqual(result.start, entryStart)
        XCTAssertEqual(result.end, idleStart)
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 500)
    }

    // MARK: resolveIdleEntry(.keep)

    func testKeepPolicyEndsAtReturnDate() throws {
        let entryStart = Date(timeIntervalSince1970: 0)
        let idleStart = Date(timeIntervalSince1970: 500)
        let returnDate = Date(timeIntervalSince1970: 900)

        let result = resolveIdleEntry(
            entryStart: entryStart,
            idleStart: idleStart,
            returnDate: returnDate,
            policy: .keep
        )
        XCTAssertEqual(result.start, entryStart)
        XCTAssertEqual(result.end, returnDate)
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 900)
    }

    func testKeepPolicyClampsClockSkewBeforeEntryStart() {
        let entryStart = Date(timeIntervalSince1970: 500)
        let result = resolveIdleEntry(
            entryStart: entryStart,
            idleStart: Date(timeIntervalSince1970: 400),
            returnDate: Date(timeIntervalSince1970: 300),
            policy: .keep
        )
        XCTAssertEqual(result.start, entryStart)
        XCTAssertEqual(result.end, entryStart)
    }

    // MARK: resolveIdleEntry(.editBoundary)

    func testEditBoundaryUsesCallerDate() throws {
        let entryStart = Date(timeIntervalSince1970: 0)
        let idleStart = Date(timeIntervalSince1970: 500)
        let returnDate = Date(timeIntervalSince1970: 900)
        let boundary = Date(timeIntervalSince1970: 700)

        let result = resolveIdleEntry(
            entryStart: entryStart,
            idleStart: idleStart,
            returnDate: returnDate,
            policy: .editBoundary(boundary)
        )
        XCTAssertEqual(result.start, entryStart)
        XCTAssertEqual(result.end, boundary)
    }

    func testEditBoundaryClampsAboveReturnDate() throws {
        let entryStart = Date(timeIntervalSince1970: 0)
        let idleStart = Date(timeIntervalSince1970: 500)
        let returnDate = Date(timeIntervalSince1970: 900)
        let boundary = Date(timeIntervalSince1970: 1_200) // after returnDate

        let result = resolveIdleEntry(
            entryStart: entryStart,
            idleStart: idleStart,
            returnDate: returnDate,
            policy: .editBoundary(boundary)
        )
        XCTAssertEqual(result.end, returnDate, "should clamp to returnDate")
    }

    func testEditBoundaryClampsBeforeEntryStart() throws {
        let entryStart = Date(timeIntervalSince1970: 500)
        let idleStart = Date(timeIntervalSince1970: 600)
        let returnDate = Date(timeIntervalSince1970: 900)
        let boundary = Date(timeIntervalSince1970: 100) // before entryStart

        let result = resolveIdleEntry(
            entryStart: entryStart,
            idleStart: idleStart,
            returnDate: returnDate,
            policy: .editBoundary(boundary)
        )
        XCTAssertEqual(result.end, entryStart, "should clamp to entryStart")
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 0)
    }

    func testEditBoundaryAtIdleStartMatchesExclude() throws {
        // editBoundary(idleStart) ≡ .exclude
        let entryStart = Date(timeIntervalSince1970: 0)
        let idleStart = Date(timeIntervalSince1970: 500)
        let returnDate = Date(timeIntervalSince1970: 900)

        let editResult = resolveIdleEntry(
            entryStart: entryStart, idleStart: idleStart, returnDate: returnDate,
            policy: .editBoundary(idleStart)
        )
        let excludeResult = resolveIdleEntry(
            entryStart: entryStart, idleStart: idleStart, returnDate: returnDate,
            policy: .exclude
        )
        XCTAssertEqual(editResult, excludeResult)
    }

    func testEditBoundaryAtReturnDateMatchesKeep() throws {
        // editBoundary(returnDate) ≡ .keep
        let entryStart = Date(timeIntervalSince1970: 0)
        let idleStart = Date(timeIntervalSince1970: 500)
        let returnDate = Date(timeIntervalSince1970: 900)

        let editResult = resolveIdleEntry(
            entryStart: entryStart, idleStart: idleStart, returnDate: returnDate,
            policy: .editBoundary(returnDate)
        )
        let keepResult = resolveIdleEntry(
            entryStart: entryStart, idleStart: idleStart, returnDate: returnDate,
            policy: .keep
        )
        XCTAssertEqual(editResult, keepResult)
    }
}
