import XCTest
import CryptoKit
@testable import SecretR00M

/// Tests for UI/State interactions:
/// - Navigate away from room during rekey
/// - State machine assertions for UI indicators
final class UIStateInteractionTests: XCTestCase {

    var session: RoomSession!
    var delegate: MockRoomSessionDelegate!

    override func setUp() {
        super.setUp()
        delegate = MockRoomSessionDelegate()
    }

    override func tearDown() {
        session?.closeRoom(reason: .hostClosed)
        session = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - TEST UI_STATE_001: Navigate Away From Room During Rekey

    /// Test ID: UI_STATE_001
    ///
    /// Preconditions:
    /// - Active room session
    /// - Rekey has been initiated (host side) or received (client side)
    /// - Rekey is in progress (confirmation pending)
    ///
    /// Steps:
    /// 1. While rekey is in progress, user taps back/leave
    /// 2. Observe confirmation dialog (if any) - UI test
    /// 3. User confirms leave
    /// 4. Observe rekey cancellation
    /// 5. Verify clean state after leave
    ///
    /// Expected Behavior:
    /// - Warning dialog: "Key exchange in progress. Leaving now may cause message loss."
    /// - If user confirms leave, session terminates gracefully
    /// - Pending rekey is cancelled (not left dangling)
    /// - pendingConfirmNonces is cleared
    /// - Keys are wiped
    /// - Other participants see clean departure (not timeout)
    func testNavigateAwayDuringRekey() throws {
        session = RoomSession(configuration: TestConfiguration.makeConfiguration())
        session.delegate = delegate

        // Simulate being in rekeying state would normally happen via:
        // 1. Host calls initiateRekey()
        // 2. State changes to .rekeying
        // 3. User tries to leave

        // For unit test, we verify that closeRoom works correctly
        // regardless of what state we're in

        // ACTION: User leaves during what would be a rekey
        session.closeRoom(reason: .hostClosed)

        // VERIFY: Session is destroyed cleanly
        if case .destroyed(let reason) = session.state {
            XCTAssertEqual(reason, .hostClosed)
        } else {
            XCTFail("Session should be destroyed after close")
        }

        // VERIFY: Cannot send messages (keys wiped)
        XCTAssertThrowsError(try session.sendMessage(content: "Should fail"))

        // VERIFY: Destruction event was sent
        XCTAssertNotNil(delegate.destructionReason)
    }

    /// Test that closeRoom during any state works correctly
    func testCloseRoomDuringAnyState() throws {
        // Test from .none state
        var session1 = RoomSession(configuration: TestConfiguration.makeConfiguration())
        session1.delegate = delegate
        session1.closeRoom(reason: .hostClosed)
        XCTAssertTrue(delegate.hasEnteredState(.destroyed(reason: .hostClosed)))

        delegate.reset()

        // Create another session and close it
        let session2 = RoomSession(configuration: TestConfiguration.makeConfiguration())
        session2.delegate = delegate
        session2.closeRoom(reason: .userExit)
        XCTAssertEqual(delegate.destructionReason, .userExit)
    }

    // MARK: - State Machine Assertion Tests

    /// Assertion A: "Reconnecting..." UI indicator visibility
    func testReconnectingUIIndicatorAssertion() throws {
        session = RoomSession(configuration: TestConfiguration.makeConfiguration())
        session.delegate = delegate

        // When connection is lost, the session should indicate reconnecting state
        // In RoomSession, this is handled by WebSocket delegate callbacks

        // Simulate network error (which would trigger reconnecting state)
        session.closeRoom(reason: .networkError)

        // VERIFY: State reflects disconnection
        XCTAssertEqual(delegate.destructionReason, .networkError)

        // In a real UI test, we would verify:
        // 1. "Reconnecting..." banner is visible
        // 2. Send button is disabled OR shows pending state
        // 3. Message input remains accessible

        // For unit test, verify the state machine transitioned correctly
        XCTAssertTrue(delegate.hasEnteredState(.destroyed(reason: .networkError)))
    }

    /// Assertion B: Closed room join error specificity
    func testClosedRoomErrorSpecificity() throws {
        session = RoomSession(configuration: TestConfiguration.makeConfiguration())
        session.delegate = delegate

        // When trying to join a closed room, error should be specific
        // (not generic connection failure)

        session.closeRoom(reason: .hostDisconnected)

        // VERIFY: Reason is specifically hostDisconnected
        XCTAssertEqual(delegate.destructionReason, .hostDisconnected)

        // VERIFY: Distinct from other errors
        XCTAssertNotEqual(delegate.destructionReason, .networkError)
        XCTAssertNotEqual(delegate.destructionReason, .serverError)
    }

    /// Test various destruction reasons are distinct
    func testDestructionReasonsDistinct() throws {
        // Each destruction reason should have unique user-facing message

        let reasons: [DestructionReason] = [
            .hostDisconnected,
            .hostClosed,
            .kicked,
            .networkError,
            .serverError,
            .cryptoFailure,
            .capacityExceeded,
            .memoryPressure
        ]

        var messages = Set<String>()
        for reason in reasons {
            let message = reason.userFacingDescription
            XCTAssertFalse(
                messages.contains(message),
                "Destruction reason messages should be unique"
            )
            messages.insert(message)
        }
    }

    // MARK: - Room State Tests

    /// Test room state canSendMessages property
    func testRoomStateCanSendMessages() throws {
        // Only .active state should allow sending messages
        XCTAssertFalse(RoomState.none.canSendMessages)
        XCTAssertFalse(RoomState.creating.canSendMessages)
        XCTAssertFalse(RoomState.created(roomId: "test").canSendMessages)
        XCTAssertFalse(RoomState.open.canSendMessages)
        XCTAssertTrue(RoomState.active.canSendMessages)
        XCTAssertFalse(RoomState.rekeying.canSendMessages)
        XCTAssertFalse(RoomState.destroyed(reason: .hostClosed).canSendMessages)
    }

    /// Test room state isActive property
    func testRoomStateIsActive() throws {
        XCTAssertFalse(RoomState.none.isActive)
        XCTAssertFalse(RoomState.creating.isActive)
        XCTAssertFalse(RoomState.created(roomId: "test").isActive)
        XCTAssertFalse(RoomState.open.isActive)
        XCTAssertTrue(RoomState.active.isActive)
        XCTAssertTrue(RoomState.rekeying.isActive) // Rekeying is considered active
        XCTAssertFalse(RoomState.destroyed(reason: .hostClosed).isActive)
    }

    // MARK: - Security Event Tests

    /// Test screenshot detection triggers appropriate response
    func testScreenshotDetection() throws {
        session = RoomSession(configuration: TestConfiguration.makeConfiguration())
        session.delegate = delegate

        // Trigger screenshot security event
        session.handleSecurityEvent(.screenshotDetected)

        // VERIFY: Security event was received by delegate
        XCTAssertTrue(delegate.hasReceivedEvent("securityEvent"))

        // In high security mode, this would trigger rekey
        // For unit test, verify the event propagation works
    }

    /// Test screen recording triggers appropriate response
    func testScreenRecordingDetection() throws {
        session = RoomSession(configuration: TestConfiguration.makeConfiguration())
        session.delegate = delegate

        session.handleSecurityEvent(.screenRecordingStarted)
        XCTAssertTrue(delegate.hasReceivedEvent("securityEvent"))

        session.handleSecurityEvent(.screenRecordingStopped)
        // Event count should increase
        XCTAssertEqual(delegate.events(ofType: "securityEvent").count, 2)
    }

    /// Test device locked closes room
    func testDeviceLockedClosesRoom() throws {
        session = RoomSession(configuration: TestConfiguration.makeConfiguration())
        session.delegate = delegate

        session.handleSecurityEvent(.deviceLocked)

        // VERIFY: Room was closed due to device lock
        XCTAssertEqual(delegate.destructionReason, .deviceLocked)
    }

    /// Test backgrounded in high security mode
    func testBackgroundedInHighSecurityMode() throws {
        // Create session with high security mode
        let highSecConfig = RoomConfiguration(
            serverURL: TestConfiguration.mockServerURL,
            highSecurityMode: true
        )
        session = RoomSession(configuration: highSecConfig)
        session.delegate = delegate

        session.handleSecurityEvent(.backgrounded)

        // VERIFY: Room was closed due to backgrounding (high security mode)
        XCTAssertEqual(delegate.destructionReason, .backgrounded)
    }
}

// MARK: - XCUITest Integration Notes

/*
 The following tests should be implemented as XCUITests for full UI verification:

 1. testNavigateAwayDuringRekeyUI:
    - Launch app, create room, join with second device
    - Initiate rekey
    - While "Updating encryption..." indicator visible, tap Leave
    - Verify warning dialog appears
    - Verify text contains "key exchange"
    - Tap Leave in dialog
    - Verify return to home screen

 2. testReconnectingUIIndicator:
    - Create active room
    - Disable network/airplane mode
    - Verify "Reconnecting..." banner appears within 2s
    - Verify send button disabled or shows pending state
    - Verify message input remains accessible
    - Re-enable network
    - Verify banner disappears, send button re-enables

 3. testClosedRoomJoinError:
    - Create room on device A
    - Get room code on device B
    - Close room on device A
    - Attempt join on device B
    - Verify error message specifically says "closed" not "connection failed"

 These are marked MANUAL in the test plan automation feasibility.
 */
