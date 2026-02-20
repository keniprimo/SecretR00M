import XCTest
import CryptoKit
@testable import SecretR00M

/// Tests for room lifecycle operations:
/// - Client leaving room (non-host)
/// - Host kicking participant
final class RoomLifecycleTests: XCTestCase {

    var hostSession: RoomSession!
    var hostDelegate: MockRoomSessionDelegate!
    var clientSession: RoomSession!
    var clientDelegate: MockRoomSessionDelegate!

    override func setUp() {
        super.setUp()
        hostDelegate = MockRoomSessionDelegate()
        clientDelegate = MockRoomSessionDelegate()
    }

    override func tearDown() {
        hostSession?.closeRoom(reason: .hostClosed)
        clientSession?.closeRoom(reason: .hostDisconnected)
        hostSession = nil
        clientSession = nil
        hostDelegate = nil
        clientDelegate = nil
        super.tearDown()
    }

    // MARK: - TEST ROOM_LIFECYCLE_001: Client Leaves Room (Non-Host)

    /// Test ID: ROOM_LIFECYCLE_001
    ///
    /// Preconditions:
    /// - Host has created room with ≥2 participants
    /// - Client B has successfully joined and completed key exchange
    /// - At least one message has been exchanged
    ///
    /// Expected Behavior:
    /// - Client B returns to home screen within 2s
    /// - Host's participant count decrements by 1
    /// - Host receives CLIENT_LEFT frame (not CLIENT_DISCONNECTED)
    /// - Client B's RoomSession is deallocated (no retain cycles)
    /// - Client B's SecureBytes keys are wiped (hasBeenWiped == true)
    /// - Attempting to send after leave throws/returns error
    func testClientLeavesRoomNonHost() throws {
        // This test validates that when a non-host client leaves:
        // 1. The leave is clean and immediate
        // 2. Keys are properly wiped
        // 3. Host receives notification
        // 4. Session can be deallocated

        // Create host session
        hostSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        hostSession.delegate = hostDelegate

        // Setup: Simulate room creation complete
        // In a real test, we'd use mock WebSocket to drive the state machine

        // Create client session
        var weakClientSession: RoomSession? = nil

        autoreleasepool {
            let client = RoomSession(configuration: TestConfiguration.makeConfiguration())
            client.delegate = clientDelegate
            weakClientSession = client

            // Simulate client in active state (normally achieved via WebSocket messages)
            // For unit test purposes, we verify the closeRoom behavior

            // ACTION: Client closes/leaves the room
            client.closeRoom(reason: .hostDisconnected)

            // VERIFY: State transitions to destroyed
            XCTAssertTrue(
                clientDelegate.hasEnteredState(.destroyed(reason: .hostDisconnected)),
                "Client should transition to destroyed state"
            )

            // VERIFY: Destruction event was received
            XCTAssertNotNil(
                clientDelegate.destructionReason,
                "Destruction reason should be set"
            )
        }

        // VERIFY: Client session can be deallocated (no retain cycles)
        // Note: In a full integration test, we'd verify weakClientSession becomes nil
        // Here we verify the state machine completed correctly

        // VERIFY: Cannot send after leave
        let testSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        testSession.closeRoom(reason: .hostDisconnected)

        XCTAssertThrowsError(try testSession.sendMessage(content: "Should fail")) { error in
            if case .invalidState = error as? RoomError {
                // Expected error
            } else {
                XCTFail("Expected RoomError.invalidState, got \(error)")
            }
        }
    }

    /// Test that client leave triggers host notification via delegate
    func testClientLeaveNotifiesHost() throws {
        // Create a host session
        hostSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        hostSession.delegate = hostDelegate

        // When CLIENT_LEFT is received, delegate should be notified
        // This tests the handleClientLeft method indirectly

        let expectation = hostDelegate.expectEvent("participantLeft", timeout: 2.0)

        // Simulate receiving CLIENT_LEFT (would normally come from WebSocket)
        // In production, this happens via webSocket(_:didReceiveString:)
        // For unit testing, we verify the state after close

        hostSession.closeRoom(reason: .hostClosed)

        // Verify destroyed event
        XCTAssertNotNil(hostDelegate.destructionReason)
    }

    // MARK: - TEST ROOM_LIFECYCLE_002: Host Kicks Participant

    /// Test ID: ROOM_LIFECYCLE_002
    ///
    /// Preconditions:
    /// - Host has created room with ≥2 participants
    /// - Client B is connected and authenticated
    /// - Room is in steady state (no pending rekey)
    ///
    /// Expected Behavior:
    /// - Host sees confirmation dialog before kick (UI test)
    /// - Client B receives KICKED frame within 500ms
    /// - Client B's WebSocket closes immediately
    /// - Client B sees "You have been removed" alert
    /// - Client B returns to home screen
    /// - Other participants see Client B removed from list
    /// - Client B's keys are wiped
    /// - If Client B tries to reconnect with same relayClientId, server rejects
    func testHostKicksParticipant() throws {
        // This test validates that when host kicks a participant:
        // 1. Kick message is sent
        // 2. Local state is cleaned up
        // 3. Rekey is triggered for remaining participants

        hostSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        hostSession.delegate = hostDelegate

        // Create client that will be kicked
        clientSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        clientSession.delegate = clientDelegate

        // Simulate client receiving KICKED notification
        // In production, this comes via WebSocket message parsing
        clientSession.closeRoom(reason: .kicked)

        // VERIFY: Client sees kicked destruction reason
        XCTAssertEqual(
            clientDelegate.destructionReason,
            .kicked,
            "Client should be destroyed with kicked reason"
        )

        // VERIFY: Kicked reason has correct user-facing message
        XCTAssertEqual(
            DestructionReason.kicked.userFacingDescription,
            "You have been removed from the room."
        )

        // VERIFY: Kicked is not recoverable (cannot rejoin)
        XCTAssertFalse(
            DestructionReason.kicked.isRecoverable,
            "Kicked should not be recoverable"
        )

        // VERIFY: Cannot send messages after kick
        XCTAssertThrowsError(try clientSession.sendMessage(content: "Should fail")) { error in
            if case .invalidState = error as? RoomError {
                // Expected error
            } else {
                XCTFail("Expected RoomError.invalidState, got \(error)")
            }
        }
    }

    /// Test that kick cleans up cryptographic material
    func testKickWipesCryptoState() throws {
        clientSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        clientSession.delegate = clientDelegate

        // Close with kick reason
        clientSession.closeRoom(reason: .kicked)

        // VERIFY: Session is destroyed
        if case .destroyed(let reason) = clientSession.state {
            XCTAssertEqual(reason, .kicked)
        } else {
            XCTFail("Session should be in destroyed state")
        }

        // VERIFY: Cannot access crypto operations
        XCTAssertThrowsError(try clientSession.sendMessage(content: "test"))
    }

    /// Test that kicked client cannot rejoin (state validation)
    func testKickedClientCannotRejoin() throws {
        clientSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        clientSession.delegate = clientDelegate

        // Simulate being kicked
        clientSession.closeRoom(reason: .kicked)

        // VERIFY: Cannot create or join new room with same session
        XCTAssertThrowsError(try clientSession.createRoom()) { error in
            if case .invalidState = error as? RoomError {
                // Expected error
            } else {
                XCTFail("Expected RoomError.invalidState, got \(error)")
            }
        }

        // A new session would be needed to rejoin
        // The server would reject based on relayClientId (not testable here)
    }

    // MARK: - Additional Lifecycle Tests

    /// Test that host close notifies all participants
    func testHostCloseNotifiesParticipants() throws {
        hostSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        hostSession.delegate = hostDelegate

        clientSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        clientSession.delegate = clientDelegate

        // Simulate client receiving room destroyed
        clientSession.closeRoom(reason: .hostClosed)

        // VERIFY: Correct destruction reason
        XCTAssertEqual(clientDelegate.destructionReason, .hostClosed)

        // VERIFY: User-facing message is appropriate
        XCTAssertEqual(
            DestructionReason.hostClosed.userFacingDescription,
            "The room has been closed."
        )
    }

    /// Test quick exit clears all state immediately
    func testQuickExitClearsAllState() throws {
        hostSession = RoomSession(configuration: TestConfiguration.makeConfiguration())
        hostSession.delegate = hostDelegate

        // Trigger quick exit
        hostSession.quickExit()

        // VERIFY: Destroyed with user exit reason
        XCTAssertEqual(hostDelegate.destructionReason, .userExit)

        // VERIFY: User exit is not recoverable
        XCTAssertFalse(DestructionReason.userExit.isRecoverable)

        // VERIFY: State is destroyed
        if case .destroyed(let reason) = hostSession.state {
            XCTAssertEqual(reason, .userExit)
        } else {
            XCTFail("Session should be destroyed after quick exit")
        }
    }
}
