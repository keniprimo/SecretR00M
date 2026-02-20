import Foundation

/// A secure, memory-only ring buffer for diagnostic logging
/// SECURITY: Never persisted to disk, automatically wiped on dealloc
final class SecureLogBuffer {

    // MARK: - Singleton

    static let shared = SecureLogBuffer()

    // MARK: - Types

    enum LogLevel: Int, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3
        case critical = 4

        var prefix: String {
            switch self {
            case .debug: return "[DEBUG]"
            case .info: return "[INFO]"
            case .warning: return "[WARN]"
            case .error: return "[ERROR]"
            case .critical: return "[CRIT]"
            }
        }

        static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct LogEntry {
        let timestamp: Date
        let level: LogLevel
        let category: String
        let message: String
        let context: [String: String]?

        var formatted: String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let ts = formatter.string(from: timestamp)

            var result = "\(ts) \(level.prefix) [\(category)] \(message)"

            if let ctx = context, !ctx.isEmpty {
                let ctxStr = ctx.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                result += " {\(ctxStr)}"
            }

            return result
        }
    }

    // MARK: - Constants

    /// Maximum entries in the ring buffer
    private let maxEntries: Int = 500

    /// Maximum total memory for log buffer (~100KB)
    private let maxMemoryBytes: Int = 100 * 1024

    // MARK: - Properties

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var estimatedBytes: Int = 0

    /// Minimum level to store (filters out lower levels)
    var minimumLevel: LogLevel = .info

    // MARK: - Initialization

    private init() {
        entries.reserveCapacity(maxEntries)

        // SECURITY: Runtime canary — if we detect a release-like environment
        // but logging is somehow still active, disable it silently.
        #if !DEBUG
        // Defense-in-depth: log() already returns early in Release via its own
        // #if !DEBUG guard. But if a build misconfiguration allows that guard
        // to be bypassed, force minimum level to suppress all output.
        minimumLevel = .init(rawValue: Int.max) ?? .critical
        #endif
    }

    deinit {
        wipe()
    }

    // MARK: - Public API

    /// Log a message
    /// - Parameters:
    ///   - level: Log level
    ///   - category: Category/subsystem name
    ///   - message: Log message
    ///   - context: Optional context dictionary
    func log(
        _ level: LogLevel,
        category: String,
        message: String,
        context: [String: String]? = nil
    ) {
        // SECURITY: Compile-time kill switch — in Release builds, all logging
        // compiles to a no-op. This is defense-in-depth: callers don't need
        // #if DEBUG guards because this method itself is dead code in Release.
        #if !DEBUG
        return
        #else
        guard level >= minimumLevel else { return }

        lock.lock()
        defer { lock.unlock() }

        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            context: context
        )

        // Estimate memory usage
        let entryBytes = estimateEntrySize(entry)
        estimatedBytes += entryBytes

        entries.append(entry)

        // Enforce limits
        enforceCapacityLimits()
        #endif
    }

    /// Convenience logging methods
    func debug(_ category: String, _ message: String, context: [String: String]? = nil) {
        log(.debug, category: category, message: message, context: context)
    }

    func info(_ category: String, _ message: String, context: [String: String]? = nil) {
        log(.info, category: category, message: message, context: context)
    }

    func warning(_ category: String, _ message: String, context: [String: String]? = nil) {
        log(.warning, category: category, message: message, context: context)
    }

    func error(_ category: String, _ message: String, context: [String: String]? = nil) {
        log(.error, category: category, message: message, context: context)
    }

    func critical(_ category: String, _ message: String, context: [String: String]? = nil) {
        log(.critical, category: category, message: message, context: context)
    }

    /// Get recent entries
    /// - Parameters:
    ///   - count: Maximum number of entries to return
    ///   - minLevel: Minimum level to include
    /// - Returns: Array of log entries (newest last)
    func getRecentEntries(count: Int = 100, minLevel: LogLevel = .info) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }

        let filtered = entries.filter { $0.level >= minLevel }
        return Array(filtered.suffix(count))
    }

    /// Get formatted log output
    /// - Parameters:
    ///   - count: Maximum number of entries
    ///   - minLevel: Minimum level to include
    /// - Returns: Formatted log string
    func getFormattedLog(count: Int = 100, minLevel: LogLevel = .info) -> String {
        let recent = getRecentEntries(count: count, minLevel: minLevel)
        return recent.map { $0.formatted }.joined(separator: "\n")
    }

    /// Get current buffer statistics
    func getStats() -> (entryCount: Int, estimatedBytes: Int) {
        lock.lock()
        defer { lock.unlock() }

        return (entries.count, estimatedBytes)
    }

    /// Securely wipe all log entries
    func wipe() {
        lock.lock()
        defer { lock.unlock() }

        // Overwrite each entry's memory
        for i in 0..<entries.count {
            // Swift strings are immutable, but we can at least remove references
            entries[i] = LogEntry(
                timestamp: Date(timeIntervalSince1970: 0),
                level: .debug,
                category: "",
                message: "",
                context: nil
            )
        }

        entries.removeAll()
        estimatedBytes = 0
    }

    // MARK: - Private

    private func estimateEntrySize(_ entry: LogEntry) -> Int {
        var size = 64 // Base overhead
        size += entry.category.utf8.count
        size += entry.message.utf8.count

        if let context = entry.context {
            for (key, value) in context {
                size += key.utf8.count + value.utf8.count + 16
            }
        }

        return size
    }

    private func enforceCapacityLimits() {
        // Remove oldest entries until under both limits
        while entries.count > maxEntries || estimatedBytes > maxMemoryBytes {
            guard let oldest = entries.first else { break }
            entries.removeFirst()
            estimatedBytes -= estimateEntrySize(oldest)
        }

        // Ensure non-negative
        if estimatedBytes < 0 {
            estimatedBytes = 0
        }
    }
}

// MARK: - Room-Specific Logging Extension

extension SecureLogBuffer {

    /// Log a room event
    func logRoomEvent(
        _ event: String,
        roomId: String? = nil,
        participantId: String? = nil,
        extra: [String: String]? = nil
    ) {
        var context = extra ?? [:]

        if let roomId = roomId {
            // Only log first 8 chars for privacy
            context["room"] = String(roomId.prefix(8))
        }

        if let participantId = participantId {
            context["participant"] = String(participantId.prefix(8))
        }

        info("Room", event, context: context.isEmpty ? nil : context)
    }

    /// Log a crypto event
    /// SECURITY: No epoch, sequence, or key material is logged — only the event name.
    func logCryptoEvent(_ event: String) {
        debug("Crypto", event)
    }

    /// Log a capacity event
    /// SECURITY: No buffer sizes or queue depths are logged — only the level.
    func logCapacityEvent(_ level: CapacityMonitor.CapacityLevel) {
        let logLevel: LogLevel = level >= .critical ? .warning : .info
        log(logLevel, category: "Capacity", message: "Level: \(level.description)")
    }

    /// Log WebSocket event
    func logWSEvent(_ event: String, error: Error? = nil) {
        if let error = error {
            self.error("WebSocket", event, context: ["error": error.localizedDescription])
        } else {
            debug("WebSocket", event)
        }
    }
}
