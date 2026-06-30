import Foundation
import XCTest
@testable import Timily

final class DiagnosticLoggerTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func expectedLine(_ message: String) -> String {
        "1970-01-01T00:00:00Z INFO app \(message)\n"
    }

    func testWritesExactOneLineFormatAndSanitizesNewlines() async throws {
        let directory = try makeDirectory()
        let logger = DiagnosticLogger(
            directoryURL: directory,
            minimumLevel: .debug,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let written = await logger.log(
            level: .error,
            category: .timer,
            message: "first\r\nsecond\nthird\rfour"
        )

        XCTAssertTrue(written)
        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.log")),
            "1970-01-01T00:00:00Z ERROR timer first  second third four\n"
        )
    }

    func testBelowMinimumLevelIsFilteredWithoutCreatingDirectory() async throws {
        let parent = try makeDirectory()
        let directory = parent.appendingPathComponent("lazy", isDirectory: true)
        let logger = DiagnosticLogger(
            directoryURL: directory,
            minimumLevel: .warning,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let written = await logger.log(level: .info, category: .app, message: "filtered")

        XCTAssertFalse(written)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSequentialAppendsPreserveOrder() async throws {
        let directory = try makeDirectory()
        let logger = DiagnosticLogger(
            directoryURL: directory,
            minimumLevel: .debug,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let firstWritten = await logger.log(level: .info, category: .app, message: "first")
        let secondWritten = await logger.log(level: .info, category: .app, message: "second")
        let thirdWritten = await logger.log(level: .info, category: .app, message: "third")

        XCTAssertTrue(firstWritten)
        XCTAssertTrue(secondWritten)
        XCTAssertTrue(thirdWritten)

        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.log")),
            expectedLine("first") + expectedLine("second") + expectedLine("third")
        )
    }

    func testConcurrentWritesProduceCompleteNonInterleavedRecords() async throws {
        let directory = try makeDirectory()
        let logger = DiagnosticLogger(
            directoryURL: directory,
            minimumLevel: .debug,
            maxFileSize: 1_048_576,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let writeResults = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for identifier in 0..<25 {
                group.addTask {
                    await logger.log(
                        level: .info,
                        category: .activity,
                        message: "concurrent-\(identifier)"
                    )
                }
            }

            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(writeResults.count, 25)
        XCTAssertTrue(writeResults.allSatisfy { $0 })

        let log = try contents(of: directory.appendingPathComponent("timily.log"))
        let records = log.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(records.last, "")

        let completeRecords = records.dropLast().map(String.init)
        let expectedRecords = Set((0..<25).map { identifier in
            "1970-01-01T00:00:00Z INFO activity concurrent-\(identifier)"
        })

        XCTAssertEqual(completeRecords.count, 25)
        XCTAssertEqual(Set(completeRecords), expectedRecords)
    }

    func testRotationKeepsNewestRecordCurrentAndOrdersArchives() async throws {
        let directory = try makeDirectory()
        let lineSize = expectedLine("first").utf8.count
        let logger = DiagnosticLogger(
            directoryURL: directory,
            minimumLevel: .debug,
            maxFileSize: UInt64(lineSize),
            archiveCount: 3,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let firstWritten = await logger.log(level: .info, category: .app, message: "first")
        let secondWritten = await logger.log(level: .info, category: .app, message: "second")
        let thirdWritten = await logger.log(level: .info, category: .app, message: "third")

        XCTAssertTrue(firstWritten)
        XCTAssertTrue(secondWritten)
        XCTAssertTrue(thirdWritten)

        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.log")),
            expectedLine("third")
        )
        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.1.log")),
            expectedLine("second")
        )
        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.2.log")),
            expectedLine("first")
        )
    }

    func testRotationEnforcesArchiveCap() async throws {
        let directory = try makeDirectory()
        let logger = DiagnosticLogger(
            directoryURL: directory,
            minimumLevel: .debug,
            maxFileSize: UInt64(expectedLine("one").utf8.count),
            archiveCount: 2,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        for message in ["one", "two", "three", "four"] {
            let written = await logger.log(level: .info, category: .app, message: message)
            XCTAssertTrue(written)
        }

        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.log")),
            expectedLine("four")
        )
        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.1.log")),
            expectedLine("three")
        )
        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.2.log")),
            expectedLine("two")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("timily.3.log").path
            )
        )
    }

    func testZeroArchiveCountReplacesCurrentFileOnRotation() async throws {
        let directory = try makeDirectory()
        let logger = DiagnosticLogger(
            directoryURL: directory,
            minimumLevel: .debug,
            maxFileSize: UInt64(expectedLine("first").utf8.count),
            archiveCount: 0,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let firstWritten = await logger.log(level: .info, category: .app, message: "first")
        let secondWritten = await logger.log(level: .info, category: .app, message: "second")

        XCTAssertTrue(firstWritten)
        XCTAssertTrue(secondWritten)

        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.log")),
            expectedLine("second")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("timily.1.log").path
            )
        )
    }

    func testOversizedFirstRecordIsWrittenWholeWithoutEmptyArchive() async throws {
        let directory = try makeDirectory()
        let logger = DiagnosticLogger(
            directoryURL: directory,
            minimumLevel: .debug,
            maxFileSize: 1,
            archiveCount: 3,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let written = await logger.log(level: .info, category: .app, message: "whole")

        XCTAssertTrue(written)

        XCTAssertEqual(
            try contents(of: directory.appendingPathComponent("timily.log")),
            expectedLine("whole")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("timily.1.log").path
            )
        )
    }

    func testInvalidDirectoryReturnsFalseWithoutThrowing() async throws {
        let parent = try makeDirectory()
        let invalidDirectory = parent.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: invalidDirectory.path, contents: Data()))
        let logger = DiagnosticLogger(
            directoryURL: invalidDirectory,
            minimumLevel: .debug,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let written = await logger.log(level: .error, category: .persistence, message: "failed")

        XCTAssertFalse(written)
    }
}
