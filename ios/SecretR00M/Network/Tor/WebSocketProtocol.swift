import Foundation
#if DEBUG
import os.log
#endif

// MARK: - WebSocket State

/// WebSocket connection states
enum WebSocketState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

/// WebSocket errors
enum WebSocketError: Error, LocalizedError {
    case connectionFailed
    case heartbeatTimeout
    case invalidURL
    case sendFailed(Error)
    case torConnectionRequired

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "WebSocket connection failed"
        case .heartbeatTimeout:
            return "Connection lost (heartbeat timeout)"
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .sendFailed(let error):
            return "Failed to send message: \(error.localizedDescription)"
        case .torConnectionRequired:
            return "Secure connection required but not available"
        }
    }
}

// MARK: - Protocol

/// Protocol for WebSocket managers (both direct and Tor-routed)
protocol WebSocketManagerProtocol: AnyObject {
    var state: WebSocketState { get }
    var protocolDelegate: WebSocketProtocolDelegate? { get set }

    func connect()
    func disconnect()
    func send(string: String)
    func send(data: Data)
    func send<T: Encodable>(message: T)
    func receivedHeartbeatAck()
}

/// Protocol delegate for WebSocket events
protocol WebSocketProtocolDelegate: AnyObject {
    func webSocketDidConnect(_ manager: WebSocketManagerProtocol)
    func webSocketDidDisconnect(_ manager: WebSocketManagerProtocol, error: Error?)
    func webSocket(_ manager: WebSocketManagerProtocol, didReceiveMessage data: Data)
    func webSocket(_ manager: WebSocketManagerProtocol, didReceiveString string: String)
}

// MARK: - Configuration

/// Configuration for creating WebSocket connections
struct WebSocketConfiguration {
    let url: URL
    let sendHeartbeats: Bool
    let useTor: Bool
    let heartbeatInterval: TimeInterval
    let heartbeatTimeout: TimeInterval
    /// SECURITY: Jitter percentage (0.0-0.5) to randomize heartbeat timing
    /// This prevents traffic fingerprinting based on heartbeat patterns
    let heartbeatJitter: Double
    /// Maximum WebSocket message size in bytes (default 50 MB for video support)
    let maximumMessageSize: Int

    /// Default maximum message size: 50 MB (supports most video clips)
    static let defaultMaximumMessageSize = 50 * 1024 * 1024

    init(
        url: URL,
        sendHeartbeats: Bool = false,
        useTor: Bool = false,
        heartbeatInterval: TimeInterval = 3.0,
        heartbeatTimeout: TimeInterval? = nil,
        heartbeatJitter: Double = 0.3,  // Default 30% jitter
        maximumMessageSize: Int = defaultMaximumMessageSize
    ) {
        self.url = url
        self.sendHeartbeats = sendHeartbeats
        self.useTor = useTor
        // Tor connections need longer heartbeat intervals due to circuit latency
        self.heartbeatInterval = useTor ? 10.0 : heartbeatInterval
        // Tor connections need much longer timeout - circuits can be slow
        // Allow up to 30 seconds for heartbeat ack over Tor
        self.heartbeatTimeout = heartbeatTimeout ?? (useTor ? 30.0 : 6.0)
        // Clamp jitter to valid range
        self.heartbeatJitter = min(max(heartbeatJitter, 0.0), 0.5)
        self.maximumMessageSize = maximumMessageSize
    }

    init?(
        urlString: String,
        sendHeartbeats: Bool = false,
        useTor: Bool = false,
        heartbeatJitter: Double = 0.3,
        maximumMessageSize: Int = defaultMaximumMessageSize
    ) {
        guard let url = URL(string: urlString) else { return nil }
        self.init(url: url, sendHeartbeats: sendHeartbeats, useTor: useTor, heartbeatJitter: heartbeatJitter, maximumMessageSize: maximumMessageSize)
    }
}

// MARK: - Factory

/// Factory for creating WebSocket managers
enum WebSocketFactory {

    /// Create a WebSocket manager based on configuration
    static func createManager(config: WebSocketConfiguration) -> WebSocketManagerProtocol {
        if config.useTor {
            return TorWebSocketAdapter(config: config)
        } else {
            return DirectWebSocketAdapter(config: config)
        }
    }

    /// Create a WebSocket manager with URL string
    static func createManager(
        urlString: String,
        sendHeartbeats: Bool = false,
        useTor: Bool = false
    ) -> WebSocketManagerProtocol? {
        guard let config = WebSocketConfiguration(
            urlString: urlString,
            sendHeartbeats: sendHeartbeats,
            useTor: useTor
        ) else { return nil }

        return createManager(config: config)
    }
}

// MARK: - Base WebSocket Adapter

/// Base class with shared WebSocket functionality
class BaseWebSocketAdapter: NSObject {

    let config: WebSocketConfiguration
    #if DEBUG
    let logger: Logger
    #endif

    var webSocketTask: URLSessionWebSocketTask?
    var urlSession: URLSession?
    let lock = NSLock()

    // Note: state uses fileprivate(set) to allow subclass access
    fileprivate(set) var state: WebSocketState = .disconnected
    weak var protocolDelegate: WebSocketProtocolDelegate?

    // Heartbeat
    var heartbeatTimer: Timer?
    var lastHeartbeatAck: Date?

    // WebSocket-level ping timer to keep SOCKS connection alive
    private var pingTimer: Timer?
    /// Ping interval for keeping SOCKS proxy connection alive (30 seconds)
    private let pingInterval: TimeInterval = 30.0

    // Send queue for serializing large message sends
    // This prevents overwhelming the connection when sending multiple large files rapidly
    private let sendQueue = DispatchQueue(label: "com.ephemeral.rooms.websocket.send", qos: .userInitiated)
    private var isSendingLargeMessage = false
    private let sendLock = NSLock()

    /// Threshold for "large" messages that should be serialized (100 KB)
    private let largeMessageThreshold = 100 * 1024

    init(config: WebSocketConfiguration, logCategory: String) {
        self.config = config
        #if DEBUG
        self.logger = Logger(subsystem: "com.ephemeral.rooms", category: logCategory)
        #endif
        super.init()
    }

    deinit {
        disconnect()
    }

    // MARK: - State Management

    func setState(_ newState: WebSocketState) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    func getState() -> WebSocketState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    // MARK: - Heartbeat

    /// Calculate jittered heartbeat interval for traffic analysis resistance
    /// SECURITY: Randomizes timing to prevent fingerprinting based on heartbeat patterns
    func jitteredHeartbeatInterval() -> TimeInterval {
        let baseInterval = config.heartbeatInterval
        let jitterRange = baseInterval * config.heartbeatJitter
        let jitter = Double.random(in: -jitterRange...jitterRange)
        return max(1.0, baseInterval + jitter) // Never less than 1 second
    }

    func startHeartbeat() {
        guard config.sendHeartbeats else { return }

        lastHeartbeatAck = Date()

        scheduleNextHeartbeat()
    }

    /// Schedule next heartbeat with jittered timing
    private func scheduleNextHeartbeat() {
        guard config.sendHeartbeats, getState() == .connected else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // SECURITY: Use jittered interval instead of fixed timing
            let interval = self.jitteredHeartbeatInterval()
            self.heartbeatTimer = Timer.scheduledTimer(
                withTimeInterval: interval,
                repeats: false
            ) { [weak self] _ in
                self?.sendHeartbeatIfNeeded()
                self?.scheduleNextHeartbeat() // Schedule next with new jitter
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
    }

    /// Start WebSocket-level ping to keep SOCKS proxy connection alive
    /// This is separate from application-level heartbeats
    func startPing() {
        guard config.useTor else { return } // Only needed for Tor connections

        stopPing()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }
    }

    func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    /// Send a WebSocket ping frame to keep the connection alive
    private func sendPing() {
        guard getState() == .connected else { return }

        webSocketTask?.sendPing { [weak self] error in
            if let error = error {
                #if DEBUG
                self?.logger.warning("WebSocket ping failed: \(error.localizedDescription)")
                #endif
                // Don't disconnect on ping failure - heartbeat will handle that
            }
        }
    }

    func sendHeartbeatIfNeeded() {
        guard getState() == .connected else { return }

        if let lastAck = lastHeartbeatAck,
           Date().timeIntervalSince(lastAck) > config.heartbeatTimeout {
            #if DEBUG
            logger.warning("Heartbeat timeout")
            #endif
            handleHeartbeatTimeout()
            return
        }

        send(string: #"{"type":"HEARTBEAT"}"#)
    }

    func handleHeartbeatTimeout() {
        // Override in subclasses
        disconnect()
        protocolDelegate?.webSocketDidDisconnect(self as! WebSocketManagerProtocol, error: WebSocketError.heartbeatTimeout)
    }

    func receivedHeartbeatAck() {
        lastHeartbeatAck = Date()
    }

    // MARK: - Receiving

    func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleReceivedMessage(message)
                self.startReceiving()

            case .failure(let error):
                self.handleError(error)
            }
        }
    }

    func handleReceivedMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            #if DEBUG
            logger.info("Received string message: \(text.count) characters")
            #endif
            if let data = text.data(using: .utf8) {
                protocolDelegate?.webSocket(self as! WebSocketManagerProtocol, didReceiveMessage: data)
            }
            protocolDelegate?.webSocket(self as! WebSocketManagerProtocol, didReceiveString: text)

        case .data(let data):
            #if DEBUG
            logger.info("Received binary message: \(data.count) bytes")
            #endif
            protocolDelegate?.webSocket(self as! WebSocketManagerProtocol, didReceiveMessage: data)

        @unknown default:
            break
        }
    }

    func handleError(_ error: Error) {
        let nsError = error as NSError
        #if DEBUG
        logger.error("WebSocket error: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            logger.error("Underlying error: \(underlyingError.localizedDescription)")
        }
        #endif

        let wasConnected = getState() == .connected
        cleanupConnection()

        if wasConnected {
            protocolDelegate?.webSocketDidDisconnect(self as! WebSocketManagerProtocol, error: error)
        }
    }

    func cleanupConnection() {
        lock.lock()
        stopHeartbeat()
        webSocketTask?.cancel()
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        state = .disconnected
        lock.unlock()
    }

    // MARK: - To Override

    func connect() {
        fatalError("Subclasses must override connect()")
    }

    func disconnect() {
        fatalError("Subclasses must override disconnect()")
    }

    func send(string: String) {
        guard getState() == .connected else { return }

        let messageSize = string.utf8.count

        // For large messages, serialize through the queue to prevent overwhelming the connection
        if messageSize > largeMessageThreshold {
            sendLargeMessage(.string(string), size: messageSize)
        } else {
            // Small messages (including heartbeats) go directly
            performSend(.string(string))
        }
    }

    func send(data: Data) {
        guard getState() == .connected else { return }

        let messageSize = data.count

        // For large messages, serialize through the queue
        if messageSize > largeMessageThreshold {
            sendLargeMessage(.data(data), size: messageSize)
        } else {
            performSend(.data(data))
        }
    }

    func send<T: Encodable>(message: T) {
        guard let data = try? JSONEncoder().encode(message),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        send(string: string)
    }

    /// Perform the actual send operation
    private func performSend(_ message: URLSessionWebSocketTask.Message) {
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                self?.handleError(error)
            }
        }
    }

    /// Send a large message through the serialization queue
    /// This ensures large messages are sent one at a time to prevent overwhelming Tor circuits
    private func sendLargeMessage(_ message: URLSessionWebSocketTask.Message, size: Int) {
        sendQueue.async { [weak self] in
            guard let self = self else { return }

            // Wait for any previous large send to complete
            self.sendLock.lock()
            while self.isSendingLargeMessage {
                self.sendLock.unlock()
                Thread.sleep(forTimeInterval: 0.1)
                self.sendLock.lock()
            }
            self.isSendingLargeMessage = true
            self.sendLock.unlock()

            #if DEBUG
            self.logger.info("Sending large message: \(size) bytes")
            #endif

            let semaphore = DispatchSemaphore(value: 0)
            var sendError: Error?

            self.webSocketTask?.send(message) { error in
                sendError = error
                semaphore.signal()
            }

            // Wait for send to complete with a timeout
            // Tor can be slow, allow up to 2 minutes for large files
            let timeout = DispatchTime.now() + .seconds(120)
            let result = semaphore.wait(timeout: timeout)

            self.sendLock.lock()
            self.isSendingLargeMessage = false
            self.sendLock.unlock()

            if result == .timedOut {
                #if DEBUG
                self.logger.error("Large message send timed out after 120 seconds")
                #endif
                DispatchQueue.main.async {
                    self.handleError(WebSocketError.sendFailed(NSError(domain: "WebSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Send timed out"])))
                }
            } else if let error = sendError {
                #if DEBUG
                self.logger.error("Large message send failed: \(error.localizedDescription)")
                #endif
                DispatchQueue.main.async {
                    self.handleError(error)
                }
            } else {
                #if DEBUG
                self.logger.info("Large message sent successfully")
                #endif
            }
        }
    }
}

// MARK: - Direct WebSocket Adapter

/// Direct WebSocket connection (no Tor)
final class DirectWebSocketAdapter: BaseWebSocketAdapter, WebSocketManagerProtocol, URLSessionWebSocketDelegate {

    init(config: WebSocketConfiguration) {
        super.init(config: config, logCategory: "DirectWebSocket")
    }

    convenience init(url: URL, sendHeartbeats: Bool = false) {
        let config = WebSocketConfiguration(url: url, sendHeartbeats: sendHeartbeats, useTor: false)
        self.init(config: config)
    }

    override func connect() {
        lock.lock()
        guard state == .disconnected else {
            lock.unlock()
            return
        }
        state = .connecting
        lock.unlock()

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.urlCache = nil
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfig.httpCookieStorage = nil
        sessionConfig.httpShouldSetCookies = false

        urlSession = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: config.url)
        // Set maximum message size to support large video messages
        webSocketTask?.maximumMessageSize = config.maximumMessageSize
        webSocketTask?.resume()

        #if DEBUG
        logger.info("Connecting with max message size: \(self.config.maximumMessageSize) bytes")
        #endif

        startReceiving()
    }

    override func disconnect() {
        lock.lock()
        guard state != .disconnected else {
            lock.unlock()
            return
        }
        state = .disconnecting
        lock.unlock()

        stopHeartbeat()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        setState(.disconnected)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        setState(.connected)
        lastHeartbeatAck = Date()
        startHeartbeat()

        #if DEBUG
        logger.info("Connected")
        #endif
        protocolDelegate?.webSocketDidConnect(self)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let wasConnected = getState() == .connected
        setState(.disconnected)
        stopHeartbeat()

        if wasConnected {
            protocolDelegate?.webSocketDidDisconnect(self, error: nil)
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

// MARK: - Tor WebSocket Adapter

/// WebSocket connection routed through Tor
final class TorWebSocketAdapter: BaseWebSocketAdapter, WebSocketManagerProtocol, URLSessionWebSocketDelegate {

    private let torManager = EphemeralTorManager.shared
    private var autoReconnect = true
    private var reconnectionAttempts = 0
    private let maxReconnectionAttempts = 5
    private var reconnectionTimer: Timer?

    init(config: WebSocketConfiguration) {
        super.init(config: config, logCategory: "TorWebSocket")
    }

    convenience init(url: URL, sendHeartbeats: Bool = false) {
        let config = WebSocketConfiguration(url: url, sendHeartbeats: sendHeartbeats, useTor: true)
        self.init(config: config)
    }

    override func connect() {
        lock.lock()
        guard state == .disconnected else {
            lock.unlock()
            return
        }
        autoReconnect = true
        lock.unlock()

        // Check if Tor is ready
        if torManager.state.isConnected {
            performConnect()
        } else {
            setState(.connecting)
            #if DEBUG
            logger.info("Waiting for Tor connection...")
            #endif

            // Start Tor if not already running
            if case .disconnected = torManager.state {
                torManager.connect()
            }

            // Observe Tor state changes
            setupTorObserver()
        }
    }

    private func setupTorObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(torStateChanged(_:)),
            name: .torStateDidChange,
            object: nil
        )
    }

    @objc private func torStateChanged(_ notification: Notification) {
        guard let torState = notification.userInfo?["state"] as? TorConnectionState else { return }

        switch torState {
        case .connected:
            lock.lock()
            if state == .connecting && webSocketTask == nil {
                lock.unlock()
                performConnect()
            } else {
                lock.unlock()
            }

        case .failed(let reason):
            #if DEBUG
            logger.error("Tor failed: \(reason)")
            #endif
            cleanupConnection()
            protocolDelegate?.webSocketDidDisconnect(self, error: TorError.torNotAvailable)

        default:
            break
        }
    }

    private func performConnect() {
        setState(.connecting)
        reconnectionAttempts = 0

        // Create session with Tor proxy
        let sessionConfig = torManager.createTorSessionConfiguration()
        // Increase timeouts for Tor - onion routing adds significant latency
        sessionConfig.timeoutIntervalForRequest = 120  // 2 minutes for initial request
        // Long-lived WebSocket connections need very long resource timeout
        // The -1001 timeout errors happen when circuits become stale
        // Setting to 0 means no timeout (unlimited)
        sessionConfig.timeoutIntervalForResource = 0   // No resource timeout for persistent WebSocket

        urlSession = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: .main)
        webSocketTask = urlSession?.webSocketTask(with: config.url)
        // Set maximum message size to support large video messages
        webSocketTask?.maximumMessageSize = config.maximumMessageSize
        webSocketTask?.resume()

        #if DEBUG
        logger.info("Connecting through Tor with max message size: \(self.config.maximumMessageSize) bytes")
        #endif

        startReceiving()
    }

    override func disconnect() {
        lock.lock()
        autoReconnect = false
        guard state != .disconnected else {
            lock.unlock()
            return
        }
        state = .disconnecting
        lock.unlock()

        NotificationCenter.default.removeObserver(self, name: .torStateDidChange, object: nil)

        stopHeartbeat()
        stopPing()
        stopReconnectionTimer()

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        setState(.disconnected)
    }

    override func handleHeartbeatTimeout() {
        #if DEBUG
        logger.warning("Heartbeat timeout - checking Tor circuit")
        #endif
        handleConnectionLost()
    }

    private func handleConnectionLost() {
        #if DEBUG
        logger.info("Connection lost - requesting new Tor circuit before reconnecting")
        #endif

        let wasConnected = getState() == .connected
        cleanupConnection()

        guard wasConnected && autoReconnect else {
            protocolDelegate?.webSocketDidDisconnect(self, error: WebSocketError.connectionFailed)
            return
        }

        // Always request a new circuit after connection loss
        // This helps avoid stale circuit issues that can cause repeated timeouts
        torManager.requestNewCircuit { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success:
                #if DEBUG
                self.logger.info("New circuit obtained, attempting reconnection")
                #endif
                self.attemptReconnection()
            case .failure(let error):
                #if DEBUG
                self.logger.warning("Circuit rotation failed: \(error.localizedDescription), forcing Tor reconnect")
                #endif
                self.torManager.forceReconnect()
                // Retry with additional delay to let Tor rebuild
                self.attemptReconnection(additionalDelay: 5.0)
            }
        }
    }

    private func attemptReconnection(additionalDelay: TimeInterval = 0) {
        lock.lock()

        guard autoReconnect else {
            lock.unlock()
            return
        }

        guard reconnectionAttempts < maxReconnectionAttempts else {
            lock.unlock()
            #if DEBUG
            logger.error("Max reconnection attempts reached")
            #endif
            protocolDelegate?.webSocketDidDisconnect(self, error: WebSocketError.connectionFailed)
            return
        }

        reconnectionAttempts += 1
        let attempt = reconnectionAttempts
        lock.unlock()

        // Exponential backoff with jitter
        // Start with longer base delay (3s) to give Tor circuits and server time to clean up
        let baseDelay = min(pow(2.0, Double(attempt - 1)) * 3.0, 30.0)
        let jitter = Double.random(in: 0...2)
        let delay = baseDelay + jitter + additionalDelay

        #if DEBUG
        logger.info("Reconnection attempt \(attempt)/\(self.maxReconnectionAttempts) in \(String(format: "%.1f", delay))s")
        #endif

        DispatchQueue.main.async { [weak self] in
            self?.reconnectionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self = self else { return }

                // Request new circuit before reconnecting to avoid stale circuit issues
                if self.torManager.state.isConnected {
                    self.torManager.requestNewCircuit { [weak self] _ in
                        // Proceed with reconnection regardless of circuit rotation result
                        self?.performConnect()
                    }
                } else {
                    self.setState(.connecting)
                }
            }
        }
    }

    private func stopReconnectionTimer() {
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        setState(.connected)
        lastHeartbeatAck = Date()
        reconnectionAttempts = 0
        startHeartbeat()
        startPing() // Start WebSocket-level ping to keep SOCKS proxy alive

        #if DEBUG
        logger.info("Connected through Tor")
        #endif
        protocolDelegate?.webSocketDidConnect(self)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let wasConnected = getState() == .connected
        setState(.disconnected)
        stopHeartbeat()

        if wasConnected && autoReconnect {
            handleConnectionLost()
        } else if wasConnected {
            protocolDelegate?.webSocketDidDisconnect(self, error: nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            let nsError = error as NSError
            #if DEBUG
            logger.error("URLSession task completed with error: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")
            #endif
            handleConnectionLost()
        }
    }
}
