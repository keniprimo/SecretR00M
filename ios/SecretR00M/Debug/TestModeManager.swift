// TestModeManager.swift
// EphemeralRooms - Internal Test Mode
//
// SECURITY: This entire file is compiled out of Release builds.
// Test Mode allows debugging message delivery by simulating a second client
// on the same device, using all real code paths (crypto, WebSocket, etc.)

#if DEBUG

import Foundation

/// TestModeManager controls the internal test mode for debugging message delivery.
/// This is DEBUG-only and provides no production functionality.
final class TestModeManager {

    // MARK: - Singleton

    static let shared = TestModeManager()

    private init() {
        // Load persisted state
        _isEnabled = UserDefaults.standard.bool(forKey: Keys.testModeEnabled)
    }

    // MARK: - Keys

    private enum Keys {
        static let testModeEnabled = "com.ephemeralrooms.debug.testModeEnabled"
    }

    // MARK: - State

    private var _isEnabled: Bool = false

    /// Whether test mode is currently enabled
    var isEnabled: Bool {
        get { _isEnabled }
        set {
            _isEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.testModeEnabled)
            print("[TestMode] Enabled: \(newValue)")
        }
    }

    /// The currently active test client (if any)
    private(set) var activeTestClient: TestClientSession?

    /// Diagnostics data for the UI panel
    private(set) var diagnostics = TestDiagnostics()

    /// Observers for diagnostics updates
    private var diagnosticsObservers: [(TestDiagnostics) -> Void] = []

    // MARK: - Test Client Lifecycle

    /// Spawn a test client to join the specified room
    /// - Parameters:
    ///   - roomId: The room ID to join
    ///   - configuration: Room configuration (must match host's config)
    func spawnTestClient(roomId: String, configuration: RoomConfiguration) {
        guard isEnabled else {
            print("[TestMode] Not enabled, skipping test client spawn")
            return
        }

        guard activeTestClient == nil else {
            print("[TestMode] Test client already active")
            return
        }

        print("[TestMode] Spawning test client for room: \(roomId.prefix(8))...")

        // Create the test client with a slight delay to simulate network latency
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.createTestClient(roomId: roomId, configuration: configuration)
        }
    }

    private func createTestClient(roomId: String, configuration: RoomConfiguration) {
        let testClient = TestClientSession(
            roomId: roomId,
            configuration: configuration,
            diagnosticsHandler: { [weak self] update in
                self?.updateDiagnostics(update)
            }
        )

        activeTestClient = testClient
        updateDiagnostics(.clientSpawned)

        // Start the join process
        testClient.connect()
    }

    /// Destroy the active test client
    func destroyTestClient() {
        guard let client = activeTestClient else { return }

        print("[TestMode] Destroying test client")
        client.disconnect()
        activeTestClient = nil
        updateDiagnostics(.clientDestroyed)
    }

    // MARK: - Diagnostics

    /// Add an observer for diagnostics updates
    func observeDiagnostics(_ handler: @escaping (TestDiagnostics) -> Void) {
        diagnosticsObservers.append(handler)
        // Immediately call with current state
        handler(diagnostics)
    }

    /// Clear all diagnostics observers
    func clearObservers() {
        diagnosticsObservers.removeAll()
    }

    private func updateDiagnostics(_ update: DiagnosticsUpdate) {
        switch update {
        case .clientSpawned:
            diagnostics.connectionState = .connecting
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "Test client spawned"))

        case .clientDestroyed:
            diagnostics.connectionState = .disconnected
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "Test client destroyed"))

        case .connectionStateChanged(let state):
            diagnostics.connectionState = state
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "Connection: \(state.description)"))

        case .joinRequestSent:
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "Join request sent"))

        case .joinApproved:
            diagnostics.joinSucceeded = true
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "Join approved"))

        case .joinRejected(let reason):
            diagnostics.joinSucceeded = false
            diagnostics.lastError = reason
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "Join rejected: \(reason)"))

        case .messageSent(let content):
            diagnostics.lastMessageSent = content
            diagnostics.messagesSentCount += 1
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "Sent: \(content.prefix(30))..."))

        case .messageReceived(let content):
            diagnostics.lastMessageReceived = content
            diagnostics.messagesReceivedCount += 1
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "Received: \(content.prefix(30))..."))

        case .epochChanged(let epoch):
            diagnostics.currentEpoch = epoch
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "Epoch: \(epoch)"))

        case .error(let message):
            diagnostics.lastError = message
            diagnostics.events.append(DiagnosticEvent(timestamp: Date(), message: "ERROR: \(message)"))
        }

        // Keep only last 50 events
        if diagnostics.events.count > 50 {
            diagnostics.events = Array(diagnostics.events.suffix(50))
        }

        // Notify observers
        for observer in diagnosticsObservers {
            observer(diagnostics)
        }
    }

    /// Reset diagnostics
    func resetDiagnostics() {
        diagnostics = TestDiagnostics()
        for observer in diagnosticsObservers {
            observer(diagnostics)
        }
    }
}

// MARK: - Diagnostics Data Structures

/// Diagnostic event for the log
struct DiagnosticEvent {
    let timestamp: Date
    let message: String

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

/// Full diagnostics state
struct TestDiagnostics {
    var connectionState: TestConnectionState = .disconnected
    var joinSucceeded: Bool? = nil
    var lastMessageSent: String? = nil
    var lastMessageReceived: String? = nil
    var currentEpoch: UInt32 = 0
    var messagesSentCount: Int = 0
    var messagesReceivedCount: Int = 0
    var lastError: String? = nil
    var events: [DiagnosticEvent] = []
}

/// Connection state for test client
enum TestConnectionState: CustomStringConvertible {
    case disconnected
    case connecting
    case connected
    case joining
    case active
    case disconnecting

    var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected (awaiting join)"
        case .joining: return "Join requested..."
        case .active: return "Active"
        case .disconnecting: return "Disconnecting..."
        }
    }
}

/// Types of diagnostics updates
enum DiagnosticsUpdate {
    case clientSpawned
    case clientDestroyed
    case connectionStateChanged(TestConnectionState)
    case joinRequestSent
    case joinApproved
    case joinRejected(String)
    case messageSent(String)
    case messageReceived(String)
    case epochChanged(UInt32)
    case error(String)
}

#endif
