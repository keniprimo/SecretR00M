import Foundation
import XCTest
@testable import SecretR00M

// MARK: - Mock Room Session Delegate

/// Mock delegate for capturing and verifying RoomSession events
final class MockRoomSessionDelegate: RoomSessionDelegate {

    // MARK: - Event Storage

    /// All state changes received
    private(set) var stateChanges: [RoomState] = []

    /// All events received
    private(set) var events: [RoomEvent] = []

    /// All messages received
    private(set) var messages: [DecryptedMessage] = []

    /// All join requests received (host only)
    private(set) var joinRequests: [PendingJoinRequest] = []

    // MARK: - Expectations

    private var stateExpectation: XCTestExpectation?
    private var expectedState: RoomState?

    private var eventExpectation: XCTestExpectation?
    private var expectedEventType: String?

    private var messageExpectation: XCTestExpectation?
    private var expectedMessageCount: Int?

    private var joinRequestExpectation: XCTestExpectation?

    // MARK: - Thread Safety

    private let lock = NSLock()

    // MARK: - RoomSessionDelegate

    func roomSession(_ session: RoomSession, didChangeState state: RoomState) {
        lock.lock()
        stateChanges.append(state)

        if let expected = expectedState, state == expected {
            stateExpectation?.fulfill()
            stateExpectation = nil
            expectedState = nil
        }
        lock.unlock()
    }

    func roomSession(_ session: RoomSession, didReceiveEvent event: RoomEvent) {
        lock.lock()
        events.append(event)

        if let expected = expectedEventType, eventMatchesType(event, expected) {
            eventExpectation?.fulfill()
            eventExpectation = nil
            expectedEventType = nil
        }
        lock.unlock()
    }

    func roomSession(_ session: RoomSession, didReceiveMessage message: DecryptedMessage) {
        lock.lock()
        messages.append(message)

        if let expected = expectedMessageCount, messages.count >= expected {
            messageExpectation?.fulfill()
            messageExpectation = nil
            expectedMessageCount = nil
        }
        lock.unlock()
    }

    func roomSession(_ session: RoomSession, didReceiveJoinRequest request: PendingJoinRequest) {
        lock.lock()
        joinRequests.append(request)
        joinRequestExpectation?.fulfill()
        joinRequestExpectation = nil
        lock.unlock()
    }

    // MARK: - Expectation Setup

    /// Wait for a specific state
    func expectState(_ state: RoomState, timeout: TimeInterval = 5.0, file: StaticString = #file, line: UInt = #line) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Wait for state: \(state)")

        lock.lock()
        // Check if already in expected state
        if stateChanges.last == state {
            lock.unlock()
            expectation.fulfill()
            return expectation
        }

        stateExpectation = expectation
        expectedState = state
        lock.unlock()

        return expectation
    }

    /// Wait for a specific event type
    func expectEvent(_ eventType: String, timeout: TimeInterval = 5.0) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Wait for event: \(eventType)")

        lock.lock()
        eventExpectation = expectation
        expectedEventType = eventType
        lock.unlock()

        return expectation
    }

    /// Wait for a specific number of messages
    func expectMessages(count: Int, timeout: TimeInterval = 5.0) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Wait for \(count) messages")

        lock.lock()
        if messages.count >= count {
            lock.unlock()
            expectation.fulfill()
            return expectation
        }

        messageExpectation = expectation
        expectedMessageCount = count
        lock.unlock()

        return expectation
    }

    /// Wait for a join request
    func expectJoinRequest(timeout: TimeInterval = 5.0) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Wait for join request")

        lock.lock()
        if !joinRequests.isEmpty {
            lock.unlock()
            expectation.fulfill()
            return expectation
        }

        joinRequestExpectation = expectation
        lock.unlock()

        return expectation
    }

    // MARK: - Query Methods

    /// Get the most recent state
    var currentState: RoomState? {
        lock.lock()
        defer { lock.unlock() }
        return stateChanges.last
    }

    /// Get the most recent event
    var lastEvent: RoomEvent? {
        lock.lock()
        defer { lock.unlock() }
        return events.last
    }

    /// Check if a specific event type was received
    func hasReceivedEvent(_ type: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains { eventMatchesType($0, type) }
    }

    /// Get all events of a specific type
    func events(ofType type: String) -> [RoomEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { eventMatchesType($0, type) }
    }

    /// Check if state was ever entered
    func hasEnteredState(_ state: RoomState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stateChanges.contains(state)
    }

    /// Get destruction reason if room was destroyed
    var destructionReason: DestructionReason? {
        lock.lock()
        defer { lock.unlock() }

        for state in stateChanges.reversed() {
            if case .destroyed(let reason) = state {
                return reason
            }
        }
        return nil
    }

    // MARK: - Reset

    func reset() {
        lock.lock()
        stateChanges.removeAll()
        events.removeAll()
        messages.removeAll()
        joinRequests.removeAll()
        stateExpectation = nil
        expectedState = nil
        eventExpectation = nil
        expectedEventType = nil
        messageExpectation = nil
        expectedMessageCount = nil
        joinRequestExpectation = nil
        lock.unlock()
    }

    // MARK: - Private

    private func eventMatchesType(_ event: RoomEvent, _ type: String) -> Bool {
        switch (event, type) {
        case (.created, "created"): return true
        case (.opened, "opened"): return true
        case (.joinRequested, "joinRequested"): return true
        case (.joinApproved, "joinApproved"): return true
        case (.joinRejected, "joinRejected"): return true
        case (.participantJoined, "participantJoined"): return true
        case (.participantLeft, "participantLeft"): return true
        case (.messageReceived, "messageReceived"): return true
        case (.rekeyStarted, "rekeyStarted"): return true
        case (.rekeyCompleted, "rekeyCompleted"): return true
        case (.securityEvent, "securityEvent"): return true
        case (.destroyed, "destroyed"): return true
        case (.error, "error"): return true
        default: return false
        }
    }
}

// MARK: - Convenience Extensions

extension RoomState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .none: return "none"
        case .creating: return "creating"
        case .created(let roomId): return "created(\(roomId))"
        case .open: return "open"
        case .active: return "active"
        case .rekeying: return "rekeying"
        case .destroyed(let reason): return "destroyed(\(reason))"
        }
    }
}
