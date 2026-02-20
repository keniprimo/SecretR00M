import Foundation
import Security
import LocalAuthentication
import CommonCrypto

/// Manages the optional App Lock feature.
///
/// App Lock is a user-enabled feature that shows a PIN lock screen
/// on app launch. The user must enter their configured PIN
/// to access the main app.
///
/// This is NOT enabled by default - users must explicitly opt-in through settings.
final class AppLockManager {

    // MARK: - Singleton

    static let shared = AppLockManager()

    private init() {}

    // MARK: - Constants

    private let passcodeKeychainKey = "com.secretr00m.applock.passcode"
    private let enabledKeychainKey = "com.secretr00m.applock.enabled"
    private let biometricsKeychainKey = "com.secretr00m.applock.biometrics"
    private let failedAttemptsKeychainKey = "com.secretr00m.applock.failedAttempts"
    private let lockoutUntilKeychainKey = "com.secretr00m.applock.lockoutUntil"

    /// Maximum failed attempts before temporary lockout
    private let maxFailedAttempts = 5

    /// Lockout duration in seconds (5 minutes)
    private let lockoutDuration: TimeInterval = 300

    // MARK: - Notifications

    static let didUnlockNotification = Notification.Name("AppLockDidUnlock")
    static let didLockNotification = Notification.Name("AppLockDidLock")

    // MARK: - State

    /// Whether App Lock is enabled by the user
    var isEnabled: Bool {
        get { getKeychainBool(key: enabledKeychainKey) }
        set { setKeychainBool(key: enabledKeychainKey, value: newValue) }
    }

    /// Whether biometric authentication is required after PIN
    var requireBiometricsAfterPasscode: Bool {
        get { getKeychainBool(key: biometricsKeychainKey) }
        set { setKeychainBool(key: biometricsKeychainKey, value: newValue) }
    }

    /// Whether a PIN has been configured
    var hasPasscode: Bool {
        return getStoredPasscodeData() != nil
    }

    /// Whether the app is currently locked
    private(set) var isLocked: Bool = true

    /// Current failed attempt count
    var failedAttempts: Int {
        get { getKeychainInt(key: failedAttemptsKeychainKey) }
        set { setKeychainInt(key: failedAttemptsKeychainKey, value: newValue) }
    }

    /// Whether currently in lockout period
    var isLockedOut: Bool {
        guard let lockoutUntil = getKeychainDate(key: lockoutUntilKeychainKey) else {
            return false
        }
        if Date() >= lockoutUntil {
            clearLockout()
            return false
        }
        return true
    }

    /// Time remaining in lockout (seconds)
    var lockoutTimeRemaining: TimeInterval {
        guard let lockoutUntil = getKeychainDate(key: lockoutUntilKeychainKey) else {
            return 0
        }
        return max(0, lockoutUntil.timeIntervalSinceNow)
    }

    // MARK: - Passcode Management

    /// Set a new PIN for App Lock
    @discardableResult
    func setPasscode(_ passcode: String) -> Bool {
        guard !passcode.isEmpty else { return false }
        guard passcode.allSatisfy({ $0.isNumber }) else { return false }
        return storePasscodeInKeychain(passcode)
    }

    /// Remove the stored PIN and disable App Lock
    func removePasscode() {
        deletePasscodeFromKeychain()
        isEnabled = false
        isLocked = true
        clearLockout()
    }

    /// Validate a PIN attempt
    func validatePasscode(_ attempt: String) -> Bool {
        guard !isLockedOut else { return false }

        guard let storedData = getStoredPasscodeData() else {
            return false
        }

        guard storedData.count == Self.saltLength + Self.hashLength else {
            return false
        }

        let salt = storedData.prefix(Self.saltLength)
        let expectedHash = storedData.suffix(Self.hashLength)

        guard let attemptHash = Self.pbkdf2Hash(passcode: attempt, salt: salt) else {
            return false
        }

        if Self.constantTimeCompare(attemptHash, Data(expectedHash)) {
            failedAttempts = 0
            isLocked = false
            NotificationCenter.default.post(name: Self.didUnlockNotification, object: nil)
            return true
        } else {
            failedAttempts += 1

            if failedAttempts >= maxFailedAttempts {
                let lockoutUntil = Date().addingTimeInterval(lockoutDuration)
                setKeychainDate(key: lockoutUntilKeychainKey, value: lockoutUntil)
            }

            return false
        }
    }

    /// Lock the app
    func lock() {
        isLocked = true
        NotificationCenter.default.post(name: Self.didLockNotification, object: nil)
    }

    /// Check if App Lock should be shown on launch
    var shouldShowLockOnLaunch: Bool {
        return isEnabled && hasPasscode
    }

    // MARK: - Lockout Management

    private func clearLockout() {
        failedAttempts = 0
        deleteKeychainItem(key: lockoutUntilKeychainKey)
    }

    // MARK: - Keychain Storage (Hashed)

    private static let saltLength = 16
    private static let hashLength = 32
    private static let pbkdf2Iterations: UInt32 = 100_000

    private func storePasscodeInKeychain(_ passcode: String) -> Bool {
        var salt = Data(count: Self.saltLength)
        let saltStatus = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, Self.saltLength, ptr.baseAddress!)
        }
        guard saltStatus == errSecSuccess else { return false }

        guard let hash = Self.pbkdf2Hash(passcode: passcode, salt: salt) else { return false }

        let data = salt + hash

        deletePasscodeFromKeychain()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: passcodeKeychainKey,
            kSecAttrService as String: "AppLock",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func getStoredPasscodeData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: passcodeKeychainKey,
            kSecAttrService as String: "AppLock",
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return data
    }

    private func deletePasscodeFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: passcodeKeychainKey,
            kSecAttrService as String: "AppLock"
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain Helpers

    private func getKeychainBool(key: String) -> Bool {
        guard let data = getKeychainData(key: key), data.count == 1 else { return false }
        return data[0] != 0
    }

    private func setKeychainBool(key: String, value: Bool) {
        let data = Data([value ? 1 : 0])
        setKeychainData(key: key, data: data)
    }

    private func getKeychainInt(key: String) -> Int {
        guard let data = getKeychainData(key: key), data.count == 8 else { return 0 }
        return data.withUnsafeBytes { $0.load(as: Int.self) }
    }

    private func setKeychainInt(key: String, value: Int) {
        var val = value
        let data = Data(bytes: &val, count: MemoryLayout<Int>.size)
        setKeychainData(key: key, data: data)
    }

    private func getKeychainDate(key: String) -> Date? {
        guard let data = getKeychainData(key: key), data.count == 8 else { return nil }
        let interval = data.withUnsafeBytes { $0.load(as: TimeInterval.self) }
        return Date(timeIntervalSince1970: interval)
    }

    private func setKeychainDate(key: String, value: Date) {
        var interval = value.timeIntervalSince1970
        let data = Data(bytes: &interval, count: MemoryLayout<TimeInterval>.size)
        setKeychainData(key: key, data: data)
    }

    private func getKeychainData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "AppLockSettings",
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func setKeychainData(key: String, data: Data) {
        deleteKeychainItem(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "AppLockSettings",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "AppLockSettings"
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - PBKDF2 Hashing

    private static func pbkdf2Hash(passcode: String, salt: Data) -> Data? {
        guard let passcodeData = passcode.data(using: .utf8) else { return nil }

        var derivedKey = Data(count: hashLength)
        let status = derivedKey.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                passcodeData.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passcodeData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        hashLength
                    )
                }
            }
        }

        return status == kCCSuccess ? derivedKey : nil
    }

    private static func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for (x, y) in zip(a, b) {
            result |= x ^ y
        }
        return result == 0
    }

    // MARK: - Biometric Authentication

    func authenticateWithBiometrics(reason: String = "Unlock SecretR00M",
                                     completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            completion(true)
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
}
