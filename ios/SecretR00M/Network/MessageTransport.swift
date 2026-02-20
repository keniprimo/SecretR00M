import Foundation
#if DEBUG
import os
#endif

// MARK: - Protocol Messages

/// Base message structure for relay protocol
struct RelayMessage: Codable {
    let type: String
    let roomId: String?
    let clientId: String?
    let payload: String?  // Base64 encoded encrypted data
    let reason: String?

    init(type: String, roomId: String? = nil, clientId: String? = nil, payload: String? = nil, reason: String? = nil) {
        self.type = type
        self.roomId = roomId
        self.clientId = clientId
        self.payload = payload
        self.reason = reason
    }
}

// MARK: - Host Messages

/// Messages sent by the host
enum HostMessage {
    case roomOpen(hostPublicKey: Data)
    case broadcast(payload: Data)
    case direct(clientId: String, payload: Data)
    case joinApproved(clientId: String, approval: JoinApproval)
    case joinRejected(clientId: String, reason: String)
    case kick(clientId: String)
    case roomClose
    case heartbeat
    /// SECURITY: Per-client encrypted rekey sent as opaque DIRECT message.
    /// No plaintext metadata (epoch, reason, keys) reaches the relay.
    case rekeyDirect(clientId: String, encryptedPayload: Data)
}

extension HostMessage {
    /// Encode to JSON string for sending
    func encode() -> String? {
        let encoder = JSONEncoder()

        switch self {
        case .roomOpen(let hostPublicKey):
            let msg: [String: Any] = [
                "type": "ROOM_OPEN",
                "payload": hostPublicKey.base64EncodedString()
            ]
            return msg.jsonString

        case .broadcast(let payload):
            let msg: [String: Any] = [
                "type": "BROADCAST",
                "payload": payload.base64EncodedString()
            ]
            return msg.jsonString

        case .direct(let clientId, let payload):
            let msg: [String: Any] = [
                "type": "DIRECT",
                "clientId": clientId,
                "payload": payload.base64EncodedString()
            ]
            return msg.jsonString

        case .joinApproved(let clientId, let approval):
            guard let approvalData = try? encoder.encode(approval),
                  let approvalString = String(data: approvalData, encoding: .utf8) else {
                return nil
            }
            let msg: [String: Any] = [
                "type": "JOIN_RESPONSE",
                "clientId": clientId,
                "payload": approvalString
            ]
            return msg.jsonString

        case .joinRejected(let clientId, let reason):
            // SECURITY: Use JSONEncoder to prevent JSON injection via reason string
            let rejection = JoinRejection(reason: reason)
            guard let rejectionData = try? JSONEncoder().encode(rejection),
                  let rejectionString = String(data: rejectionData, encoding: .utf8) else {
                return nil
            }
            let msg: [String: Any] = [
                "type": "JOIN_RESPONSE",
                "clientId": clientId,
                "payload": rejectionString
            ]
            return msg.jsonString

        case .kick(let clientId):
            let msg: [String: Any] = [
                "type": "KICK",
                "clientId": clientId
            ]
            return msg.jsonString

        case .roomClose:
            return #"{"type":"ROOM_CLOSE"}"#

        case .heartbeat:
            return #"{"type":"HEARTBEAT"}"#

        case .rekeyDirect(let clientId, let encryptedPayload):
            // SECURITY: Rekey payloads are sent as opaque encrypted binary via DIRECT.
            // The relay sees only base64 data — no epoch, reason, or keys leak.
            let msg: [String: Any] = [
                "type": "DIRECT",
                "clientId": clientId,
                "payload": encryptedPayload.base64EncodedString()
            ]
            return msg.jsonString
        }
    }
}

// MARK: - Client Messages

/// Messages sent by clients
enum ClientMessage {
    case joinRequest(request: JoinRequest)
    case joinConfirm(confirmation: JoinConfirmation)
    case message(payload: Data)
    // SECURITY: rekeyConfirm removed from wire protocol.
    // Rekey confirmations are now sent as encrypted MESSAGE frames
    // to prevent relay forgery of the client's new ephemeral public key.
}

extension ClientMessage {
    /// Encode to JSON string for sending
    func encode() -> String? {
        let encoder = JSONEncoder()

        switch self {
        case .joinRequest(let request):
            guard let requestData = try? encoder.encode(request),
                  let requestString = String(data: requestData, encoding: .utf8) else {
                return nil
            }
            let msg: [String: Any] = [
                "type": "JOIN_REQUEST",
                "payload": requestString
            ]
            return msg.jsonString

        case .joinConfirm(let confirmation):
            guard let confirmData = try? encoder.encode(confirmation),
                  let confirmString = String(data: confirmData, encoding: .utf8) else {
                return nil
            }
            let msg: [String: Any] = [
                "type": "JOIN_CONFIRM",
                "payload": confirmString
            ]
            return msg.jsonString

        case .message(let payload):
            let msg: [String: Any] = [
                "type": "MESSAGE",
                "payload": payload.base64EncodedString()
            ]
            return msg.jsonString
        }
    }
}

// MARK: - Received Message Parsing

/// Parsed incoming message types
enum ReceivedMessage {
    case roomCreated(roomId: String)
    case connected(clientId: String)
    case joinRequest(clientId: String, request: JoinRequest)
    case joinResponse(approval: JoinApproval?, rejection: JoinRejection?)
    case joinConfirm(clientId: String, confirmation: JoinConfirmation)
    // SECURITY: rekeyConfirm removed — now delivered as encrypted MESSAGE frame
    case message(senderId: String?, payload: Data)
    case clientMessage(clientId: String, payload: Data)
    case clientLeft(clientId: String)
    case roomDestroyed(reason: String)
    case kicked(reason: String)
    case heartbeatAck
    case error(message: String)
    case unknown(type: String)
}

/// MessageParser handles parsing incoming relay messages
enum MessageParser {

    #if DEBUG
    private static let logger = os.Logger(subsystem: "com.ephemeral.rooms", category: "MessageParser")
    #endif

    /// Parse a JSON message string
    /// - Parameter string: The JSON string received from the relay
    /// - Returns: The parsed message, or nil if parsing fails
    static func parse(_ string: String) -> ReceivedMessage? {
        guard let data = string.data(using: .utf8) else {
            #if DEBUG
            logger.error("Failed to parse message data")
            #endif
            return nil
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            json = parsed
        } catch {
            #if DEBUG
            logger.error("JSON parsing failed")
            #endif
            return nil
        }

        guard let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "ROOM_CREATED":
            guard let roomId = json["roomId"] as? String else { return nil }
            return .roomCreated(roomId: roomId)

        case "CONNECTED":
            guard let clientId = json["clientId"] as? String else { return nil }
            return .connected(clientId: clientId)

        case "JOIN_REQUEST":
            guard let clientId = json["clientId"] as? String,
                  let payloadString = json["payload"] as? String,
                  let payloadData = payloadString.data(using: .utf8),
                  let request = try? JSONDecoder().decode(JoinRequest.self, from: payloadData) else {
                return nil
            }
            return .joinRequest(clientId: clientId, request: request)

        case "JOIN_RESPONSE":
            guard let payloadString = json["payload"] as? String,
                  let payloadData = payloadString.data(using: .utf8) else {
                return nil
            }

            // Try parsing as approval
            if let approval = try? JSONDecoder().decode(JoinApproval.self, from: payloadData) {
                return .joinResponse(approval: approval, rejection: nil)
            }

            // Try parsing as rejection
            if let rejection = try? JSONDecoder().decode(JoinRejection.self, from: payloadData) {
                return .joinResponse(approval: nil, rejection: rejection)
            }

            return nil

        case "JOIN_CONFIRM":
            guard let clientId = json["clientId"] as? String,
                  let payloadString = json["payload"] as? String,
                  let payloadData = payloadString.data(using: .utf8),
                  let confirmation = try? JSONDecoder().decode(JoinConfirmation.self, from: payloadData) else {
                return nil
            }
            return .joinConfirm(clientId: clientId, confirmation: confirmation)

        // SECURITY: REKEY_CONFIRM case removed from wire protocol.
        // Confirmations are now sent as encrypted MESSAGE frames.

        case "MESSAGE":
            let senderId = json["clientId"] as? String
            guard let payloadString = json["payload"] as? String,
                  let payload = Data(base64Encoded: payloadString) else {
                return nil
            }
            return .message(senderId: senderId, payload: payload)

        case "CLIENT_MESSAGE":
            guard let clientId = json["clientId"] as? String,
                  let payloadString = json["payload"] as? String,
                  let payload = Data(base64Encoded: payloadString) else {
                return nil
            }
            return .clientMessage(clientId: clientId, payload: payload)

        case "CLIENT_LEFT":
            guard let clientId = json["clientId"] as? String else { return nil }
            return .clientLeft(clientId: clientId)

        case "ROOM_DESTROYED":
            let reason = json["reason"] as? String ?? "unknown"
            return .roomDestroyed(reason: reason)

        case "KICKED":
            let reason = json["reason"] as? String ?? "unknown"
            return .kicked(reason: reason)

        case "HEARTBEAT_ACK":
            return .heartbeatAck

        case "ERROR":
            let message = json["reason"] as? String ?? "Unknown error"
            return .error(message: message)

        default:
            return .unknown(type: type)
        }
    }
}

// MARK: - Dictionary Extension

private extension Dictionary where Key == String, Value == Any {
    var jsonString: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: self),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
