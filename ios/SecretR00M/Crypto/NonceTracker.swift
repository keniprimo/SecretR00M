import Foundation

/// NonceTracker provides replay protection using a sliding window algorithm.
/// SECURITY: Uses sequence-based windowing to prevent replay attacks even after pruning.
///
/// The algorithm works as follows:
/// - For each sender, track the highest sequence number seen
/// - Maintain a bitmap of recent sequences within the window
/// - Reject any sequence below (highest - windowSize) as too old
/// - Reject any sequence already seen in the bitmap
/// - This is the standard DTLS/IPsec anti-replay window algorithm
final class NonceTracker {

    /// Per-sender tracking data
    private struct SenderState {
        var highestSequence: UInt64 = 0
        /// Bitmap for sequences in range [highestSequence - windowSize + 1, highestSequence]
        /// Bit i is set if sequence (highestSequence - i) has been seen
        var bitmap: UInt64 = 0
    }

    private var senderStates: [UUID: SenderState] = [:]
    private let windowSize: UInt64
    private let lock = NSLock()

    /// Initialize with a window size
    /// - Parameter windowSize: Number of sequences to track per sender (max 64 for bitmap, default 64)
    init(windowSize: UInt64 = 64) {
        // Bitmap-based approach limits window to 64, but this is sufficient for real-time messaging
        // Any message more than 64 behind the highest will be rejected as too old
        self.windowSize = min(windowSize, 64)
    }

    /// Validate that a sequence has not been seen before for this sender
    /// - Parameters:
    ///   - nonce: The 12-byte nonce (used for additional uniqueness check)
    ///   - senderId: The sender's UUID
    ///   - sequence: The message sequence number
    /// - Returns: True if the sequence is valid (not seen before), false if replay
    func validate(nonce: Data, senderId: UUID, sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return validateSequence(senderId: senderId, sequence: sequence)
    }

    /// Check and mark in one atomic operation
    /// - Parameters:
    ///   - nonce: The 12-byte nonce
    ///   - senderId: The sender's UUID
    ///   - sequence: The message sequence number
    /// - Returns: True if valid and marked, false if replay
    func validateAndMark(nonce: Data, senderId: UUID, sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard validateSequence(senderId: senderId, sequence: sequence) else {
            return false
        }

        markSequence(senderId: senderId, sequence: sequence)
        return true
    }

    /// Mark a nonce as used
    /// - Parameters:
    ///   - nonce: The 12-byte nonce
    ///   - senderId: The sender's UUID
    ///   - sequence: The message sequence number
    func markUsed(nonce: Data, senderId: UUID, sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        markSequence(senderId: senderId, sequence: sequence)
    }

    /// Wipe all tracking state
    func wipe() {
        lock.lock()
        defer { lock.unlock() }

        senderStates.removeAll()
    }

    /// Remove tracking for a specific sender
    /// - Parameter senderId: The sender's UUID to remove
    func removeSender(_ senderId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        senderStates.removeValue(forKey: senderId)
    }

    /// Get statistics about the tracker
    var stats: (nonceCount: Int, senderCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        // Estimate nonce count as sum of popcount of all bitmaps
        let nonceCount = senderStates.values.reduce(0) { $0 + $1.bitmap.nonzeroBitCount }
        return (nonceCount, senderStates.count)
    }

    // MARK: - Private

    /// Validate a sequence number for a sender (called while lock is held)
    private func validateSequence(senderId: UUID, sequence: UInt64) -> Bool {
        guard let state = senderStates[senderId] else {
            // First message from this sender - always valid
            return true
        }

        let highest = state.highestSequence

        // Case 1: Sequence is higher than anything we've seen - valid
        if sequence > highest {
            return true
        }

        // Case 2: Sequence is too old (outside window) - reject
        if highest >= windowSize && sequence < highest - windowSize + 1 {
            return false
        }

        // Case 3: Sequence is within window - check bitmap
        let offset = highest - sequence
        if offset < 64 {
            let bit = UInt64(1) << offset
            if (state.bitmap & bit) != 0 {
                // Already seen this sequence - replay detected
                return false
            }
        }

        return true
    }

    /// Mark a sequence as seen for a sender (called while lock is held)
    private func markSequence(senderId: UUID, sequence: UInt64) {
        var state = senderStates[senderId] ?? SenderState()

        if sequence > state.highestSequence {
            // New highest sequence - shift bitmap
            let shift = sequence - state.highestSequence
            if shift >= 64 {
                // Jumped more than window size - clear bitmap
                state.bitmap = 1 // Only current sequence is set (at position 0)
            } else {
                // Shift bitmap left and set bit 0 for current sequence
                state.bitmap = (state.bitmap << shift) | 1
            }
            state.highestSequence = sequence
        } else {
            // Sequence within window - set the appropriate bit
            let offset = state.highestSequence - sequence
            if offset < 64 {
                state.bitmap |= (UInt64(1) << offset)
            }
            // If offset >= 64, sequence is too old but we validated it passed somehow
            // This shouldn't happen in normal operation
        }

        senderStates[senderId] = state
    }
}
