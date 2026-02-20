import Foundation
import UIKit
import MachO

/// DeviceIntegrityChecker performs best-effort device security checks.
///
/// IMPORTANT: This cannot detect sophisticated spyware like Pegasus.
/// These are heuristics only and should not be relied upon for security.
/// False positives are possible. Do not block users based solely on these checks.
enum DeviceIntegrityChecker {

    // MARK: - Result Types

    enum RiskLevel: String {
        case normal = "normal"
        case elevated = "elevated"
        case high = "high"
    }

    enum RiskIndicator: String {
        case jailbreakPaths = "jailbreak_paths"
        case jailbreakApps = "jailbreak_apps"
        case debuggerAttached = "debugger_attached"
        case screenCaptureActive = "screen_capture_active"
        case suspiciousDylibs = "suspicious_dylibs"
        case sandboxCompromised = "sandbox_compromised"
    }

    struct IntegrityResult {
        let riskLevel: RiskLevel
        let indicators: [RiskIndicator]
        let timestamp: Date

        var hasRisks: Bool {
            return riskLevel != .normal
        }
    }

    // MARK: - Check

    /// Perform device integrity check
    /// - Returns: Result with risk level and detected indicators
    static func performCheck() -> IntegrityResult {
        var indicators: [RiskIndicator] = []

        // Check for jailbreak paths
        if checkJailbreakPaths() {
            indicators.append(.jailbreakPaths)
        }

        // Check for jailbreak apps
        if checkJailbreakApps() {
            indicators.append(.jailbreakApps)
        }

        // Check for debugger
        if isDebuggerAttached() {
            indicators.append(.debuggerAttached)
        }

        // Check screen capture
        if UIScreen.main.isCaptured {
            indicators.append(.screenCaptureActive)
        }

        // Check for suspicious dylibs
        if hasSuspiciousDylibs() {
            indicators.append(.suspiciousDylibs)
        }

        // Check sandbox
        if isSandboxCompromised() {
            indicators.append(.sandboxCompromised)
        }

        // Determine risk level
        let riskLevel: RiskLevel
        switch indicators.count {
        case 0:
            riskLevel = .normal
        case 1:
            riskLevel = .elevated
        default:
            riskLevel = .high
        }

        return IntegrityResult(
            riskLevel: riskLevel,
            indicators: indicators,
            timestamp: Date()
        )
    }

    // MARK: - Individual Checks

    /// Check for common jailbreak file paths
    private static func checkJailbreakPaths() -> Bool {
        let jailbreakPaths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/private/var/lib/apt",
            "/private/var/lib/cydia",
            "/private/var/stash",
            "/usr/sbin/sshd",
            "/usr/bin/ssh",
            "/bin/bash",
            "/etc/apt",
            "/Library/MobileSubstrate/MobileSubstrate.dylib"
        ]

        for path in jailbreakPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }

        return false
    }

    /// Check if jailbreak apps can be opened
    private static func checkJailbreakApps() -> Bool {
        let jailbreakURLs = [
            "cydia://",
            "sileo://",
            "zbra://"
        ]

        for urlString in jailbreakURLs {
            if let url = URL(string: urlString),
               UIApplication.shared.canOpenURL(url) {
                return true
            }
        }

        return false
    }

    /// Check if debugger is attached (P_TRACED flag)
    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        guard result == 0 else { return false }

        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Check for suspicious loaded dylibs
    private static func hasSuspiciousDylibs() -> Bool {
        let suspiciousFrameworks = [
            "FridaGadget",
            "frida",
            "cynject",
            "libcycript",
            "SSLKillSwitch",
            "SSLKillSwitch2",
            "MobileSubstrate",
            "SubstrateInserter",
            "SubstrateBootstrap"
        ]

        for i in 0..<_dyld_image_count() {
            guard let namePtr = _dyld_get_image_name(i) else { continue }
            let imageName = String(cString: namePtr)

            for suspicious in suspiciousFrameworks {
                if imageName.lowercased().contains(suspicious.lowercased()) {
                    return true
                }
            }
        }

        return false
    }

    /// Check if sandbox appears compromised
    private static func isSandboxCompromised() -> Bool {
        // Try to write outside sandbox
        let testPath = "/private/test_sandbox_\(UUID().uuidString)"

        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            // If we could write, sandbox is compromised
            try? FileManager.default.removeItem(atPath: testPath)
            return true
        } catch {
            // Expected - sandbox working correctly
            return false
        }
    }

    // MARK: - User-Friendly Messages

    /// Get a user-friendly description of the risk level
    static func riskDescription(for result: IntegrityResult) -> String {
        switch result.riskLevel {
        case .normal:
            return "Device security appears normal."
        case .elevated:
            return "Elevated risk environment detected. For maximum security, consider using a different device."
        case .high:
            return "High-risk environment detected. This device may have security modifications that could compromise message privacy."
        }
    }
}
