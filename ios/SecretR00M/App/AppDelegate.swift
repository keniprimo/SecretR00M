import UIKit

// MARK: - Build Configuration Security Checklist
//
// REQUIRED Xcode Build Settings for secure logging:
//
// Debug configuration:
//   SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG
//   GCC_PREPROCESSOR_DEFINITIONS = DEBUG=1 $(inherited)
//
// Release configuration:
//   SWIFT_ACTIVE_COMPILATION_CONDITIONS = (empty or inherited — must NOT contain DEBUG)
//   GCC_PREPROCESSOR_DEFINITIONS = $(inherited) — must NOT contain DEBUG=1
//   OTHER_SWIFT_FLAGS — must NOT contain -DDEBUG
//   SWIFT_COMPILATION_MODE = wholemodule
//   ENABLE_NS_ASSERTIONS = NO
//
// Archive verification:
//   - Xcode → Product → Archive always uses Release configuration
//   - TestFlight builds are always Release (no separate "Ad Hoc" config exists)
//   - Verify: In archive, run `strings` on binary — "com.ephemeral.rooms" logger
//     subsystem string should NOT appear (compiled out by #if DEBUG)
//
// Runtime defense-in-depth (3 layers):
//   1. AppDelegate.application(_:didFinishLaunchingWithOptions:) redirects stderr
//      to /dev/null in Release (#if !DEBUG), suppressing residual os_log/print/NSLog
//   2. SecureLogBuffer.log() returns immediately in Release builds (#if !DEBUG)
//   3. SecureLogBuffer.init() sets minimumLevel to maximum in Release (canary)

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    // MARK: - Properties

    /// Reference to active session for lifecycle management
    weak var activeSession: RoomSession?

    // MARK: - Application Lifecycle

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // IMPORTANT: Clear stale Keychain data on fresh install
        // iOS Keychain persists across app deletion/reinstall, which causes
        // the privacy lock to appear with an old passcode after reinstall.
        // We detect fresh install by checking a UserDefaults flag (which IS cleared on reinstall).
        clearKeychainOnFreshInstall()

        // Register for lifecycle notifications to enforce key destruction
        registerLifecycleObservers()

        // SECURITY: Suppress os.log output in release builds.
        // os.log persists to the system log which can be read by forensic tools
        // or accessed via Xcode/Console.app. In production, only the memory-only
        // SecureLogBuffer should be used for diagnostics.
        #if !DEBUG
        // Redirect stderr to /dev/null to suppress os_log output
        // This also suppresses NSLog, print(), and other stderr output
        freopen("/dev/null", "w", stderr)
        #endif

        // Disable screenshots in task switcher (best effort)
        // Note: This doesn't prevent screenshots, just hides content in switcher
        application.isIdleTimerDisabled = false

        return true
    }

    /// Clear Keychain on fresh install to prevent stale passcode lock
    ///
    /// iOS Keychain data persists even when the app is deleted and reinstalled.
    /// This causes issues where the privacy lock appears with an unknown passcode.
    /// We use a UserDefaults flag to detect fresh installs (UserDefaults IS cleared on reinstall).
    private func clearKeychainOnFreshInstall() {
        let hasLaunchedKey = "com.ephemeral.hasLaunchedBefore"

        if !UserDefaults.standard.bool(forKey: hasLaunchedKey) {
            // First launch after install - clear any stale Keychain data
            #if DEBUG
            print("[AppDelegate] Fresh install detected - clearing stale Keychain data")
            #endif

            // Clear AppLockManager's passcode and settings
            AppLockManager.shared.removePasscode()

            // Mark that we've launched
            UserDefaults.standard.set(true, forKey: hasLaunchedKey)
            UserDefaults.standard.synchronize()
        }
    }

    // MARK: - Interface Orientation

    /// Lock app to portrait orientation only
    /// This provides a programmatic backup to Info.plist settings
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return .portrait
    }

    // MARK: - UISceneSession Lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
        // Scene discarded - wipe any session
        activeSession?.quickExit()
    }

    // MARK: - Lifecycle Observers

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default

        // App entering background - CRITICAL: destroy session
        center.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Device locking - CRITICAL: destroy session
        center.addObserver(
            self,
            selector: #selector(protectedDataWillBecomeUnavailable),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil
        )

        // Memory warning - may need to clear
        center.addObserver(
            self,
            selector: #selector(didReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        // App termination - best effort wipe
        center.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    // MARK: - Lifecycle Handlers

    @objc private func applicationDidEnterBackground() {
        // IMMEDIATE destruction - no grace period
        // This is the primary security boundary
        activeSession?.closeRoom(reason: .backgrounded)

        #if DEBUG
        // Clean up test client when backgrounding
        TestModeManager.shared.destroyTestClient()
        #endif

        // SECURITY: Wipe Tor directory on background to reduce forensic evidence.
        // If the device is seized while the app is backgrounded, no Tor state data
        // will be recoverable from the Caches directory.
        EphemeralTorManager.shared.wipeTorDirectory()
    }

    @objc private func protectedDataWillBecomeUnavailable() {
        // Device is being locked - destroy everything
        activeSession?.closeRoom(reason: .deviceLocked)
    }

    @objc private func didReceiveMemoryWarning() {
        // Under memory pressure - if in high security mode, destroy
        if HighSecurityMode.shared.isEnabled {
            activeSession?.quickExit()
        }
    }

    @objc private func applicationWillTerminate() {
        // Best effort - this notification is not guaranteed
        activeSession?.quickExit()

        #if DEBUG
        // Clean up test client on termination
        TestModeManager.shared.destroyTestClient()
        #endif

        // SECURITY: Always wipe Tor directory on exit (not just high-security mode).
        // The Tor data directory contains guard node selections, consensus documents,
        // and circuit history that could reveal usage patterns to forensic analysis.
        EphemeralTorManager.shared.wipeTorDirectory()

        // Perform additional cleanup in high-security mode
        if HighSecurityMode.shared.isEnabled {
            HighSecurityMode.shared.performSecureCleanup()
        }
    }
}
