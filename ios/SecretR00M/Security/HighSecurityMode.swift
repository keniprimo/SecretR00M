import Foundation

#if DEBUG
import os.log
#endif

/// HighSecurityMode manages strict security settings for maximum privacy.
/// Integrates traffic analysis resistance, cover traffic, and Tor hardening.
final class HighSecurityMode {

    // MARK: - Singleton

    static let shared = HighSecurityMode()

    // MARK: - Properties

    #if DEBUG
    private let logger = Logger(subsystem: "com.ephemeral.rooms", category: "HighSecurityMode")
    #endif

    /// Whether high security mode is currently enabled
    private(set) var isEnabled = false

    /// Traffic padding manager for analysis resistance
    let coverTrafficManager = CoverTrafficManager()

    /// Settings for high security mode
    let settings = Settings()

    // MARK: - Settings

    struct Settings {
        // Content visibility
        let disableAllPreviews = true
        let requirePressAndHoldToReveal = true
        let revealTimeout: TimeInterval = 3.0
        let hideContactNames = true
        let hideAvatars = true
        let disableLinkPreviews = true

        // Auto-lock
        let autoLockTimeout: TimeInterval = 30.0
        let lockOnBackground = true
        let lockOnCapture = true

        // Capture response
        let blankUIOnCapture = true
        let rekeyOnScreenshot = true
        let rekeyOnRecording = true
        let rekeyOnBackground = true

        // Quick Exit
        let showExitButton = true
        let exitOnShake = false  // Could enable shake-to-exit

        // SECURITY: Traffic analysis resistance settings
        let coverTrafficMode: CoverTrafficManager.Mode = .medium
        let useLargerPaddingBuckets = true
        let heartbeatJitter: Double = 0.4  // 40% jitter (vs 30% normal)
        let circuitRotationInterval: TimeInterval = 300  // 5 minutes (vs 10 normal)

        // SECURITY: Tor hardening
        let wipeTorDirectoryOnExit = true
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Control

    /// Enable high security mode
    func enable() {
        guard !isEnabled else { return }
        isEnabled = true

        #if DEBUG
        logger.info("High security mode ENABLED")
        #endif

        // Configure Tor for high security
        EphemeralTorManager.shared.configureHighSecurityMode(true)

        // Enable strict network validation
        NetworkSecurityValidator.shared.strictMode = true

        NotificationCenter.default.post(
            name: .highSecurityModeDidChange,
            object: self,
            userInfo: ["enabled": true]
        )
    }

    /// Disable high security mode
    func disable() {
        guard isEnabled else { return }
        isEnabled = false

        #if DEBUG
        logger.info("High security mode DISABLED")
        #endif

        // Stop cover traffic
        coverTrafficManager.stop()

        // Configure Tor for normal operation
        EphemeralTorManager.shared.configureHighSecurityMode(false)

        NotificationCenter.default.post(
            name: .highSecurityModeDidChange,
            object: self,
            userInfo: ["enabled": false]
        )
    }

    /// Toggle high security mode
    func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }

    // MARK: - Configuration Application

    /// Apply high security settings to a room configuration
    func applyTo(_ configuration: inout RoomConfiguration) {
        configuration.highSecurityMode = isEnabled
        configuration.rekeyOnScreenshot = settings.rekeyOnScreenshot
        configuration.rekeyOnRecording = settings.rekeyOnRecording
        configuration.notifyOnCapture = true
    }

    // MARK: - Session Integration

    /// Start cover traffic for a session
    /// - Parameter session: The session to send cover traffic through
    func startCoverTraffic(for session: CoverTrafficDelegate) {
        guard isEnabled else { return }
        #if DEBUG
        logger.info("Starting traffic padding for session")
        #endif
        coverTrafficManager.start(mode: settings.coverTrafficMode, session: session)
    }

    /// Stop padding traffic when session ends
    func stopCoverTraffic() {
        coverTrafficManager.stop()

        #if DEBUG
        // Log statistics
        let stats = coverTrafficManager.statistics
        logger.info("Traffic padding stats: \(stats.padding) padding, \(stats.real) real, ratio: \(String(format: "%.2f", stats.ratio))")
        #endif
    }

    // MARK: - Cleanup

    /// Perform secure cleanup when app exits
    func performSecureCleanup() {
        #if DEBUG
        logger.info("Performing secure cleanup")
        #endif

        // Stop cover traffic
        stopCoverTraffic()

        // Wipe Tor directory if configured
        if settings.wipeTorDirectoryOnExit {
            EphemeralTorManager.shared.wipeTorDirectory()
        }

        #if DEBUG
        logger.info("Secure cleanup completed")
        #endif
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let highSecurityModeDidChange = Notification.Name("highSecurityModeDidChange")
}
