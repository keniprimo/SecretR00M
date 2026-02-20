import Foundation
import CryptoKit
import UIKit

#if DEBUG
import os.log
private let logger = Logger(subsystem: "com.ephemeral.rooms", category: "RoomSession")
#endif

/// Delegate protocol for room session events
protocol RoomSessionDelegate: AnyObject {
    func roomSession(_ session: RoomSession, didChangeState state: RoomState)
    func roomSession(_ session: RoomSession, didReceiveEvent event: RoomEvent)
    func roomSession(_ session: RoomSession, didReceiveMessage message: DecryptedMessage)
    func roomSession(_ session: RoomSession, didReceiveJoinRequest request: PendingJoinRequest)
}

/// RoomSession manages the complete lifecycle of an ephemeral room.
/// All cryptographic material and messages are stored in memory only.
final class RoomSession {

    // MARK: - Public Properties

    /// Current room state
    /// Note: Use updateState() to change state safely, which handles delegate notification outside of lock
    private(set) var state: RoomState = .none

    /// Role in this room
    private(set) var role: RoomRole?

    /// Room identifier (base64url encoded)
    private(set) var roomIdString: String?

    /// Our participant ID
    private(set) var participantId: UUID?

    /// Configuration
    /// Room configuration. SECURITY: May be escalated by device integrity checks.
    private(set) var configuration: RoomConfiguration

    /// Delegate for events
    weak var delegate: RoomSessionDelegate?

    // MARK: - Private Properties (Memory Only)

    /// Room ID as raw bytes
    private var roomId: Data?

    /// Room master key - MEMORY ONLY, wiped on destroy
    private var masterKey: SecureBytes?

    /// Our ephemeral X25519 key pair
    private var ephemeralKeyPair: Curve25519.KeyAgreement.PrivateKey?

    /// Current key epoch
    private var currentEpoch: UInt32 = 0

    /// Our message sequence number
    private var sequenceNumber: UInt64 = 0

    /// Participants in the room
    private var participants: [UUID: Participant] = [:]

    /// Session keys for participants (from handshake)
    private var sessionKeys: [UUID: SymmetricKey] = [:]

    /// Pending join requests (host only)
    private var pendingJoins: [String: PendingJoinRequest] = [:]

    /// Pending confirmations awaiting verification (clientId -> confirmation data)
    /// SECURITY: Participants are NOT added to room until confirmation is verified
    private var pendingConfirmations: [String: (sessionKey: SymmetricKey, clientPublicKey: Data, participantId: UUID, participant: Participant)] = [:]

    /// Reverse mapping from participant UUID to relay client ID (for kick messages)
    private var participantClientIds: [UUID: String] = [:]

    /// Host tracks each client's current ephemeral public key for per-client DH rekey.
    /// Updated on join (from JoinRequest.clientPublicKey) and on rekey confirm
    /// (from RekeyConfirmation.newPublicKey).
    private var clientEphemeralKeys: [String: Curve25519.KeyAgreement.PublicKey] = [:]

    /// SECURITY: Host tracks pending confirm nonces per client for HMAC verification.
    /// Key = relay clientId, value = (confirmNonce, epoch).
    /// Cleared on successful confirmation or client departure.
    private var pendingConfirmNonces: [String: (nonce: Data, epoch: UInt32, hostEphemeralPub: Data)] = [:]

    /// Message buffer (volatile, limited by count AND memory)
    private var messageBuffer: [DecryptedMessage] = []

    /// Current estimated memory usage of message buffer in bytes
    private var messageBufferBytes: Int = 0

    /// Maximum memory budget for message buffer (20 MB)
    /// SECURITY: Reduced from 100MB to prevent memory exhaustion DoS
    private let maxMessageBufferBytes: Int = 20 * 1024 * 1024

    /// SECURITY: Message auto-expiry interval. Messages older than this are
    /// automatically purged from the in-memory buffer to minimize forensic
    /// exposure if the device is seized while the app is running.
    private let messageExpiryInterval: TimeInterval = 300 // 5 minutes
    private var messageExpiryTimer: Timer?

    /// Maximum size for a single message (40 MB)
    /// This must be less than the WebSocket maximum message size (50 MB) to account for
    /// encryption overhead, base64 encoding, and JSON wrapper
    static let maxMessageSize: Int = 40 * 1024 * 1024

    /// Nonce tracker for replay protection
    private var nonceTracker = NonceTracker()

    /// WebSocket manager (supports both direct and Tor-routed connections)
    private var webSocket: WebSocketManagerProtocol?

    /// Rekey tracking
    private var messagesSinceRekey: Int = 0
    private var lastRekeyTime: Date?

    private let lock = NSLock()

    /// Background queue for crypto operations to avoid blocking main thread
    private let cryptoQueue = DispatchQueue(label: "com.ephemeral.rooms.crypto", qos: .userInitiated)

    /// SECURITY: Queue for timing-obfuscated message sending.
    /// Messages are dispatched with random delays (0-300ms) to prevent
    /// traffic correlation based on timing patterns (e.g., keystroke timing).
    private let sendQueue = DispatchQueue(label: "com.ephemeral.rooms.send", qos: .userInitiated)

    /// Secure log buffer for diagnostics
    private let logBuffer = SecureLogBuffer.shared

    /// Capacity monitor for memory tracking
    private let capacityMonitor = CapacityMonitor.shared

    /// Track consecutive crypto failures for circuit breaker
    private var consecutiveCryptoFailures: Int = 0
    private let maxConsecutiveCryptoFailures: Int = 5

    /// SECURITY: Invite token stored temporarily for in-band delivery (not in URL)
    private var pendingInviteToken: String?

    // MARK: - Initialization

    init(configuration: RoomConfiguration = .default) {
        self.configuration = configuration
        setupCapacityMonitoring()
        startMessageExpiryTimer()
    }

    // MARK: - State Management

    /// Update state and notify delegate - call WITHOUT holding the lock
    /// This ensures delegate callbacks happen outside of any lock
    private func notifyStateChange(_ newState: RoomState) {
        state = newState
        delegate?.roomSession(self, didChangeState: newState)
    }

    /// Notify delegate of an event - call WITHOUT holding the lock
    private func notifyEvent(_ event: RoomEvent) {
        delegate?.roomSession(self, didReceiveEvent: event)
    }

    private func setupCapacityMonitoring() {
        // Monitor memory warnings from the system
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        logBuffer.warning("RoomSession", "Received memory warning from system")

        lock.lock()
        defer { lock.unlock() }

        // Aggressively evict old messages
        let evictCount = messageBuffer.count / 2
        evictOldMessages(count: evictCount)

        // If still critical, close gracefully
        if capacityMonitor.getCurrentSnapshot().overallLevel >= .critical {
            logBuffer.critical("RoomSession", "Memory pressure too high, closing room")
            DispatchQueue.main.async { [weak self] in
                self?.closeRoom(reason: .memoryPressure)
            }
        }
    }

    deinit {
        messageExpiryTimer?.invalidate()
        wipeAllKeys()
    }

    // MARK: - Message Auto-Expiry

    /// Start the timer that periodically purges expired messages
    /// SECURITY: Minimizes forensic exposure window if device is seized while running
    private func startMessageExpiryTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.messageExpiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.purgeExpiredMessages()
            }
        }
    }

    /// Remove messages older than the expiry interval
    private func purgeExpiredMessages() {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-messageExpiryInterval)
        let before = messageBuffer.count
        messageBuffer.removeAll { $0.receivedAt < cutoff }

        // Recalculate memory usage after purge
        if messageBuffer.count < before {
            messageBufferBytes = messageBuffer.reduce(0) { $0 + estimateMessageSize($1) }
            capacityMonitor.updateMessageBuffer(bytes: messageBufferBytes, count: messageBuffer.count)
            logBuffer.debug("RoomSession", "Purged expired messages")
        }
        lock.unlock()
    }

    // MARK: - Device Integrity Response

    /// SECURITY: Check device integrity and escalate protections if compromised.
    /// On jailbroken/instrumented devices:
    ///   - Force high security mode (larger padding, more frequent rekey)
    ///   - Reduce message expiry to 60s (vs 300s normal)
    ///   - Log security event for user awareness
    private func applyDeviceIntegrityProtections() {
        let result = DeviceIntegrityChecker.performCheck()

        if result.riskLevel == .high {
            logBuffer.critical("RoomSession", "HIGH RISK device environment detected")
            // Force high security mode
            configuration.highSecurityMode = true
            // Shorten rekey intervals on compromised devices
            configuration.rekeyIntervalSeconds = 30
            configuration.rekeyMessageCount = 10
        } else if result.riskLevel == .elevated {
            logBuffer.warning("RoomSession", "Elevated risk device environment detected")
            configuration.highSecurityMode = true
        }
    }

    // MARK: - Host Operations

    /// Create a new room as host
    /// - Parameter customRoomId: Optional custom room ID (will be sanitized for URL safety)
    func createRoom(customRoomId: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }

        guard state == .none else {
            throw RoomError.invalidState
        }

        state = .creating
        role = .host

        // SECURITY: Check device integrity and escalate protections if compromised
        applyDeviceIntegrityProtections()

        // Use custom room ID or generate one
        let finalRoomIdString: String
        if let custom = customRoomId, !custom.isEmpty {
            // Sanitize custom room ID for URL safety
            finalRoomIdString = KeyGeneration.sanitizeRoomId(custom)
            // Create a hash of the custom ID for internal use
            roomId = KeyGeneration.hashRoomId(finalRoomIdString)
        } else {
            // Generate random room ID
            let generatedRoomId = try KeyGeneration.generateRoomId()
            roomId = generatedRoomId
            finalRoomIdString = generatedRoomId.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        roomIdString = finalRoomIdString
        masterKey = try KeyGeneration.generateMasterKey()
        ephemeralKeyPair = KeyGeneration.generateKeyPair()
        participantId = UUID()
        currentEpoch = 1

        #if DEBUG
        if let mk = masterKey, let rid = roomId {
            let hostMasterKeyHash = mk.withUnsafeBytes { ptr -> String in
                let data = Data(ptr)
                return data.prefix(4).map { String(format: "%02x", $0) }.joined()
            }
            let roomIdHash = rid.prefix(4).map { String(format: "%02x", $0) }.joined()
            print("[DEBUG] HOST createRoom: epoch=\(currentEpoch), masterKeyPrefix=\(hostMasterKeyHash), roomIdPrefix=\(roomIdHash), roomIdString=\(roomIdString ?? "nil") (len=\(roomIdString?.count ?? 0))")
        }
        #endif

        // Connect to relay
        guard let roomIdStr = roomIdString else {
            throw RoomError.internalError
        }

        let wsURL = "\(configuration.serverURL)/rooms/\(roomIdStr)"
        guard let url = URL(string: wsURL) else {
            throw RoomError.invalidServerURL
        }

        // Create WebSocket with Tor if configured
        let wsConfig = WebSocketConfiguration(url: url, sendHeartbeats: true, useTor: configuration.useTor)
        let ws = WebSocketFactory.createManager(config: wsConfig)

        webSocket = ws
        ws.protocolDelegate = self
        ws.connect()
    }

    /// Open the room for client joins (host only)
    func openRoom() {
        var shouldNotify = false

        lock.lock()
        guard role == .host else {
            lock.unlock()
            return
        }

        if case .created = state {
            guard let keyPair = ephemeralKeyPair,
                  let encoded = HostMessage.roomOpen(hostPublicKey: keyPair.publicKey.rawRepresentation).encode() else {
                lock.unlock()
                return
            }

            webSocket?.send(string: encoded)
            state = .open
            shouldNotify = true
        }
        lock.unlock()

        // Notify delegate outside of lock
        if shouldNotify {
            delegate?.roomSession(self, didChangeState: .open)
            delegate?.roomSession(self, didReceiveEvent: .opened)
        }
    }

    /// Approve a pending join request (host only)
    func approveJoin(clientId: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard role == .host else {
            throw RoomError.invalidState
        }
        guard state == .open || state == .active else {
            throw RoomError.invalidState
        }
        guard let pending = pendingJoins.removeValue(forKey: clientId) else {
            throw RoomError.invalidState
        }
        guard let keyPair = ephemeralKeyPair else {
            throw RoomError.invalidState
        }
        guard let masterKey = masterKey else {
            throw RoomError.invalidState
        }
        guard let roomId = roomId else {
            throw RoomError.invalidState
        }

        let approval: JoinApproval
        let uuid: UUID
        let sessionKey: SymmetricKey
        (approval, uuid, sessionKey) = try HandshakeEngine.processJoinRequest(
            request: pending.request,
            hostPrivateKey: keyPair,
            masterKey: masterKey,
            roomId: roomId,
            currentEpoch: currentEpoch
        )

        let participant = Participant(
            id: uuid,
            publicKey: pending.request.clientPublicKey,
            displayName: pending.request.displayName,
            joinedAt: Date()
        )

        // Store pending confirmation data for verification when client confirms
        // SECURITY: Do NOT add to participants/sessionKeys until confirmation is verified
        pendingConfirmations[clientId] = (
            sessionKey: sessionKey,
            clientPublicKey: pending.request.clientPublicKey,
            participantId: uuid,
            participant: participant
        )

        guard let encoded = HostMessage.joinApproved(clientId: clientId, approval: approval).encode() else {
            throw RoomError.encodingFailed
        }

        webSocket?.send(string: encoded)

        // Note: state and participant events deferred until confirmation verified
    }

    /// Reject a pending join request (host only)
    func rejectJoin(clientId: String, reason: String = "Rejected by host") {
        lock.lock()
        defer { lock.unlock() }

        guard role == .host else { return }

        pendingJoins.removeValue(forKey: clientId)

        if let encoded = HostMessage.joinRejected(clientId: clientId, reason: reason).encode() {
            webSocket?.send(string: encoded)
        }
    }

    /// Kick a participant (host only)
    /// SECURITY: Triggers immediate rekey so the removed participant cannot decrypt future messages
    func kickParticipant(_ participantId: UUID) {
        var shouldRekey = false

        lock.lock()

        guard role == .host else {
            lock.unlock()
            return
        }

        // Send KICK message to relay if we have the client ID mapping
        if let clientId = participantClientIds[participantId] {
            if let encoded = HostMessage.kick(clientId: clientId).encode() {
                webSocket?.send(string: encoded)
            }
        }

        // Remove participant state
        let clientId = participantClientIds[participantId]
        participants.removeValue(forKey: participantId)
        sessionKeys.removeValue(forKey: participantId)
        participantClientIds.removeValue(forKey: participantId)
        if let cid = clientId {
            clientEphemeralKeys.removeValue(forKey: cid)
            pendingConfirmNonces.removeValue(forKey: cid)
        }
        nonceTracker.removeSender(participantId)

        // Must rekey if there are remaining participants
        shouldRekey = !participants.isEmpty && state == .active

        lock.unlock()

        // Trigger immediate rekey outside of lock so removed participant
        // cannot decrypt any messages sent after this point
        if shouldRekey {
            initiateRekey(reason: "participant_removed")
        }
    }

    // MARK: - Client Operations

    /// Join an existing room as client with invite token
    /// - Parameters:
    ///   - roomIdString: The room ID to join
    ///   - inviteToken: The single-use invite token (required for server validation)
    func joinRoom(roomIdString: String, inviteToken: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard state == .none else {
            throw RoomError.invalidState
        }

        guard !inviteToken.isEmpty else {
            throw RoomError.inviteTokenRequired
        }

        guard KeyGeneration.isValidRoomId(roomIdString) else {
            throw RoomError.invalidRoomId
        }

        guard let roomIdData = KeyGeneration.parseRoomIdFlexible(roomIdString) else {
            throw RoomError.invalidRoomId
        }

        state = .creating
        role = .client
        self.roomIdString = roomIdString
        roomId = roomIdData
        ephemeralKeyPair = KeyGeneration.generateKeyPair()
        // SECURITY: Store token to send in first WebSocket message (not in URL)
        self.pendingInviteToken = inviteToken
        // SECURITY: Check device integrity and escalate protections
        applyDeviceIntegrityProtections()

        // SECURITY: Token removed from URL to prevent relay log exposure.
        // Token will be sent as the first WebSocket message after connection.
        let wsURL = "\(configuration.serverURL)/rooms/\(roomIdString)/join"
        guard let url = URL(string: wsURL) else {
            throw RoomError.invalidServerURL
        }

        #if DEBUG
        logger.info("Joining room with invite token (sent in-band)")
        #endif

        // Create WebSocket with Tor if configured
        let wsConfig = WebSocketConfiguration(url: url, sendHeartbeats: false, useTor: configuration.useTor)
        let ws = WebSocketFactory.createManager(config: wsConfig)

        webSocket = ws
        ws.protocolDelegate = self
        ws.connect()
    }

    /// Join an existing room as client without an invite token
    /// This connects to the room but the client will need to wait for host approval
    /// The host will receive a JOIN_REQUEST and must approve before the room becomes active
    /// - Parameter roomIdString: The room ID to join
    func joinRoomPendingApproval(roomIdString: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard state == .none else {
            throw RoomError.invalidState
        }

        guard KeyGeneration.isValidRoomId(roomIdString) else {
            throw RoomError.invalidRoomId
        }

        guard let roomIdData = KeyGeneration.parseRoomIdFlexible(roomIdString) else {
            throw RoomError.invalidRoomId
        }

        state = .creating
        role = .client
        self.roomIdString = roomIdString
        roomId = roomIdData
        ephemeralKeyPair = KeyGeneration.generateKeyPair()

        // Connect to relay WITHOUT invite token
        // Server will allow connection but client must request approval from host
        let wsURL = "\(configuration.serverURL)/rooms/\(roomIdString)/join"
        guard let url = URL(string: wsURL) else {
            throw RoomError.invalidServerURL
        }

        #if DEBUG
        logger.info("Joining room pending approval (no invite token)")
        #endif

        // Create WebSocket with Tor if configured
        let wsConfig = WebSocketConfiguration(url: url, sendHeartbeats: false, useTor: configuration.useTor)
        let ws = WebSocketFactory.createManager(config: wsConfig)

        webSocket = ws
        ws.protocolDelegate = self
        ws.connect()
    }

    // MARK: - Messaging

    /// Send a text message
    func sendMessage(content: String) throws {
        let message: DecryptedMessage
        let shouldCheckRekey: Bool

        // Hold lock only for state access and crypto operations
        lock.lock()

        guard state == .active,
              let masterKey = masterKey,
              let participantId = participantId else {
            lock.unlock()
            throw RoomError.invalidState
        }

        sequenceNumber += 1
        messagesSinceRekey += 1
        let seq = sequenceNumber
        shouldCheckRekey = role == .host

        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let plaintext = MessageCrypto.encodeTextMessage(text: content, timestamp: timestamp)
        // SECURITY: Per-message key derivation - each message gets a unique key
        // derived from (master key, epoch, sequence). Key is used once then discarded.
        #if DEBUG
        let masterKeyHashSend = masterKey.withUnsafeBytes { ptr -> String in
            let data = Data(ptr)
            return data.prefix(4).map { String(format: "%02x", $0) }.joined()
        }
        print("[DEBUG] sendMessage: epoch=\(currentEpoch), seq=\(seq), role=\(role), masterKeyPrefix=\(masterKeyHashSend)")
        #endif
        let messageKey = KeyExchange.derivePerMessageKey(masterKey: masterKey, epoch: currentEpoch, sequence: seq)

        let encrypted: Data
        do {
            encrypted = try MessageCrypto.encrypt(
                plaintext: plaintext,
                key: messageKey,
                senderId: participantId,
                sequence: seq,
                epoch: currentEpoch
            )
        } catch {
            lock.unlock()
            throw error
        }
        // Per-message key is discarded here (falls out of scope)

        // Send via appropriate message type based on role
        let encoded: String?
        if role == .host {
            encoded = HostMessage.broadcast(payload: encrypted).encode()
        } else {
            encoded = ClientMessage.message(payload: encrypted).encode()
        }

        guard let messageString = encoded else {
            lock.unlock()
            throw RoomError.encodingFailed
        }

        // SECURITY: Timing-obfuscated send to resist traffic correlation
        sendWithTimingJitter(messageString)

        // Create message object while still holding lock (need participantId)
        message = DecryptedMessage.text(
            senderId: participantId,
            content: content,
            sequence: seq
        )

        // Release lock BEFORE calling addMessageToBuffer (which acquires its own lock)
        lock.unlock()

        // Add to our own message buffer (handles its own locking)
        addMessageToBuffer(message)

        // Check if rekey is needed
        if shouldCheckRekey {
            checkRekeyNeeded()
        }
    }

    /// Send an image message
    func sendImage(imageData: Data, mimeType: String) throws {
        // Validate message size before processing
        if imageData.count > Self.maxMessageSize {
            logBuffer.warning("RoomSession", "Image exceeds size limit")
            throw RoomError.messageTooLarge(size: imageData.count, maxSize: Self.maxMessageSize)
        }

        let message: DecryptedMessage
        let shouldCheckRekey: Bool

        // Hold lock only for state access and crypto operations
        lock.lock()

        guard state == .active,
              let masterKey = masterKey,
              let participantId = participantId else {
            lock.unlock()
            throw RoomError.invalidState
        }

        sequenceNumber += 1
        messagesSinceRekey += 1
        let seq = sequenceNumber
        shouldCheckRekey = role == .host

        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let plaintext = MessageCrypto.encodeImageMessage(imageData: imageData, mimeType: mimeType, timestamp: timestamp)
        // SECURITY: Per-message key derivation
        let messageKey = KeyExchange.derivePerMessageKey(masterKey: masterKey, epoch: currentEpoch, sequence: seq)

        let encrypted: Data
        do {
            encrypted = try MessageCrypto.encrypt(
                plaintext: plaintext,
                key: messageKey,
                senderId: participantId,
                sequence: seq,
                epoch: currentEpoch
            )
        } catch {
            lock.unlock()
            throw error
        }

        // Send via appropriate message type based on role
        let encoded: String?
        if role == .host {
            encoded = HostMessage.broadcast(payload: encrypted).encode()
        } else {
            encoded = ClientMessage.message(payload: encrypted).encode()
        }

        guard let messageString = encoded else {
            lock.unlock()
            throw RoomError.encodingFailed
        }

        // SECURITY: Timing-obfuscated send to resist traffic correlation
        sendWithTimingJitter(messageString)

        // Create message object while still holding lock (need participantId)
        message = DecryptedMessage.image(
            senderId: participantId,
            imageData: imageData,
            mimeType: mimeType,
            sequence: seq
        )

        // Release lock BEFORE calling addMessageToBuffer (which acquires its own lock)
        lock.unlock()

        // Add to our own message buffer (handles its own locking)
        addMessageToBuffer(message)

        // Check if rekey is needed
        if shouldCheckRekey {
            checkRekeyNeeded()
        }
    }

    /// Send a video message
    func sendVideo(videoData: Data, mimeType: String, thumbnailData: Data?, duration: Double) throws {
        // Validate message size before processing
        // Account for thumbnail in size calculation
        let totalSize = videoData.count + (thumbnailData?.count ?? 0)
        if totalSize > Self.maxMessageSize {
            logBuffer.warning("RoomSession", "Video exceeds size limit")
            throw RoomError.messageTooLarge(size: totalSize, maxSize: Self.maxMessageSize)
        }

        let message: DecryptedMessage
        let shouldCheckRekey: Bool

        // Hold lock only for state access and crypto operations
        lock.lock()

        guard state == .active,
              let masterKey = masterKey,
              let participantId = participantId else {
            lock.unlock()
            throw RoomError.invalidState
        }

        sequenceNumber += 1
        messagesSinceRekey += 1
        let seq = sequenceNumber
        shouldCheckRekey = role == .host

        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let plaintext = MessageCrypto.encodeVideoMessage(
            videoData: videoData,
            mimeType: mimeType,
            thumbnailData: thumbnailData,
            duration: duration,
            timestamp: timestamp
        )
        // SECURITY: Per-message key derivation
        let messageKey = KeyExchange.derivePerMessageKey(masterKey: masterKey, epoch: currentEpoch, sequence: seq)

        let encrypted: Data
        do {
            encrypted = try MessageCrypto.encrypt(
                plaintext: plaintext,
                key: messageKey,
                senderId: participantId,
                sequence: seq,
                epoch: currentEpoch
            )
        } catch {
            lock.unlock()
            throw error
        }

        // Send via appropriate message type based on role
        let encoded: String?
        if role == .host {
            encoded = HostMessage.broadcast(payload: encrypted).encode()
        } else {
            encoded = ClientMessage.message(payload: encrypted).encode()
        }

        guard let messageString = encoded else {
            lock.unlock()
            throw RoomError.encodingFailed
        }

        // SECURITY: Timing-obfuscated send to resist traffic correlation
        sendWithTimingJitter(messageString)

        // Create message object while still holding lock (need participantId)
        message = DecryptedMessage.video(
            senderId: participantId,
            videoData: videoData,
            mimeType: mimeType,
            thumbnail: thumbnailData,
            duration: duration,
            sequence: seq
        )

        // Release lock BEFORE calling addMessageToBuffer (which acquires its own lock)
        lock.unlock()

        // Add to our own message buffer (handles its own locking)
        addMessageToBuffer(message)

        // Check if rekey is needed
        if shouldCheckRekey {
            checkRekeyNeeded()
        }
    }

    // MARK: - Timing Obfuscation

    /// Send a message with random timing jitter to resist traffic analysis
    /// SECURITY: Adds 0-300ms random delay to prevent timing correlation attacks.
    /// Uses Int.random(in:) for unbiased generation (no modulo bias).
    private func sendWithTimingJitter(_ messageString: String) {
        let delayMs = Double(Int.random(in: 0..<300))

        sendQueue.asyncAfter(deadline: .now() + delayMs / 1000.0) { [weak self] in
            #if DEBUG
            // DIAGNOSTIC: Log message sends to isolate delivery failures
            let truncated = messageString.prefix(100)
            print("[DEBUG] sendWithTimingJitter: sending \(messageString.count) bytes - \(truncated)...")
            #endif
            self?.webSocket?.send(string: messageString)
        }
    }

    // MARK: - Rekeying

    /// Initiate a rekey (host only) — per-client DH, no broadcast path.
    ///
    /// SECURITY: Forward secrecy guarantee:
    ///   1. Host generates a fresh X25519 ephemeral per rekey.
    ///   2. For each client, host performs DH(hostEphemeral, clientCurrentPublic).
    ///   3. Each client receives a uniquely wrapped copy of the new master key
    ///      via an encrypted DIRECT message (relay sees opaque binary).
    ///   4. Compromise of old master key + relay logs does NOT reveal future epochs
    ///      because the DH shared secret is unknown to the attacker.
    func initiateRekey(reason: String) {
        var newEpoch: UInt32 = 0
        var shouldNotifyStarted = false
        var shouldNotifyCompleted = false

        lock.lock()

        guard role == .host, state == .active,
              let oldMasterKey = masterKey,
              let roomId = roomId else {
            lock.unlock()
            return
        }

        // Snapshot current clients and their ephemeral keys
        let clientSnapshot: [(relayClientId: String, publicKey: Curve25519.KeyAgreement.PublicKey)] =
            clientEphemeralKeys.compactMap { (relayId, pubKey) in
                return (relayClientId: relayId, publicKey: pubKey)
            }

        guard !clientSnapshot.isEmpty else {
            // No clients to rekey with — nothing to do
            lock.unlock()
            return
        }

        do {
            let newMasterKey = try KeyGeneration.generateMasterKey()

            // Generate ONE fresh host ephemeral per rekey (shared across all clients for this epoch)
            let hostEphemeral = KeyGeneration.generateKeyPair()

            state = .rekeying
            shouldNotifyStarted = true

            // Send per-client rekey payloads via DIRECT messages
            for client in clientSnapshot {
                let payload = try HandshakeEngine.createPerClientRekeyPayload(
                    oldMasterKey: oldMasterKey,
                    newMasterKey: newMasterKey,
                    currentEpoch: currentEpoch,
                    hostEphemeralPrivateKey: hostEphemeral,
                    clientPublicKey: client.publicKey,
                    roomId: roomId
                )

                // SECURITY: Track the confirmNonce + host ephemeral so we can verify the client's HMAC later
                pendingConfirmNonces[client.relayClientId] = (
                    nonce: payload.confirmNonce,
                    epoch: currentEpoch + 1,
                    hostEphemeralPub: hostEphemeral.publicKey.rawRepresentation
                )

                // Encode the payload as encrypted binary (relay sees opaque base64)
                let payloadData = try JSONEncoder().encode(payload)

                // Encrypt the JSON payload using the current epoch's message key
                // so the relay cannot parse it even as JSON
                let messageKey = KeyExchange.deriveMessageKey(masterKey: oldMasterKey, epoch: currentEpoch)
                let encNonce = try MessageCrypto.generateRandomNonce()
                let sealed = try ChaChaPoly.seal(
                    payloadData,
                    using: messageKey,
                    nonce: ChaChaPoly.Nonce(data: encNonce)
                )
                // Frame: nonce(12) + ciphertext + tag(16)
                var encryptedFrame = encNonce
                encryptedFrame.append(sealed.ciphertext)
                encryptedFrame.append(sealed.tag)

                if let encoded = HostMessage.rekeyDirect(
                    clientId: client.relayClientId,
                    encryptedPayload: encryptedFrame
                ).encode() {
                    webSocket?.send(string: encoded)
                }
            }

            // Update local state
            oldMasterKey.wipe()
            masterKey = newMasterKey
            currentEpoch += 1
            newEpoch = currentEpoch
            nonceTracker.wipe()
            messagesSinceRekey = 0
            lastRekeyTime = Date()

            state = .active
            shouldNotifyCompleted = true

        } catch {
            logBuffer.error("RoomSession", "Rekey failed")
            // Rekey failed, continue with old key
            if state == .rekeying {
                state = .active
            }
        }

        lock.unlock()

        if shouldNotifyStarted {
            delegate?.roomSession(self, didReceiveEvent: .rekeyStarted(reason: reason))
        }
        if shouldNotifyCompleted {
            delegate?.roomSession(self, didReceiveEvent: .rekeyCompleted(newEpoch: newEpoch))
        }
    }

    private func checkRekeyNeeded() {
        guard role == .host else { return }

        let needsRekey: Bool

        if configuration.rekeyMessageCount > 0 && messagesSinceRekey >= configuration.rekeyMessageCount {
            needsRekey = true
        } else if configuration.rekeyIntervalSeconds > 0,
                  let lastRekey = lastRekeyTime,
                  Date().timeIntervalSince(lastRekey) >= configuration.rekeyIntervalSeconds {
            needsRekey = true
        } else {
            needsRekey = false
        }

        if needsRekey {
            initiateRekey(reason: "periodic")
        }
    }

    // MARK: - Destruction

    /// Close the room and wipe all state
    func closeRoom(reason: DestructionReason = .hostClosed) {
        lock.lock()

        guard state != .destroyed(reason: reason) else {
            lock.unlock()
            return
        }

        // Notify server if voluntary close
        if reason == .hostClosed || reason == .userExit {
            if let encoded = HostMessage.roomClose.encode() {
                webSocket?.send(string: encoded)
            }
        }

        // Stop expiry timer
        messageExpiryTimer?.invalidate()
        messageExpiryTimer = nil

        // Disconnect
        webSocket?.disconnect()
        webSocket = nil

        // Wipe all cryptographic material
        wipeAllKeys()

        // Clear message buffer
        messageBuffer.removeAll()
        messageBufferBytes = 0

        // Clear participants
        participants.removeAll()
        sessionKeys.removeAll()
        pendingJoins.removeAll()
        pendingConfirmations.removeAll()

        // Update state
        state = .destroyed(reason: reason)

        // Release lock BEFORE delegate callbacks to prevent deadlock
        lock.unlock()

        // Notify delegate outside of lock
        delegate?.roomSession(self, didChangeState: state)
        delegate?.roomSession(self, didReceiveEvent: .destroyed(reason: reason))
    }

    /// Quick exit - synchronous, immediate cleanup
    func quickExit() {
        closeRoom(reason: .userExit)

        // Clear clipboard
        UIPasteboard.general.items = []
    }

    /// Wipe all cryptographic material
    private func wipeAllKeys() {
        masterKey?.wipe()
        masterKey = nil
        ephemeralKeyPair = nil
        sessionKeys.removeAll()
        participantClientIds.removeAll()
        clientEphemeralKeys.removeAll()
        pendingConfirmNonces.removeAll()
        nonceTracker.wipe()
        sequenceNumber = 0
        currentEpoch = 0
        pendingInviteToken = nil
    }

    // MARK: - Message Buffer

    /// Add message to buffer - MUST be called on main thread
    /// Note: This method handles its own locking and releases the lock before delegate callbacks
    private func addMessageToBuffer(_ message: DecryptedMessage) {
        #if DEBUG
        print("[DEBUG] addMessageToBuffer: \(message)")
        #endif
        var shouldCloseRoom = false

        // Lock only for buffer operations
        lock.lock()

        // Estimate message size for memory budget
        let messageSize = estimateMessageSize(message)
        messageBufferBytes += messageSize
        messageBuffer.append(message)

        // Update capacity monitor
        capacityMonitor.updateMessageBuffer(bytes: messageBufferBytes, count: messageBuffer.count)

        // Log capacity events at warning level
        let snapshot = capacityMonitor.getCurrentSnapshot()
        if snapshot.bufferLevel >= .warning {
            logBuffer.logCapacityEvent(snapshot.bufferLevel)
        }

        // SECURITY: Enforce both count AND memory limits to prevent DoS
        // Remove oldest messages until we're under both limits
        while messageBuffer.count > configuration.maxMessageBuffer || messageBufferBytes > maxMessageBufferBytes {
            guard let removed = messageBuffer.first else { break }
            messageBuffer.removeFirst()
            messageBufferBytes -= estimateMessageSize(removed)
        }

        // Ensure messageBufferBytes doesn't go negative due to estimation errors
        if messageBufferBytes < 0 {
            messageBufferBytes = 0
        }

        // Check if capacity exceeded - close gracefully instead of crashing
        if snapshot.overallLevel == .exceeded {
            logBuffer.critical("RoomSession", "Capacity exceeded, closing room gracefully")
            shouldCloseRoom = true
        }

        // IMPORTANT: Release lock BEFORE delegate callbacks to prevent deadlock
        lock.unlock()

        if shouldCloseRoom {
            DispatchQueue.main.async { [weak self] in
                self?.closeRoom(reason: .capacityExceeded)
            }
            return
        }

        // Delegate callback is called WITHOUT holding the lock
        #if DEBUG
        print("[DEBUG] Calling delegate?.roomSession(didReceiveMessage:) - delegate is \(delegate == nil ? "nil" : "set")")
        #endif
        delegate?.roomSession(self, didReceiveMessage: message)
    }

    /// Evict oldest messages to free memory
    /// - Parameter count: Number of messages to evict
    private func evictOldMessages(count: Int) {
        guard count > 0, !messageBuffer.isEmpty else { return }

        let actualCount = min(count, messageBuffer.count)
        logBuffer.info("RoomSession", "Evicting old messages for memory management")

        for _ in 0..<actualCount {
            guard let removed = messageBuffer.first else { break }
            messageBuffer.removeFirst()
            messageBufferBytes -= estimateMessageSize(removed)
        }

        if messageBufferBytes < 0 {
            messageBufferBytes = 0
        }

        // Update capacity monitor after eviction
        capacityMonitor.updateMessageBuffer(bytes: messageBufferBytes, count: messageBuffer.count)
    }

    /// Estimate the memory size of a message in bytes
    private func estimateMessageSize(_ message: DecryptedMessage) -> Int {
        var size = 100 // Base overhead for struct, UUID, Date, etc.
        size += message.content.utf8.count

        switch message.contentType {
        case .text(let text):
            size += text.utf8.count
        case .image(let data, let mimeType):
            size += data.count + mimeType.utf8.count
        case .video(let data, let mimeType, let thumbnail, _):
            size += data.count + mimeType.utf8.count
            size += thumbnail?.count ?? 0
        case .system(let text):
            size += text.utf8.count
        }

        return size
    }

    /// Get current messages (copy)
    var messages: [DecryptedMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messageBuffer
    }

    /// Clear all messages
    func clearMessages() {
        lock.lock()
        defer { lock.unlock() }
        messageBuffer.removeAll()
        messageBufferBytes = 0
    }

    // MARK: - Security Events

    /// Handle a security event
    func handleSecurityEvent(_ event: SecurityEventType) {
        delegate?.roomSession(self, didReceiveEvent: .securityEvent(event: event))

        switch event {
        case .screenshotDetected:
            if configuration.rekeyOnScreenshot && role == .host {
                initiateRekey(reason: "screenshot_detected")
            }

        case .screenRecordingStarted:
            if configuration.rekeyOnRecording && role == .host {
                initiateRekey(reason: "screen_recording_detected")
            }

        case .backgrounded:
            // In high security mode, destroy room on background
            if configuration.highSecurityMode {
                closeRoom(reason: .backgrounded)
            }

        case .deviceLocked:
            closeRoom(reason: .deviceLocked)

        case .screenRecordingStopped:
            // Recording stopped, no action needed
            break
        }
    }
}

// MARK: - WebSocket Delegate

extension RoomSession: WebSocketProtocolDelegate {

    func webSocketDidConnect(_ manager: WebSocketManagerProtocol) {
        // Connection established, waiting for server messages
        #if DEBUG
        logger.info("WebSocket connected")
        #endif

        // SECURITY: Send invite token in-band (first message) rather than in URL
        // This prevents token exposure in relay access logs and proxy caches
        if let token = pendingInviteToken {
            if let tokenData = try? JSONSerialization.data(withJSONObject: ["type": "AUTH", "token": token]),
               let tokenString = String(data: tokenData, encoding: .utf8) {
                manager.send(string: tokenString)
            }
            pendingInviteToken = nil // Wipe after sending
        }
    }

    func webSocketDidDisconnect(_ manager: WebSocketManagerProtocol, error: Error?) {
        #if DEBUG
        if let error = error {
            logger.error("WebSocket disconnected with error: \(error.localizedDescription)")
        } else {
            logger.info("WebSocket disconnected without error")
        }
        #endif

        let reason: DestructionReason
        if error != nil {
            reason = .networkError
        } else {
            reason = .hostDisconnected
        }

        if state != .destroyed(reason: reason) {
            closeRoom(reason: reason)
        }
    }

    func webSocket(_ manager: WebSocketManagerProtocol, didReceiveMessage data: Data) {
        // Binary messages not expected from relay
    }

    func webSocket(_ manager: WebSocketManagerProtocol, didReceiveString string: String) {
        #if DEBUG
        // DIAGNOSTIC: Log all received messages to isolate delivery failures
        let truncated = string.prefix(100)
        print("[DEBUG] webSocket didReceiveString: \(string.count) bytes - \(truncated)...")
        #endif

        guard let message = MessageParser.parse(string) else {
            #if DEBUG
            print("[DEBUG] MessageParser.parse() returned nil for message")
            #endif
            return
        }

        #if DEBUG
        print("[DEBUG] Parsed message type: \(message)")
        #endif

        // Process message - each case handles its own locking to avoid holding lock during delegate callbacks
        switch message {
        case .roomCreated(let roomId):
            handleRoomCreated(roomId: roomId)

        case .connected(let clientId):
            handleConnected(clientId: clientId)

        case .joinRequest(let clientId, let request):
            handleJoinRequest(clientId: clientId, request: request)

        case .joinResponse(let approval, let rejection):
            handleJoinResponse(approval: approval, rejection: rejection)

        case .joinConfirm(let clientId, let confirmation):
            handleJoinConfirm(clientId: clientId, confirmation: confirmation)

        // SECURITY: .rekeyConfirm removed from wire protocol.
        // Confirmations are now received as encrypted MESSAGE frames
        // and handled inside processEncryptedMessage → handleEncryptedRekeyConfirm.

        case .message(let senderId, let payload):
            processEncryptedMessage(payload: payload, senderClientId: senderId)

        case .clientMessage(let clientId, let payload):
            processEncryptedMessage(payload: payload, senderClientId: clientId)

        case .clientLeft(let clientId):
            handleClientLeft(clientId: clientId)

        case .roomDestroyed(let reason):
            let destructionReason = DestructionReason(rawValue: reason) ?? .hostDisconnected
            closeRoom(reason: destructionReason)

        case .kicked(let reason):
            closeRoom(reason: .kicked)

        case .heartbeatAck:
            webSocket?.receivedHeartbeatAck()

        case .error(let errorMessage):
            handleServerError(errorMessage)

        case .unknown:
            break
        }
    }

    private func handleServerError(_ errorMessage: String) {
        logBuffer.error("RoomSession", "Server error")

        // Handle specific error cases
        if errorMessage.lowercased().contains("room already exists") {
            // Host tried to reconnect but room still exists on server
            // This is a race condition - the old connection hasn't been cleaned up yet
            // Don't close the room - notify delegate to show error and let user decide
            logBuffer.warning("RoomSession", "Room already exists on server - server needs time to clean up old connection")

            // Notify delegate about the error - the WebSocket will keep trying to reconnect
            delegate?.roomSession(self, didReceiveEvent: .error(message: "Connection interrupted. Reconnecting..."))

            // Note: The TorWebSocketAdapter will continue its reconnection attempts with exponential backoff
            // The server should clean up the old room after its own timeout (typically 30-60 seconds)
            // If all reconnection attempts fail, the WebSocket will notify us via webSocketDidDisconnect
        } else if errorMessage.lowercased().contains("room not found") {
            // Room was destroyed while we were trying to reconnect
            closeRoom(reason: .hostDisconnected)
        } else {
            // Generic error - notify delegate
            delegate?.roomSession(self, didReceiveEvent: .error(message: errorMessage))
        }
    }

    // MARK: - Message Handlers (lock-safe)

    private func handleRoomCreated(roomId: String) {
        var shouldNotify = false
        var newState: RoomState?

        lock.lock()
        if role == .host {
            roomIdString = roomId
            state = .created(roomId: roomId)
            newState = state
            shouldNotify = true
        }
        lock.unlock()

        if shouldNotify, let newState = newState {
            delegate?.roomSession(self, didChangeState: newState)
            delegate?.roomSession(self, didReceiveEvent: .created(roomId: roomId))
        }
    }

    private func handleConnected(clientId: String?) {
        lock.lock()
        guard role == .client, let keyPair = ephemeralKeyPair else {
            lock.unlock()
            return
        }

        #if DEBUG
        logger.info("Client connected - sending join request")
        #endif

        do {
            // Create and send join request (host must approve for key exchange)
            let request = try HandshakeEngine.createJoinRequest(clientKeyPair: keyPair)
            if let encoded = ClientMessage.joinRequest(request: request).encode() {
                webSocket?.send(string: encoded)
            }
            lock.unlock()
        } catch {
            lock.unlock()
            closeRoom(reason: .networkError)
        }
    }

    private func handleJoinRequest(clientId: String, request: JoinRequest) {
        var pending: PendingJoinRequest?

        lock.lock()
        if role == .host {
            pending = PendingJoinRequest(
                clientId: clientId,
                request: request,
                receivedAt: Date()
            )
            pendingJoins[clientId] = pending
        }
        lock.unlock()

        if let pending = pending {
            delegate?.roomSession(self, didReceiveJoinRequest: pending)
            delegate?.roomSession(self, didReceiveEvent: .joinRequested(
                clientId: clientId,
                displayName: request.displayName
            ))
        }
    }

    private func handleJoinResponse(approval: JoinApproval?, rejection: JoinRejection?) {
        lock.lock()
        guard role == .client else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let approval = approval {
            processJoinApproval(approval)
        } else if let rejection = rejection {
            delegate?.roomSession(self, didReceiveEvent: .joinRejected(reason: rejection.reason))
            closeRoom(reason: .joinRejected)
        }
    }

    private func handleClientLeft(clientId: String) {
        var shouldRekey = false

        lock.lock()

        guard role == .host else {
            lock.unlock()
            return
        }

        // Find participant by client ID using reverse mapping
        let participantId = participantClientIds.first(where: { $0.value == clientId })?.key

        if let pid = participantId {
            participants.removeValue(forKey: pid)
            sessionKeys.removeValue(forKey: pid)
            participantClientIds.removeValue(forKey: pid)
            clientEphemeralKeys.removeValue(forKey: clientId)
            pendingConfirmNonces.removeValue(forKey: clientId)
            nonceTracker.removeSender(pid)

            // Must rekey if there are remaining participants
            shouldRekey = !participants.isEmpty && state == .active
        }

        lock.unlock()

        if let pid = participantId {
            delegate?.roomSession(self, didReceiveEvent: .participantLeft(participantId: pid))
        }

        // SECURITY: Rekey so departed participant cannot decrypt future messages
        if shouldRekey {
            initiateRekey(reason: "participant_left")
        }
    }

    private func handleJoinConfirm(clientId: String, confirmation: JoinConfirmation) {
        var participant: Participant?
        var shouldNotifyStateChange = false
        var newState: RoomState?

        lock.lock()
        guard role == .host else {
            lock.unlock()
            return
        }

        // Verify the confirmation proof
        guard let pendingData = pendingConfirmations.removeValue(forKey: clientId),
              let hostKeyPair = ephemeralKeyPair else {
            // Unknown client or missing host key - potential attack, ignore
            lock.unlock()
            logBuffer.warning("RoomSession", "Join confirmation from unknown client")
            return
        }

        // Verify the HMAC proof using the session key
        let isValid = HandshakeEngine.verifyConfirmation(
            confirmation: confirmation,
            sessionKey: pendingData.sessionKey,
            clientPublicKey: pendingData.clientPublicKey,
            hostPublicKey: hostKeyPair.publicKey.rawRepresentation
        )

        if isValid {
            // SECURITY: Only NOW add participant after successful verification
            participants[pendingData.participantId] = pendingData.participant
            sessionKeys[pendingData.participantId] = pendingData.sessionKey
            participantClientIds[pendingData.participantId] = clientId
            participant = pendingData.participant

            // Track client's current ephemeral public key for per-client DH rekey
            if let clientPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pendingData.clientPublicKey) {
                clientEphemeralKeys[clientId] = clientPub
            }

            if state == .open {
                state = .active
                newState = state
                shouldNotifyStateChange = true
            }
        } else {
            // Invalid confirmation - potential attack
            logBuffer.warning("RoomSession", "Invalid join confirmation received")
        }
        lock.unlock()

        // Notify delegate outside of lock
        if shouldNotifyStateChange, let newState = newState {
            delegate?.roomSession(self, didChangeState: newState)
        }
        if let participant = participant {
            delegate?.roomSession(self, didReceiveEvent: .participantJoined(participant: participant))
        }
    }

    /// Handle HMAC-authenticated rekey confirmation from client (host side).
    /// SECURITY: Verifies HMAC before accepting the client's new ephemeral public key.
    /// Relay cannot forge this because it does not know the new master key.
    private func handleEncryptedRekeyConfirm(plaintext: Data, senderClientId: String?) {
        guard let clientId = senderClientId else {
            logBuffer.warning("RoomSession", "Rekey confirmation without client ID")
            return
        }

        // Strip content type byte (0x05) to get the JSON payload
        guard plaintext.count > 1 else {
            logBuffer.warning("RoomSession", "Rekey confirmation payload too short")
            return
        }
        let confirmJSON = plaintext.subdata(in: 1..<plaintext.count)

        guard let confirmation = try? JSONDecoder().decode(RekeyConfirmation.self, from: confirmJSON) else {
            logBuffer.warning("RoomSession", "Failed to decode rekey confirmation")
            return
        }

        lock.lock()
        guard role == .host else {
            lock.unlock()
            return
        }

        // SECURITY: Verify pending confirmNonce matches
        guard let pending = pendingConfirmNonces[clientId] else {
            lock.unlock()
            logBuffer.warning("RoomSession", "No pending confirm nonce for client")
            return
        }

        guard pending.epoch == confirmation.epoch,
              pending.nonce == confirmation.confirmNonce else {
            lock.unlock()
            logBuffer.warning("RoomSession", "Confirm nonce/epoch mismatch — potential forgery")
            return
        }

        guard let masterKey = masterKey, let roomId = roomId else {
            lock.unlock()
            return
        }

        // Derive the confirm key (same derivation as client side)
        let confirmKey = KeyExchange.deriveConfirmKey(
            masterKey: masterKey,
            epoch: confirmation.epoch,
            confirmNonce: confirmation.confirmNonce
        )

        // Rebuild the HMAC message: epoch || newPublicKey || confirmNonce || hostEphemeralPublicKey || roomId
        var hmacMessage = Data()
        var epochBE = confirmation.epoch.bigEndian
        hmacMessage.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })
        hmacMessage.append(confirmation.newPublicKey)
        hmacMessage.append(confirmation.confirmNonce)
        hmacMessage.append(pending.hostEphemeralPub)
        hmacMessage.append(roomId)

        // SECURITY: Verify HMAC — this proves the confirmation came from a participant
        // who knows the new master key (which the relay does not)
        let isValid = HMAC<SHA256>.isValidAuthenticationCode(
            confirmation.mac,
            authenticating: hmacMessage,
            using: confirmKey
        )

        guard isValid else {
            pendingConfirmNonces.removeValue(forKey: clientId)
            lock.unlock()
            logBuffer.warning("RoomSession", "HMAC verification FAILED for rekey confirmation — forgery detected")
            return
        }

        // HMAC valid — accept the new ephemeral public key
        pendingConfirmNonces.removeValue(forKey: clientId)

        if confirmation.newPublicKey.count == 32,
           let newPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: confirmation.newPublicKey) {
            clientEphemeralKeys[clientId] = newPub
            logBuffer.logCryptoEvent("Key rotation verified")
        } else {
            logBuffer.warning("RoomSession", "Invalid rekey confirmation public key")
        }
        lock.unlock()
    }

    private func processJoinApproval(_ approval: JoinApproval) {
        var newClientId: UUID?
        var shouldNotify = false

        lock.lock()
        guard role == .client,
              let keyPair = ephemeralKeyPair,
              let roomId = roomId else {
            lock.unlock()
            return
        }

        do {
            let (newMasterKey, sessionKey, clientId) = try HandshakeEngine.processJoinApproval(
                approval: approval,
                clientPrivateKey: keyPair,
                roomId: roomId
            )

            #if DEBUG
            let clientMasterKeyHash = newMasterKey.withUnsafeBytes { ptr -> String in
                let data = Data(ptr)
                return data.prefix(4).map { String(format: "%02x", $0) }.joined()
            }
            let roomIdHash = roomId.prefix(4).map { String(format: "%02x", $0) }.joined()
            print("[DEBUG] CLIENT processJoinApproval: epoch=\(approval.epoch), masterKeyPrefix=\(clientMasterKeyHash), roomIdPrefix=\(roomIdHash), roomIdString=\(self.roomIdString ?? "nil") (len=\(self.roomIdString?.count ?? 0))")
            #endif

            masterKey = newMasterKey
            participantId = clientId
            currentEpoch = approval.epoch
            newClientId = clientId

            // Send confirmation
            let confirmation = HandshakeEngine.generateConfirmation(
                sessionKey: sessionKey,
                clientPublicKey: keyPair.publicKey.rawRepresentation,
                hostPublicKey: approval.hostPublicKey
            )

            if let encoded = ClientMessage.joinConfirm(confirmation: confirmation).encode() {
                webSocket?.send(string: encoded)
            }

            state = .active
            shouldNotify = true
            lock.unlock()

        } catch {
            lock.unlock()
            closeRoom(reason: .networkError)
            return
        }

        // Notify delegate outside of lock
        if shouldNotify, let clientId = newClientId {
            delegate?.roomSession(self, didChangeState: .active)
            delegate?.roomSession(self, didReceiveEvent: .joinApproved(participantId: clientId))
        }
    }

    private func processEncryptedMessage(payload: Data, senderClientId: String?) {
        #if DEBUG
        print("[DEBUG] processEncryptedMessage: payload=\(payload.count) bytes, senderClientId=\(senderClientId ?? "nil")")
        #endif
        logBuffer.debug("RoomSession", "Received encrypted message")

        // SECURITY FIX: Derive per-message key synchronously under the lock.
        // Capture only the derived SymmetricKey (value type) into the async closure,
        // NOT the SecureBytes masterKey. This prevents a race where closeRoom() wipes
        // the masterKey while the cryptoQueue closure still holds a reference to it.
        lock.lock()
        guard let masterKey = masterKey else {
            lock.unlock()
            #if DEBUG
            print("[DEBUG] processEncryptedMessage: FAIL - no masterKey")
            #endif
            logBuffer.error("RoomSession", "No master key for decryption")
            return
        }

        guard payload.count >= MessageCrypto.minimumFrameSize else {
            lock.unlock()
            logBuffer.error("RoomSession", "Frame too short for decryption")
            return
        }

        let frameEpoch = payload.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let frameSequence = payload.subdata(in: 5..<13).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }

        #if DEBUG
        // DIAGNOSTIC: Log key derivation parameters to debug crypto mismatch
        let masterKeyHash = masterKey.withUnsafeBytes { ptr -> String in
            let data = Data(ptr)
            return data.prefix(4).map { String(format: "%02x", $0) }.joined()
        }
        print("[DEBUG] Key derivation: frameEpoch=\(frameEpoch), frameSequence=\(frameSequence), currentEpoch=\(currentEpoch), masterKeyPrefix=\(masterKeyHash)")
        #endif

        // Derive per-message key NOW, under the lock, while masterKey is valid
        let messageKey = KeyExchange.derivePerMessageKey(masterKey: masterKey, epoch: frameEpoch, sequence: frameSequence)
        let myParticipantId = participantId

        // Also derive the message-level key for potential rekey payload decryption
        let epochMessageKey = KeyExchange.deriveMessageKey(masterKey: masterKey, epoch: currentEpoch)
        let currentRoomId = roomId
        let currentEphemeralKeyPair = ephemeralKeyPair
        let epoch = currentEpoch
        lock.unlock()

        // Run crypto operations on background queue — only SymmetricKey (value type) captured
        cryptoQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                let decrypted = try MessageCrypto.decrypt(frame: payload, key: messageKey)

                #if DEBUG
                print("[DEBUG] Decryption SUCCESS: senderId=\(decrypted.senderId), seq=\(decrypted.sequence), epoch=\(decrypted.epoch)")
                #endif
                self.logBuffer.logCryptoEvent("Decryption successful")

                // Reset failure counter on success
                self.lock.lock()
                self.consecutiveCryptoFailures = 0
                self.lock.unlock()

                // Replay protection
                self.lock.lock()
                let isValid = self.nonceTracker.validateAndMark(
                    nonce: decrypted.nonce,
                    senderId: decrypted.senderId,
                    sequence: decrypted.sequence
                )
                self.lock.unlock()

                guard isValid else {
                    #if DEBUG
                    print("[DEBUG] Replay detected, dropping message")
                    #endif
                    self.logBuffer.warning("RoomSession", "Replay detected, dropping message")
                    return
                }

                // Don't display our own messages
                if decrypted.senderId == myParticipantId {
                    #if DEBUG
                    print("[DEBUG] Dropping own message (senderId matches myParticipantId)")
                    #endif
                    return
                }

                guard let contentType = MessageCrypto.detectContentType(decrypted.plaintext) else {
                    #if DEBUG
                    print("[DEBUG] Could not detect content type from plaintext")
                    #endif
                    return
                }
                #if DEBUG
                print("[DEBUG] Content type: \(contentType)")
                #endif

                // SECURITY: Handle encrypted rekey confirmations (host side)
                if contentType == .rekeyConfirm {
                    self.handleEncryptedRekeyConfirm(
                        plaintext: decrypted.plaintext,
                        senderClientId: senderClientId
                    )
                    return
                }

                let message: DecryptedMessage?

                switch contentType {
                case .text:
                    if let (text, _) = MessageCrypto.decodeTextMessage(decrypted.plaintext) {
                        message = DecryptedMessage.text(
                            senderId: decrypted.senderId,
                            content: text,
                            sequence: decrypted.sequence
                        )
                    } else {
                        message = nil
                    }

                case .image:
                    if let (imageData, mimeType, _) = MessageCrypto.decodeImageMessage(decrypted.plaintext) {
                        message = DecryptedMessage.image(
                            senderId: decrypted.senderId,
                            imageData: imageData,
                            mimeType: mimeType,
                            sequence: decrypted.sequence
                        )
                    } else {
                        message = nil
                    }

                case .video:
                    if let (videoData, mimeType, thumbnail, duration, _) = MessageCrypto.decodeVideoMessage(decrypted.plaintext) {
                        message = DecryptedMessage.video(
                            senderId: decrypted.senderId,
                            videoData: videoData,
                            mimeType: mimeType,
                            thumbnail: thumbnail,
                            duration: duration,
                            sequence: decrypted.sequence
                        )
                    } else {
                        message = nil
                    }

                case .system:
                    message = nil

                case .rekeyConfirm:
                    // Rekey confirmations are handled separately via handleEncryptedRekeyConfirm
                    // If we reach here, it means a confirmation was decrypted as a regular message
                    // which shouldn't happen. Ignore it.
                    message = nil
                }

                if let msg = message {
                    DispatchQueue.main.async { [weak self] in
                        self?.addMessageToBuffer(msg)
                    }
                }

            } catch {
                #if DEBUG
                print("[DEBUG] Decryption FAILED: \(error)")
                #endif
                // Decryption failed — check if this is an encrypted rekey payload (client-side)
                self.lock.lock()
                let isClient = self.role == .client
                self.lock.unlock()

                if isClient, let roomId = currentRoomId, let keyPair = currentEphemeralKeyPair {
                    #if DEBUG
                    print("[DEBUG] Trying to decrypt as rekey payload (client-side)")
                    #endif
                    // Try to decrypt as an encrypted rekey payload
                    self.tryProcessEncryptedRekey(
                        encryptedFrame: payload,
                        epochMessageKey: epochMessageKey,
                        clientPrivateKey: keyPair,
                        roomId: roomId,
                        currentEpoch: epoch
                    )
                    return
                }

                self.logBuffer.error("RoomSession", "Decryption failed")

                // Circuit breaker
                self.lock.lock()
                self.consecutiveCryptoFailures += 1
                let failures = self.consecutiveCryptoFailures
                self.lock.unlock()

                if failures >= self.maxConsecutiveCryptoFailures {
                    self.logBuffer.critical("RoomSession", "Too many crypto failures, closing room")
                    DispatchQueue.main.async { [weak self] in
                        self?.closeRoom(reason: .cryptoFailure)
                    }
                }
            }
        }
    }

    /// Try to process an encrypted rekey payload received as a DIRECT message (client side).
    /// The payload is encrypted with the current epoch's message key, then contains a
    /// JSON-encoded PerClientRekeyPayload inside.
    private func tryProcessEncryptedRekey(
        encryptedFrame: Data,
        epochMessageKey: SymmetricKey,
        clientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        roomId: Data,
        currentEpoch: UInt32
    ) {
        // Frame format: nonce(12) + ciphertext + tag(16)
        guard encryptedFrame.count >= 28 else { return } // 12 + 0 + 16 minimum

        let nonce = encryptedFrame.subdata(in: 0..<12)
        let ciphertextAndTag = encryptedFrame.subdata(in: 12..<encryptedFrame.count)
        guard ciphertextAndTag.count >= 16 else { return }
        let ciphertext = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)

        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let payloadData = try ChaChaPoly.open(sealedBox, using: epochMessageKey)

            // Parse the rekey payload
            let rekeyPayload = try JSONDecoder().decode(PerClientRekeyPayload.self, from: payloadData)

            // Get current master key under lock for unwrapping
            lock.lock()
            guard let currentMasterKey = masterKey else {
                lock.unlock()
                return
            }

            let newMasterKey = try HandshakeEngine.processPerClientRekeyPayload(
                payload: rekeyPayload,
                currentMasterKey: currentMasterKey,
                currentEpoch: self.currentEpoch,
                clientPrivateKey: clientPrivateKey,
                roomId: roomId
            )

            // Apply new epoch
            currentMasterKey.wipe()
            masterKey = newMasterKey
            self.currentEpoch = rekeyPayload.newEpoch
            nonceTracker.wipe()
            messagesSinceRekey = 0
            lastRekeyTime = Date()

            // SECURITY: Rotate client ephemeral key pair for next rekey
            let newKeyPair = KeyGeneration.generateKeyPair()
            ephemeralKeyPair = newKeyPair

            let newEpoch = self.currentEpoch
            let capturedMasterKey = masterKey
            let capturedParticipantId = participantId
            lock.unlock()

            // SECURITY: Send rekey confirmation as an encrypted MESSAGE frame.
            // This makes it indistinguishable from normal messages at the relay level
            // and HMAC-authenticates the newPublicKey so the relay cannot forge it.
            if let newMK = capturedMasterKey,
               let pid = capturedParticipantId {
                let rid = roomId
                // Derive confirm key from new master key + confirmNonce
                let confirmKey = KeyExchange.deriveConfirmKey(
                    masterKey: newMK,
                    epoch: newEpoch,
                    confirmNonce: rekeyPayload.confirmNonce
                )

                // Build HMAC message: epoch || newPublicKey || confirmNonce || hostEphemeralPublicKey || roomId
                var hmacMessage = Data()
                var epochBE = newEpoch.bigEndian
                hmacMessage.append(contentsOf: withUnsafeBytes(of: &epochBE) { Array($0) })
                hmacMessage.append(newKeyPair.publicKey.rawRepresentation)
                hmacMessage.append(rekeyPayload.confirmNonce)
                hmacMessage.append(rekeyPayload.hostEphemeralPublicKey)
                hmacMessage.append(rid)

                let mac = Data(HMAC<SHA256>.authenticationCode(for: hmacMessage, using: confirmKey))

                let confirmation = RekeyConfirmation(
                    epoch: newEpoch,
                    newPublicKey: newKeyPair.publicKey.rawRepresentation,
                    confirmNonce: rekeyPayload.confirmNonce,
                    mac: mac
                )

                // Encode as internal rekeyConfirm content type, encrypt as MESSAGE frame
                let confirmData = try JSONEncoder().encode(confirmation)
                var payload = Data()
                payload.append(MessageCrypto.ContentType.rekeyConfirm.rawValue)
                payload.append(confirmData)

                // Use per-message key for encryption
                self.lock.lock()
                self.sequenceNumber += 1
                let seq = self.sequenceNumber
                self.lock.unlock()

                let messageKey = KeyExchange.derivePerMessageKey(masterKey: newMK, epoch: newEpoch, sequence: seq)
                let encrypted = try MessageCrypto.encrypt(
                    plaintext: payload,
                    key: messageKey,
                    senderId: pid,
                    sequence: seq,
                    epoch: newEpoch
                )

                if let encoded = ClientMessage.message(payload: encrypted).encode() {
                    self.webSocket?.send(string: encoded)
                }
            }

            logBuffer.logCryptoEvent("Rekey successful")

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.roomSession(self, didReceiveEvent: .rekeyStarted(reason: "host_initiated"))
                self.delegate?.roomSession(self, didReceiveEvent: .rekeyCompleted(newEpoch: newEpoch))
            }
        } catch {
            // Not a rekey payload or decryption failed — count as crypto failure
            lock.lock()
            consecutiveCryptoFailures += 1
            let failures = consecutiveCryptoFailures
            lock.unlock()

            if failures >= maxConsecutiveCryptoFailures {
                logBuffer.critical("RoomSession", "Too many crypto failures, closing room")
                DispatchQueue.main.async { [weak self] in
                    self?.closeRoom(reason: .cryptoFailure)
                }
            }
        }
    }
}

// MARK: - Errors

enum RoomError: Error, LocalizedError {
    case invalidState
    case invalidRoomId
    case invalidServerURL
    case encodingFailed
    case internalError
    case notHost
    case notClient
    case messageTooLarge(size: Int, maxSize: Int)
    case inviteTokenRequired

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "Cannot perform operation in current room state"
        case .invalidRoomId:
            return "Invalid room ID format"
        case .invalidServerURL:
            return "Invalid server URL"
        case .encodingFailed:
            return "Failed to encode message"
        case .internalError:
            return "An internal error occurred"
        case .notHost:
            return "Only the host can perform this action"
        case .notClient:
            return "Only clients can perform this action"
        case .messageTooLarge(let size, let maxSize):
            let sizeMB = Double(size) / 1024.0 / 1024.0
            let maxMB = Double(maxSize) / 1024.0 / 1024.0
            return String(format: "Message too large (%.1f MB). Maximum size is %.0f MB.", sizeMB, maxMB)
        case .inviteTokenRequired:
            return "An invite token is required to join this room"
        }
    }
}
