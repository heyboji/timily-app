import Foundation

// MARK: - DiagnosticLogLevel

/// Severity of a diagnostic log record, ordered from least to most severe.
nonisolated public enum DiagnosticLogLevel: Int, Comparable, Sendable {
    case debug
    case info
    case warning
    case error

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    fileprivate var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARNING"
        case .error: "ERROR"
        }
    }
}

// MARK: - DiagnosticLogCategory

/// Subsystem that produced a diagnostic log record.
nonisolated public enum DiagnosticLogCategory: String, Sendable {
    case app
    case persistence
    case timer
    case activity
    case backup
}

// MARK: - DiagnosticLogger

/// Writes bounded, one-line diagnostic records to a local UTF-8 text file.
///
/// Log messages must contain only non-sensitive diagnostic facts. Never pass
/// URLs, document paths, task descriptions, or project names. The logger does
/// not attempt heuristic redaction, so callers are responsible for privacy.
public actor DiagnosticLogger {

    /// Production logger at Application Support/Timily/Logs/timily.log.
    public static let shared: DiagnosticLogger = {
        let fileManager = FileManager.default
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return DiagnosticLogger(
            directoryURL: applicationSupport
                .appendingPathComponent("Timily/Logs", isDirectory: true),
            minimumLevel: .debug
        )
    }()

    private let directoryURL: URL
    private let minimumLevel: DiagnosticLogLevel
    private let maxFileSize: UInt64
    private let archiveCount: Int
    private let clock: @Sendable () -> Date
    private let timestampFormatter: ISO8601DateFormatter

    public init(
        directoryURL: URL,
        minimumLevel: DiagnosticLogLevel,
        maxFileSize: UInt64 = 1_048_576,
        archiveCount: Int = 3,
        clock: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.directoryURL = directoryURL
        self.minimumLevel = minimumLevel
        self.maxFileSize = maxFileSize
        self.archiveCount = max(0, archiveCount)
        self.clock = clock

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.timestampFormatter = formatter
    }

    /// Appends one diagnostic record when its level meets `minimumLevel`.
    ///
    /// - Important: Do not include URLs, document paths, task descriptions, or
    ///   project names in `message`. No content redaction is performed.
    /// - Returns: `true` when the record was written; `false` when filtered or
    ///   when any filesystem operation failed. Filesystem errors never escape.
    @discardableResult
    public func log(
        level: DiagnosticLogLevel,
        category: DiagnosticLogCategory,
        message: String
    ) async -> Bool {
        guard level >= minimumLevel else { return false }

        let timestamp = timestampFormatter.string(from: clock())
        let safeCategory = Self.singleLine(category.rawValue)
        let safeMessage = Self.singleLine(message)
        let line = "\(timestamp) \(level.label) \(safeCategory) \(safeMessage)\n"

        guard let data = line.data(using: .utf8) else { return false }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let fileURL = directoryURL.appendingPathComponent("timily.log")
            let currentSize = try Self.fileSize(at: fileURL)

            if currentSize > 0 && currentSize + UInt64(data.count) > maxFileSize {
                try rotate(currentURL: fileURL)
            }

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    return false
                }
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func rotate(currentURL: URL) throws {
        let fileManager = FileManager.default

        guard archiveCount > 0 else {
            try fileManager.removeItem(at: currentURL)
            return
        }

        let oldestURL = archiveURL(number: archiveCount)
        if fileManager.fileExists(atPath: oldestURL.path) {
            try fileManager.removeItem(at: oldestURL)
        }

        if archiveCount > 1 {
            for number in stride(from: archiveCount - 1, through: 1, by: -1) {
                let sourceURL = archiveURL(number: number)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                try fileManager.moveItem(at: sourceURL, to: archiveURL(number: number + 1))
            }
        }

        try fileManager.moveItem(at: currentURL, to: archiveURL(number: 1))
    }

    private func archiveURL(number: Int) -> URL {
        directoryURL.appendingPathComponent("timily.\(number).log")
    }

    private static func fileSize(at url: URL) throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
