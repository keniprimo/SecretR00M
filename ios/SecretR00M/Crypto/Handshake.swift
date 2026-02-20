import Foundation
import CryptoKit

// MARK: - Handshake Messages

/// Join request sent by client to host
struct JoinRequest: Codable {
    let clientPublicKey: Data    // 32 bytes, X25519 public key
    let joinNonce: Data          // 16 bytes, replay protection
    let timestamp: UInt64        // Unix millis
    let displayName: String?     // Optional display name
}

/// Join approval sent by host to client
struct JoinApproval: Codable {
    let clientId: String         // Assigned client ID (UUID string)
    let encryptedMasterKey: Data // ChaCha20-Poly1305 encrypted master key + tag
    let nonce: Data              // 12 bytes
    let epoch: UInt32            // Current key epoch
    let hostPublicKey: Data      // 32 bytes
}

/// Join rejection sent by host to client
struct JoinRejection: Codable {
    let reason: String
}

/// Join confirmation sent by client to host
struct JoinConfirmation: Codable {
    let proof: Data              // HMAC proof of key possession
}

// MARK: - Handshake Errors

enum HandshakeError: Error {
    case timestampOutOfRange
    case invalidPublicKey
    case invalidApproval
    case decryptionFailed
    case invalidProof
    case invalidNonce
}

// MARK: - Handshake Engine

/// HandshakeEngine implements the secure join protocol
enum HandshakeEngine {

    /// Maximum timestamp skew allowed (60 seconds)
    /// SECURITY: Must be long enough for manual host approval flow (user tapping "Approve")
    /// but short enough to prevent replay attacks. 60s is a reasonable balance.
    static let maxTimestampSkew: UInt64 = 60_000

    // MARK: - Host Operations

    /// Create a join request (client side)
    /// - Parameters:
    ///   - clientKeyPair: Client's ephemeral X25519 key pair
    ///   - displayName: Optional display name
    /// - Returns: The join request
    static func createJoinRequest(
        clientKeyPair: Curve25519.KeyAgreement.PrivateKey,
        displayName: String? = nil
    ) throws -> JoinRequest {
        let joinNonce = try KeyGeneration.randomBytes(count: 16)
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        return JoinRequest(
            clientPublicKey: clientKeyPair.publicKey.rawRepresentation,
            joinNonce: joinNonce,
            timestamp: timestamp,
            displayName: displayName
        )
    }

    /// Process a join request and generate approval (host side)
    /// - Parameters:
    ///   - request: The join request from the client
    ///   - hostPrivateKey: Host's ephemeral X25519 private key
    ///   - masterKey: Room master key
    ///   - roomId: Room identifier
    ///   - currentEpoch: Current key epoch
    /// - Returns: Tuple of (approval message, assigned client UUID, session key)
    static func processJoinRequest(
        request: JoinRequest,
        hostPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        masterKey: SecureBytes,
        roomId: Data,
        currentEpoch: UInt32
    ) throws -> (approval: JoinApproval, clientId: UUID, sessionKey: SymmetricKey) {
        // Validate timestamp
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let timeDiff = now > request.timestamp ? now - request.timestamp : request.timestamp - now
        guard timeDiff < maxTimestampSkew else {
            throw HandshakeError.timestampOutOfRange
        }

        // Parse client public key
        let clientPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            clientPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.clientPublicKey)
        } catch {
            throw HandshakeError.invalidPublicKey
        }

        // Derive session key
        let hostPublicKeyData = hostPrivateKey.publicKey.rawRepresentation
        #if DEBUG
        print("[DEBUG] HOST processJoinRequest: roomIdPrefix=\(roomId.prefix(4).map { String(format: "%02x", $0) }.joined()), hostPubPrefix=\(hostPublicKeyData.prefix(4).map { String(format: "%02x", $0) }.joined()), clientPubPrefix=\(request.clientPublicKey.prefix(4).map { String(format: "%02x", $0) }.joined())")
        #endif
        let sessionKey = try KeyExchange.deriveSessionKey(
            privateKey: hostPrivateKey,
            peerPublicKey: clientPublicKey,
            roomId: roomId,
            hostPublicKey: hostPublicKeyData,
            clientPublicKey: request.clientPublicKey
        )
        #if DEBUG
        sessionKey.withUnsafeBytes { ptr in
            let sessionKeyPrefix = Data(ptr).prefix(4).map { String(format: "%02x", $0) }.joined()
            print("[DEBUG] HOST sessionKey prefix: \(sessionKeyPrefix)")
        }
        #endif

        // Generate nonce for encrypting master key
        let nonce = try KeyGeneration.generateNonce()

        // Build transcript for AAD
        let transcript = hostPublicKeyData + request.clientPublicKey + roomId

        // Encrypt master key using secure scoped access
        #if DEBUG
        masterKey.withUnsafeBytes { ptr in
            let masterKeyPrefix = Data(ptr).prefix(4).map { String(format: "%02x", $0) }.joined()
            print("[DEBUG] HOST encrypting masterKey with prefix: \(masterKeyPrefix)")
        }
        #endif
        let sealedBox = try masterKey.withSecureData { masterKeyData in
            try ChaChaPoly.seal(
                masterKeyData,
                using: sessionKey,
                nonce: ChaChaPoly.Nonce(data: nonce),
                authenticating: transcript
            )
        }

        let encryptedMasterKey = sealedBox.ciphertext + sealedBox.tag

        let clientId = UUID()

        let approval = JoinApproval(
            clientId: clientId.uuidString,
            encryptedMasterKey: encryptedMasterKey,
            nonce: nonce,
            epoch: currentEpoch,
            hostPublicKey: hostPublicKeyData
        )

        return (approval, clientId, sessionKey)
    }

    // MARK: - Client Operations

    /// Process a join approval and extract the master key (client side)
    /// - Parameters:
    ///   - approval: The approval from the host
    ///   - clientPrivateKey: Client's ephemeral X25519 private key
    ///   - roomId: Room identifier
    /// - Returns: Tuple of (master key, session key, assigned client ID)
    static func processJoinApproval(
        approval: JoinApproval,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        roomId: Data
    ) throws -> (masterKey: SecureBytes, sessionKey: SymmetricKey, clientId: UUID) {
        // Parse host public key
        let hostPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            hostPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: approval.hostPublicKey)
        } catch {
            throw HandshakeError.invalidPublicKey
        }

        // Parse client ID
        guard let clientId = UUID(uuidString: approval.clientId) else {
            throw HandshakeError.invalidApproval
        }

        // Derive session key
        let clientPublicKeyData = clientPrivateKey.publicKey.rawRepresentation
        #if DEBUG
        print("[DEBUG] CLIENT processJoinApproval: roomIdPrefix=\(roomId.prefix(4).map { String(format: "%02x", $0) }.joined()), hostPubPrefix=\(approval.hostPublicKey.prefix(4).map { String(format: "%02x", $0) }.joined()), clientPubPrefix=\(clientPublicKeyData.prefix(4).map { String(format: "%02x", $0) }.joined())")
        #endif
        let sessionKey = try KeyExchange.deriveSessionKey(
            privateKey: clientPrivateKey,
            peerPublicKey: hostPublicKey,
            roomId: roomId,
            hostPublicKey: approval.hostPublicKey,
            clientPublicKey: clientPublicKeyData
        )
        #if DEBUG
        sessionKey.withUnsafeBytes { ptr in
            let sessionKeyPrefix = Data(ptr).prefix(4).map { String(format: "%02x", $0) }.joined()
            print("[DEBUG] CLIENT sessionKey prefix: \(sessionKeyPrefix)")
        }
        #endif

        // Build transcript for AAD
        let transcript = approval.hostPublicKey + clientPublicKeyData + roomId

        // Validate encrypted master key length
        guard approval.encryptedMasterKey.count >= 16 else {
            throw HandshakeError.invalidApproval
        }

        let ciphertext = approval.encryptedMasterKey.dropLast(16)
        let tag = approval.encryptedMasterKey.suffix(16)

        // Decrypt master key
        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: approval.nonce),
                ciphertext: ciphertext,
                tag: tag
            )
        } catch {
            throw HandshakeError.invalidNonce
        }

        let masterKeyData: Data
        do {
            masterKeyData = try ChaChaPoly.open(sealedBox, using: sessionKey, authenticating: transcript)
        } catch {
            #if DEBUG
            print("[DEBUG] CLIENT ChaChaPoly.open FAILED: \(error)")
            #endif
            throw HandshakeError.decryptionFailed
        }

        #if DEBUG
        let masterKeyPrefix = masterKeyData.prefix(4).map { String(format: "%02x", $0) }.joined()
        print("[DEBUG] CLIENT decrypted masterKey with prefix: \(masterKeyPrefix)")
        #endif

        let masterKey = SecureBytes(data: masterKeyData)

        return (masterKey, sessionKey, clientId)
    }

    // MARK: - Confirmation

    /// Generate a confirmation proof (client side)
    /// - Parameters:
    ///   - sessionKey: The derived session key
    ///   - clientPublicKey: Client's public key
    ///   - hostPublicKey: Host's public key
    /// - Returns: The confirmation message
    static func generateConfirmation(
        sessionKey: SymmetricKey,
        clientPublicKey: Data,
        hostPublicKey: Data
    ) -> JoinConfirmation {
        let message = "join-confirm-v1".data(using: .utf8)! + clientPublicKey + hostPublicKey
        let proof = HMAC<SHA256>.authenticationCode(for: message, using: sessionKey)
        return JoinConfirmation(proof: Data(proof))
    }

    /// Verify a confirmation proof (host side)
    /// - Parameters:
    ///   - confirmation: The confirmation from the client
    ///   - sessionKey: The derived session key
    ///   - clientPublicKey: Client's public key
    ///   - hostPublicKey: Host's public key
    /// - Returns: True if the proof is valid
    static func verifyConfirmation(
        confirmation: JoinConfirmation,
        sessionKey: SymmetricKey,
        clientPublicKey: Data,
        hostPublicKey: Data
    ) -> Bool {
        let message = "join-confirm-v1".data(using: .utf8)! + clientPublicKey + hostPublicKey
        return HMAC<SHA256>.isValidAuthenticationCode(
            confirmation.proof,
            authenticating: message,
            using: sessionKey
        )
    }
}

// MARK: - Rekey Messages (v3 — per-client DH, encrypted end-to-end)

/// Per-client rekey payload sent as encrypted binary via DIRECT message.
/// SECURITY: The relay sees only opaque base64 data — no epoch, reason, or public keys leak.
/// Each client receives a uniquely wrapped copy of the new master key.
struct PerClientRekeyPayload: Codable {
    let newEpoch: UInt32
    let wrappedKey: Data            // New master key encrypted with DH-derived rekey key
    let nonce: Data                 // 12 bytes
    let hostEphemeralPublicKey: Data // 32 bytes — fresh per-rekey host ephemeral
    let clientEphemeralPublicKey: Data // 32 bytes — client's latest ephemeral (echo for binding)
    let confirmNonce: Data          // 16 bytes — random nonce for HMAC binding (client must echo)
}

/// Rekey confirmation from client — includes the client's fresh ephemeral public key
/// for the next rekey round. SECURITY: HMAC-authenticated to prevent relay forgery.
struct RekeyConfirmation: Codable {
    let epoch: UInt32
    let newPublicKey: Data          // 32 bytes — client's fresh ephemeral for next rekey
    let confirmNonce: Data          // 16 bytes — echoed from PerClientRekeyPayload
    let mac: Data                   // 32 bytes — HMAC-SHA256(confirmKey, epoch||newPublicKey||confirmNonce||hostEphemeralPub||roomId)
}

/// Legacy RekeyMessage retained only for type compatibility in MessageTransport.
/// SECURITY: No longer produced. The broadcast rekey path is fully removed.
struct RekeyMessage: Codable {
    let newEpoch: UInt32
    let wrappedKey: Data
    let nonce: Data
    let reason: String
    let ephemeralPublicKey: Data
}

// MARK: - Rekey Operations (v3 — per-client DH only)

extension HandshakeEngine {

    /// Create a per-client rekey payload using fresh DH (host side).
    ///
    /// SECURITY — Forward secrecy guarantee:
    ///   - Host generates a fresh X25519 ephemeral per rekey.
    ///   - Wrapping key = HKDF(DH(hostEphemeral, clientCurrentPublic), context).
    ///   - Compromise of old master key does NOT reveal wrapping key because
    ///     the attacker does not know the host ephemeral private key.
    ///   - Old master key hash is mixed into context for key continuity.
    ///
    /// - Parameters:
    ///   - oldMasterKey: Current master key (mixed into HKDF context)
    ///   - newMasterKey: New master key to deliver
    ///   - currentEpoch: Current epoch (new epoch = currentEpoch + 1)
    ///   - hostEphemeralPrivateKey: Fresh X25519 private key for this rekey
    ///   - clientPublicKey: Client's current ephemeral public key
    ///   - roomId: Room identifier for context binding
    /// - Returns: Encrypted per-client rekey payload
    static func createPerClientRekeyPayload(
        oldMasterKey: SecureBytes,
        newMasterKey: SecureBytes,
        currentEpoch: UInt32,
        hostEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        clientPublicKey: Curve25519.KeyAgreement.PublicKey,
        roomId: Data
    ) throws -> PerClientRekeyPayload {
        let newEpoch = currentEpoch + 1

        // Derive per-client wrapping key via DH
        let rekeyKey = try KeyExchange.deriveRekeyKeyDH(
            oldMasterKey: oldMasterKey,
            ephemeralPrivateKey: hostEphemeralPrivateKey,
            peerPublicKey: clientPublicKey,
            roomId: roomId,
            epoch: newEpoch
        )

        // Generate nonce
        let nonce = try KeyGeneration.generateNonce()

        // Build AAD: epoch || roomId || hostEphemeralPub || clientPub
        var aad = Data()
        var epochBE = newEpoch.bigEndian
        aad.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })
        aad.append(roomId)
        aad.append(hostEphemeralPrivateKey.publicKey.rawRepresentation)
        aad.append(clientPublicKey.rawRepresentation)

        // Encrypt new master key with AAD binding
        let sealedBox = try newMasterKey.withSecureData { newKeyData in
            try ChaChaPoly.seal(
                newKeyData,
                using: rekeyKey,
                nonce: ChaChaPoly.Nonce(data: nonce),
                authenticating: aad
            )
        }

        let wrappedKey = sealedBox.ciphertext + sealedBox.tag

        // SECURITY: Generate random confirmNonce for HMAC binding.
        // Client must echo this nonce in the RekeyConfirmation to prove it
        // received the genuine payload (relay cannot forge this).
        let confirmNonce = try KeyGeneration.randomBytes(count: 16)

        return PerClientRekeyPayload(
            newEpoch: newEpoch,
            wrappedKey: wrappedKey,
            nonce: nonce,
            hostEphemeralPublicKey: hostEphemeralPrivateKey.publicKey.rawRepresentation,
            clientEphemeralPublicKey: clientPublicKey.rawRepresentation,
            confirmNonce: confirmNonce
        )
    }

    /// Process a per-client rekey payload (client side).
    ///
    /// SECURITY: Client uses its current ephemeral private key to perform DH
    /// with the host's fresh ephemeral public key. After successful unwrap,
    /// the client MUST rotate its ephemeral key pair and send the new public
    /// key in the RekeyConfirmation.
    ///
    /// - Parameters:
    ///   - payload: The per-client rekey payload from host
    ///   - currentMasterKey: Current master key (for context binding)
    ///   - currentEpoch: Current epoch
    ///   - clientPrivateKey: Client's current ephemeral private key
    ///   - roomId: Room identifier
    /// - Returns: The new master key
    static func processPerClientRekeyPayload(
        payload: PerClientRekeyPayload,
        currentMasterKey: SecureBytes,
        currentEpoch: UInt32,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        roomId: Data
    ) throws -> SecureBytes {
        // Verify epoch transition
        guard payload.newEpoch == currentEpoch + 1 else {
            throw HandshakeError.invalidApproval
        }

        // Validate keys
        guard payload.hostEphemeralPublicKey.count == 32,
              payload.clientEphemeralPublicKey.count == 32 else {
            throw HandshakeError.invalidPublicKey
        }

        // Verify the payload is addressed to us
        guard payload.clientEphemeralPublicKey == clientPrivateKey.publicKey.rawRepresentation else {
            throw HandshakeError.invalidApproval
        }

        let hostEphemeralPublic = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: payload.hostEphemeralPublicKey
        )

        // Derive wrapping key via DH (mirrors host-side derivation)
        let rekeyKey = try KeyExchange.deriveRekeyKeyDH(
            oldMasterKey: currentMasterKey,
            ephemeralPrivateKey: clientPrivateKey,
            peerPublicKey: hostEphemeralPublic,
            roomId: roomId,
            epoch: payload.newEpoch
        )

        // Validate wrapped key length
        guard payload.wrappedKey.count >= 16 else {
            throw HandshakeError.invalidApproval
        }

        let ciphertext = payload.wrappedKey.dropLast(16)
        let tag = payload.wrappedKey.suffix(16)

        // Rebuild AAD for verification
        var aad = Data()
        var epochBE = payload.newEpoch.bigEndian
        aad.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })
        aad.append(roomId)
        aad.append(payload.hostEphemeralPublicKey)
        aad.append(payload.clientEphemeralPublicKey)

        // Decrypt new master key
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: payload.nonce),
            ciphertext: ciphertext,
            tag: tag
        )

        let newKeyData = try ChaChaPoly.open(sealedBox, using: rekeyKey, authenticating: aad)
        return SecureBytes(data: newKeyData)
    }
}
