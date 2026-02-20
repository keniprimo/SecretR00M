import Foundation
import UIKit

/// Delegate for security monitor events
protocol SecurityMonitorDelegate: AnyObject {
    func securityMonitor(_ monitor: SecurityMonitor, didDetect event: SecurityEventType)
}

/// SecurityMonitor detects security-relevant events like screenshots and screen recording.
/// Note: iOS does not allow preventing screenshots/recording, only detecting them.
final class SecurityMonitor {

    // MARK: - Properties

    weak var delegate: SecurityMonitorDelegate?

    private var isMonitoring = false
    private var wasRecording = false

    // MARK: - Initialization

    init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Monitoring Control

    /// Start monitoring for security events
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Screen recording/mirroring detection (iOS 11+)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(capturedDidChange),
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )

        // Screenshot detection (iOS 7+)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDidTakeScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )

        // App lifecycle for background/lock detection
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(protectedDataWillBecomeUnavailable),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )

        // Check initial state
        wasRecording = UIScreen.main.isCaptured
    }

    /// Stop monitoring for security events
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Current State

    /// Check if screen is currently being captured (recording/mirroring)
    var isScreenBeingCaptured: Bool {
        return UIScreen.main.isCaptured
    }

    /// Get current security state
    func currentState() -> SecurityState {
        return SecurityState(
            isScreenBeingCaptured: UIScreen.main.isCaptured,
            isMonitoring: isMonitoring
        )
    }

    // MARK: - Event Handlers

    @objc private func capturedDidChange() {
        let isNowRecording = UIScreen.main.isCaptured

        if isNowRecording && !wasRecording {
            // Recording started
            delegate?.securityMonitor(self, didDetect: .screenRecordingStarted)
        } else if !isNowRecording && wasRecording {
            // Recording stopped
            delegate?.securityMonitor(self, didDetect: .screenRecordingStopped)
        }

        wasRecording = isNowRecording
    }

    @objc private func userDidTakeScreenshot() {
        // Screenshot already taken - we can only react
        delegate?.securityMonitor(self, didDetect: .screenshotDetected)
    }

    @objc private func didEnterBackground() {
        delegate?.securityMonitor(self, didDetect: .backgrounded)
    }

    @objc private func protectedDataWillBecomeUnavailable() {
        delegate?.securityMonitor(self, didDetect: .deviceLocked)
    }
}

/// Current security state
struct SecurityState {
    let isScreenBeingCaptured: Bool
    let isMonitoring: Bool
}
