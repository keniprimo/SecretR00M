import Foundation
import CryptoKit
import Security

/// MessageCrypto provides AEAD encryption/decryption using ChaCha20-Poly1305.
///
/// Message frame format:
/// - version: 1 byte (0x01)
/// - epoch: 4 bytes (big-endian uint32)
/// - sequence: 8 bytes (big-endian uint64)
/// - senderId: 16 bytes (UUID)
/// - nonce: 12 bytes
/// - ciphertext: variable length (padded to fixed sizes)
/// - tag: 16 bytes (Poly1305)
enum MessageCrypto {

    /// Errors that can occur during message crypto operations
    enum Error: Swift.Error {
        case frameTooShort
        case unsupportedVersion
        case decryptionFailed
        case invalidNonce
        case invalidFrame
        case invalidPadding
        case messageTooLarge
    }

    /// Current protocol version
    static let protocolVersion: UInt8 = 0x01

    /// Frame header size (before ciphertext): version(1) + epoch(4) + sequence(8) + senderId(16) + nonce(12) = 41
    static let headerSize = 1 + 4 + 8 + 16 + 12

    /// Minimum frame size: header(41) + tag(16) = 57
    static let minimumFrameSize = headerSize + 16

    // MARK: - Traffic Analysis Resistance (Padding)

    /// Padding bucket sizes to prevent traffic analysis
    /// SECURITY: All messages are padded to one of these fixed sizes
    /// This prevents relay from inferring content type from message size
    enum PaddingBucket: Int, CaseIterable {
        case tiny = 256           // Short text messages
        case small = 1024         // Longer text, small system messages
        case medium = 8192        // Small images, thumbnails
        case large = 65536        // Medium images
        case xlarge = 262144      // Large images, short videos
        case xxlarge = 1048576    // Videos up to 1MB
        case maximum = 5242880    // Maximum: 5MB videos

        /// Get the appropriate bucket for a given plaintext size
        static func bucketFor(size: Int) -> PaddingBucket? {
            for bucket in PaddingBucket.allCases {
                if size <= bucket.rawValue - 4 { // Reserve 4 bytes for length prefix
                    return bucket
                }
            }
            return nil
        }
    }

    /// Pad plaintext to a fixed bucket size with randomized variance for traffic analysis resistance
    /// Format: [4-byte length (big-endian)] [plaintext] [random padding]
    ///
    /// SECURITY: Two layers of traffic analysis resistance:
    /// 1. Bucket quantization: Messages are padded to discrete bucket sizes
    /// 2. Random variance: ±10% random size added within each bucket to prevent
    ///    exact-size fingerprinting (e.g., distinguishing "hello" from "world")
    ///
    /// - Parameters:
    ///   - plaintext: The original plaintext
    ///   - highSecurityMode: If true, always pad to maximum bucket (more expensive)
    /// - Returns: Padded plaintext
    /// - Throws: If plaintext is too large or random generation fails
    static func padPlaintext(_ plaintext: Data, highSecurityMode: Bool = false) throws -> Data {
        let plaintextSize = plaintext.count

        // Determine target bucket
        let bucket: PaddingBucket
        if highSecurityMode {
            // In high security mode, use larger buckets to reduce fingerprinting
            if plaintextSize <= PaddingBucket.small.rawValue - 4 {
                bucket = .small
            } else if plaintextSize <= PaddingBucket.large.rawValue - 4 {
                bucket = .large
            } else {
                bucket = .maximum
            }
        } else {
            guard let selectedBucket = PaddingBucket.bucketFor(size: plaintextSize) else {
                throw Error.messageTooLarge
            }
            bucket = selectedBucket
        }

        // SECURITY: Add random variance (±10%) within the bucket to prevent
        // exact-size fingerprinting. Two messages of different lengths that land
        // in the same bucket will now have different padded sizes.
        let baseSize = bucket.rawValue
        let varianceRange = max(1, baseSize / 10) // 10% of bucket size
        var randomVarianceBytes = Data(count: 4)
        _ = randomVarianceBytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 4, ptr.baseAddress!)
        }
        let randomValue = randomVarianceBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        // Random offset: 0 to varianceRange (only additive - never smaller than bucket)
        let variance = Int(randomValue) % (varianceRange + 1)
        let targetSize = baseSize + variance

        let paddingNeeded = targetSize - 4 - plaintextSize

        // Build padded message: [length][plaintext][random padding]
        var padded = Data(capacity: targetSize)

        // 4-byte length prefix (big-endian)
        var lengthBE = UInt32(plaintextSize).bigEndian
        padded.append(contentsOf: withUnsafeBytes(of: &lengthBE) { Array($0) })

        // Original plaintext
        padded.append(plaintext)

        // Random padding (not zeros - zeros could leak info)
        if paddingNeeded > 0 {
            var randomPadding = Data(count: paddingNeeded)
            let result = randomPadding.withUnsafeMutableBytes { ptr in
                SecRandomCopyBytes(kSecRandomDefault, paddingNeeded, ptr.baseAddress!)
            }
            guard result == errSecSuccess else {
                throw Error.invalidNonce
            }
            padded.append(randomPadding)
        }

        return padded
    }

    /// Remove padding and extract original plaintext
    /// - Parameter padded: The padded plaintext
    /// - Returns: Original plaintext
    /// - Throws: If padding is invalid
    static func unpadPlaintext(_ padded: Data) throws -> Data {
        guard padded.count >= 4 else {
            throw Error.invalidPadding
        }

        // Read length prefix
        let lengthData = padded.subdata(in: 0..<4)
        let length = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })

        // Validate length
        guard length >= 0, length <= padded.count - 4 else {
            throw Error.invalidPadding
        }

        // Extract original plaintext
        return padded.subdata(in: 4..<(4 + length))
    }

    /// Encrypt a plaintext message with padding for traffic analysis resistance
    /// - Parameters:
    ///   - plaintext: The message content to encrypt
    ///   - key: The symmetric encryption key
    ///   - senderId: UUID of the sender
    ///   - sequence: Monotonic sequence number for this sender
    ///   - epoch: Current key epoch
    ///   - highSecurityMode: Use larger padding buckets for maximum protection
    /// - Returns: The encrypted frame as Data
    /// - Throws: If encryption fails
    static func encrypt(
        plaintext: Data,
        key: SymmetricKey,
        senderId: UUID,
        sequence: UInt64,
        epoch: UInt32,
        highSecurityMode: Bool = false
    ) throws -> Data {
        // SECURITY: Pad plaintext to fixed bucket sizes to prevent traffic analysis
        let paddedPlaintext = try padPlaintext(plaintext, highSecurityMode: highSecurityMode)

        // Generate cryptographically secure random nonce (12 bytes for ChaCha20-Poly1305)
        let nonce = try generateRandomNonce()

        // Construct AAD: version || epoch || sequence || senderId
        let aad = constructAAD(epoch: epoch, sequence: sequence, senderId: senderId)

        // Encrypt with ChaCha20-Poly1305
        let sealedBox = try ChaChaPoly.seal(
            paddedPlaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: nonce),
            authenticating: aad
        )

        // Build frame
        var frame = Data(capacity: headerSize + sealedBox.ciphertext.count + 16)

        // Version
        frame.append(protocolVersion)

        // Epoch (big-endian)
        var epochBE = epoch.bigEndian
        frame.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })

        // Sequence (big-endian)
        var sequenceBE = sequence.bigEndian
        frame.append(contentsOf: withUnsafeBytes(of: &sequenceBE) { Array($0) })

        // Sender ID (16 bytes)
        frame.append(contentsOf: withUnsafeBytes(of: senderId.uuid) { Array($0) })

        // Nonce
        frame.append(nonce)

        // Ciphertext
        frame.append(sealedBox.ciphertext)

        // Tag
        frame.append(sealedBox.tag)

        return frame
    }

    /// Decrypted message result
    struct DecryptedMessage {
        let plaintext: Data
        let senderId: UUID
        let sequence: UInt64
        let epoch: UInt32
        let nonce: Data
    }

    /// Decrypt an encrypted message frame
    /// - Parameters:
    ///   - frame: The encrypted frame
    ///   - key: The symmetric decryption key
    /// - Returns: The decrypted message with metadata
    /// - Throws: If decryption fails
    static func decrypt(frame: Data, key: SymmetricKey) throws -> DecryptedMessage {
        guard frame.count >= minimumFrameSize else {
            throw Error.frameTooShort
        }

        var offset = 0

        // Version
        let version = frame[offset]
        offset += 1
        guard version == protocolVersion else {
            throw Error.unsupportedVersion
        }

        // Epoch
        let epochData = frame.subdata(in: offset..<(offset + 4))
        let epoch = epochData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4

        // Sequence
        let sequenceData = frame.subdata(in: offset..<(offset + 8))
        let sequence = sequenceData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        offset += 8

        // Sender ID
        let senderIdData = frame.subdata(in: offset..<(offset + 16))
        let senderId = senderIdData.withUnsafeBytes { ptr -> UUID in
            UUID(uuid: ptr.load(as: uuid_t.self))
        }
        offset += 16

        // Nonce
        let nonce = frame.subdata(in: offset..<(offset + 12))
        offset += 12

        // Ciphertext and tag
        let ciphertextAndTag = frame.subdata(in: offset..<frame.count)
        guard ciphertextAndTag.count >= 16 else {
            throw Error.frameTooShort
        }

        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)

        // Reconstruct AAD
        let aad = constructAAD(epoch: epoch, sequence: sequence, senderId: senderId)

        // Decrypt
        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
        } catch {
            throw Error.invalidFrame
        }

        let paddedPlaintext: Data
        do {
            paddedPlaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw Error.decryptionFailed
        }

        // SECURITY: Remove padding to get original plaintext
        let plaintext = try unpadPlaintext(paddedPlaintext)

        return DecryptedMessage(
            plaintext: plaintext,
            senderId: senderId,
            sequence: sequence,
            epoch: epoch,
            nonce: nonce
        )
    }

    /// Generate a cryptographically secure random nonce
    /// - Returns: 12-byte random nonce for ChaCha20-Poly1305
    /// - Throws: If random generation fails
    static func generateRandomNonce() throws -> Data {
        var nonce = Data(count: 12)
        let result = nonce.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 12, ptr.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw Error.invalidNonce
        }
        return nonce
    }

    /// Construct a deterministic nonce from message metadata (deprecated, kept for decryption compatibility)
    /// - Parameters:
    ///   - epoch: Key epoch
    ///   - senderId: Sender UUID
    ///   - sequence: Message sequence number
    /// - Returns: 12-byte nonce
    @available(*, deprecated, message: "Use generateRandomNonce() for encryption")
    static func constructNonce(epoch: UInt32, senderId: UUID, sequence: UInt64) -> Data {
        var nonce = Data(capacity: 12)

        // Epoch: 4 bytes
        var epochBE = epoch.bigEndian
        nonce.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })

        // Sender hash: first 4 bytes of SHA256(senderId)
        let senderData = withUnsafeBytes(of: senderId.uuid) { Data($0) }
        let senderHash = SHA256.hash(data: senderData)
        nonce.append(contentsOf: senderHash.prefix(4))

        // Sequence: lower 4 bytes
        var seqLower = UInt32(truncatingIfNeeded: sequence).bigEndian
        nonce.append(contentsOf: withUnsafeBytes(of: &seqLower) { Array($0) })

        return nonce
    }

    /// Construct AAD (Additional Authenticated Data) from message metadata
    private static func constructAAD(epoch: UInt32, sequence: UInt64, senderId: UUID) -> Data {
        var aad = Data(capacity: 1 + 4 + 8 + 16)

        // Version
        aad.append(protocolVersion)

        // Epoch
        var epochBE = epoch.bigEndian
        aad.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })

        // Sequence
        var sequenceBE = sequence.bigEndian
        aad.append(contentsOf: withUnsafeBytes(of: &sequenceBE) { Array($0) })

        // Sender ID
        aad.append(contentsOf: withUnsafeBytes(of: senderId.uuid) { Array($0) })

        return aad
    }
}

// MARK: - High-level message types
extension MessageCrypto {

    /// Message content types
    enum ContentType: UInt8 {
        case text = 0x01
        case image = 0x02
        case system = 0x03
        case video = 0x04
        /// SECURITY: Internal type for rekey confirmations sent as encrypted MESSAGE frames.
        /// Indistinguishable from normal messages at the relay level (opaque ciphertext).
        case rekeyConfirm = 0x05
    }

    /// Encode a text message for encryption
    /// - Parameters:
    ///   - text: The text content
    ///   - timestamp: Unix timestamp in milliseconds
    /// - Returns: Encoded plaintext ready for encryption
    static func encodeTextMessage(text: String, timestamp: UInt64) -> Data {
        var payload = Data()

        // Content type
        payload.append(ContentType.text.rawValue)

        // Timestamp (8 bytes, big-endian)
        var timestampBE = timestamp.bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &timestampBE) { Array($0) })

        // Content (UTF-8)
        if let textData = text.data(using: .utf8) {
            payload.append(textData)
        }

        return payload
    }

    /// Decode a text message from decrypted plaintext
    /// - Parameter plaintext: The decrypted payload
    /// - Returns: Tuple of (text content, timestamp) or nil if invalid
    static func decodeTextMessage(_ plaintext: Data) -> (text: String, timestamp: UInt64)? {
        guard plaintext.count >= 9 else { return nil } // type + timestamp minimum

        let contentType = plaintext[0]
        guard contentType == ContentType.text.rawValue else { return nil }

        let timestampData = plaintext.subdata(in: 1..<9)
        let timestamp = timestampData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }

        let textData = plaintext.subdata(in: 9..<plaintext.count)
        guard let text = String(data: textData, encoding: .utf8) else { return nil }

        return (text, timestamp)
    }

    /// Encode a system message
    /// - Parameters:
    ///   - event: System event type
    ///   - timestamp: Unix timestamp
    /// - Returns: Encoded plaintext
    static func encodeSystemMessage(event: String, timestamp: UInt64) -> Data {
        var payload = Data()

        payload.append(ContentType.system.rawValue)

        var timestampBE = timestamp.bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &timestampBE) { Array($0) })

        if let eventData = event.data(using: .utf8) {
            payload.append(eventData)
        }

        return payload
    }

    /// Encode an image message for encryption
    /// - Parameters:
    ///   - imageData: The compressed image data (JPEG/PNG)
    ///   - mimeType: MIME type of the image (e.g., "image/jpeg")
    ///   - timestamp: Unix timestamp in milliseconds
    /// - Returns: Encoded plaintext ready for encryption
    static func encodeImageMessage(imageData: Data, mimeType: String, timestamp: UInt64) -> Data {
        var payload = Data()

        // Content type
        payload.append(ContentType.image.rawValue)

        // Timestamp (8 bytes, big-endian)
        var timestampBE = timestamp.bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &timestampBE) { Array($0) })

        // MIME type length (2 bytes, big-endian)
        let mimeData = mimeType.data(using: .utf8) ?? Data()
        var mimeLengthBE = UInt16(mimeData.count).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &mimeLengthBE) { Array($0) })

        // MIME type
        payload.append(mimeData)

        // Image data
        payload.append(imageData)

        return payload
    }

    /// Decode an image message from decrypted plaintext
    /// - Parameter plaintext: The decrypted payload
    /// - Returns: Tuple of (imageData, mimeType, timestamp) or nil if invalid
    static func decodeImageMessage(_ plaintext: Data) -> (imageData: Data, mimeType: String, timestamp: UInt64)? {
        // Minimum: type(1) + timestamp(8) + mimeLength(2) = 11 bytes
        guard plaintext.count >= 11 else { return nil }

        let contentType = plaintext[0]
        guard contentType == ContentType.image.rawValue else { return nil }

        let timestampData = plaintext.subdata(in: 1..<9)
        let timestamp = timestampData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }

        let mimeLengthData = plaintext.subdata(in: 9..<11)
        let mimeLength = Int(mimeLengthData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })

        guard plaintext.count >= 11 + mimeLength else { return nil }

        let mimeData = plaintext.subdata(in: 11..<(11 + mimeLength))
        guard let mimeType = String(data: mimeData, encoding: .utf8) else { return nil }

        let imageData = plaintext.subdata(in: (11 + mimeLength)..<plaintext.count)

        return (imageData, mimeType, timestamp)
    }

    /// Encode a video message for encryption
    /// - Parameters:
    ///   - videoData: The compressed video data
    ///   - mimeType: MIME type of the video (e.g., "video/mp4")
    ///   - thumbnailData: Optional thumbnail image data (JPEG)
    ///   - duration: Video duration in seconds
    ///   - timestamp: Unix timestamp in milliseconds
    /// - Returns: Encoded plaintext ready for encryption
    static func encodeVideoMessage(videoData: Data, mimeType: String, thumbnailData: Data?, duration: Double, timestamp: UInt64) -> Data {
        var payload = Data()

        // Content type
        payload.append(ContentType.video.rawValue)

        // Timestamp (8 bytes, big-endian)
        var timestampBE = timestamp.bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &timestampBE) { Array($0) })

        // Duration (8 bytes, big-endian double)
        var durationBits = duration.bitPattern.bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &durationBits) { Array($0) })

        // MIME type length (2 bytes, big-endian)
        let mimeData = mimeType.data(using: .utf8) ?? Data()
        var mimeLengthBE = UInt16(mimeData.count).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &mimeLengthBE) { Array($0) })

        // MIME type
        payload.append(mimeData)

        // Thumbnail length (4 bytes, big-endian)
        let thumbnail = thumbnailData ?? Data()
        var thumbLengthBE = UInt32(thumbnail.count).bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &thumbLengthBE) { Array($0) })

        // Thumbnail data
        payload.append(thumbnail)

        // Video data
        payload.append(videoData)

        return payload
    }

    /// Decode a video message from decrypted plaintext
    /// - Parameter plaintext: The decrypted payload
    /// - Returns: Tuple of (videoData, mimeType, thumbnailData, duration, timestamp) or nil if invalid
    static func decodeVideoMessage(_ plaintext: Data) -> (videoData: Data, mimeType: String, thumbnailData: Data?, duration: Double, timestamp: UInt64)? {
        // Minimum: type(1) + timestamp(8) + duration(8) + mimeLength(2) + thumbLength(4) = 23 bytes
        guard plaintext.count >= 23 else { return nil }

        let contentType = plaintext[0]
        guard contentType == ContentType.video.rawValue else { return nil }

        let timestampData = plaintext.subdata(in: 1..<9)
        let timestamp = timestampData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }

        let durationData = plaintext.subdata(in: 9..<17)
        let durationBits = durationData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let duration = Double(bitPattern: durationBits)

        let mimeLengthData = plaintext.subdata(in: 17..<19)
        let mimeLength = Int(mimeLengthData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })

        guard plaintext.count >= 23 + mimeLength else { return nil }

        let mimeData = plaintext.subdata(in: 19..<(19 + mimeLength))
        guard let mimeType = String(data: mimeData, encoding: .utf8) else { return nil }

        let thumbLengthData = plaintext.subdata(in: (19 + mimeLength)..<(23 + mimeLength))
        let thumbLength = Int(thumbLengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })

        guard plaintext.count >= 23 + mimeLength + thumbLength else { return nil }

        let thumbnailData: Data?
        if thumbLength > 0 {
            thumbnailData = plaintext.subdata(in: (23 + mimeLength)..<(23 + mimeLength + thumbLength))
        } else {
            thumbnailData = nil
        }

        let videoData = plaintext.subdata(in: (23 + mimeLength + thumbLength)..<plaintext.count)

        return (videoData, mimeType, thumbnailData, duration, timestamp)
    }

    /// Detect the content type from decrypted plaintext
    /// - Parameter plaintext: The decrypted payload
    /// - Returns: The content type, or nil if invalid
    static func detectContentType(_ plaintext: Data) -> ContentType? {
        guard !plaintext.isEmpty else { return nil }
        return ContentType(rawValue: plaintext[0])
    }
}
