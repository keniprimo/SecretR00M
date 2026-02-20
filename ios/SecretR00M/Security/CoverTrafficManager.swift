import Foundation
import CryptoKit

/// SECURITY: CoverTrafficManager generates padding messages for traffic analysis resistance.
/// Standard practice in encrypted messaging to prevent metadata-based correlation attacks.
///
/// Padding traffic strategy:
/// - Sends encrypted noise messages at random intervals
/// - Messages are indistinguishable from real messages (same size buckets)
/// - Only the sender knows which messages are real vs padding
/// - Padding messages are silently discarded by recipients
final class CoverTrafficManager {

    // MARK: - Types

    /// Traffic padding mode
    enum Mode {
        case disabled           // No padding traffic
        case low                // Occasional padding (1-3 per minute)
        case medium             // Moderate padding (3-6 per minute)
        case high               // Heavy padding (6-12 per minute)
        case paranoid           // Maximum protection (12-20 per minute)

        var messagesPerMinute: ClosedRange<Double> {
            switch self {
            case .disabled: return 0...0
            case .low: return 1...3
            case .medium: return 3...6
            case .high: return 6...12
            case .paranoid: return 12...20
            }
        }
    }

    /// Padding message marker (first byte of padding plaintext)
    /// SECURITY: This byte is checked after decryption to identify padding
    static let paddingMarker: UInt8 = 0xFF

    // MARK: - Properties

    private var mode: Mode = .disabled
    private var timer: Timer?
    private weak var session: CoverTrafficDelegate?
    private let lock = NSLock()

    /// Statistics
    private(set) var paddingSent: UInt64 = 0
    private(set) var realMessagesSent: UInt64 = 0

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Start generating padding traffic
    /// - Parameters:
    ///   - mode: Padding traffic intensity
    ///   - session: Delegate to send padding messages through
    func start(mode: Mode, session: CoverTrafficDelegate) {
        lock.lock()
        defer { lock.unlock() }

        self.mode = mode
        self.session = session

        guard mode != .disabled else {
            stop()
            return
        }

        scheduleNextPadding()
    }

    /// Stop padding traffic
    func stop() {
        lock.lock()
        defer { lock.unlock() }

        timer?.invalidate()
        timer = nil
        mode = .disabled
    }

    /// Check if a decrypted message is a padding message (noise traffic)
    /// - Parameter plaintext: The decrypted plaintext
    /// - Returns: True if this is a padding message that should be discarded
    static func isPaddingMessage(_ plaintext: Data) -> Bool {
        guard !plaintext.isEmpty else { return false }
        return plaintext[0] == paddingMarker
    }

    /// Generate a padding message payload
    /// - Returns: Random data that matches real message sizes
    func generatePaddingPayload() -> Data {
        // Pick a random size bucket to match real message sizes
        let buckets: [Int] = [256, 1024, 8192]  // Most common sizes for text/small media
        let targetSize = buckets.randomElement() ?? 256

        // Generate random payload with padding marker
        var payload = Data(count: targetSize - 4)  // Leave room for length prefix
        payload[0] = Self.paddingMarker  // Mark as padding

        // Fill rest with random data
        _ = payload.withUnsafeMutableBytes { ptr in
            // Skip first byte (marker), fill rest with random
            if ptr.count > 1 {
                SecRandomCopyBytes(kSecRandomDefault, ptr.count - 1, ptr.baseAddress!.advanced(by: 1))
            }
        }

        return payload
    }

    /// Record that a real message was sent (for ratio tracking)
    func recordRealMessage() {
        lock.lock()
        realMessagesSent += 1
        lock.unlock()
    }

    /// Get traffic padding statistics
    var statistics: (padding: UInt64, real: UInt64, ratio: Double) {
        lock.lock()
        defer { lock.unlock() }

        let total = paddingSent + realMessagesSent
        let ratio = total > 0 ? Double(paddingSent) / Double(total) : 0
        return (paddingSent, realMessagesSent, ratio)
    }

    // MARK: - Private

    private func scheduleNextPadding() {
        guard mode != .disabled, session != nil else { return }

        // Calculate random interval based on mode
        let range = mode.messagesPerMinute
        let messagesPerMinute = Double.random(in: range)

        guard messagesPerMinute > 0 else { return }

        // Convert to interval with some jitter
        let baseInterval = 60.0 / messagesPerMinute
        let jitter = Double.random(in: -0.3...0.3) * baseInterval
        let interval = max(1.0, baseInterval + jitter)

        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.sendPadding()
                self?.scheduleNextPadding()
            }
        }
    }

    private func sendPadding() {
        lock.lock()
        let currentSession = session
        lock.unlock()

        guard let session = currentSession else { return }

        let payload = generatePaddingPayload()

        // Send through session (will be encrypted like a real message)
        session.sendCoverTraffic(payload: payload)

        lock.lock()
        paddingSent += 1
        lock.unlock()
    }
}

// MARK: - Delegate Protocol

/// Protocol for sending padding traffic through a session
protocol CoverTrafficDelegate: AnyObject {
    /// Send padding traffic payload (will be encrypted and transmitted)
    func sendCoverTraffic(payload: Data)
}
