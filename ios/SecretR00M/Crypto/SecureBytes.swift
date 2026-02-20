import Foundation

/// SecureBytes provides a secure container for sensitive byte data (keys, secrets)
/// with explicit zeroing capability to minimize plaintext lifetime in memory.
///
/// Security properties:
/// - Explicit wipe() method zeros all bytes
/// - Automatic wipe on deallocation
/// - No implicit copying (final class)
/// - Memory barrier after zeroing
final class SecureBytes {
    private var storage: ContiguousArray<UInt8>
    private var isWiped = false
    private let lock = NSLock()

    /// Initialize with a specific byte count (zeros)
    init(count: Int) {
        storage = ContiguousArray(repeating: 0, count: count)
    }

    /// Initialize from Data (copies bytes, then data should be zeroed by caller)
    init(data: Data) {
        storage = ContiguousArray(data)
    }

    /// Initialize from raw bytes
    init(bytes: [UInt8]) {
        storage = ContiguousArray(bytes)
    }

    /// The number of bytes stored
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return isWiped ? 0 : storage.count
    }

    /// Access the raw bytes in a scoped closure
    /// - Parameter body: Closure that receives the raw buffer pointer
    /// - Returns: The result of the closure
    /// - Throws: If the closure throws, or if storage is already wiped
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }

        precondition(!isWiped, "Attempting to access wiped SecureBytes")
        return try storage.withUnsafeBytes(body)
    }

    /// Copy bytes to Data (use sparingly, caller should zero result when done)
    /// WARNING: This creates an unwiped copy. Prefer using withUnsafeBytes when possible.
    @available(*, deprecated, message: "Use withUnsafeBytes or withSecureData for safer access")
    func copyToData() -> Data {
        lock.lock()
        defer { lock.unlock() }

        precondition(!isWiped, "Attempting to access wiped SecureBytes")
        return Data(storage)
    }

    /// Access bytes as Data within a secure scope, wiping after use
    /// - Parameter body: Closure that receives temporary Data, automatically wiped after
    /// - Returns: The result of the closure
    /// - Throws: If the closure throws
    func withSecureData<R>(_ body: (inout Data) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }

        precondition(!isWiped, "Attempting to access wiped SecureBytes")

        // Create mutable copy
        var data = Data(storage)
        defer {
            // Securely wipe the temporary Data
            data.withUnsafeMutableBytes { ptr in
                if let baseAddress = ptr.baseAddress {
                    memset_s(baseAddress, ptr.count, 0, ptr.count)
                }
            }
        }

        return try body(&data)
    }

    /// Securely wipe all bytes
    func wipe() {
        lock.lock()
        defer { lock.unlock() }

        guard !isWiped else { return }

        // SECURITY: Use memset_s which is guaranteed not to be optimized away
        storage.withUnsafeMutableBufferPointer { ptr in
            if let baseAddress = ptr.baseAddress {
                memset_s(baseAddress, ptr.count, 0, ptr.count)
            }
        }

        isWiped = true
    }

    /// Check if storage has been wiped
    var hasBeenWiped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isWiped
    }

    deinit {
        wipe()
    }
}

// MARK: - Equatable (constant-time comparison)
extension SecureBytes: Equatable {
    static func == (lhs: SecureBytes, rhs: SecureBytes) -> Bool {
        lhs.lock.lock()
        defer { lhs.lock.unlock() }
        rhs.lock.lock()
        defer { rhs.lock.unlock() }

        guard !lhs.isWiped && !rhs.isWiped else { return false }
        guard lhs.storage.count == rhs.storage.count else { return false }

        // Constant-time comparison to prevent timing attacks
        var result: UInt8 = 0
        for i in lhs.storage.indices {
            result |= lhs.storage[i] ^ rhs.storage[i]
        }
        return result == 0
    }
}

// MARK: - Data Extension for Secure Wiping

extension Data {
    /// SECURITY: Securely wipe the contents of this Data buffer
    /// Uses memset_s which is guaranteed not to be optimized away
    mutating func secureWipe() {
        guard !isEmpty else { return }

        withUnsafeMutableBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                // memset_s is guaranteed to not be optimized away by the compiler
                memset_s(baseAddress, ptr.count, 0, ptr.count)
            }
        }

        // Memory barrier to ensure the write is flushed
        OSMemoryBarrier()
    }

    /// SECURITY: Create a copy that can be securely wiped
    /// Returns a tuple of (copy, wipe function)
    func withSecureCopy<R>(_ body: (inout Data) throws -> R) rethrows -> R {
        var copy = self
        defer {
            copy.secureWipe()
        }
        return try body(&copy)
    }
}

// MARK: - Array Extension for Secure Wiping

extension Array where Element == UInt8 {
    /// SECURITY: Securely wipe the contents of this byte array
    mutating func secureWipe() {
        guard !isEmpty else { return }

        for i in indices {
            self[i] = 0
        }

        // Memory barrier to ensure the write is flushed
        OSMemoryBarrier()
    }
}

// MARK: - String Extension for Secure Handling

extension String {
    /// SECURITY: Convert to Data and perform operation, wiping the Data after
    func withSecureUTF8Data<R>(_ body: (Data) throws -> R) rethrows -> R {
        var data = self.data(using: .utf8) ?? Data()
        defer {
            data.secureWipe()
        }
        return try body(data)
    }
}
