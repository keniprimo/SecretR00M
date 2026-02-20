import Foundation
import UIKit
#if DEBUG
import os.log
#endif

// MARK: - Pending Invite Data

/// Represents a pending invite that is waiting for secure connection to be ready
/// SECURITY: This data is only stored in memory, never persisted
struct PendingInvite {
    /// Room ID - nil if we need to validate token to discover it
    let roomId: String?
    let token: String
    let receivedAt: Date
    let expiresAt: Date

    /// Whether this invite requires token validation to discover the roomId
    var requiresTokenValidation: Bool {
        return roomId == nil
    }

    /// Default expiration time for invites (24 hours)
    static let defaultExpirationInterval: TimeInterval = 24 * 60 * 60

    init(roomId: String?, token: String, receivedAt: Date = Date(), expiresAt: Date? = nil) {
        self.roomId = roomId
        self.token = token
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt ?? receivedAt.addingTimeInterval(Self.defaultExpirationInterval)
    }

    /// Whether the invite has expired
    var isExpired: Bool {
        return Date() > expiresAt
    }

    /// Validate the invite data
    func validate() -> Result<Void, InviteCoordinatorError> {
        if isExpired {
            return .failure(.inviteExpired)
        }
        // roomId can be nil (pending validation) but if provided must not be empty
        if let roomId = roomId, roomId.isEmpty {
            return .failure(.invalidRoomId)
        }
        if token.isEmpty {
            return .failure(.invalidToken)
        }
        return .success(())
    }
}

// MARK: - Invite Coordinator Errors

enum InviteCoordinatorError: LocalizedError {
    case inviteExpired
    case invalidRoomId
    case invalidToken
    case invalidInvite
    case alreadyProcessing
    case torNotReady
    case torConnectionFailed(Error)
    case torTimeout
    case roomNotFound
    case joinFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .inviteExpired:
            return "This invite has expired. Please request a new one."
        case .invalidRoomId:
            return "Invalid room identifier."
        case .invalidToken:
            return "Invalid invite token."
        case .invalidInvite:
            return "This invite link is invalid."
        case .alreadyProcessing:
            return "An invite is already being processed."
        case .torNotReady:
            return "Secure connection not ready. Please try again."
        case .torConnectionFailed(let error):
            return "Unable to establish secure connection: \(error.localizedDescription)"
        case .torTimeout:
            return "Connection timed out. Please check your network and try again."
        case .roomNotFound:
            return "This room is no longer available."
        case .joinFailed(let reason):
            return "Failed to join room: \(reason)"
        case .cancelled:
            return "Join cancelled."
        }
    }
}

// MARK: - Invite Coordinator State

enum InviteCoordinatorState: Equatable {
    case idle
    case waitingForTor(progress: Int)
    case validatingInvite
    case joiningRoom
    case connectedWaitingApproval  // Connected to room, waiting for host to approve
    case approved                   // Host approved, entering room
    case joined
    case failed(String)
    case cancelled
}

// MARK: - Delegate Protocol

protocol InviteCoordinatorDelegate: AnyObject {
    /// Called when an invite is received and the coordinator starts processing
    func inviteCoordinatorDidReceiveInvite(_ coordinator: InviteCoordinator)

    /// Called when state changes (for UI updates)
    func inviteCoordinator(_ coordinator: InviteCoordinator, didChangeState state: InviteCoordinatorState)

    /// Called when Tor progress updates (for progress UI)
    func inviteCoordinator(_ coordinator: InviteCoordinator, didUpdateTorProgress progress: Int)

    /// Called when the invite is validated and join should proceed
    func inviteCoordinator(_ coordinator: InviteCoordinator, shouldJoinRoom roomId: String, withToken token: String)

    /// Called when an error occurs
    func inviteCoordinator(_ coordinator: InviteCoordinator, didFailWithError error: InviteCoordinatorError)

    /// Called when the user cancels
    func inviteCoordinatorDidCancel(_ coordinator: InviteCoordinator)
}

// MARK: - Invite Coordinator

/// Coordinates the invite flow, ensuring Tor is ready before any network operations
/// SECURITY: This class ensures that room joins NEVER happen before Tor is fully ready
final class InviteCoordinator {

    // MARK: - Properties

    #if DEBUG
    private let logger = Logger(subsystem: "com.ephemeral.rooms", category: "InviteCoordinator")
    #endif

    /// Current state
    private(set) var state: InviteCoordinatorState = .idle {
        didSet {
            guard state != oldValue else { return }
            #if DEBUG
            logger.info("State changed: \(String(describing: self.state))")
            #endif
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.inviteCoordinator(self, didChangeState: self.state)
            }
        }
    }

    /// Pending invite data (memory only, never persisted)
    private var pendingInvite: PendingInvite?

    /// Whether a join is currently in progress (prevents duplicates)
    private var joinInProgress = false

    /// Lock to prevent race conditions
    private let lock = NSLock()

    /// Tor state observer
    private var torStateObserver: NSObjectProtocol?

    /// Tor ready observer
    private var torReadyObserver: NSObjectProtocol?

    /// Tor error observer
    private var torErrorObserver: NSObjectProtocol?

    /// Timeout timer for Tor connection
    private var torTimeoutTimer: Timer?

    /// Tor connection timeout (60 seconds)
    private let torTimeout: TimeInterval = 60

    /// Reference to Tor manager
    private let torManager: EphemeralTorManager

    /// Delegate for callbacks
    weak var delegate: InviteCoordinatorDelegate?

    /// Whether there's a pending invite
    var hasPendingInvite: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingInvite != nil
    }

    // MARK: - Initialization

    init(torManager: EphemeralTorManager = .shared) {
        self.torManager = torManager
    }

    deinit {
        cleanupObservers()
        torTimeoutTimer?.invalidate()
    }

    // MARK: - Public API

    /// Handle an incoming invite with known roomId
    /// - Parameters:
    ///   - roomId: The room ID to join
    ///   - token: The invite token
    func handleInvite(roomId: String, token: String) {
        handleInviteInternal(roomId: roomId, token: token)
    }

    /// Handle an incoming invite where only the token is known
    /// The roomId will be discovered by validating the token after Tor is ready
    /// - Parameter token: The invite token
    func handleTokenOnlyInvite(token: String) {
        handleInviteInternal(roomId: nil, token: token)
    }

    private func handleInviteInternal(roomId: String?, token: String) {
        lock.lock()
        defer { lock.unlock() }

        #if DEBUG
        if let roomId = roomId {
            logger.info("Received invite for room: \(roomId.prefix(8))...")
        } else {
            logger.info("Received token-only invite (roomId to be validated)")
        }
        #endif

        // 1. Validate input
        guard !token.isEmpty else {
            #if DEBUG
            logger.error("Invalid invite: empty token")
            #endif
            notifyError(.invalidInvite)
            return
        }

        // If roomId is provided, it must not be empty
        if let roomId = roomId, roomId.isEmpty {
            #if DEBUG
            logger.error("Invalid invite: empty roomId provided")
            #endif
            notifyError(.invalidInvite)
            return
        }

        // 2. Prevent duplicate handling
        guard pendingInvite == nil && !joinInProgress else {
            #if DEBUG
            logger.warning("Already processing an invite")
            #endif
            notifyError(.alreadyProcessing)
            return
        }

        // 3. Cache invite in memory (NEVER persist)
        pendingInvite = PendingInvite(roomId: roomId, token: token)

        // 4. Notify delegate
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.inviteCoordinatorDidReceiveInvite(self)
        }

        // 5. Evaluate Tor state and proceed
        evaluateTorStateAndProceed()
    }

    /// Cancel the pending invite
    func cancelPendingInvite() {
        lock.lock()
        defer { lock.unlock() }

        #if DEBUG
        logger.info("Cancelling pending invite")
        #endif

        pendingInvite = nil
        joinInProgress = false
        state = .cancelled

        cleanupObservers()
        torTimeoutTimer?.invalidate()
        torTimeoutTimer = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.inviteCoordinatorDidCancel(self)
        }
    }

    /// Retry after a failure
    func retry() {
        lock.lock()

        guard let invite = pendingInvite else {
            lock.unlock()
            #if DEBUG
            logger.warning("No pending invite to retry")
            #endif
            return
        }

        // Reset state
        joinInProgress = false
        state = .idle
        lock.unlock()

        // Re-evaluate Tor state
        evaluateTorStateAndProceed()
    }

    /// Reset the coordinator to idle state
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        pendingInvite = nil
        joinInProgress = false
        state = .idle

        cleanupObservers()
        torTimeoutTimer?.invalidate()
        torTimeoutTimer = nil
    }

    /// Called when app enters foreground - re-evaluate Tor state if there's a pending invite
    func appDidEnterForeground() {
        lock.lock()
        guard pendingInvite != nil, !joinInProgress else {
            lock.unlock()
            return
        }
        lock.unlock()

        #if DEBUG
        logger.info("App entered foreground with pending invite - re-evaluating Tor state")
        #endif
        evaluateTorStateAndProceed()
    }

    // MARK: - Private Methods

    private func evaluateTorStateAndProceed() {
        // Check if Tor is already ready
        if torManager.verifyTorReady() {
            #if DEBUG
            logger.info("Tor is already ready - proceeding with invite")
            #endif
            onTorReady()
            return
        }

        // Check Tor state
        if torManager.state.isConnecting {
            #if DEBUG
            logger.info("Tor is connecting - waiting for ready")
            #endif
            state = .waitingForTor(progress: getBootstrapProgress())
            observeTorState()
            startTorTimeout()
        } else if torManager.state.isConnected {
            // Connected but not fully ready (waiting for circuit?)
            #if DEBUG
            logger.info("Tor connected but not fully ready - waiting")
            #endif
            state = .waitingForTor(progress: 90)
            observeTorState()
            startTorTimeout()
        } else {
            // Tor not started - start it
            #if DEBUG
            logger.info("Tor not started - starting Tor")
            #endif
            state = .waitingForTor(progress: 0)
            observeTorState()
            startTorTimeout()
            torManager.connect()
        }
    }

    private func getBootstrapProgress() -> Int {
        if case .bootstrapping(let progress) = torManager.state {
            return progress
        }
        return 0
    }

    private func observeTorState() {
        cleanupObservers()

        // Observe state changes for progress updates
        torStateObserver = NotificationCenter.default.addObserver(
            forName: .torStateDidChange,
            object: torManager,
            queue: .main
        ) { [weak self] notification in
            self?.handleTorStateChange(notification)
        }

        // Observe ready notification
        torReadyObserver = NotificationCenter.default.addObserver(
            forName: .torDidBecomeReady,
            object: torManager,
            queue: .main
        ) { [weak self] _ in
            self?.onTorReady()
        }

        // Observe errors
        torErrorObserver = NotificationCenter.default.addObserver(
            forName: .torDidEncounterError,
            object: torManager,
            queue: .main
        ) { [weak self] notification in
            if let error = notification.userInfo?["error"] as? Error {
                self?.onTorFailed(error: error)
            }
        }
    }

    private func handleTorStateChange(_ notification: Notification) {
        guard let state = notification.userInfo?["state"] as? TorConnectionState else { return }

        switch state {
        case .bootstrapping(let progress):
            self.state = .waitingForTor(progress: progress)
            delegate?.inviteCoordinator(self, didUpdateTorProgress: progress)

        case .connected:
            // Wait for the ready notification to ensure full readiness
            self.state = .waitingForTor(progress: 95)
            delegate?.inviteCoordinator(self, didUpdateTorProgress: 95)

        case .failed(let reason):
            onTorFailed(error: TorError.bootstrapFailed(reason))

        case .disconnected:
            // If we were waiting for Tor and it disconnected, that's a failure
            if case .waitingForTor = self.state {
                onTorFailed(error: TorError.notConnected)
            }

        case .reconnecting:
            // Keep waiting
            break
        }
    }

    private func onTorReady() {
        lock.lock()

        // Double-check Tor is truly ready (belt and suspenders)
        guard torManager.verifyTorReady() else {
            lock.unlock()
            #if DEBUG
            logger.warning("onTorReady called but Tor not actually ready")
            #endif
            return
        }

        // Stop timeout timer
        torTimeoutTimer?.invalidate()
        torTimeoutTimer = nil

        // Clean up observers
        cleanupObservers()

        lock.unlock()

        #if DEBUG
        logger.info("Tor is ready - executing join")
        #endif
        executeJoin()
    }

    private func onTorFailed(error: Error) {
        lock.lock()

        // Stop timeout timer
        torTimeoutTimer?.invalidate()
        torTimeoutTimer = nil

        // Clean up observers
        cleanupObservers()

        // Keep the invite for retry
        joinInProgress = false
        state = .failed(error.localizedDescription)

        lock.unlock()

        #if DEBUG
        logger.error("Tor failed: \(error.localizedDescription)")
        #endif
        notifyError(.torConnectionFailed(error))
    }

    private func startTorTimeout() {
        torTimeoutTimer?.invalidate()

        torTimeoutTimer = Timer.scheduledTimer(withTimeInterval: torTimeout, repeats: false) { [weak self] _ in
            self?.handleTorTimeout()
        }
    }

    private func handleTorTimeout() {
        lock.lock()

        cleanupObservers()

        // Keep the invite for retry
        joinInProgress = false
        state = .failed("Connection timed out")

        lock.unlock()

        #if DEBUG
        logger.error("Tor connection timed out after \(self.torTimeout) seconds")
        #endif
        notifyError(.torTimeout)
    }

    private func executeJoin() {
        lock.lock()

        // 1. Get and validate pending invite
        guard let invite = pendingInvite else {
            lock.unlock()
            #if DEBUG
            logger.warning("No pending invite to execute")
            #endif
            return
        }

        // 2. Validate invite
        switch invite.validate() {
        case .failure(let error):
            pendingInvite = nil
            lock.unlock()
            #if DEBUG
            logger.error("Invite validation failed: \(error.localizedDescription)")
            #endif
            notifyError(error)
            return
        case .success:
            break
        }

        // 3. CRITICAL: Final Tor check before any network operation
        guard torManager.verifyTorReady() else {
            lock.unlock()
            #if DEBUG
            logger.error("SECURITY: Attempted join but Tor not ready - aborting")
            #endif
            notifyError(.torNotReady)
            return
        }

        // 4. Mark join in progress (prevents duplicates)
        joinInProgress = true

        // 5. Clear pending invite (we're about to use it)
        let inviteToUse = invite
        pendingInvite = nil

        // 6. Update state
        state = .validatingInvite

        lock.unlock()

        // 7. Delegate handles the actual join
        // If roomId is nil, delegate will need to validate the token first
        #if DEBUG
        if let roomId = inviteToUse.roomId {
            logger.info("Executing join for room: \(roomId.prefix(8))...")
        } else {
            logger.info("Executing token validation (roomId will be discovered)")
        }
        #endif
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Pass empty string for roomId if nil - delegate will check requiresTokenValidation
            self.delegate?.inviteCoordinator(self, shouldJoinRoom: inviteToUse.roomId ?? "", withToken: inviteToUse.token)
        }
    }

    private func cleanupObservers() {
        if let observer = torStateObserver {
            NotificationCenter.default.removeObserver(observer)
            torStateObserver = nil
        }
        if let observer = torReadyObserver {
            NotificationCenter.default.removeObserver(observer)
            torReadyObserver = nil
        }
        if let observer = torErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            torErrorObserver = nil
        }
    }

    private func notifyError(_ error: InviteCoordinatorError) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.inviteCoordinator(self, didFailWithError: error)
        }
    }

    // MARK: - Join Completion Callbacks

    /// Call this when WebSocket connects and join request is sent
    func joinRequestSent() {
        lock.lock()
        defer { lock.unlock() }

        state = .connectedWaitingApproval
        #if DEBUG
        logger.info("Connected - waiting for host approval")
        #endif
    }

    /// Call this when host approves the join request
    func joinApproved() {
        lock.lock()
        defer { lock.unlock() }

        state = .approved
        #if DEBUG
        logger.info("Join approved by host")
        #endif
    }

    /// Call this when join succeeds
    func joinDidSucceed() {
        lock.lock()
        defer { lock.unlock() }

        joinInProgress = false
        state = .joined
        #if DEBUG
        logger.info("Join succeeded")
        #endif
    }

    /// Call this when join fails
    func joinDidFail(reason: String) {
        lock.lock()
        defer { lock.unlock() }

        joinInProgress = false
        state = .failed(reason)
        #if DEBUG
        logger.error("Join failed: \(reason)")
        #endif
    }
}
