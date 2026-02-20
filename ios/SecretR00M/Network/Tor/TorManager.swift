import Foundation
import Network
import UIKit
import Security
import CFNetwork
#if DEBUG
import os.log
#endif

#if !targetEnvironment(simulator)
import Tor
import IPtProxy
import IPtProxyUI
#endif

// MARK: - Tor Connection States

/// Tor connection states with associated data
enum TorConnectionState: Equatable {
    case disconnected
    case bootstrapping(progress: Int)
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        switch self {
        case .bootstrapping, .reconnecting:
            return true
        default:
            return false
        }
    }
}

/// Tor circuit health status
enum CircuitHealth: Equatable {
    case healthy
    case degraded
    case unhealthy
    case unknown
}

// MARK: - Errors

/// TorError errors
enum TorError: Error, LocalizedError {
    case notConnected
    case bootstrapFailed(String)
    case bootstrapTimeout
    case circuitBuildFailed
    case proxyConnectionFailed
    case torNotAvailable
    case networkUnavailable
    case maxRetriesExceeded
    case healthCheckFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Secure connection not established"
        case .bootstrapFailed(let reason):
            return "Connection failed: \(reason)"
        case .bootstrapTimeout:
            return "Connection timed out"
        case .circuitBuildFailed:
            return "Failed to establish secure route"
        case .proxyConnectionFailed:
            return "Failed to connect to secure proxy"
        case .torNotAvailable:
            return "Secure service is not available"
        case .networkUnavailable:
            return "Network is not available"
        case .maxRetriesExceeded:
            return "Maximum connection attempts exceeded"
        case .healthCheckFailed:
            return "Secure connection health check failed"
        }
    }
}

// MARK: - Bridge Transport Types

/// Available Tor bridge transport types for censorship circumvention
enum BridgeTransportType: String, CaseIterable, Codable {
    case automatic = "automatic"
    case obfs4 = "obfs4"
    case snowflake = "snowflake"
    case meek = "meek"
    case direct = "direct"

    var displayName: String {
        switch self {
        case .automatic: return "Direct"  // Legacy, maps to direct
        case .direct: return "Direct (Recommended)"
        case .obfs4: return "obfs4 Bridge"
        case .snowflake: return "Snowflake Bridge"
        case .meek: return "Meek Bridge"
        }
    }

    var description: String {
        switch self {
        case .automatic: return "Connect directly without bridges"  // Legacy
        case .direct: return "Fastest option, works on most networks"
        case .obfs4: return "Obfuscated protocol for censored networks"
        case .snowflake: return "WebRTC-based, for heavily censored networks"
        case .meek: return "Domain fronting, slowest but most resistant"
        }
    }
}

// MARK: - Retry Configuration

/// Configuration for connection retry behavior
struct TorRetryConfiguration {
    var maxRetries: Int = 4
    static let `default` = TorRetryConfiguration()
}

// MARK: - Delegate Protocol

/// TorManager delegate for status updates
protocol TorManagerDelegate: AnyObject {
    func torManager(_ manager: EphemeralTorManager, didChangeState state: TorConnectionState)
    func torManager(_ manager: EphemeralTorManager, didUpdateCircuitHealth health: CircuitHealth)
    func torManager(_ manager: EphemeralTorManager, didEncounterError error: Error)
}

// MARK: - Notifications

extension Notification.Name {
    static let torStateDidChange = Notification.Name("TorManagerStateDidChange")
    static let torCircuitHealthDidChange = Notification.Name("TorManagerCircuitHealthDidChange")
    static let torDidEncounterError = Notification.Name("TorManagerDidEncounterError")
    static let torDidBecomeReady = Notification.Name("TorManagerDidBecomeReady")
}

// MARK: - EphemeralTorManager

/// Minimal Tor manager using raw Tor.framework (TorThread + TorController).
///
/// This implementation bypasses the TorManager pod entirely and talks to Tor directly.
/// It uses fixed ports, no bridges, no retries, no state reuse.
///
/// Startup timeline:
///   1. Wipe + create data directory (fresh every time)
///   2. Build TorConfiguration with fixed ports and minimal torrc
///   3. Start TorThread
///   4. Connect TorController to control port
///   5. Authenticate with cookie
///   6. Subscribe to STATUS_CLIENT events
///   7. Wait for bootstrap 100%
///   8. Read SOCKS port from getInfoForKeys
///   9. Verify SOCKS with TCP handshake
///  10. Mark as connected
///
/// If ANY step fails → state = .failed, no retry.
final class EphemeralTorManager {

    // MARK: - Singleton

    static let shared = EphemeralTorManager()

    // MARK: - Fixed Ports

    /// Fixed SOCKS port. No auto-assignment, no guessing.
    private static let fixedSocksPort: UInt16 = 39050

    // MARK: - Properties

    #if DEBUG
    private let logger = Logger(subsystem: "com.ephemeral.rooms", category: "TorManager")
    #endif

    /// Current connection state
    private(set) var state: TorConnectionState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            #if DEBUG
            logger.info("State changed: \(String(describing: self.state))")
            #endif
            notifyStateChange()
        }
    }

    /// Current circuit health
    private(set) var circuitHealth: CircuitHealth = .unknown {
        didSet {
            guard circuitHealth != oldValue else { return }
            notifyCircuitHealthChange()
        }
    }

    /// Delegate for callbacks
    weak var delegate: TorManagerDelegate?

    /// Current SOCKS port (available after connection)
    private(set) var socksPort: UInt16 = 0

    // MARK: - Simulator Properties

    #if targetEnvironment(simulator)
    private let simulatedSocksPort: UInt16 = 9050
    #endif

    // MARK: - Private Properties

    private var networkMonitor: NWPathMonitor?
    private var isNetworkAvailable = true
    private var isStartingTor = false

    /// Circuit rotation timer
    private var circuitRotationTimer: Timer?
    private var circuitRotationInterval: TimeInterval = 600

    // MARK: - Connection State (preserved for API compatibility)

    private(set) var retryConfiguration = TorRetryConfiguration.default
    private(set) var currentRetryAttempt: Int = 0
    private(set) var currentBridgeType: BridgeTransportType = .automatic
    private(set) var autoRetryEnabled: Bool = true
    private var lastFailureTime: Date?
    private let reconnectCooldown: TimeInterval = 30.0

    // MARK: - Raw Tor.framework objects (Device only)

    #if !targetEnvironment(simulator)
    private var torThread: TorThread?
    private var torController: TorController?
    private var torConfiguration: TorConfiguration?
    private var progressObserver: Any?
    private var circuitObserver: Any?

    /// Stall detection timer
    private var stallTimer: DispatchSourceTimer?
    private var lastProgressTime: Date = Date()
    private var lastProgressPercentage: Int = -1
    private let stallTimeout: TimeInterval = 120

    /// IPtProxy controller for pluggable transports (bridges)
    private var iptController: IPtProxyController?
    private var activeTransport: String?
    #endif

    /// The Tor data directory path
    private var torDirectoryURL: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cacheDir.appendingPathComponent("tor_minimal", isDirectory: true)
    }

    // MARK: - Initialization

    private init() {
        setupNetworkMonitor()
    }

    // MARK: - Public API

    /// Verify that Tor is fully ready for network operations
    func verifyTorReady() -> Bool {
        guard case .connected = state else { return false }
        guard socksPort > 0 else { return false }
        guard circuitHealth == .healthy || circuitHealth == .degraded else { return false }

        #if !targetEnvironment(simulator)
        guard getProxyConfiguration() != nil else { return false }
        #endif

        return true
    }

    /// Start Tor connection
    func connect() {
        guard !state.isConnected && !state.isConnecting else { return }
        guard !isStartingTor else { return }

        guard isNetworkAvailable else {
            state = .failed(reason: "Network unavailable")
            notifyError(TorError.networkUnavailable)
            return
        }

        currentRetryAttempt = 0
        currentBridgeType = EphemeralTorManager.selectedBridgeType
        lastFailureTime = nil
        state = .bootstrapping(progress: 0)

        #if targetEnvironment(simulator)
        startSimulatedTor()
        #else
        startRealTor()
        #endif
    }

    /// Disconnect from Tor
    func disconnect() {
        isStartingTor = false

        #if !targetEnvironment(simulator)
        stopStallTimer()
        teardownTor()
        #endif

        stopCircuitRotation()
        socksPort = 0
        state = .disconnected
        circuitHealth = .unknown
    }

    /// Force reconnection
    func forceReconnect() {
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.connect()
        }
    }

    /// Ensure Tor is connected, reconnecting if necessary
    func ensureConnected() {
        switch state {
        case .disconnected:
            connect()
        case .failed:
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) < reconnectCooldown {
                return
            }
            connect()
        case .connected, .bootstrapping, .reconnecting:
            break
        }
    }

    // MARK: - Circuit Rotation

    func startCircuitRotation(interval: TimeInterval = 600) {
        circuitRotationInterval = interval
        stopCircuitRotation()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.circuitRotationTimer = Timer.scheduledTimer(
                withTimeInterval: interval,
                repeats: true
            ) { [weak self] _ in
                self?.requestNewCircuit { _ in }
            }
        }
    }

    func stopCircuitRotation() {
        circuitRotationTimer?.invalidate()
        circuitRotationTimer = nil
    }

    // MARK: - Bridge Configuration (preserved for API compatibility)

    func setBridgeType(_ type: BridgeTransportType) {
        Self.selectedBridgeType = type
        if state.isConnected || state.isConnecting {
            forceReconnect()
        }
    }

    var availableBridgeTypes: [BridgeTransportType] {
        return BridgeTransportType.allCases
    }

    // MARK: - Retry Configuration (preserved for API compatibility)

    func setRetryConfiguration(_ configuration: TorRetryConfiguration) {
        retryConfiguration = configuration
    }

    func setAutoRetry(enabled: Bool) {
        autoRetryEnabled = enabled
    }

    func retryNow() {
        guard case .failed = state else { return }
        currentRetryAttempt = 0
        lastFailureTime = nil
        isStartingTor = false
        state = .bootstrapping(progress: 0)

        #if targetEnvironment(simulator)
        startSimulatedTor()
        #else
        startRealTor()
        #endif
    }

    func retryWithBridgeType(_ bridgeType: BridgeTransportType) {
        currentBridgeType = bridgeType
        currentRetryAttempt = 0
        isStartingTor = false

        #if !targetEnvironment(simulator)
        teardownTor()
        wipeTorDataDirectory()
        #endif

        lastFailureTime = nil
        state = .bootstrapping(progress: 0)

        #if targetEnvironment(simulator)
        startSimulatedTor()
        #else
        startRealTor()
        #endif
    }

    func cancelRetry() {
        isStartingTor = false
    }

    /// Request a new circuit
    func requestNewCircuit(completion: @escaping (Result<Void, Error>) -> Void) {
        guard state.isConnected else {
            completion(.failure(TorError.notConnected))
            return
        }

        #if targetEnvironment(simulator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.circuitHealth = .healthy
            completion(.success(()))
        }
        #else
        guard let controller = torController else {
            completion(.failure(TorError.notConnected))
            return
        }
        // SIGNAL NEWNYM tells Tor to use new circuits for future requests
        controller.sendCommand("SIGNAL", arguments: ["NEWNYM"], data: nil) { codes, _, stop in
            stop.pointee = true
            let success = codes.contains(where: { $0.intValue == 250 })
            DispatchQueue.main.async {
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(TorError.circuitBuildFailed))
                }
            }
            return true
        }
        #endif
    }

    // MARK: - Proxy Configuration

    func getProxyConfiguration() -> [String: Any]? {
        guard state.isConnected, socksPort > 0 else { return nil }

        #if targetEnvironment(simulator)
        fatalError("SECURITY: Tor is not available in simulator.")
        #else
        // Build SOCKS5 proxy config dictionary manually — no pod dependency.
        // Same keys that the TorManager pod uses internally.
        return [
            kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5,
            kCFStreamPropertySOCKSProxyHost as String: "127.0.0.1",
            kCFStreamPropertySOCKSProxyPort as String: NSNumber(value: socksPort),
        ]
        #endif
    }

    func createTorURLSession() -> URLSession? {
        let config = createTorSessionConfiguration()
        return URLSession(configuration: config)
    }

    func createTorSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral

        #if targetEnvironment(simulator)
        fatalError("SECURITY: Tor is not available in simulator.")
        #else
        if state.isConnected, socksPort > 0 {
            config.connectionProxyDictionary = getProxyConfiguration()
        }
        #endif

        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120

        return config
    }

    // MARK: - Simulator Implementation

    #if targetEnvironment(simulator)

    private func startSimulatedTor() {
        var progress = 0

        func updateProgress() {
            progress += 10

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                self.state = .bootstrapping(progress: progress)

                if progress < 100 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        updateProgress()
                    }
                } else {
                    self.socksPort = self.simulatedSocksPort
                    self.state = .connected
                    self.circuitHealth = .healthy
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            updateProgress()
        }
    }

    #endif

    // MARK: - Real Tor Implementation (Device only)

    #if !targetEnvironment(simulator)

    private func startRealTor() {
        guard !isStartingTor else {
            #if DEBUG
            logger.warning("startRealTor called while already starting — ignoring")
            #endif
            return
        }
        isStartingTor = true

        // ──────────────────────────────────────────────────────────────────
        // STEP 1: Tear down any previous Tor instance completely
        // ──────────────────────────────────────────────────────────────────
        teardownTor()

        // ──────────────────────────────────────────────────────────────────
        // STEP 2: Wipe and recreate data directory (fresh every time)
        // ──────────────────────────────────────────────────────────────────
        wipeTorDataDirectory()

        let fm = FileManager.default
        let dataDir = torDirectoryURL

        do {
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        } catch {
            #if DEBUG
            logger.error("FATAL: Cannot create data directory: \(error.localizedDescription)")
            logger.error("Path: \(dataDir.path)")
            #endif
            isStartingTor = false
            state = .failed(reason: "Cannot create data directory")
            notifyError(TorError.bootstrapFailed("Directory creation failed"))
            return
        }

        // Verify write access
        let testFile = dataDir.appendingPathComponent(".write_test")
        let testData = Data("test".utf8)
        do {
            try testData.write(to: testFile)
            try fm.removeItem(at: testFile)
        } catch {
            #if DEBUG
            logger.error("FATAL: Data directory is not writable: \(error.localizedDescription)")
            #endif
            isStartingTor = false
            state = .failed(reason: "Data directory not writable")
            notifyError(TorError.bootstrapFailed("Directory not writable"))
            return
        }

        #if DEBUG
        logger.info("[STEP 2] Data directory created: \(dataDir.path)")
        #endif

        // ──────────────────────────────────────────────────────────────────
        // STEP 2.5: Start pluggable transport if bridges are enabled
        // ──────────────────────────────────────────────────────────────────
        let bridgeType = Self.selectedBridgeType
        var transportPort: Int = 0
        var transportName: String? = nil
        var bridgeLines: [String] = []

        if bridgeType != .direct && bridgeType != .automatic {
            // Initialize IPtProxy controller
            if iptController == nil {
                Transport.stateLocation = dataDir
                iptController = IPtProxyController(
                    dataDir.path,
                    enableLogging: true,
                    unsafeLogging: false,
                    logLevel: "INFO",
                    transportStopped: nil
                )
            }

            // Configure and start the appropriate transport
            switch bridgeType {
            case .obfs4:
                transportName = IPtProxyObfs4
                do {
                    try iptController?.start(IPtProxyObfs4, proxy: nil)
                    transportPort = iptController?.port(IPtProxyObfs4) ?? 0
                    activeTransport = IPtProxyObfs4
                    bridgeLines = BuiltInBridges.shared?.obfs4?.map { $0.raw } ?? []
                    #if DEBUG
                    logger.info("[STEP 2.5] Started obfs4 transport on port \(transportPort)")
                    #endif
                } catch {
                    #if DEBUG
                    logger.error("[STEP 2.5] Failed to start obfs4: \(error.localizedDescription)")
                    #endif
                }

            case .snowflake:
                transportName = IPtProxySnowflake
                // Configure Snowflake settings from built-in bridges
                if let snowflake = BuiltInBridges.shared?.snowflake?.first {
                    var fronts = Set<String>(["github.githubassets.com"])
                    if let front = snowflake.front { fronts.insert(front) }
                    if let f = snowflake.fronts { fronts.formUnion(f) }

                    iptController?.snowflakeIceServers = snowflake.ice ?? ""
                    iptController?.snowflakeBrokerUrl = snowflake.url?.absoluteString ?? ""
                    iptController?.snowflakeFrontDomains = fronts.joined(separator: ",")
                    iptController?.snowflakeAmpCacheUrl = ""
                }
                do {
                    try iptController?.start(IPtProxySnowflake, proxy: nil)
                    transportPort = iptController?.port(IPtProxySnowflake) ?? 0
                    activeTransport = IPtProxySnowflake
                    // Use raw bridge lines from built-in bridges
                    bridgeLines = BuiltInBridges.shared?.snowflake?.map { $0.raw } ?? []
                    #if DEBUG
                    logger.info("[STEP 2.5] Started snowflake transport on port \(transportPort)")
                    #endif
                } catch {
                    #if DEBUG
                    logger.error("[STEP 2.5] Failed to start snowflake: \(error.localizedDescription)")
                    #endif
                }

            case .meek:
                transportName = IPtProxyMeekLite
                do {
                    try iptController?.start(IPtProxyMeekLite, proxy: nil)
                    transportPort = iptController?.port(IPtProxyMeekLite) ?? 0
                    activeTransport = IPtProxyMeekLite
                    bridgeLines = BuiltInBridges.shared?.meek?.map { $0.raw } ?? []
                    #if DEBUG
                    logger.info("[STEP 2.5] Started meek transport on port \(transportPort)")
                    #endif
                } catch {
                    #if DEBUG
                    logger.error("[STEP 2.5] Failed to start meek: \(error.localizedDescription)")
                    #endif
                }

            default:
                break
            }
        }

        let useBridges = transportPort > 0 && transportName != nil && !bridgeLines.isEmpty

        #if DEBUG
        if useBridges {
            logger.info("[STEP 2.5] Using bridges: \(bridgeType.rawValue) with \(bridgeLines.count) bridge lines")
        } else {
            logger.info("[STEP 2.5] Direct connection (no bridges)")
        }
        #endif

        // ──────────────────────────────────────────────────────────────────
        // STEP 3: Build TorConfiguration
        // ──────────────────────────────────────────────────────────────────
        let conf = TorConfiguration()
        conf.ignoreMissingTorrc = true
        conf.cookieAuthentication = true
        conf.autoControlPort = true       // Let Tor pick a control port and write it to a file
        conf.avoidDiskWrites = true
        conf.dataDirectory = dataDir
        conf.geoipFile = Bundle.geoIp?.geoipFile
        conf.geoip6File = Bundle.geoIp?.geoip6File

        // Build torrc options
        var options: [String: String] = [
            "SocksPort": "127.0.0.1:\(Self.fixedSocksPort)",
            "SafeLogging": "1",
            "LogMessageDomains": "1",
            "UseMicrodescriptors": "1",
            "LearnCircuitBuildTimeout": "1",
            "ConnectionPadding": "1",
        ]

        if useBridges, let tName = transportName {
            options["UseBridges"] = "1"
            options["ClientTransportPlugin"] = "\(tName) socks5 127.0.0.1:\(transportPort)"
        } else {
            options["UseBridges"] = "0"
        }

        #if DEBUG
        options["Log"] = "notice stdout"
        #else
        options["Log"] = "err file /dev/null"
        #endif

        conf.options.addEntries(from: options)

        // Add bridge lines if using bridges
        if useBridges {
            for bridgeLine in bridgeLines {
                conf.arguments.add("--Bridge")
                conf.arguments.add(bridgeLine)
            }
        }

        self.torConfiguration = conf

        #if DEBUG
        logger.info("[STEP 3] TorConfiguration built. SOCKS=127.0.0.1:\(Self.fixedSocksPort), UseBridges=\(useBridges ? "1" : "0")")
        #endif

        // ──────────────────────────────────────────────────────────────────
        // STEP 4: Start TorThread (or reuse existing one — TorThread is a process singleton)
        // ──────────────────────────────────────────────────────────────────
        if let existingThread = TorThread.active {
            #if DEBUG
            logger.info("[STEP 4] Reusing existing TorThread (singleton)")
            #endif
            self.torThread = existingThread
        } else {
            let thread = TorThread(configuration: conf)
            thread.start()
            self.torThread = thread
            #if DEBUG
            logger.info("[STEP 4] TorThread started (new)")
            #endif
        }

        // ──────────────────────────────────────────────────────────────────
        // STEP 5: Connect TorController (after a short delay for Tor to open ports)
        // ──────────────────────────────────────────────────────────────────
        startStallTimer()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.isStartingTor else { return }
            self.connectController()
        }
    }

    /// Connect to Tor's control port, authenticate, and start monitoring bootstrap.
    /// Retries up to `maxControllerAttempts` times with delays between attempts.
    private func connectController(attempt: Int = 1) {
        let maxControllerAttempts = 10

        guard let conf = torConfiguration else {
            fatalConnectError("No TorConfiguration")
            return
        }

        // ──────────────────────────────────────────────────────────────────
        // STEP 5a: Create TorController from control port file
        // ──────────────────────────────────────────────────────────────────
        guard let controlPortFile = conf.controlPortFile else {
            fatalConnectError("No control port file path")
            return
        }

        // Wait for the control port file to appear (Tor writes it after starting)
        var fileAttempts = 0
        while !FileManager.default.fileExists(atPath: controlPortFile.path) && fileAttempts < 40 {
            Thread.sleep(forTimeInterval: 0.25)
            fileAttempts += 1
        }

        guard FileManager.default.fileExists(atPath: controlPortFile.path) else {
            if attempt < maxControllerAttempts {
                #if DEBUG
                DispatchQueue.main.async {
                    self.logger.warning("[STEP 5] Control port file not found, retry \(attempt)/\(maxControllerAttempts)")
                }
                #endif
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self, self.isStartingTor else { return }
                    self.connectController(attempt: attempt + 1)
                }
                return
            }
            fatalConnectError("Control port file never appeared at: \(controlPortFile.path)")
            return
        }

        // TorController(controlPortFile:) reads the port from the file and
        // AUTOMATICALLY connects in the initializer. We don't call connect() again.
        let controller = TorController(controlPortFile: controlPortFile)
        self.torController = controller

        // ──────────────────────────────────────────────────────────────────
        // STEP 5b: Verify controller is connected (it connects in init)
        // ──────────────────────────────────────────────────────────────────
        guard controller.isConnected else {
            if attempt < maxControllerAttempts {
                #if DEBUG
                DispatchQueue.main.async {
                    self.logger.warning("[STEP 5] Controller not connected after init, retry \(attempt)/\(maxControllerAttempts)")
                }
                #endif
                self.torController = nil
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self, self.isStartingTor else { return }
                    self.connectController(attempt: attempt + 1)
                }
                return
            }
            fatalConnectError("Controller not connected after \(maxControllerAttempts) attempts")
            return
        }

        #if DEBUG
        DispatchQueue.main.async {
            self.logger.info("[STEP 5] TorController connected")
        }
        #endif

        // ──────────────────────────────────────────────────────────────────
        // STEP 6: Authenticate with cookie
        // ──────────────────────────────────────────────────────────────────
        guard let cookie = conf.cookie else {
            fatalConnectError("No authentication cookie available")
            return
        }

        controller.authenticate(with: cookie) { [weak self] success, error in
            guard let self = self else { return }

            if let error = error {
                self.fatalConnectError("Authentication failed: \(error.localizedDescription)")
                return
            }

            guard success else {
                self.fatalConnectError("Authentication returned false")
                return
            }

            #if DEBUG
            DispatchQueue.main.async {
                self.logger.info("[STEP 6] Authenticated with cookie")
            }
            #endif

            // ──────────────────────────────────────────────────────────────
            // STEP 7: Subscribe to bootstrap progress events
            // ──────────────────────────────────────────────────────────────
            self.progressObserver = controller.addObserver(forStatusEvents: {
                [weak self] (type, severity, action, arguments) -> Bool in
                guard let self = self else { return false }

                if type == "STATUS_CLIENT" && action == "BOOTSTRAP" {
                    let progress = Int(arguments?["PROGRESS"] ?? "0") ?? 0
                    let summary = arguments?["SUMMARY"] ?? ""

                    #if DEBUG
                    DispatchQueue.main.async {
                        self.logger.info("[BOOTSTRAP] \(progress)% — \(summary)")
                    }
                    #endif

                    DispatchQueue.main.async {
                        guard self.state.isConnecting else { return }
                        self.state = .bootstrapping(progress: progress)

                        // Only reset stall timer when percentage actually increases
                        if progress > self.lastProgressPercentage {
                            self.lastProgressPercentage = progress
                            self.lastProgressTime = Date()
                        }
                    }

                    return true
                }

                return false
            })

            // ──────────────────────────────────────────────────────────────
            // STEP 8: Wait for circuit establishment
            // ──────────────────────────────────────────────────────────────
            self.circuitObserver = controller.addObserver(forCircuitEstablished: {
                [weak self] established in
                guard let self = self, established else { return }

                #if DEBUG
                DispatchQueue.main.async {
                    self.logger.info("[STEP 8] Circuit established!")
                }
                #endif

                // Remove observers — we only need the first establishment
                if let obs = self.progressObserver {
                    controller.removeObserver(obs)
                    self.progressObserver = nil
                }
                if let obs = self.circuitObserver {
                    controller.removeObserver(obs)
                    self.circuitObserver = nil
                }

                // ──────────────────────────────────────────────────────────
                // STEP 9: Read SOCKS port from Tor
                // ──────────────────────────────────────────────────────────
                controller.getInfoForKeys(["net/listeners/socks"]) { [weak self] response in
                    guard let self = self else { return }

                    // Parse "127.0.0.1:39050" from response
                    guard let firstResponse = response.first,
                          let portString = firstResponse.split(separator: ":").last,
                          let port = UInt16(portString) else {

                        #if DEBUG
                        DispatchQueue.main.async {
                            self.logger.error("Failed to parse SOCKS port from: \(response)")
                        }
                        #endif
                        self.fatalConnectError("Cannot read SOCKS port from Tor")
                        return
                    }

                    #if DEBUG
                    DispatchQueue.main.async {
                        self.logger.info("[STEP 9] SOCKS port confirmed: \(port)")
                    }
                    #endif

                    // ──────────────────────────────────────────────────
                    // STEP 10: Verify SOCKS with TCP connection
                    // ──────────────────────────────────────────────────
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.verifySocksAndFinish(port: port)
                    }
                }
            })
        }
    }

    /// Verify SOCKS proxy works with a TCP connection, then mark as connected.
    private func verifySocksAndFinish(port: UInt16) {
        stopStallTimer()

        // TCP connect to SOCKS port to verify it's listening
        let host = NWEndpoint.Host("127.0.0.1")
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: host, port: nwPort, using: .tcp)

        connection.stateUpdateHandler = { [weak self] connectionState in
            guard let self = self else { return }

            switch connectionState {
            case .ready:
                // SOCKS port is accepting connections
                connection.cancel()

                DispatchQueue.main.async {
                    guard self.isStartingTor else { return }
                    self.isStartingTor = false
                    self.socksPort = port

                    #if DEBUG
                    self.logger.info("[STEP 10] SOCKS verified. Tor is READY. Port=\(port)")
                    #endif

                    self.state = .connected
                    self.circuitHealth = .healthy
                }

            case .failed(let error):
                connection.cancel()
                self.fatalConnectError("SOCKS TCP verify failed: \(error.localizedDescription)")

            case .cancelled:
                break

            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))

        // Timeout the SOCKS verification after 10 seconds
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.isStartingTor else { return }
            connection.cancel()
            self.fatalConnectError("SOCKS TCP verify timed out")
        }
    }

    /// Fatal error during connection — tear down everything, set failed state, no retry.
    private func fatalConnectError(_ message: String) {
        #if DEBUG
        DispatchQueue.main.async {
            self.logger.error("FATAL: \(message)")
        }
        #endif

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isStartingTor = false
            self.stopStallTimer()
            self.teardownTor()
            self.lastFailureTime = Date()
            self.state = .failed(reason: message)
            self.notifyError(TorError.bootstrapFailed(message))
        }
    }

    /// Tear down all Tor objects — thread, controller, observers, and transports.
    private func teardownTor() {
        // Stop any active pluggable transport
        if let transport = activeTransport {
            iptController?.stop(transport)
            activeTransport = nil
            #if DEBUG
            logger.info("[TEARDOWN] Stopped transport: \(transport)")
            #endif
        }

        if let obs = progressObserver {
            torController?.removeObserver(obs)
            progressObserver = nil
        }
        if let obs = circuitObserver {
            torController?.removeObserver(obs)
            circuitObserver = nil
        }
        torController?.disconnect()
        torController = nil
        torThread?.cancel()
        torThread = nil
        torConfiguration = nil
    }

    // MARK: - Stall Detection

    private func startStallTimer() {
        stopStallTimer()
        lastProgressTime = Date()
        lastProgressPercentage = -1

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            let elapsed = Date().timeIntervalSince(self.lastProgressTime)
            if elapsed >= self.stallTimeout {
                #if DEBUG
                DispatchQueue.main.async {
                    self.logger.warning("Bootstrap stalled for \(Int(elapsed))s — killing Tor")
                }
                #endif
                self.stopStallTimer()
                DispatchQueue.main.async {
                    guard self.state.isConnecting else { return }
                    self.fatalConnectError("Bootstrap stalled at \(self.lastProgressPercentage)% for \(Int(elapsed))s")
                }
            }
        }
        timer.resume()
        stallTimer = timer
    }

    private func stopStallTimer() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    /// Wipe Tor data directory completely.
    private func wipeTorDataDirectory() {
        try? FileManager.default.removeItem(at: torDirectoryURL)
    }

    #endif

    // MARK: - Network Monitoring

    private func setupNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let wasAvailable = self.isNetworkAvailable
            self.isNetworkAvailable = path.status == .satisfied

            if !wasAvailable && self.isNetworkAvailable {
                DispatchQueue.main.async {
                    self.lastFailureTime = nil
                    switch self.state {
                    case .disconnected, .failed:
                        self.connect()
                    default:
                        break
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        networkMonitor = monitor
    }

    // MARK: - Notifications

    private func notifyStateChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.delegate?.torManager(self, didChangeState: self.state)

            NotificationCenter.default.post(
                name: .torStateDidChange,
                object: self,
                userInfo: ["state": self.state]
            )

            if self.verifyTorReady() {
                NotificationCenter.default.post(
                    name: .torDidBecomeReady,
                    object: self,
                    userInfo: ["socksPort": self.socksPort]
                )
            }
        }
    }

    private func notifyCircuitHealthChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.delegate?.torManager(self, didUpdateCircuitHealth: self.circuitHealth)

            NotificationCenter.default.post(
                name: .torCircuitHealthDidChange,
                object: self,
                userInfo: ["health": self.circuitHealth]
            )
        }
    }

    private func notifyError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.delegate?.torManager(self, didEncounterError: error)

            NotificationCenter.default.post(
                name: .torDidEncounterError,
                object: self,
                userInfo: ["error": error]
            )
        }
    }
}

// MARK: - User Preferences

extension EphemeralTorManager {

    private static let torEnabledKeychainAccount = "com.secretr00m.tor.enabled"
    private static let torEnabledKeychainService = "TorPreferences"
    private static let bridgeTypeKeychainAccount = "com.secretr00m.tor.bridgetype"
    private static let legacyTorEnabledKey = "TorManager.torEnabled"

    static var isTorEnabled: Bool {
        get {
            migrateFromUserDefaultsIfNeeded()
            return getKeychainBool(account: torEnabledKeychainAccount) ?? false
        }
        set {
            setKeychainBool(newValue, account: torEnabledKeychainAccount)
            if newValue {
                shared.connect()
            } else {
                shared.disconnect()
            }
        }
    }

    static var selectedBridgeType: BridgeTransportType {
        get {
            guard let data = getKeychainData(account: bridgeTypeKeychainAccount),
                  let typeString = String(data: data, encoding: .utf8),
                  let type = BridgeTransportType(rawValue: typeString) else {
                // Default to direct connection (no bridges) — bridges are opt-in
                return .direct
            }
            return type
        }
        set {
            if let data = newValue.rawValue.data(using: .utf8) {
                setKeychainData(data, account: bridgeTypeKeychainAccount)
            }
        }
    }

    // MARK: - Migration

    private static var hasMigrated = false
    private static func migrateFromUserDefaultsIfNeeded() {
        guard !hasMigrated else { return }
        hasMigrated = true

        let defaults = UserDefaults.standard
        guard defaults.object(forKey: legacyTorEnabledKey) != nil else { return }

        let oldValue = defaults.bool(forKey: legacyTorEnabledKey)
        setKeychainBool(oldValue, account: torEnabledKeychainAccount)

        defaults.removeObject(forKey: legacyTorEnabledKey)
        defaults.synchronize()
    }

    // MARK: - Keychain Helpers

    private static func setKeychainBool(_ value: Bool, account: String) {
        let data = Data([value ? 1 : 0])
        setKeychainData(data, account: account)
    }

    private static func getKeychainBool(account: String) -> Bool? {
        guard let data = getKeychainData(account: account), !data.isEmpty else {
            return nil
        }
        return data[0] != 0
    }

    private static func setKeychainData(_ data: Data, account: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: torEnabledKeychainService
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: torEnabledKeychainService,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func getKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: torEnabledKeychainService,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }
}

// MARK: - Security Hardening

extension EphemeralTorManager {

    func wipeTorDirectory() {
        if state.isConnected || state.isConnecting {
            disconnect()
        }

        let torDir = torDirectoryURL

        do {
            if FileManager.default.fileExists(atPath: torDir.path) {
                try secureDeleteDirectory(at: torDir)
            }
        } catch {
            #if DEBUG
            logger.error("Failed to wipe Tor directory: \(error.localizedDescription)")
            #endif
        }
    }

    private func secureDeleteDirectory(at url: URL) throws {
        let fileManager = FileManager.default

        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for item in contents {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                try secureDeleteDirectory(at: item)
            } else {
                try secureDeleteFile(at: item)
            }
        }

        try fileManager.removeItem(at: url)
    }

    private func secureDeleteFile(at url: URL) throws {
        let fileManager = FileManager.default

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int,
              fileSize > 0 else {
            try fileManager.removeItem(at: url)
            return
        }

        for _ in 0..<3 {
            var randomData = Data(count: fileSize)
            _ = randomData.withUnsafeMutableBytes { ptr in
                SecRandomCopyBytes(kSecRandomDefault, fileSize, ptr.baseAddress!)
            }
            try randomData.write(to: url)
        }

        try fileManager.removeItem(at: url)
    }

    func configureHighSecurityMode(_ enabled: Bool) {
        if enabled {
            startCircuitRotation(interval: 300)
        } else {
            startCircuitRotation(interval: 600)
        }
    }
}
