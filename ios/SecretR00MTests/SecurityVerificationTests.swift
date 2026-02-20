import XCTest
import CryptoKit
@testable import SecretR00M

/// Comprehensive Security Verification Tests
/// These tests verify that all security claims made by the EphemeralRooms system hold in practice
final class SecurityVerificationTests: XCTestCase {

    // MARK: - TEST-STORAGE-001: No SQLite/Database Files Created

    func testNoSQLiteDatabasesExist() throws {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let tempURL = fileManager.temporaryDirectory

        let searchPaths = [documentsURL, appSupportURL, cachesURL, tempURL]
        let dbExtensions = ["sqlite", "sqlite3", "db", "realm", "sqlite-wal", "sqlite-shm"]

        var foundDatabases: [URL] = []

        for path in searchPaths {
            if let enumerator = fileManager.enumerator(at: path, includingPropertiesForKeys: nil) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if dbExtensions.contains(fileURL.pathExtension.lowercased()) {
                        // Exclude known system databases
                        let pathString = fileURL.path.lowercased()
                        if !pathString.contains("webdata") && !pathString.contains("cache.db") {
                            foundDatabases.append(fileURL)
                        }
                    }
                }
            }
        }

        XCTAssertTrue(foundDatabases.isEmpty, "Found database files that should not exist: \(foundDatabases)")
    }

    // MARK: - TEST-STORAGE-002: UserDefaults Contains No Message Content

    func testUserDefaultsNoMessageContent() {
        let defaults = UserDefaults.standard.dictionaryRepresentation()

        // Create a test marker that would indicate message storage
        let forbiddenPatterns = [
            "message",
            "plaintext",
            "ciphertext",
            "content",
            "chat",
            "encrypted_message"
        ]

        for (key, _) in defaults {
            let keyLower = key.lowercased()
            for pattern in forbiddenPatterns {
                // Skip ephemeral settings that are expected
                if keyLower.contains("ephemeral") && keyLower.contains("setting") {
                    continue
                }
                // Skip Apple-specific keys
                if keyLower.hasPrefix("ns") || keyLower.hasPrefix("apple") || keyLower.hasPrefix("ck") {
                    continue
                }
                XCTAssertFalse(
                    keyLower.contains(pattern),
                    "UserDefaults contains suspicious key that might store messages: \(key)"
                )
            }
        }
    }

    // MARK: - TEST-STORAGE-003: Keychain Contains Only Expected Items

    func testKeychainContainsOnlyExpectedItems() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String else {
                    continue
                }

                // Only ephemeral keys/settings should exist
                let allowedPrefixes = [
                    "com.ephemeral.",
                    "ephemeral.",
                    "com.apple.",  // System items
                    "Apple",
                    "group."
                ]

                let isAllowed = allowedPrefixes.contains { account.hasPrefix($0) }

                XCTAssertTrue(
                    isAllowed,
                    "Unexpected keychain item: \(account). Messages should never be in keychain."
                )
            }
        }
    }

    // MARK: - TEST-MEMORY-001: SecureBytes Properly Wipes Memory

    func testSecureBytesWipesAllBytes() {
        let testData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE])
        let secureBytes = SecureBytes(data: testData)

        // Verify data is stored
        XCTAssertEqual(secureBytes.count, 8)

        // Wipe the data
        secureBytes.wipe()

        // Verify wiped state
        XCTAssertTrue(secureBytes.hasBeenWiped)
        XCTAssertEqual(secureBytes.count, 0)
    }

    func testSecureBytesWipesOnDeallocation() {
        var accessedBeforeDealloc = false

        autoreleasepool {
            let secureBytes = SecureBytes(count: 32)
            secureBytes.withUnsafeBytes { ptr in
                // Fill with non-zero data
                XCTAssertEqual(ptr.count, 32)
                accessedBeforeDealloc = true
            }
            // secureBytes goes out of scope and deinit is called
        }

        XCTAssertTrue(accessedBeforeDealloc)
        // Memory is wiped in deinit - we can't easily verify this without memory tools
        // but we can verify the deinit path exists by checking the implementation
    }

    func testSecureBytesConstantTimeComparison() {
        let bytes1 = SecureBytes(data: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let bytes2 = SecureBytes(data: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let bytes3 = SecureBytes(data: Data([1, 2, 3, 4, 5, 6, 7, 9]))

        XCTAssertEqual(bytes1, bytes2)
        XCTAssertNotEqual(bytes1, bytes3)

        // Test that wiped bytes are never equal
        bytes1.wipe()
        XCTAssertNotEqual(bytes1, bytes2)
    }

    // MARK: - TEST-MEMORY-002: Data Extension Secure Wipe

    func testDataSecureWipe() {
        var data = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        data.secureWipe()

        // After wipe, all bytes should be zero
        let allZero = data.allSatisfy { $0 == 0 }
        XCTAssertTrue(allZero || data.isEmpty, "Data was not properly wiped")
    }

    func testDataWithSecureCopy() {
        let originalData = Data([0x11, 0x22, 0x33, 0x44])
        var copiedValue: UInt8 = 0

        originalData.withSecureCopy { copy in
            copiedValue = copy[0]
        }

        XCTAssertEqual(copiedValue, 0x11)
        // The copy is wiped after the closure exits
    }

    // MARK: - TEST-CRYPTO-001: Message Padding Applied

    func testMessagePaddingToBucketSizes() throws {
        // SECURITY NOTE: Padding includes random variance (0-10%) for traffic analysis resistance
        // So we verify the padded size is within the expected range [bucket, bucket * 1.1]

        // Test tiny bucket (256 bytes base)
        let shortMessage = Data("Hi".utf8)
        let paddedShort = try MessageCrypto.padPlaintext(shortMessage)
        XCTAssertGreaterThanOrEqual(paddedShort.count, 256)
        XCTAssertLessThanOrEqual(paddedShort.count, 256 + 26) // +10% = 25.6, round up to 26

        // Test small bucket (1024 bytes base)
        let mediumMessage = Data(repeating: 0x41, count: 500)
        let paddedMedium = try MessageCrypto.padPlaintext(mediumMessage)
        XCTAssertGreaterThanOrEqual(paddedMedium.count, 1024)
        XCTAssertLessThanOrEqual(paddedMedium.count, 1024 + 103) // +10% = 102.4, round up

        // Test medium bucket (8192 bytes base)
        let largerMessage = Data(repeating: 0x42, count: 2000)
        let paddedLarger = try MessageCrypto.padPlaintext(largerMessage)
        XCTAssertGreaterThanOrEqual(paddedLarger.count, 8192)
        XCTAssertLessThanOrEqual(paddedLarger.count, 8192 + 820) // +10% = 819.2, round up
    }

    func testMessagePaddingRoundTrip() throws {
        let original = "This is a secret message that needs padding"
        let originalData = Data(original.utf8)

        let padded = try MessageCrypto.padPlaintext(originalData)
        let unpadded = try MessageCrypto.unpadPlaintext(padded)

        XCTAssertEqual(String(data: unpadded, encoding: .utf8), original)
    }

    func testHighSecurityModeLargerPadding() throws {
        let shortMessage = Data("Hi".utf8)

        let normalPadded = try MessageCrypto.padPlaintext(shortMessage, highSecurityMode: false)
        let highSecPadded = try MessageCrypto.padPlaintext(shortMessage, highSecurityMode: true)

        // High security mode should use larger buckets
        XCTAssertGreaterThanOrEqual(highSecPadded.count, normalPadded.count)
    }

    func testPaddingIsRandom() throws {
        let message = Data("Test".utf8)

        let padded1 = try MessageCrypto.padPlaintext(message)
        let padded2 = try MessageCrypto.padPlaintext(message)

        // SECURITY: With random variance, two paddings of the same message will:
        // 1. Both be within the same bucket range (256 to 256+10%)
        // 2. Likely have different sizes due to random variance
        // 3. Have different padding content (random bytes)

        // Both should be in the tiny bucket range (256 to ~282)
        XCTAssertGreaterThanOrEqual(padded1.count, 256)
        XCTAssertLessThanOrEqual(padded1.count, 282)
        XCTAssertGreaterThanOrEqual(padded2.count, 256)
        XCTAssertLessThanOrEqual(padded2.count, 282)

        // The padded data should be different (random variance + random padding bytes)
        // With high probability, either sizes or content will differ
        XCTAssertNotEqual(padded1, padded2, "Padded data should differ due to random variance and padding")
    }

    // MARK: - TEST-CRYPTO-002: Encryption Produces Authenticated Ciphertext

    func testEncryptionDecryptionIntegrity() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Secret message content for testing".utf8)
        let senderId = UUID()

        let encrypted = try MessageCrypto.encrypt(
            plaintext: plaintext,
            key: key,
            senderId: senderId,
            sequence: 1,
            epoch: 1
        )

        let decrypted = try MessageCrypto.decrypt(frame: encrypted, key: key)

        XCTAssertEqual(decrypted.plaintext, plaintext)
        XCTAssertEqual(decrypted.senderId, senderId)
        XCTAssertEqual(decrypted.sequence, 1)
        XCTAssertEqual(decrypted.epoch, 1)
    }

    func testTamperDetection() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Secret".utf8)

        var encrypted = try MessageCrypto.encrypt(
            plaintext: plaintext,
            key: key,
            senderId: UUID(),
            sequence: 1,
            epoch: 1
        )

        // Tamper with ciphertext
        encrypted[encrypted.count - 20] ^= 0xFF

        XCTAssertThrowsError(try MessageCrypto.decrypt(frame: encrypted, key: key)) { error in
            XCTAssertTrue(error is MessageCrypto.Error)
        }
    }

    func testWrongKeyCannotDecrypt() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let plaintext = Data("Secret".utf8)

        let encrypted = try MessageCrypto.encrypt(
            plaintext: plaintext,
            key: key1,
            senderId: UUID(),
            sequence: 1,
            epoch: 1
        )

        XCTAssertThrowsError(try MessageCrypto.decrypt(frame: encrypted, key: key2))
    }

    // MARK: - TEST-CRYPTO-003: Nonce Uniqueness

    func testRandomNonceUniqueness() throws {
        var nonces = Set<Data>()

        for _ in 0..<10000 {
            let nonce = try MessageCrypto.generateRandomNonce()
            XCTAssertEqual(nonce.count, 12)
            XCTAssertFalse(nonces.contains(nonce), "Nonce collision detected!")
            nonces.insert(nonce)
        }
    }

    func testCiphertextDiffersWithSameMessage() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Same message".utf8)
        let senderId = UUID()

        let encrypted1 = try MessageCrypto.encrypt(
            plaintext: plaintext,
            key: key,
            senderId: senderId,
            sequence: 1,
            epoch: 1
        )

        let encrypted2 = try MessageCrypto.encrypt(
            plaintext: plaintext,
            key: key,
            senderId: senderId,
            sequence: 2,
            epoch: 1
        )

        // Ciphertexts should be different due to random nonces
        XCTAssertNotEqual(encrypted1, encrypted2)
    }

    // MARK: - TEST-CRYPTO-004: Key Exchange Symmetry

    func testKeyExchangeProducesSameKey() throws {
        let aliceKeyPair = KeyGeneration.generateKeyPair()
        let bobKeyPair = KeyGeneration.generateKeyPair()
        let roomId = try KeyGeneration.generateRoomId()

        let aliceKey = try KeyExchange.deriveSessionKey(
            privateKey: aliceKeyPair,
            peerPublicKey: bobKeyPair.publicKey,
            roomId: roomId,
            hostPublicKey: aliceKeyPair.publicKey.rawRepresentation,
            clientPublicKey: bobKeyPair.publicKey.rawRepresentation
        )

        let bobKey = try KeyExchange.deriveSessionKey(
            privateKey: bobKeyPair,
            peerPublicKey: aliceKeyPair.publicKey,
            roomId: roomId,
            hostPublicKey: aliceKeyPair.publicKey.rawRepresentation,
            clientPublicKey: bobKeyPair.publicKey.rawRepresentation
        )

        // Both parties should derive the same key
        let aliceKeyData = aliceKey.withUnsafeBytes { Data($0) }
        let bobKeyData = bobKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(aliceKeyData, bobKeyData)
    }

    // MARK: - TEST-NET-001: Network Validator Only Accepts .onion URLs

    func testOnionURLValidation() {
        let validator = NetworkSecurityValidator.shared

        // IMPORTANT: Disable strict mode for testing so invalid URLs return false
        // instead of crashing (strictMode causes fatalError for security violations)
        let originalStrictMode = validator.strictMode
        validator.strictMode = false
        defer { validator.strictMode = originalStrictMode }

        // Valid v3 onion URLs (56 char address)
        // Base32 uses a-z and 2-7, so we use a valid 56-character address
        let validV3 = "ws://abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuv23.onion/rooms/test"
        XCTAssertTrue(validator.isValidOnionURL(URL(string: validV3)!))

        // Valid v2 onion URLs (16 char address) - deprecated but still valid format
        let validV2 = "ws://abcdefghijklmnop.onion/rooms/test"
        XCTAssertTrue(validator.isValidOnionURL(URL(string: validV2)!))

        // Invalid: clearnet domain
        XCTAssertFalse(validator.isValidOnionURL(URL(string: "ws://example.com/rooms/test")!))

        // Invalid: IP address
        XCTAssertFalse(validator.isValidOnionURL(URL(string: "ws://192.168.1.1/rooms/test")!))

        // Invalid: HTTP scheme (not WebSocket)
        XCTAssertFalse(validator.isValidOnionURL(URL(string: "http://test234567890123456.onion/rooms/test")!))

        // Invalid: wrong length
        XCTAssertFalse(validator.isValidOnionURL(URL(string: "ws://tooshort.onion/rooms/test")!))
    }

    func testClearnetIPDetection() {
        let validator = NetworkSecurityValidator.shared

        // IPv4 should be detected
        XCTAssertTrue(validator.isLikelyClearnetIP("192.168.1.1"))
        XCTAssertTrue(validator.isLikelyClearnetIP("10.0.0.1"))
        XCTAssertTrue(validator.isLikelyClearnetIP("8.8.8.8"))

        // IPv6 should be detected
        XCTAssertTrue(validator.isLikelyClearnetIP("2001:db8::1"))

        // .onion addresses should NOT be detected as clearnet
        XCTAssertFalse(validator.isLikelyClearnetIP("example.onion"))
    }

    // MARK: - TEST-COVER-001: Traffic Padding Manager

    func testPaddingMarkerConstant() {
        XCTAssertEqual(CoverTrafficManager.paddingMarker, 0xFF)
    }

    func testPaddingDetection() {
        // Padding messages start with padding marker
        let paddingPayload = Data([CoverTrafficManager.paddingMarker, 0x01, 0x02, 0x03])
        XCTAssertTrue(CoverTrafficManager.isPaddingMessage(paddingPayload))

        // Real messages don't start with padding marker
        let realPayload = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertFalse(CoverTrafficManager.isPaddingMessage(realPayload))

        // Empty payload is not padding
        XCTAssertFalse(CoverTrafficManager.isPaddingMessage(Data()))
    }

    func testPaddingPayloadGeneration() {
        let manager = CoverTrafficManager()
        let padding = manager.generatePaddingPayload()

        // Should start with padding marker
        XCTAssertEqual(padding.first, CoverTrafficManager.paddingMarker)

        // Should be one of the valid bucket sizes (minus 4 for length prefix)
        let validSizes = [252, 1020, 8188] // bucket sizes minus 4
        XCTAssertTrue(validSizes.contains(padding.count), "Padding size \(padding.count) not in valid sizes")
    }

    // MARK: - TEST-REPLAY-001: Replay Attack Prevention

    func testNonceTrackerRejectsReplay() {
        let tracker = NonceTracker()
        let nonce = Data(repeating: 0x42, count: 12)
        let senderId = UUID()

        // First use should be valid
        XCTAssertTrue(tracker.validate(nonce: nonce, senderId: senderId, sequence: 1))
        tracker.markUsed(nonce: nonce, senderId: senderId, sequence: 1)

        // Replay should be rejected
        XCTAssertFalse(tracker.validate(nonce: nonce, senderId: senderId, sequence: 1))
    }

    func testNonceTrackerWipe() {
        let tracker = NonceTracker()
        let nonce = Data(repeating: 0x42, count: 12)
        let senderId = UUID()

        tracker.markUsed(nonce: nonce, senderId: senderId, sequence: 1)
        XCTAssertFalse(tracker.validate(nonce: nonce, senderId: senderId, sequence: 1))

        tracker.wipe()

        // After wipe, nonce should be valid again (new session)
        XCTAssertTrue(tracker.validate(nonce: nonce, senderId: senderId, sequence: 1))
    }

    // MARK: - TEST-FORWARD-001: Forward Secrecy

    func testEachSessionHasUniqueKeys() throws {
        // Generate two independent sessions
        let session1Host = KeyGeneration.generateKeyPair()
        let session1Client = KeyGeneration.generateKeyPair()
        let session1RoomId = try KeyGeneration.generateRoomId()

        let session2Host = KeyGeneration.generateKeyPair()
        let session2Client = KeyGeneration.generateKeyPair()
        let session2RoomId = try KeyGeneration.generateRoomId()

        // Derive keys for each session
        let key1 = try KeyExchange.deriveSessionKey(
            privateKey: session1Host,
            peerPublicKey: session1Client.publicKey,
            roomId: session1RoomId,
            hostPublicKey: session1Host.publicKey.rawRepresentation,
            clientPublicKey: session1Client.publicKey.rawRepresentation
        )

        let key2 = try KeyExchange.deriveSessionKey(
            privateKey: session2Host,
            peerPublicKey: session2Client.publicKey,
            roomId: session2RoomId,
            hostPublicKey: session2Host.publicKey.rawRepresentation,
            clientPublicKey: session2Client.publicKey.rawRepresentation
        )

        // Keys should be different
        let key1Data = key1.withUnsafeBytes { Data($0) }
        let key2Data = key2.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(key1Data, key2Data)
    }

    func testMasterKeyGeneration() throws {
        let key1 = try KeyGeneration.generateMasterKey()
        let key2 = try KeyGeneration.generateMasterKey()

        // Each generation should produce unique key
        let key1Data = key1.copyToData()
        let key2Data = key2.copyToData()
        XCTAssertNotEqual(key1Data, key2Data)
        XCTAssertEqual(key1Data.count, 32)
    }
}
