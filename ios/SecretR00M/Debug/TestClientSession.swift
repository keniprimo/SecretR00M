// TestClientSession.swift
// EphemeralRooms - Internal Test Mode
//
// SECURITY: This entire file is compiled out of Release builds.
// TestClientSession is a full RoomSession instance that behaves exactly
// like a real remote client - no shortcuts, no mocking.

#if DEBUG

import Foundation

/// TestClientSession simulates a second client joining a room.
/// It uses all real code paths: WebSocket, crypto, handshake, etc.
/// This is for functional verification, NOT mocking.
final class TestClientSession: RoomSessionDelegate {

    // MARK: - Properties

    /// The underlying real RoomSession (uses all production code paths)
    private let session: RoomSession

    /// Room ID we're joining
    private let roomId: String

    /// Callback for diagnostics updates
    private let diagnosticsHandler: (DiagnosticsUpdate) -> Void

    /// Timer for sending test messages
    private var messageTimer: Timer?

    /// Count of test messages sent
    private var testMessageCount = 0

    /// Maximum test messages to send (prevents spam)
    private let maxTestMessages = 10

    /// Whether we've successfully joined
    private var hasJoined = false

    // MARK: - Initialization

    init(roomId: String,
         configuration: RoomConfiguration,
         diagnosticsHandler: @escaping (DiagnosticsUpdate) -> Void) {
        self.roomId = roomId
        self.diagnosticsHandler = diagnosticsHandler

        // Create a real RoomSession - this is NOT a mock!
        // It will use real crypto, real WebSocket, real everything
        self.session = RoomSession(configuration: configuration)
        self.session.delegate = self

        print("[TestClient] Created with roomId: \(roomId.prefix(8))...")
    }

    deinit {
        disconnect()
        print("[TestClient] Deinitialized")
    }

    // MARK: - Connection

    /// Connect and join the room (pending approval)
    func connect() {
        diagnosticsHandler(.connectionStateChanged(.connecting))

        do {
            // Use the real join flow - requires host approval
            try session.joinRoomPendingApproval(roomIdString: roomId)
            print("[TestClient] Join request initiated")
        } catch {
            print("[TestClient] Failed to initiate join: \(error)")
            diagnosticsHandler(.error("Failed to connect: \(error.localizedDescription)"))
        }
    }

    /// Disconnect and clean up
    func disconnect() {
        diagnosticsHandler(.connectionStateChanged(.disconnecting))

        // Stop message timer
        messageTimer?.invalidate()
        messageTimer = nil

        // Leave the room properly
        session.closeRoom(reason: .hostClosed)

        hasJoined = false
        diagnosticsHandler(.connectionStateChanged(.disconnected))
        print("[TestClient] Disconnected")
    }

    // MARK: - Message Simulation

    /// Start sending periodic test messages
    private func startMessageSimulation() {
        guard messageTimer == nil else { return }

        print("[TestClient] Starting message simulation")

        // Send first message immediately
        sendTestMessage()

        // Then send every 2 seconds
        messageTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sendTestMessage()
        }
    }

    /// Stop sending test messages
    private func stopMessageSimulation() {
        messageTimer?.invalidate()
        messageTimer = nil
    }

    /// Send a single test message
    private func sendTestMessage() {
        guard hasJoined else { return }
        guard testMessageCount < maxTestMessages else {
            print("[TestClient] Max test messages reached, stopping")
            stopMessageSimulation()
            return
        }

        testMessageCount += 1
        let content = "[TestClient] Test message #\(testMessageCount) at \(Date())"

        do {
            try session.sendMessage(content: content)
            diagnosticsHandler(.messageSent(content))
            print("[TestClient] Sent: \(content)")
        } catch {
            print("[TestClient] Failed to send message: \(error)")
            diagnosticsHandler(.error("Send failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - RoomSessionDelegate

    func roomSession(_ session: RoomSession, didChangeState state: RoomState) {
        print("[TestClient] State changed: \(state)")

        switch state {
        case .none:
            diagnosticsHandler(.connectionStateChanged(.disconnected))

        case .creating:
            diagnosticsHandler(.connectionStateChanged(.connecting))

        case .created(_):
            // This shouldn't happen for a client
            break

        case .open:
            // This shouldn't happen for a client
            break

        case .active:
            hasJoined = true
            diagnosticsHandler(.connectionStateChanged(.active))
            diagnosticsHandler(.joinApproved)

            // Epoch is reported via rekeyCompleted events

            // Start message simulation after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startMessageSimulation()
            }

        case .rekeying:
            print("[TestClient] Rekeying in progress")

        case .destroyed(let reason):
            hasJoined = false
            stopMessageSimulation()
            diagnosticsHandler(.connectionStateChanged(.disconnected))
            diagnosticsHandler(.error("Room destroyed: \(reason.rawValue)"))
        }
    }

    func roomSession(_ session: RoomSession, didReceiveEvent event: RoomEvent) {
        print("[TestClient] Event: \(event)")

        switch event {
        case .joinApproved(_):
            diagnosticsHandler(.joinApproved)

        case .joinRejected(let reason):
            hasJoined = false
            diagnosticsHandler(.joinRejected(reason))

        case .rekeyStarted(_):
            print("[TestClient] Rekey started")

        case .rekeyCompleted(let newEpoch):
            diagnosticsHandler(.epochChanged(newEpoch))
            print("[TestClient] Rekey completed, new epoch: \(newEpoch)")

        case .error(let message):
            diagnosticsHandler(.error(message))

        case .destroyed(let reason):
            hasJoined = false
            stopMessageSimulation()
            diagnosticsHandler(.error("Room destroyed: \(reason.rawValue)"))

        case .created, .opened, .joinRequested, .participantJoined, .participantLeft, .messageReceived, .securityEvent:
            // Handle other events silently
            break
        }
    }

    func roomSession(_ session: RoomSession, didReceiveMessage message: DecryptedMessage) {
        // Log received messages for debugging
        let contentStr: String
        switch message.contentType {
        case .text(_):
            contentStr = message.content
        case .image(data: _, mimeType: _):
            contentStr = "[Image]"
        case .video(data: _, mimeType: _, thumbnail: _, duration: _):
            contentStr = "[Video]"
        case .system(_):
            contentStr = "[System] \(message.content)"
        }

        diagnosticsHandler(.messageReceived(contentStr))
        print("[TestClient] Received message: \(contentStr.prefix(50))...")
    }

    func roomSession(_ session: RoomSession, didReceiveJoinRequest request: PendingJoinRequest) {
        // Test client doesn't handle join requests (it's not a host)
    }
}

#endif
