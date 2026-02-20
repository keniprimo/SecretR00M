import XCTest
import CryptoKit
@testable import SecretR00M

final class CryptoTests: XCTestCase {

    // MARK: - SecureBytes Tests

    func testSecureBytesWipe() {
        let bytes = SecureBytes(count: 32)
        XCTAssertEqual(bytes.count, 32)

        bytes.wipe()

        XCTAssertTrue(bytes.hasBeenWiped)
        XCTAssertEqual(bytes.count, 0)
    }

    func testSecureBytesEquality() {
        let data1 = Data([1, 2, 3, 4])
        let data2 = Data([1, 2, 3, 4])
        let data3 = Data([1, 2, 3, 5])

        let bytes1 = SecureBytes(data: data1)
        let bytes2 = SecureBytes(data: data2)
        let bytes3 = SecureBytes(data: data3)

        XCTAssertEqual(bytes1, bytes2)
        XCTAssertNotEqual(bytes1, bytes3)
    }

    // MARK: - Key Generation Tests

    func testRoomIdGeneration() throws {
        let roomId = try KeyGeneration.generateRoomId()
        XCTAssertEqual(roomId.count, 32)
    }

    func testRoomIdUniqueness() throws {
        var ids = Set<Data>()
        for _ in 0..<1000 {
            let id = try KeyGeneration.generateRoomId()
            XCTAssertFalse(ids.contains(id), "Room ID collision detected")
            ids.insert(id)
        }
    }

    func testRoomIdStringFormat() throws {
        let roomIdString = try KeyGeneration.generateRoomIdString()
        XCTAssertEqual(roomIdString.count, 43)
        XCTAssertTrue(KeyGeneration.isValidRoomId(roomIdString))
    }

    func testMasterKeyGeneration() throws {
        let key = try KeyGeneration.generateMasterKey()
        XCTAssertEqual(key.count, 32)
    }

    func testKeyPairGeneration() {
        let keyPair = KeyGeneration.generateKeyPair()
        XCTAssertEqual(keyPair.publicKey.rawRepresentation.count, 32)
    }

    // MARK: - Key Exchange Tests

    func testKeyExchangeSymmetry() throws {
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

        // Keys should be identical
        let aliceKeyData = aliceKey.withUnsafeBytes { Data($0) }
        let bobKeyData = bobKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(aliceKeyData, bobKeyData)
    }

    func testMessageKeyDerivationDeterminism() throws {
        let masterKey = try KeyGeneration.generateMasterKey()
        let epoch: UInt32 = 1

        let key1 = KeyExchange.deriveMessageKey(masterKey: masterKey, epoch: epoch)
        let key2 = KeyExchange.deriveMessageKey(masterKey: masterKey, epoch: epoch)

        let key1Data = key1.withUnsafeBytes { Data($0) }
        let key2Data = key2.withUnsafeBytes { Data($0) }
        XCTAssertEqual(key1Data, key2Data)
    }

    func testDifferentEpochsDifferentKeys() throws {
        let masterKey = try KeyGeneration.generateMasterKey()

        let key1 = KeyExchange.deriveMessageKey(masterKey: masterKey, epoch: 1)
        let key2 = KeyExchange.deriveMessageKey(masterKey: masterKey, epoch: 2)

        let key1Data = key1.withUnsafeBytes { Data($0) }
        let key2Data = key2.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(key1Data, key2Data)
    }

    // MARK: - Message Crypto Tests

    func testEncryptDecryptRoundtrip() throws {
        let key = SymmetricKey(size: .bits256)
        let senderId = UUID()
        let plaintext = "Hello, World!".data(using: .utf8)!

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

    func testWrongKeyFailsDecryption() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let plaintext = "Secret".data(using: .utf8)!

        let encrypted = try MessageCrypto.encrypt(
            plaintext: plaintext,
            key: key1,
            senderId: UUID(),
            sequence: 1,
            epoch: 1
        )

        XCTAssertThrowsError(try MessageCrypto.decrypt(frame: encrypted, key: key2))
    }

    func testTamperedCiphertextFailsDecryption() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = "Secret".data(using: .utf8)!

        var encrypted = try MessageCrypto.encrypt(
            plaintext: plaintext,
            key: key,
            senderId: UUID(),
            sequence: 1,
            epoch: 1
        )

        // Tamper with ciphertext
        encrypted[encrypted.count - 10] ^= 0xFF

        XCTAssertThrowsError(try MessageCrypto.decrypt(frame: encrypted, key: key))
    }

    func testNonceUniqueness() {
        let senderId = UUID()
        var nonces = Set<Data>()

        for sequence in 0..<10000 {
            let nonce = MessageCrypto.constructNonce(epoch: 1, senderId: senderId, sequence: UInt64(sequence))
            XCTAssertFalse(nonces.contains(nonce), "Nonce collision at sequence \(sequence)")
            nonces.insert(nonce)
        }
    }

    func testTextMessageEncodeDecode() {
        let text = "Hello, World!"
        let timestamp: UInt64 = 1234567890000

        let encoded = MessageCrypto.encodeTextMessage(text: text, timestamp: timestamp)
        let decoded = MessageCrypto.decodeTextMessage(encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.text, text)
        XCTAssertEqual(decoded?.timestamp, timestamp)
    }

    // MARK: - Nonce Tracker Tests

    func testReplayRejected() {
        let tracker = NonceTracker()
        let nonce = Data(repeating: 0x01, count: 12)
        let senderId = UUID()

        XCTAssertTrue(tracker.validate(nonce: nonce, senderId: senderId, sequence: 1))
        tracker.markUsed(nonce: nonce, senderId: senderId, sequence: 1)
        XCTAssertFalse(tracker.validate(nonce: nonce, senderId: senderId, sequence: 1))
    }

    func testOutOfOrderMessagesAccepted() {
        let tracker = NonceTracker()
        let senderId = UUID()

        func makeNonce(_ seq: UInt64) -> Data {
            var data = Data(repeating: 0, count: 12)
            var seqBE = UInt32(seq).bigEndian
            data.replaceSubrange(8..<12, with: withUnsafeBytes(of: &seqBE) { Data($0) })
            return data
        }

        // Receive out of order
        tracker.markUsed(nonce: makeNonce(5), senderId: senderId, sequence: 5)
        tracker.markUsed(nonce: makeNonce(3), senderId: senderId, sequence: 3)

        // Late message should still be accepted
        XCTAssertTrue(tracker.validate(nonce: makeNonce(4), senderId: senderId, sequence: 4))
    }

    func testTrackerWipe() {
        let tracker = NonceTracker()
        let nonce = Data(repeating: 0x01, count: 12)
        let senderId = UUID()

        tracker.markUsed(nonce: nonce, senderId: senderId, sequence: 1)
        XCTAssertFalse(tracker.validate(nonce: nonce, senderId: senderId, sequence: 1))

        tracker.wipe()

        // After wipe, same nonce should be valid again
        XCTAssertTrue(tracker.validate(nonce: nonce, senderId: senderId, sequence: 1))
    }

    // MARK: - Handshake Tests

    func testFullHandshake() throws {
        // Host setup
        let hostKeyPair = KeyGeneration.generateKeyPair()
        let masterKey = try KeyGeneration.generateMasterKey()
        let roomId = try KeyGeneration.generateRoomId()

        // Client creates join request
        let clientKeyPair = KeyGeneration.generateKeyPair()
        let request = try HandshakeEngine.createJoinRequest(clientKeyPair: clientKeyPair)

        // Host processes and approves
        let (approval, clientId, hostSessionKey) = try HandshakeEngine.processJoinRequest(
            request: request,
            hostPrivateKey: hostKeyPair,
            masterKey: masterKey,
            roomId: roomId,
            currentEpoch: 1
        )

        // Client processes approval
        let (recoveredMasterKey, clientSessionKey, recoveredClientId) = try HandshakeEngine.processJoinApproval(
            approval: approval,
            clientPrivateKey: clientKeyPair,
            roomId: roomId
        )

        // Verify client ID matches
        XCTAssertEqual(recoveredClientId, clientId)

        // Verify master key matches
        let originalKeyData = masterKey.copyToData()
        let recoveredKeyData = recoveredMasterKey.copyToData()
        XCTAssertEqual(originalKeyData, recoveredKeyData)

        // Verify session keys match
        let hostKeyData = hostSessionKey.withUnsafeBytes { Data($0) }
        let clientKeyData = clientSessionKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(hostKeyData, clientKeyData)

        // Test confirmation
        let confirmation = HandshakeEngine.generateConfirmation(
            sessionKey: clientSessionKey,
            clientPublicKey: clientKeyPair.publicKey.rawRepresentation,
            hostPublicKey: hostKeyPair.publicKey.rawRepresentation
        )

        XCTAssertTrue(HandshakeEngine.verifyConfirmation(
            confirmation: confirmation,
            sessionKey: hostSessionKey,
            clientPublicKey: clientKeyPair.publicKey.rawRepresentation,
            hostPublicKey: hostKeyPair.publicKey.rawRepresentation
        ))
    }

    func testRekeyProtocol() throws {
        let oldMasterKey = try KeyGeneration.generateMasterKey()
        let newMasterKey = try KeyGeneration.generateMasterKey()
        let currentEpoch: UInt32 = 1

        // Generate key pairs for host and client
        let hostEphemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKeyPair = Curve25519.KeyAgreement.PrivateKey()
        let roomId = Data((0..<8).map { _ in UInt8.random(in: 0...255) })

        // Create per-client rekey payload
        let rekeyPayload = try HandshakeEngine.createPerClientRekeyPayload(
            oldMasterKey: oldMasterKey,
            newMasterKey: newMasterKey,
            currentEpoch: currentEpoch,
            hostEphemeralPrivateKey: hostEphemeralKey,
            clientPublicKey: clientKeyPair.publicKey,
            roomId: roomId
        )

        XCTAssertEqual(rekeyPayload.newEpoch, currentEpoch + 1)

        // Process rekey payload on client side
        let recoveredKey = try HandshakeEngine.processPerClientRekeyPayload(
            payload: rekeyPayload,
            currentMasterKey: oldMasterKey,
            currentEpoch: currentEpoch,
            clientPrivateKey: clientKeyPair,
            roomId: roomId
        )

        // Verify keys match
        let originalData = newMasterKey.copyToData()
        let recoveredData = recoveredKey.copyToData()
        XCTAssertEqual(originalData, recoveredData)
    }
}
