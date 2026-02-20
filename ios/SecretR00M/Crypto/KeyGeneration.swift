import Foundation
import CryptoKit
import Security

/// KeyGeneration provides secure random key and identifier generation.
/// All randomness comes from the system CSPRNG (SecRandomCopyBytes).
enum KeyGeneration {

    /// Errors that can occur during key generation
    enum Error: Swift.Error {
        case randomGenerationFailed(OSStatus)
    }

    /// Generate a 32-byte room identifier using CSPRNG
    /// - Returns: 32 bytes of cryptographically secure random data
    /// - Throws: If CSPRNG fails
    static func generateRoomId() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            throw Error.randomGenerationFailed(status)
        }

        return Data(bytes)
    }

    /// Generate a 32-byte room identifier as base64url string
    /// - Returns: Base64url encoded room ID (43 characters)
    /// - Throws: If CSPRNG fails
    static func generateRoomIdString() throws -> String {
        let roomId = try generateRoomId()
        return roomId.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generate a 32-byte master key using CSPRNG
    /// - Returns: SecureBytes containing the master key
    /// - Throws: If CSPRNG fails
    static func generateMasterKey() throws -> SecureBytes {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            throw Error.randomGenerationFailed(status)
        }

        let secureKey = SecureBytes(bytes: bytes)

        // Zero the temporary array
        for i in bytes.indices {
            bytes[i] = 0
        }

        return secureKey
    }

    /// Generate an X25519 ephemeral key pair
    /// - Returns: A new Curve25519 private key (public key derivable from it)
    static func generateKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        return Curve25519.KeyAgreement.PrivateKey()
    }

    /// Generate an Ed25519 signing key pair (for optional message signatures)
    /// - Returns: A new Curve25519 signing private key
    static func generateSigningKeyPair() -> Curve25519.Signing.PrivateKey {
        return Curve25519.Signing.PrivateKey()
    }

    /// Generate random bytes
    /// - Parameter count: Number of bytes to generate
    /// - Returns: Data containing random bytes
    /// - Throws: If CSPRNG fails
    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            throw Error.randomGenerationFailed(status)
        }

        return Data(bytes)
    }

    /// Generate a random UUID
    /// - Returns: A cryptographically random UUID
    static func generateUUID() -> UUID {
        return UUID()
    }

    /// Generate a random nonce for AEAD
    /// - Returns: 12 bytes of random data
    /// - Throws: If CSPRNG fails
    static func generateNonce() throws -> Data {
        return try randomBytes(count: 12)
    }
}

// MARK: - Room ID Utilities
extension KeyGeneration {

    /// Parse a base64url room ID string to Data
    /// - Parameter roomIdString: Base64url encoded room ID
    /// - Returns: Decoded room ID data, or nil if invalid
    static func parseRoomId(_ roomIdString: String) -> Data? {
        // Convert base64url to standard base64
        var base64 = roomIdString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64) else {
            return nil
        }

        // Validate length (should be 32 bytes)
        guard data.count == 32 else {
            return nil
        }

        return data
    }

    /// Validate a room ID string format
    /// - Parameter roomIdString: The room ID to validate
    /// - Returns: True if the format is valid (URL-safe characters, 1-64 chars)
    static func isValidRoomId(_ roomIdString: String) -> Bool {
        // Allow custom room IDs: alphanumeric, dash, underscore, 1-64 characters
        let pattern = "^[A-Za-z0-9_-]{1,64}$"
        return roomIdString.range(of: pattern, options: .regularExpression) != nil
    }

    /// Sanitize a custom room ID for URL safety
    /// - Parameter roomId: The custom room ID
    /// - Returns: URL-safe room ID string
    static func sanitizeRoomId(_ roomId: String) -> String {
        // Remove any characters that aren't URL-safe
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var sanitized = roomId
            .components(separatedBy: allowed.inverted)
            .joined(separator: "-")
            .lowercased()

        // Limit to 64 characters
        if sanitized.count > 64 {
            sanitized = String(sanitized.prefix(64))
        }

        // Remove leading/trailing dashes
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // If empty after sanitization, generate random suffix
        if sanitized.isEmpty {
            sanitized = "room-\(UUID().uuidString.prefix(8).lowercased())"
        }

        return sanitized
    }

    /// Create a 32-byte hash of a custom room ID for internal use
    /// - Parameter roomIdString: The room ID string
    /// - Returns: SHA256 hash of the room ID
    static func hashRoomId(_ roomIdString: String) -> Data {
        let hash = SHA256.hash(data: Data(roomIdString.utf8))
        return Data(hash)
    }

    /// Parse a room ID string to Data (supports both custom and base64url formats)
    /// - Parameter roomIdString: Room ID string
    /// - Returns: 32-byte room ID data
    static func parseRoomIdFlexible(_ roomIdString: String) -> Data? {
        #if DEBUG
        print("[DEBUG] parseRoomIdFlexible: input='\(roomIdString)' (len=\(roomIdString.count))")
        #endif

        // First try to parse as base64url (legacy 43-char format)
        if roomIdString.count == 43 {
            if let data = parseRoomId(roomIdString) {
                #if DEBUG
                print("[DEBUG] parseRoomIdFlexible: SUCCESS via parseRoomId, prefix=\(data.prefix(4).map { String(format: "%02x", $0) }.joined())")
                #endif
                return data
            }
            #if DEBUG
            print("[DEBUG] parseRoomIdFlexible: parseRoomId FAILED for 43-char string, falling through to hash")
            #endif
        }

        // Otherwise, hash the custom room ID
        guard isValidRoomId(roomIdString) else {
            #if DEBUG
            print("[DEBUG] parseRoomIdFlexible: isValidRoomId FAILED")
            #endif
            return nil
        }
        let hashed = hashRoomId(roomIdString)
        #if DEBUG
        print("[DEBUG] parseRoomIdFlexible: HASHED the roomId, prefix=\(hashed.prefix(4).map { String(format: "%02x", $0) }.joined())")
        #endif
        return hashed
    }
}
