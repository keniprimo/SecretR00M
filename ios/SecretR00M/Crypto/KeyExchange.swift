import Foundation
import CryptoKit

/// KeyExchange provides X25519 ECDH key exchange and HKDF key derivation.
enum KeyExchange {

    /// Errors that can occur during key exchange
    enum Error: Swift.Error {
        case invalidPublicKey
        case keyAgreementFailed
        case derivationFailed
    }

    /// Perform X25519 key agreement and derive a session key
    /// - Parameters:
    ///   - privateKey: Our X25519 private key
    ///   - peerPublicKey: Peer's X25519 public key
    ///   - roomId: Room identifier for context binding
    ///   - hostPublicKey: Host's public key (raw bytes)
    ///   - clientPublicKey: Client's public key (raw bytes)
    /// - Returns: A 256-bit symmetric session key
    /// - Throws: If key agreement fails
    static func deriveSessionKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey,
        roomId: Data,
        hostPublicKey: Data,
        clientPublicKey: Data
    ) throws -> SymmetricKey {
        // Perform X25519 key agreement
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        } catch {
            throw Error.keyAgreementFailed
        }

        // Build transcript for context binding
        var transcript = Data()
        transcript.append(hostPublicKey)
        transcript.append(clientPublicKey)
        transcript.append(roomId)
        transcript.append("session-key-v1".data(using: .utf8)!)

        // Derive session key using HKDF
        let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: roomId,
            sharedInfo: transcript,
            outputByteCount: 32
        )

        return sessionKey
    }

    /// Derive a message encryption key from the master key and epoch
    /// - Parameters:
    ///   - masterKey: The room master key
    ///   - epoch: Current key epoch
    /// - Returns: A 256-bit symmetric key for message encryption
    static func deriveMessageKey(masterKey: SecureBytes, epoch: UInt32) -> SymmetricKey {
        // SECURITY: Build 32-byte salt from epoch + domain separator hash
        // This provides proper domain separation per NIST guidelines
        var epochBytes = epoch.bigEndian
        var saltInput = Data(bytes: &epochBytes, count: 4)
        saltInput.append("EphemeralRooms-message-salt-v1".data(using: .utf8)!)
        let salt = Data(SHA256.hash(data: saltInput)) // 32 bytes

        let info = "message-key-v1".data(using: .utf8)!

        return masterKey.withUnsafeBytes { masterKeyPtr in
            let masterKeyData = Data(masterKeyPtr)
            let inputKey = SymmetricKey(data: masterKeyData)

            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKey,
                salt: salt,
                info: info,
                outputByteCount: 32
            )
        }
    }

    /// Derive a rekey wrapping key from the master key and epoch
    /// - Parameters:
    ///   - masterKey: The current room master key
    ///   - epoch: Current key epoch
    /// - Returns: A 256-bit symmetric key for wrapping the new master key
    @available(*, deprecated, message: "Use deriveRekeyKeyDH for forward-secure ratchet")
    static func deriveRekeyKey(masterKey: SecureBytes, epoch: UInt32) -> SymmetricKey {
        // SECURITY: Build 32-byte salt from epoch + domain separator hash
        var epochBytes = epoch.bigEndian
        var saltInput = Data(bytes: &epochBytes, count: 4)
        saltInput.append("EphemeralRooms-rekey-salt-v1".data(using: .utf8)!)
        let salt = Data(SHA256.hash(data: saltInput)) // 32 bytes

        let info = "rekey-wrap-v1".data(using: .utf8)!

        return masterKey.withUnsafeBytes { masterKeyPtr in
            let masterKeyData = Data(masterKeyPtr)
            let inputKey = SymmetricKey(data: masterKeyData)

            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKey,
                salt: salt,
                info: info,
                outputByteCount: 32
            )
        }
    }

    // MARK: - Forward-Secure Ratchet

    /// Derive a rekey wrapping key using fresh DH exchange (forward-secure)
    /// SECURITY: Each rekey uses a fresh ephemeral DH key exchange so that
    /// compromise of the old master key does NOT reveal the new master key.
    /// This breaks the deterministic chain of the old key-wrapping approach.
    /// - Parameters:
    ///   - oldMasterKey: Current master key (mixed into derivation for key continuity)
    ///   - ephemeralPrivateKey: Fresh ephemeral X25519 private key generated for this rekey
    ///   - peerPublicKeys: All participants' current public keys
    ///   - roomId: Room identifier for context binding
    ///   - epoch: New epoch number
    /// - Returns: A 256-bit symmetric key for wrapping the new master key
    static func deriveRekeyKeyDH(
        oldMasterKey: SecureBytes,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey,
        roomId: Data,
        epoch: UInt32
    ) throws -> SymmetricKey {
        // Perform X25519 key agreement with fresh ephemeral key
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        } catch {
            throw Error.keyAgreementFailed
        }

        // Build context: old master key hash + room ID + epoch + domain separator
        // Including old master key hash provides key continuity (prevents injection)
        // but the DH shared secret provides forward secrecy
        var context = Data()
        oldMasterKey.withUnsafeBytes { ptr in
            let hash = SHA256.hash(data: Data(ptr))
            context.append(Data(hash))
        }
        context.append(roomId)
        var epochBE = epoch.bigEndian
        context.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })
        context.append("ratchet-rekey-v2".data(using: .utf8)!)

        // HKDF with DH shared secret as input, old master key hash as salt
        let salt = Data(SHA256.hash(data: context))

        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: context,
            outputByteCount: 32
        )
    }

    /// Derive a per-message key from the epoch key, providing per-message forward secrecy
    /// SECURITY: Each message uses a unique key derived from (epoch key, sequence).
    /// After encryption, the caller should discard the per-message key immediately.
    /// - Parameters:
    ///   - masterKey: The room master key for the current epoch
    ///   - epoch: Current key epoch
    ///   - sequence: Message sequence number
    /// - Returns: A 256-bit symmetric key unique to this message
    static func derivePerMessageKey(masterKey: SecureBytes, epoch: UInt32, sequence: UInt64) -> SymmetricKey {
        var saltInput = Data()
        var epochBE = epoch.bigEndian
        saltInput.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })
        var seqBE = sequence.bigEndian
        saltInput.append(contentsOf: withUnsafeBytes(of: &seqBE) { Array($0) })
        saltInput.append("EphemeralRooms-per-message-salt-v1".data(using: .utf8)!)
        let salt = Data(SHA256.hash(data: saltInput))

        let info = "per-message-key-v1".data(using: .utf8)!

        return masterKey.withUnsafeBytes { masterKeyPtr in
            let masterKeyData = Data(masterKeyPtr)
            let inputKey = SymmetricKey(data: masterKeyData)

            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKey,
                salt: salt,
                info: info,
                outputByteCount: 32
            )
        }
    }

    /// Derive a membership key for encrypted member operations
    /// - Parameters:
    ///   - masterKey: The room master key
    ///   - epoch: Current key epoch
    /// - Returns: A 256-bit symmetric key
    static func deriveMembershipKey(masterKey: SecureBytes, epoch: UInt32) -> SymmetricKey {
        // SECURITY: Build 32-byte salt from epoch + domain separator hash
        var epochBytes = epoch.bigEndian
        var saltInput = Data(bytes: &epochBytes, count: 4)
        saltInput.append("EphemeralRooms-membership-salt-v1".data(using: .utf8)!)
        let salt = Data(SHA256.hash(data: saltInput)) // 32 bytes

        let info = "membership-key-v1".data(using: .utf8)!

        return masterKey.withUnsafeBytes { masterKeyPtr in
            let masterKeyData = Data(masterKeyPtr)
            let inputKey = SymmetricKey(data: masterKeyData)

            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKey,
                salt: salt,
                info: info,
                outputByteCount: 32
            )
        }
    }

    /// Derive a confirmation key for authenticating rekey confirmations.
    /// SECURITY: Used to HMAC-authenticate REKEY_CONFIRM payloads so the relay
    /// cannot forge or modify the client's new ephemeral public key.
    /// - Parameters:
    ///   - masterKey: The NEW master key (post-rekey) — both host and client have it
    ///   - epoch: The new epoch
    ///   - confirmNonce: Random nonce generated by host, included in PerClientRekeyPayload
    /// - Returns: A 256-bit symmetric key for HMAC confirmation
    static func deriveConfirmKey(masterKey: SecureBytes, epoch: UInt32, confirmNonce: Data) -> SymmetricKey {
        var saltInput = Data()
        var epochBE = epoch.bigEndian
        saltInput.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })
        saltInput.append(confirmNonce)
        saltInput.append("EphemeralRooms-confirm-salt-v1".data(using: .utf8)!)
        let salt = Data(SHA256.hash(data: saltInput))

        let info = "rekey-confirm-key-v1".data(using: .utf8)!

        return masterKey.withUnsafeBytes { masterKeyPtr in
            let masterKeyData = Data(masterKeyPtr)
            let inputKey = SymmetricKey(data: masterKeyData)

            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKey,
                salt: salt,
                info: info,
                outputByteCount: 32
            )
        }
    }

    /// Parse a raw public key to Curve25519.KeyAgreement.PublicKey
    /// - Parameter data: 32 bytes of raw public key data
    /// - Returns: The parsed public key
    /// - Throws: If the data is not a valid public key
    static func parsePublicKey(_ data: Data) throws -> Curve25519.KeyAgreement.PublicKey {
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        } catch {
            throw Error.invalidPublicKey
        }
    }
}
