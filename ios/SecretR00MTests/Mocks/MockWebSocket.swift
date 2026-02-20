import Foundation
@testable import SecretR00M

// MARK: - Mock WebSocket Manager

/// Mock WebSocket for testing network behavior without real connections
final class MockWebSocket: WebSocketManagerProtocol {

    // MARK: - Protocol Conformance

    private(set) var state: WebSocketState = .disconnected
    weak var protocolDelegate: WebSocketProtocolDelegate?

    // MARK: - Test Configuration

    /// Delay before connect completes (simulates network latency)
    var connectDelay: TimeInterval = 0.1

    /// Whether connect should succeed
    var connectShouldSucceed = true

    /// Error to return on connect failure
    var connectError: Error = WebSocketError.connectionFailed

    /// Whether reconnect attempts should succeed
    var reconnectShouldFail = false

    /// Delay for responses (simulates network latency)
    var responseDelay: TimeInterval = 0.05

    /// Whether the socket is in "disconnected" simulation mode
    var simulatedDisconnected = false

    /// Callback when reconnect is attempted
    var onReconnectAttempt: (() -> Void)?

    /// Callback when a message is sent
    var onMessageSent: ((String) -> Void)?

    // MARK: - Sent Message Tracking

    /// All messages sent through this socket
    private(set) var sentMessages: [String] = []

    /// Parsed sent frames for verification
    private(set) var sentFrames: [MockSentFrame] = []

    /// Pending messages queued while disconnected
    private(set) var pendingMessages: [String] = []

    /// Number of pending messages
    var pendingMessageCount: Int { pendingMessages.count }

    // MARK: - Connection Management

    private var isReconnecting = false
    private var reconnectAttempts = 0

    func connect() {
        guard state == .disconnected else { return }

        state = .connecting

        if isReconnecting {
            reconnectAttempts += 1
            onReconnectAttempt?()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + connectDelay) { [weak self] in
            guard let self = self else { return }

            if self.reconnectShouldFail && self.isReconnecting {
                self.state = .disconnected
                self.protocolDelegate?.webSocketDidDisconnect(self, error: self.connectError)
                return
            }

            if self.connectShouldSucceed {
                self.state = .connected
                self.simulatedDisconnected = false
                self.protocolDelegate?.webSocketDidConnect(self)

                // Flush pending messages
                for message in self.pendingMessages {
                    self.sentMessages.append(message)
                }
                self.pendingMessages.removeAll()
            } else {
                self.state = .disconnected
                self.protocolDelegate?.webSocketDidDisconnect(self, error: self.connectError)
            }
        }
    }

    func disconnect() {
        guard state != .disconnected else { return }

        state = .disconnecting
        state = .disconnected
        simulatedDisconnected = true
    }

    func send(string: String) {
        if simulatedDisconnected || state != .connected {
            // Queue message if disconnected
            pendingMessages.append(string)
            return
        }

        sentMessages.append(string)

        // Parse frame type for verification
        if let frame = parseFrame(string) {
            sentFrames.append(frame)
        }

        onMessageSent?(string)
    }

    func send(data: Data) {
        guard state == .connected, !simulatedDisconnected else { return }

        if let string = String(data: data, encoding: .utf8) {
            send(string: string)
        }
    }

    func send<T: Encodable>(message: T) {
        guard let data = try? JSONEncoder().encode(message),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        send(string: string)
    }

    func receivedHeartbeatAck() {
        // No-op for mock
    }

    // MARK: - Simulation Methods

    /// Simulate a disconnect event
    func simulateDisconnect(error: Error? = nil) {
        guard state == .connected else { return }

        simulatedDisconnected = true
        state = .disconnected
        isReconnecting = true

        protocolDelegate?.webSocketDidDisconnect(self, error: error)
    }

    /// Simulate reconnection completing
    func simulateReconnect() {
        simulatedDisconnected = false
        state = .connected
        isReconnecting = false
        reconnectAttempts = 0

        protocolDelegate?.webSocketDidConnect(self)

        // Flush pending messages
        for message in pendingMessages {
            sentMessages.append(message)
        }
        pendingMessages.removeAll()
    }

    /// Simulate receiving a message from server
    func simulateReceive(string: String) {
        protocolDelegate?.webSocket(self, didReceiveString: string)
    }

    /// Simulate receiving binary data
    func simulateReceive(data: Data) {
        protocolDelegate?.webSocket(self, didReceiveMessage: data)
    }

    /// Simulate server sending ROOM_CREATED
    func simulateRoomCreated(roomId: String) {
        let message = """
        {"type":"ROOM_CREATED","room_id":"\(roomId)"}
        """
        simulateReceive(string: message)
    }

    /// Simulate server sending CONNECTED (for clients)
    func simulateConnected(clientId: String? = nil) {
        var message = #"{"type":"CONNECTED""#
        if let id = clientId {
            message += #","client_id":"\#(id)""#
        }
        message += "}"
        simulateReceive(string: message)
    }

    /// Simulate server sending JOIN_REQUEST (for host)
    func simulateJoinRequest(clientId: String, publicKey: Data, displayName: String? = nil) {
        let pubKeyBase64 = publicKey.base64EncodedString()
        var message = """
        {"type":"JOIN_REQUEST","client_id":"\(clientId)","request":{"client_public_key":"\(pubKeyBase64)"
        """
        if let name = displayName {
            message += #","display_name":"\#(name)""#
        }
        message += "}}"
        simulateReceive(string: message)
    }

    /// Simulate server sending CLIENT_LEFT
    func simulateClientLeft(clientId: String) {
        let message = """
        {"type":"CLIENT_LEFT","client_id":"\(clientId)"}
        """
        simulateReceive(string: message)
    }

    /// Simulate server sending KICKED
    func simulateKicked(reason: String = "Removed by host") {
        let message = """
        {"type":"KICKED","reason":"\(reason)"}
        """
        simulateReceive(string: message)
    }

    /// Simulate server sending ROOM_DESTROYED
    func simulateRoomDestroyed(reason: String = "host_closed") {
        let message = """
        {"type":"ROOM_DESTROYED","reason":"\(reason)"}
        """
        simulateReceive(string: message)
    }

    /// Simulate server sending ERROR
    func simulateError(message: String) {
        let msg = """
        {"type":"ERROR","message":"\(message)"}
        """
        simulateReceive(string: msg)
    }

    /// Simulate server sending HEARTBEAT_ACK
    func simulateHeartbeatAck() {
        simulateReceive(string: #"{"type":"HEARTBEAT_ACK"}"#)
    }

    // MARK: - Reset

    /// Reset all state for reuse
    func reset() {
        state = .disconnected
        simulatedDisconnected = false
        isReconnecting = false
        reconnectAttempts = 0
        sentMessages.removeAll()
        sentFrames.removeAll()
        pendingMessages.removeAll()
        connectShouldSucceed = true
        reconnectShouldFail = false
    }

    // MARK: - Private

    private func parseFrame(_ string: String) -> MockSentFrame? {
        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        return MockSentFrame(
            type: type,
            payload: json["payload"] as? String,
            clientId: json["client_id"] as? String,
            rawJSON: json
        )
    }
}

// MARK: - Mock Sent Frame

/// Parsed representation of a sent WebSocket frame
struct MockSentFrame {
    let type: String
    let payload: String?
    let clientId: String?
    let rawJSON: [String: Any]

    var isMessage: Bool { type == "MESSAGE" || type == "BROADCAST" }
    var isHeartbeat: Bool { type == "HEARTBEAT" }
    var isJoinRequest: Bool { type == "JOIN_REQUEST" }
    var isJoinConfirm: Bool { type == "JOIN_CONFIRM" }
    var isRekey: Bool { type == "REKEY" || type == "REKEY_DIRECT" }
    var isKick: Bool { type == "KICK" }
    var isRoomClose: Bool { type == "ROOM_CLOSE" }
}

// MARK: - Mock WebSocket Factory

/// Factory that injects mock WebSockets for testing
enum MockWebSocketFactory {

    private static var mockSocket: MockWebSocket?

    /// Install a mock socket to be returned by the factory
    static func install(_ mock: MockWebSocket) {
        mockSocket = mock
    }

    /// Remove the installed mock
    static func uninstall() {
        mockSocket = nil
    }

    /// Get the currently installed mock (if any)
    static var current: MockWebSocket? { mockSocket }
}
