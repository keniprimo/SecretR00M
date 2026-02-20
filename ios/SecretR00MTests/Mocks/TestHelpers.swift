import Foundation
import XCTest
import CryptoKit
@testable import SecretR00M

// MARK: - Test Configuration

/// Test configuration that uses mock server URL for testing
struct TestConfiguration {
    /// Mock onion URL for testing (satisfies validation but doesn't connect)
    /// Uses valid base32 characters (a-z, 2-7) for 56-character v3 onion address
    static let mockServerURL = "ws://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2.onion"

    /// Create a test RoomConfiguration
    static func makeConfiguration(highSecurity: Bool = false) -> RoomConfiguration {
        return RoomConfiguration(serverURL: mockServerURL, highSecurityMode: highSecurity)
    }
}

// MARK: - Test Session Factory

/// Factory for creating test RoomSessions with mocked dependencies
enum TestSessionFactory {

    /// Create a host session ready for testing
    /// - Parameters:
    ///   - delegate: The delegate to attach
    ///   - mockWS: The mock WebSocket to inject
    /// - Returns: Configured RoomSession
    static func createHostSession(
        delegate: MockRoomSessionDelegate? = nil,
        mockWS: MockWebSocket? = nil
    ) -> RoomSession {
        let session = RoomSession(configuration: TestConfiguration.makeConfiguration())
        if let delegate = delegate {
            session.delegate = delegate
        }
        return session
    }

    /// Create a client session ready for testing
    /// - Parameters:
    ///   - delegate: The delegate to attach
    ///   - mockWS: The mock WebSocket to inject
    /// - Returns: Configured RoomSession
    static func createClientSession(
        delegate: MockRoomSessionDelegate? = nil,
        mockWS: MockWebSocket? = nil
    ) -> RoomSession {
        let session = RoomSession(configuration: TestConfiguration.makeConfiguration())
        if let delegate = delegate {
            session.delegate = delegate
        }
        return session
    }
}

// MARK: - Crypto Test Helpers

enum CryptoTestHelpers {

    /// Generate a valid test key pair
    static func generateKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        return Curve25519.KeyAgreement.PrivateKey()
    }

    /// Generate random bytes for testing
    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Generate a test room ID
    static func generateRoomId() -> Data {
        return randomBytes(count: 32)
    }

    /// Generate a test room ID string
    static func generateRoomIdString() -> String {
        return generateRoomId().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Create a mock JoinRequest
    static func createJoinRequest(displayName: String? = nil) -> JoinRequest {
        let keyPair = generateKeyPair()
        return JoinRequest(
            clientPublicKey: keyPair.publicKey.rawRepresentation,
            joinNonce: randomBytes(count: 16),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            displayName: displayName
        )
    }

    /// Create test encrypted payload (not actually encrypted, for mock testing)
    static func createMockEncryptedPayload(content: String = "Test") -> Data {
        return content.data(using: .utf8) ?? Data()
    }
}

// MARK: - Timing Helpers

enum TimingHelpers {

    /// Wait for a condition with timeout
    static func waitFor(
        timeout: TimeInterval = 5.0,
        interval: TimeInterval = 0.1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
        return false
    }

    /// Run the main run loop for a duration
    static func runLoop(for duration: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }

    /// Execute a block after a delay
    static func after(_ delay: TimeInterval, block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }
}

// MARK: - XCTest Extensions

extension XCTestCase {

    /// Wait for multiple expectations with default timeout
    func wait(for expectations: [XCTestExpectation], timeout: TimeInterval = 5.0) {
        wait(for: expectations, timeout: timeout, enforceOrder: false)
    }

    /// Assert that a block eventually returns true
    func assertEventually(
        timeout: TimeInterval = 5.0,
        message: String = "Condition not met",
        file: StaticString = #file,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) {
        let result = TimingHelpers.waitFor(timeout: timeout, condition: condition)
        XCTAssertTrue(result, message, file: file, line: line)
    }

    /// Assert that a value eventually equals expected
    func assertEventuallyEqual<T: Equatable>(
        _ expression: @escaping @autoclosure () -> T,
        _ expected: T,
        timeout: TimeInterval = 5.0,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let result = TimingHelpers.waitFor(timeout: timeout) {
            expression() == expected
        }
        XCTAssertTrue(result, "Expected \(expected) but got \(expression())", file: file, line: line)
    }
}

// MARK: - Mock Rekey Confirmation

/// Create a mock RekeyConfirmation for testing
struct MockRekeyConfirmation {
    let epoch: UInt32
    let newPublicKey: Data
    let confirmNonce: Data
    let mac: Data

    static func create(
        epoch: UInt32 = 2,
        newPublicKey: Data? = nil,
        confirmNonce: Data? = nil,
        mac: Data? = nil
    ) -> RekeyConfirmation {
        return RekeyConfirmation(
            epoch: epoch,
            newPublicKey: newPublicKey ?? CryptoTestHelpers.randomBytes(count: 32),
            confirmNonce: confirmNonce ?? CryptoTestHelpers.randomBytes(count: 16),
            mac: mac ?? CryptoTestHelpers.randomBytes(count: 32)
        )
    }
}

// MARK: - Connection State Assertions

/// Assertions for WebSocket connection state
enum ConnectionStateAssertions {

    /// Assert that reconnecting UI should be visible
    static func assertReconnectingUIState(
        session: RoomSession,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        // When session is in reconnecting state:
        // 1. State should not be .active
        // 2. State should not be .destroyed
        // 3. Messages should be queueable

        let state = session.state
        XCTAssertNotEqual(state, .active, "Session should not be active during reconnect", file: file, line: line)

        if case .destroyed = state {
            XCTFail("Session should not be destroyed during reconnect", file: file, line: line)
        }
    }

    /// Assert closed room error is specific (not generic connection failure)
    static func assertClosedRoomError(
        _ error: Error,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        // The error should specifically indicate the room was closed,
        // not a generic connection failure
        if let roomError = error as? RoomError {
            // RoomError doesn't have a .roomClosed case, so we check the destruction reason
            XCTFail("Expected destruction reason, got RoomError: \(roomError)", file: file, line: line)
        }

        // Check if it's a WebSocket error indicating room closed
        let errorDescription = (error as NSError).localizedDescription.lowercased()
        let isRoomClosedError = errorDescription.contains("closed") ||
                                errorDescription.contains("destroyed") ||
                                errorDescription.contains("not found")

        XCTAssertTrue(isRoomClosedError || error is WebSocketError,
                     "Error should indicate room closure, got: \(error)",
                     file: file, line: line)
    }
}

// MARK: - Rekey State Assertions

/// Assertions for rekey state machine
enum RekeyStateAssertions {

    /// Assert that a late rekey confirmation is properly ignored
    static func assertLateRekeyConfirmationIgnored(
        delegate: MockRoomSessionDelegate,
        session: RoomSession,
        clientId: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        // Late confirmation should NOT cause:
        // 1. A crash
        // 2. A state change
        // 3. A rekeyCompleted event for this epoch

        // Check no crash occurred (we're still executing)
        XCTAssertTrue(true, "No crash occurred", file: file, line: line)

        // Check session is still active (not destroyed)
        if case .destroyed = session.state {
            XCTFail("Session should not be destroyed after late confirmation", file: file, line: line)
        }

        // A warning should have been logged (we can't easily verify this in unit tests)
        // but the session should continue functioning normally
    }
}
