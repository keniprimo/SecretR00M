import Foundation
import Network

#if DEBUG
import os.log
#endif

/// SECURITY: NetworkSecurityValidator ensures all traffic goes through Tor
/// and detects potential clearnet escapes or configuration errors.
///
/// Defense-in-depth measures:
/// - Validates URLs are .onion before any connection
/// - Checks that SOCKS proxy is properly configured
/// - Monitors for unexpected network activity
/// - Provides fail-closed behavior
final class NetworkSecurityValidator {

    // MARK: - Singleton

    static let shared = NetworkSecurityValidator()

    // MARK: - Properties

    #if DEBUG
    private let logger = Logger(subsystem: "com.ephemeral.rooms", category: "NetworkSecurity")
    #endif

    /// SECURITY: Flag to enable strict mode (crashes on violations)
    var strictMode: Bool = true

    // MARK: - URL Validation

    /// SECURITY: Validate that a URL is safe to connect to
    /// - Parameter url: The URL to validate
    /// - Returns: True if the URL is a valid .onion address
    func isValidOnionURL(_ url: URL) -> Bool {
        guard let host = url.host else {
            #if DEBUG
            logger.error("URL has no host")
            #endif
            return false
        }

        // Must be .onion
        guard host.hasSuffix(".onion") else {
            #if DEBUG
            logger.error("SECURITY VIOLATION: Non-onion URL detected")
            #endif
            handleViolation("Attempted connection to non-.onion URL")
            return false
        }

        // Validate onion address format
        let onionAddress = String(host.dropLast(6))

        // v3 onion: 56 chars, v2 onion: 16 chars
        guard onionAddress.count == 56 || onionAddress.count == 16 else {
            #if DEBUG
            logger.error("Invalid onion address length: \(onionAddress.count)")
            #endif
            return false
        }

        // Validate base32 character set
        let base32 = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz234567")
        guard onionAddress.unicodeScalars.allSatisfy({ base32.contains($0) }) else {
            #if DEBUG
            logger.error("Invalid onion address characters")
            #endif
            return false
        }

        // Validate scheme
        guard let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            #if DEBUG
            logger.error("Invalid scheme for WebSocket")
            #endif
            return false
        }

        return true
    }

    /// SECURITY: Validate URL string before connection
    func validateConnectionURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else {
            #if DEBUG
            logger.error("Invalid URL string")
            #endif
            return false
        }
        return isValidOnionURL(url)
    }

    // MARK: - Session Configuration Validation

    /// SECURITY: Validate that a URLSessionConfiguration has Tor proxy set
    /// - Parameter config: The session configuration to validate
    /// - Returns: True if properly configured for Tor
    func validateSessionConfiguration(_ config: URLSessionConfiguration) -> Bool {
        guard let proxyDict = config.connectionProxyDictionary else {
            #if DEBUG
            logger.error("SECURITY VIOLATION: No proxy configuration found")
            #endif
            handleViolation("URLSession has no proxy configured")
            return false
        }

        // Check for SOCKS proxy settings
        let socksEnable = proxyDict["SOCKSEnable"] as? Bool ?? false
        let socksProxy = proxyDict["SOCKSProxy"] as? String

        guard socksEnable else {
            #if DEBUG
            logger.error("SECURITY VIOLATION: SOCKS proxy not enabled")
            #endif
            handleViolation("SOCKS proxy is disabled")
            return false
        }

        guard socksProxy == "127.0.0.1" || socksProxy == "localhost" else {
            #if DEBUG
            logger.error("SECURITY VIOLATION: SOCKS proxy not pointing to localhost")
            #endif
            handleViolation("SOCKS proxy pointing to unexpected host")
            return false
        }

        #if DEBUG
        // Verify no cookies, no caching
        if config.httpCookieStorage != nil {
            logger.warning("Cookie storage is enabled - potential privacy leak")
        }

        if config.urlCache != nil {
            logger.warning("URL cache is enabled - potential privacy leak")
        }
        #endif

        return true
    }

    // MARK: - Runtime Checks

    /// SECURITY: Perform pre-connection validation
    /// Call this before any network operation
    /// - Parameters:
    ///   - url: The target URL
    ///   - config: The session configuration
    /// - Returns: True if safe to proceed
    func validateBeforeConnection(url: URL, config: URLSessionConfiguration) -> Bool {
        // Check URL
        guard isValidOnionURL(url) else {
            return false
        }

        // Check configuration
        guard validateSessionConfiguration(config) else {
            return false
        }

        // Check Tor is actually connected
        let torManager = EphemeralTorManager.shared
        guard torManager.state.isConnected else {
            #if DEBUG
            logger.error("SECURITY VIOLATION: Attempting connection without secure route")
            #endif
            handleViolation("Secure connection not established")
            return false
        }

        #if DEBUG
        logger.debug("Pre-connection validation passed")
        #endif
        return true
    }

    // MARK: - Violation Handling

    /// SECURITY: Handle a security violation
    /// In strict mode, this crashes the app to prevent data leakage
    private func handleViolation(_ message: String) {
        #if DEBUG
        logger.critical("SECURITY VIOLATION: \(message)")
        #endif

        // Post notification for UI handling
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .networkSecurityViolation,
                object: nil,
                userInfo: ["message": message]
            )
        }

        if strictMode {
            // SECURITY: Fail closed - crash to prevent clearnet traffic
            fatalError("SECURITY VIOLATION: \(message). Network safety cannot be guaranteed.")
        }
    }

    // MARK: - Diagnostic Tests

    /// SECURITY: Run diagnostic tests to verify Tor configuration
    /// Returns a report of any issues found
    func runDiagnostics() -> [String] {
        var issues: [String] = []

        // Check Tor state
        let torManager = EphemeralTorManager.shared
        if !torManager.state.isConnected {
            issues.append("Secure connection not established")
        }

        if torManager.socksPort == 0 {
            issues.append("SOCKS port is not set")
        }

        // Check for simulator
        #if targetEnvironment(simulator)
        issues.append("CRITICAL: Running in simulator - Secure routing not available")
        #endif

        // Check default configuration
        let defaultConfig = RoomConfiguration.default
        if !validateConnectionURL(defaultConfig.serverURL) {
            issues.append("Default server URL is not a valid .onion address")
        }

        return issues
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let networkSecurityViolation = Notification.Name("NetworkSecurityViolation")
}

// MARK: - IP Leak Detection (Best Effort)

extension NetworkSecurityValidator {

    /// SECURITY: Check if an IP address appears to be a clearnet address
    /// This is a heuristic check - Tor should prevent any IP leakage
    func isLikelyClearnetIP(_ address: String) -> Bool {
        // .onion addresses should never resolve to IPs
        // If we see an IP, something is wrong

        // IPv4 pattern
        let ipv4Pattern = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
        if address.range(of: ipv4Pattern, options: .regularExpression) != nil {
            #if DEBUG
            logger.error("Clearnet IPv4 detected")
            #endif
            return true
        }

        // IPv6 pattern (simplified)
        if address.contains(":") && !address.hasSuffix(".onion") {
            #if DEBUG
            logger.error("Clearnet IPv6 detected")
            #endif
            return true
        }

        return false
    }
}

// MARK: - WebSocket Validation

extension NetworkSecurityValidator {

    /// SECURITY: Create a validated WebSocket configuration
    /// This is the ONLY way to create WebSocket connections
    func createValidatedWebSocketConfig(
        urlString: String,
        sendHeartbeats: Bool = false
    ) -> WebSocketConfiguration? {
        // Validate URL first
        guard validateConnectionURL(urlString) else {
            #if DEBUG
            logger.error("Failed to create WebSocket config: Invalid URL")
            #endif
            return nil
        }

        // Force Tor usage - no option to disable
        return WebSocketConfiguration(
            urlString: urlString,
            sendHeartbeats: sendHeartbeats,
            useTor: true,  // Always true - hardcoded for safety
            heartbeatJitter: 0.3  // 30% jitter for traffic analysis resistance
        )
    }
}
