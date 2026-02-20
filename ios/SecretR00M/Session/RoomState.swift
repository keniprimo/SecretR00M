import Foundation

// MARK: - Room State

/// Room lifecycle states
enum RoomState: Equatable {
    case none                           // No room
    case creating                       // Creating/joining in progress
    case created(roomId: String)        // Host: room created, not yet open
    case open                           // Host: room open for joins
    case active                         // Room active with participants
    case rekeying                       // Key rotation in progress
    case destroyed(reason: DestructionReason)  // Room terminated

    var isActive: Bool {
        switch self {
        case .active, .rekeying:
            return true
        default:
            return false
        }
    }

    var canSendMessages: Bool {
        return self == .active
    }
}

/// Reasons for room destruction
enum DestructionReason: String, Equatable {
    case hostDisconnected = "host_disconnected"
    case hostClosed = "host_closed"
    case heartbeatTimeout = "heartbeat_timeout"
    case serverError = "server_error"
    case userExit = "user_exit"
    case backgrounded = "backgrounded"
    case deviceLocked = "device_locked"
    case kicked = "kicked"
    case joinRejected = "join_rejected"
    case networkError = "network_error"
    // Stability-related reasons
    case capacityExceeded = "capacity_exceeded"
    case cryptoFailure = "crypto_failure"
    case memoryPressure = "memory_pressure"

    /// User-facing description of the destruction reason
    var userFacingDescription: String {
        switch self {
        case .hostDisconnected:
            return "The room host has disconnected."
        case .hostClosed:
            return "The room has been closed."
        case .heartbeatTimeout:
            return "Connection lost due to network timeout."
        case .serverError:
            return "Server error occurred. Please try creating a new room."
        case .userExit:
            return "You have exited the conversation."
        case .backgrounded:
            return "Room closed (app backgrounded)."
        case .deviceLocked:
            return "Room closed (device locked)."
        case .kicked:
            return "You have been removed from the room."
        case .joinRejected:
            return "Your join request was rejected."
        case .networkError:
            return "Connection lost. Please check your network."
        case .capacityExceeded:
            return "Room capacity exceeded. Messages were arriving too fast."
        case .cryptoFailure:
            return "Encryption error. Room closed for security."
        case .memoryPressure:
            return "Device memory low. Room closed to protect your data."
        }
    }

    /// Whether this reason is recoverable (user can try to rejoin)
    var isRecoverable: Bool {
        switch self {
        case .userExit, .kicked, .joinRejected, .cryptoFailure:
            return false
        default:
            return true
        }
    }
}

/// Role in a room
enum RoomRole: Equatable {
    case host
    case client
}

// MARK: - Participant

/// A participant in the room
struct Participant: Identifiable {
    let id: UUID
    let publicKey: Data
    let displayName: String?
    let joinedAt: Date

    /// Short identifier for display (first 8 chars of UUID)
    var shortId: String {
        String(id.uuidString.prefix(8))
    }
}

// MARK: - Message Content Type

/// Type of message content
enum MessageContentType {
    case text(String)
    case image(data: Data, mimeType: String)
    case video(data: Data, mimeType: String, thumbnail: Data?, duration: Double)
    case system(String)
}

// MARK: - Decrypted Message

/// A decrypted message for display
struct DecryptedMessage: Identifiable {
    let id: UUID
    let senderId: UUID
    let content: String
    let contentType: MessageContentType
    let sequence: UInt64
    let receivedAt: Date
    let isSystemMessage: Bool

    /// Image data if this is an image message
    var imageData: Data? {
        if case .image(let data, _) = contentType {
            return data
        }
        return nil
    }

    /// Video data if this is a video message
    var videoData: Data? {
        if case .video(let data, _, _, _) = contentType {
            return data
        }
        return nil
    }

    /// Video thumbnail if this is a video message
    var videoThumbnail: Data? {
        if case .video(_, _, let thumbnail, _) = contentType {
            return thumbnail
        }
        return nil
    }

    /// Video duration if this is a video message
    var videoDuration: Double? {
        if case .video(_, _, _, let duration) = contentType {
            return duration
        }
        return nil
    }

    init(
        id: UUID = UUID(),
        senderId: UUID,
        content: String,
        contentType: MessageContentType = .text(""),
        sequence: UInt64,
        receivedAt: Date = Date(),
        isSystemMessage: Bool = false
    ) {
        self.id = id
        self.senderId = senderId
        self.content = content
        self.contentType = contentType
        self.sequence = sequence
        self.receivedAt = receivedAt
        self.isSystemMessage = isSystemMessage
    }

    /// Convenience initializer for text messages
    static func text(
        id: UUID = UUID(),
        senderId: UUID,
        content: String,
        sequence: UInt64,
        receivedAt: Date = Date()
    ) -> DecryptedMessage {
        DecryptedMessage(
            id: id,
            senderId: senderId,
            content: content,
            contentType: .text(content),
            sequence: sequence,
            receivedAt: receivedAt,
            isSystemMessage: false
        )
    }

    /// Convenience initializer for image messages
    static func image(
        id: UUID = UUID(),
        senderId: UUID,
        imageData: Data,
        mimeType: String,
        sequence: UInt64,
        receivedAt: Date = Date()
    ) -> DecryptedMessage {
        DecryptedMessage(
            id: id,
            senderId: senderId,
            content: "[Image]",
            contentType: .image(data: imageData, mimeType: mimeType),
            sequence: sequence,
            receivedAt: receivedAt,
            isSystemMessage: false
        )
    }

    /// Convenience initializer for video messages
    static func video(
        id: UUID = UUID(),
        senderId: UUID,
        videoData: Data,
        mimeType: String,
        thumbnail: Data?,
        duration: Double,
        sequence: UInt64,
        receivedAt: Date = Date()
    ) -> DecryptedMessage {
        DecryptedMessage(
            id: id,
            senderId: senderId,
            content: "[Video]",
            contentType: .video(data: videoData, mimeType: mimeType, thumbnail: thumbnail, duration: duration),
            sequence: sequence,
            receivedAt: receivedAt,
            isSystemMessage: false
        )
    }

    /// Convenience initializer for system messages
    static func system(
        id: UUID = UUID(),
        senderId: UUID,
        content: String,
        sequence: UInt64,
        receivedAt: Date = Date()
    ) -> DecryptedMessage {
        DecryptedMessage(
            id: id,
            senderId: senderId,
            content: content,
            contentType: .system(content),
            sequence: sequence,
            receivedAt: receivedAt,
            isSystemMessage: true
        )
    }
}

// MARK: - Room Configuration

/// Errors related to room configuration
enum RoomConfigurationError: Error, LocalizedError {
    case invalidOnionURL
    case nonOnionURLWithTor

    var errorDescription: String? {
        switch self {
        case .invalidOnionURL:
            return "Invalid .onion URL format"
        case .nonOnionURLWithTor:
            return "Only secure .onion URLs are allowed"
        }
    }
}

/// Configuration for room behavior
/// All connections are routed through a secure privacy network
struct RoomConfiguration {
    /// Server URL for the relay (always uses .onion hidden service)
    let serverURL: String

    /// Always true - all connections use secure routing for IP anonymity
    let useTor: Bool = true

    /// Whether to enable high security mode
    var highSecurityMode: Bool = false

    /// Maximum message buffer size
    var maxMessageBuffer: Int = 50

    /// Rekey interval in seconds (0 = disabled)
    /// SECURITY: Shortened from 300s to 60s for tighter forward secrecy epochs
    var rekeyIntervalSeconds: TimeInterval = 60

    /// Rekey after this many messages (0 = disabled)
    /// SECURITY: Shortened from 100 to 20 for tighter forward secrecy epochs
    var rekeyMessageCount: Int = 20

    /// Rekey on screenshot detection
    var rekeyOnScreenshot: Bool = true

    /// Rekey on screen recording detection
    var rekeyOnRecording: Bool = true

    /// Notify room on capture events
    var notifyOnCapture: Bool = true

    /// Initialize with validation
    /// - Parameters:
    ///   - serverURL: The server URL (must be .onion for secure connections)
    ///   - highSecurityMode: Enable high security mode
    /// SECURITY: Uses guard statement instead of precondition to ensure validation in Release builds
    init(serverURL: String, highSecurityMode: Bool = false) {
        // SECURITY: Validate .onion URL format - this check MUST run in Release builds
        // Using guard + fatalError instead of precondition to ensure it's never stripped
        guard Self.isValidOnionURL(serverURL) else {
            // This is a programming error - crash immediately to prevent traffic leakage
            fatalError("SECURITY VIOLATION: Server URL must be a valid .onion address, got: \(serverURL.prefix(20))...")
        }
        self.serverURL = serverURL
        self.highSecurityMode = highSecurityMode
    }

    /// Validate that a URL is a valid .onion address
    /// - Parameter urlString: The URL string to validate
    /// - Returns: True if valid .onion URL
    static func isValidOnionURL(_ urlString: String) -> Bool {
        // Parse the URL
        guard let url = URL(string: urlString),
              let host = url.host else {
            return false
        }

        // Must end with .onion
        guard host.hasSuffix(".onion") else {
            return false
        }

        // Extract the onion address (without .onion suffix)
        let onionAddress = String(host.dropLast(6)) // Remove ".onion"

        // v3 onion addresses are 56 characters (base32 encoded)
        // v2 onion addresses are 16 characters (deprecated but still valid)
        let validLengths = [16, 56]
        guard validLengths.contains(onionAddress.count) else {
            return false
        }

        // Validate base32 character set for v3 or base32 for v2
        let base32Chars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz234567")
        guard onionAddress.unicodeScalars.allSatisfy({ base32Chars.contains($0) }) else {
            return false
        }

        // Scheme must be ws:// or wss:// for WebSocket
        let validSchemes = ["ws", "wss"]
        guard let scheme = url.scheme?.lowercased(),
              validSchemes.contains(scheme) else {
            return false
        }

        return true
    }

    /// Default configuration - uses secure privacy network with .onion hidden service
    static let `default` = RoomConfiguration(
        serverURL: "ws://xihrxmtwitgihtxllygrgoxixuu6ib7kzmgvosv7467tnij5svgyabid.onion"
    )

    /// High privacy configuration - same as default but with high security mode enabled
    static let highPrivacy = RoomConfiguration(
        serverURL: "ws://xihrxmtwitgihtxllygrgoxixuu6ib7kzmgvosv7467tnij5svgyabid.onion",
        highSecurityMode: true
    )
}

// MARK: - Room Events

/// Events that can occur in a room
enum RoomEvent {
    case created(roomId: String)
    case opened
    case joinRequested(clientId: String, displayName: String?)
    case joinApproved(participantId: UUID)
    case joinRejected(reason: String)
    case participantJoined(participant: Participant)
    case participantLeft(participantId: UUID)
    case messageReceived(message: DecryptedMessage)
    case rekeyStarted(reason: String)
    case rekeyCompleted(newEpoch: UInt32)
    case securityEvent(event: SecurityEventType)
    case destroyed(reason: DestructionReason)
    case error(message: String)
}

/// Security event types
enum SecurityEventType {
    case screenshotDetected
    case screenRecordingStarted
    case screenRecordingStopped
    case backgrounded
    case deviceLocked
}

// MARK: - Pending Join Request

/// A pending join request awaiting host approval
struct PendingJoinRequest {
    let clientId: String
    let request: JoinRequest
    let receivedAt: Date
}
