import Foundation

// Note: WebSocketState and WebSocketError are defined in WebSocketProtocol.swift

/// WebSocket manager delegate protocol (for legacy WebSocketManager)
protocol WebSocketManagerDelegate: AnyObject {
    func webSocketDidConnect(_ manager: WebSocketManager)
    func webSocketDidDisconnect(_ manager: WebSocketManager, error: Error?)
    func webSocket(_ manager: WebSocketManager, didReceiveMessage data: Data)
    func webSocket(_ manager: WebSocketManager, didReceiveString string: String)
}

/// WebSocketManager handles WebSocket connections using URLSession.
/// Uses ephemeral configuration to avoid caching.
final class WebSocketManager: NSObject {

    // MARK: - Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let url: URL
    private let lock = NSLock()

    private(set) var state: WebSocketState = .disconnected
    weak var delegate: WebSocketManagerDelegate?

    // Heartbeat
    private var heartbeatTimer: Timer?
    private var lastHeartbeatAck: Date?
    private let heartbeatInterval: TimeInterval = 3.0
    private let heartbeatTimeout: TimeInterval = 6.0
    private var sendHeartbeats: Bool = false

    /// Maximum WebSocket message size: 50 MB (supports large video messages)
    private let maximumMessageSize = 50 * 1024 * 1024

    // MARK: - Initialization

    /// Initialize with a WebSocket URL
    /// - Parameters:
    ///   - url: The WebSocket URL (wss://...)
    ///   - sendHeartbeats: Whether to send heartbeat messages (host only)
    init(url: URL, sendHeartbeats: Bool = false) {
        self.url = url
        self.sendHeartbeats = sendHeartbeats
        super.init()
    }

    /// Initialize with a URL string
    /// - Parameters:
    ///   - urlString: The WebSocket URL string
    ///   - sendHeartbeats: Whether to send heartbeat messages
    convenience init?(urlString: String, sendHeartbeats: Bool = false) {
        guard let url = URL(string: urlString) else { return nil }
        self.init(url: url, sendHeartbeats: sendHeartbeats)
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection Management

    /// Connect to the WebSocket server
    func connect() {
        lock.lock()
        defer { lock.unlock() }

        guard state == .disconnected else { return }
        state = .connecting

        // Use ephemeral configuration - no caching, no cookies, no credentials storage
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false

        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: url)
        // Set maximum message size to support large video messages
        webSocketTask?.maximumMessageSize = maximumMessageSize
        webSocketTask?.resume()

        startReceiving()
    }

    /// Disconnect from the WebSocket server
    func disconnect() {
        lock.lock()
        defer { lock.unlock() }

        guard state != .disconnected else { return }
        state = .disconnecting

        stopHeartbeat()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        state = .disconnected
    }

    /// Send a string message
    /// - Parameter string: The string to send
    func send(string: String) {
        guard state == .connected else { return }

        webSocketTask?.send(.string(string)) { [weak self] error in
            if let error = error {
                self?.handleError(error)
            }
        }
    }

    /// Send binary data
    /// - Parameter data: The data to send
    func send(data: Data) {
        guard state == .connected else { return }

        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error = error {
                self?.handleError(error)
            }
        }
    }

    /// Send a Codable message as JSON
    /// - Parameter message: The message to encode and send
    func send<T: Encodable>(message: T) {
        guard let data = try? JSONEncoder().encode(message),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        send(string: string)
    }

    // MARK: - Heartbeat

    /// Start sending heartbeats (host only)
    private func startHeartbeat() {
        guard sendHeartbeats else { return }

        lastHeartbeatAck = Date()

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            self?.sendHeartbeatIfNeeded()
        }
    }

    /// Stop heartbeat timer
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Send heartbeat and check for timeout
    private func sendHeartbeatIfNeeded() {
        guard state == .connected else { return }

        // Check if last heartbeat was acknowledged
        if let lastAck = lastHeartbeatAck, Date().timeIntervalSince(lastAck) > heartbeatTimeout {
            // Heartbeat timeout - disconnect
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.disconnect()
                self.delegate?.webSocketDidDisconnect(self, error: WebSocketError.heartbeatTimeout)
            }
            return
        }

        // Send heartbeat
        send(string: #"{"type":"HEARTBEAT"}"#)
    }

    /// Called when heartbeat ack is received
    func receivedHeartbeatAck() {
        lastHeartbeatAck = Date()
    }

    // MARK: - Private

    /// Start receiving messages
    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self.delegate?.webSocket(self, didReceiveMessage: data)
                    }
                    self.delegate?.webSocket(self, didReceiveString: text)

                case .data(let data):
                    self.delegate?.webSocket(self, didReceiveMessage: data)

                @unknown default:
                    break
                }

                // Continue receiving
                self.startReceiving()

            case .failure(let error):
                self.handleError(error)
            }
        }
    }

    /// Handle connection errors
    private func handleError(_ error: Error) {
        let wasConnected = state == .connected
        disconnect()

        if wasConnected {
            delegate?.webSocketDidDisconnect(self, error: error)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketManager: URLSessionWebSocketDelegate {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        state = .connected
        lastHeartbeatAck = Date()
        lock.unlock()

        startHeartbeat()
        delegate?.webSocketDidConnect(self)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.lock()
        let wasConnected = state == .connected
        state = .disconnected
        lock.unlock()

        stopHeartbeat()

        if wasConnected {
            delegate?.webSocketDidDisconnect(self, error: nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            handleError(error)
        }
    }
}
