import Foundation
#if DEBUG
import os.log
#endif

/// Monitors memory and capacity metrics for room stability
/// SECURITY: All data is in-memory only, never persisted
final class CapacityMonitor {

    // MARK: - Singleton

    static let shared = CapacityMonitor()

    // MARK: - Constants

    /// Memory thresholds (in bytes)
    struct Thresholds {
        static let warningLevel: Int = 15 * 1024 * 1024     // 15 MB - yellow warning
        static let criticalLevel: Int = 18 * 1024 * 1024    // 18 MB - red warning
        static let maxLevel: Int = 20 * 1024 * 1024         // 20 MB - must evict
    }

    /// WebSocket queue thresholds (message count)
    struct QueueThresholds {
        static let warningLevel: Int = 50
        static let criticalLevel: Int = 100
        static let maxLevel: Int = 200
    }

    // MARK: - Types

    enum CapacityLevel: Int, Comparable {
        case healthy = 0
        case warning = 1
        case critical = 2
        case exceeded = 3

        var description: String {
            switch self {
            case .healthy: return "Healthy"
            case .warning: return "Warning"
            case .critical: return "Critical"
            case .exceeded: return "Exceeded"
            }
        }

        static func < (lhs: CapacityLevel, rhs: CapacityLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct CapacitySnapshot {
        let messageBufferBytes: Int
        let messageCount: Int
        let wsQueueDepth: Int
        let bufferLevel: CapacityLevel
        let queueLevel: CapacityLevel
        let timestamp: Date

        var overallLevel: CapacityLevel {
            max(bufferLevel, queueLevel)
        }

        var bufferPercentage: Double {
            Double(messageBufferBytes) / Double(Thresholds.maxLevel) * 100
        }

        var queuePercentage: Double {
            Double(wsQueueDepth) / Double(QueueThresholds.maxLevel) * 100
        }
    }

    // MARK: - Delegate

    protocol Delegate: AnyObject {
        func capacityMonitor(_ monitor: CapacityMonitor, didChangeLevel level: CapacityLevel)
        func capacityMonitorDidExceedCapacity(_ monitor: CapacityMonitor)
    }

    // MARK: - Properties

    #if DEBUG
    private let logger = Logger(subsystem: "com.ephemeral.rooms", category: "CapacityMonitor")
    #endif
    private let lock = NSLock()

    /// Current capacity metrics
    private var messageBufferBytes: Int = 0
    private var messageCount: Int = 0
    private var wsQueueDepth: Int = 0

    /// Historical tracking for trends
    private var recentSnapshots: [CapacitySnapshot] = []
    private let maxSnapshotHistory = 60  // Keep last 60 snapshots

    /// Delegate for capacity events
    weak var delegate: Delegate?

    /// Last reported level (to avoid duplicate notifications)
    private var lastReportedLevel: CapacityLevel = .healthy

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Update message buffer metrics
    /// - Parameters:
    ///   - bytes: Current buffer size in bytes
    ///   - count: Number of messages in buffer
    func updateMessageBuffer(bytes: Int, count: Int) {
        lock.lock()
        defer { lock.unlock() }

        messageBufferBytes = bytes
        messageCount = count

        checkAndNotify()
    }

    /// Update WebSocket queue depth
    /// - Parameter depth: Number of pending messages in queue
    func updateWSQueueDepth(_ depth: Int) {
        lock.lock()
        defer { lock.unlock() }

        wsQueueDepth = depth

        checkAndNotify()
    }

    /// Get current capacity snapshot
    /// - Returns: Current capacity state
    func getCurrentSnapshot() -> CapacitySnapshot {
        lock.lock()
        defer { lock.unlock() }

        return createSnapshot()
    }

    /// Check if we should evict messages
    /// - Returns: True if message eviction is needed
    func shouldEvictMessages() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return messageBufferBytes >= Thresholds.maxLevel
    }

    /// Get recommended eviction count
    /// - Returns: Number of messages to evict to return to healthy state
    func recommendedEvictionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard messageCount > 0 else { return 0 }

        // Target: get to warning level (75% of max)
        let targetBytes = Thresholds.warningLevel
        let bytesToFree = max(0, messageBufferBytes - targetBytes)

        // Estimate average message size
        let avgMessageSize = messageBufferBytes / messageCount

        guard avgMessageSize > 0 else { return messageCount / 4 }

        return max(1, bytesToFree / avgMessageSize)
    }

    /// Reset all metrics
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        messageBufferBytes = 0
        messageCount = 0
        wsQueueDepth = 0
        recentSnapshots.removeAll()
        lastReportedLevel = .healthy
    }

    // MARK: - Debug

    /// Get debug summary for overlay
    func debugSummary() -> String {
        let snapshot = getCurrentSnapshot()

        let bufferMB = Double(snapshot.messageBufferBytes) / 1024.0 / 1024.0
        let maxMB = Double(Thresholds.maxLevel) / 1024.0 / 1024.0

        return """
        Buffer: \(String(format: "%.1f", bufferMB))/\(String(format: "%.0f", maxMB))MB (\(snapshot.messageCount) msgs)
        Queue: \(snapshot.wsQueueDepth)/\(QueueThresholds.maxLevel)
        Level: \(snapshot.overallLevel.description)
        """
    }

    // MARK: - Private

    private func createSnapshot() -> CapacitySnapshot {
        CapacitySnapshot(
            messageBufferBytes: messageBufferBytes,
            messageCount: messageCount,
            wsQueueDepth: wsQueueDepth,
            bufferLevel: calculateBufferLevel(),
            queueLevel: calculateQueueLevel(),
            timestamp: Date()
        )
    }

    private func calculateBufferLevel() -> CapacityLevel {
        if messageBufferBytes >= Thresholds.maxLevel {
            return .exceeded
        } else if messageBufferBytes >= Thresholds.criticalLevel {
            return .critical
        } else if messageBufferBytes >= Thresholds.warningLevel {
            return .warning
        }
        return .healthy
    }

    private func calculateQueueLevel() -> CapacityLevel {
        if wsQueueDepth >= QueueThresholds.maxLevel {
            return .exceeded
        } else if wsQueueDepth >= QueueThresholds.criticalLevel {
            return .critical
        } else if wsQueueDepth >= QueueThresholds.warningLevel {
            return .warning
        }
        return .healthy
    }

    private func checkAndNotify() {
        let snapshot = createSnapshot()

        // Store snapshot for history
        recentSnapshots.append(snapshot)
        if recentSnapshots.count > maxSnapshotHistory {
            recentSnapshots.removeFirst()
        }

        // Check if level changed
        let newLevel = snapshot.overallLevel
        if newLevel != lastReportedLevel {
            lastReportedLevel = newLevel

            #if DEBUG
            logger.info("Capacity level changed to: \(newLevel.description)")
            #endif

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.capacityMonitor(self, didChangeLevel: newLevel)

                if newLevel == .exceeded {
                    self.delegate?.capacityMonitorDidExceedCapacity(self)
                }
            }
        }

        // Log if critical or worse
        if newLevel >= .critical {
            #if DEBUG
            logger.warning("Capacity critical - buffer: \(self.messageBufferBytes) bytes, queue: \(self.wsQueueDepth)")
            #endif
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let capacityLevelDidChange = Notification.Name("com.ephemeral.rooms.capacityLevelDidChange")
    static let capacityDidExceed = Notification.Name("com.ephemeral.rooms.capacityDidExceed")
}
