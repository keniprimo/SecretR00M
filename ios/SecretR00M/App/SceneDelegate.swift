import UIKit
#if DEBUG
import os.log
#endif

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    #if DEBUG
    private let logger = Logger(subsystem: "com.ephemeral.rooms", category: "SceneDelegate")
    #endif

    /// Whether the real app has been unlocked
    private var isUnlocked = false

    /// Privacy overlay shown in app switcher
    private var privacySplashView: UIView?

    /// Reference to navigation controller for deep link navigation
    private weak var navigationController: UINavigationController?

    /// Current room session when joining via deep link
    private var currentSession: RoomSession?

    /// Loading alert shown during room join
    private var joiningLoadingAlert: UIAlertController?

    /// Invite coordinator for Tor-safe invite handling
    private lazy var inviteCoordinator: InviteCoordinator = {
        let coordinator = InviteCoordinator()
        coordinator.delegate = self
        return coordinator
    }()

    /// Tor waiting view controller (shown while waiting for Tor)
    private var torWaitingViewController: UIViewController?

    // MARK: - Scene Lifecycle

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        #if DEBUG
        logger.info("scene willConnectTo called")
        #endif
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let window = UIWindow(windowScene: windowScene)
        self.window = window

        // CRITICAL: Register deep link handler EARLY, before any other setup
        // This ensures we don't lose deep links that arrive during initialization
        #if DEBUG
        logger.info("Registering deep link handler early in lifecycle")
        #endif
        setupDeepLinkHandler()

        // Check if app lock is enabled
        if AppLockManager.shared.shouldShowLockOnLaunch {
            #if DEBUG
            logger.info("Showing app lock screen")
            #endif
            showPINLockScreen(in: windowScene)
            // Store connection options for after unlock
            storeConnectionOptions(connectionOptions)
            return
        }

        // Normal launch - no lock required
        // CRITICAL: Store connection options BEFORE showing main interface
        // so processPendingDeepLinks() can find them
        storeConnectionOptions(connectionOptions)

        showMainInterface(in: windowScene)
        isUnlocked = true
    }

    /// Store connection options to process after unlock
    private var pendingURLContexts: Set<UIOpenURLContext>?
    private var pendingUserActivity: NSUserActivity?

    private func storeConnectionOptions(_ options: UIScene.ConnectionOptions) {
        if let urlContext = options.urlContexts.first {
            pendingURLContexts = options.urlContexts
        }
        if let userActivity = options.userActivities.first,
           userActivity.activityType == NSUserActivityTypeBrowsingWeb {
            pendingUserActivity = userActivity
        }
    }

    // MARK: - App Lock (User-Enabled Feature)

    /// Show the PIN lock screen when enabled
    /// No network activity starts until user unlocks
    private func showPINLockScreen(in scene: UIWindowScene) {
        let lockVC = PINPadViewController()
        lockVC.onUnlockRequested = { [weak self] in
            self?.transitionFromLockScreen()
        }

        window?.rootViewController = lockVC
        window?.makeKeyAndVisible()
    }

    /// Transition from lock screen to the main app
    private func transitionFromLockScreen() {
        guard let windowScene = window?.windowScene else { return }

        isUnlocked = true

        // Animate transition
        UIView.transition(with: window!, duration: 0.3, options: .transitionCrossDissolve) { [weak self] in
            self?.showMainInterface(in: windowScene)
        }
    }

    private func showMainInterface(in scene: UIWindowScene) {
        // Create navigation controller with home view
        let homeVC = HomeViewController()
        let navController = UINavigationController(rootViewController: homeVC)
        self.navigationController = navController

        window?.rootViewController = navController
        window?.makeKeyAndVisible()

        // Handler should already be registered in scene(_:willConnectTo:options:)
        // but ensure it's set up in case this is called from transition
        if DeepLinkHandler.shared.onDeepLinkReceived == nil {
            setupDeepLinkHandler()
        }

        // Process any pending deep links
        processPendingDeepLinks()

        // Check clipboard for deferred deep link (first launch after install)
        checkClipboardForInvite()
    }

    private func processPendingDeepLinks() {
        // Handle URL contexts that arrived at launch
        if let urlContexts = pendingURLContexts, let urlContext = urlContexts.first {
            handleIncomingURL(urlContext.url)
            pendingURLContexts = nil
        }

        // Handle user activities
        if let userActivity = pendingUserActivity,
           let url = userActivity.webpageURL {
            handleIncomingURL(url)
            pendingUserActivity = nil
        }
    }

    // MARK: - URL Handling

    /// Handle URLs opened while app is running
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        #if DEBUG
        logger.info("scene openURLContexts called with \(URLContexts.count) URLs")
        #endif
        guard let urlContext = URLContexts.first else {
            #if DEBUG
            logger.warning("No URL contexts to process")
            #endif
            return
        }

        #if DEBUG
        logger.info("Processing URL: \(urlContext.url.scheme ?? "nil", privacy: .public)://...")
        #endif

        // CRITICAL: Ensure handler is registered (may have been cleared)
        if DeepLinkHandler.shared.onDeepLinkReceived == nil {
            #if DEBUG
            logger.warning("Handler was nil in openURLContexts - re-registering")
            #endif
            setupDeepLinkHandler()
        }

        handleIncomingURL(urlContext.url)
    }

    /// Handle Universal Links via NSUserActivity
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        #if DEBUG
        logger.info("scene continue userActivity called")
        #endif
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else {
            #if DEBUG
            logger.debug("Not a web browsing activity or no URL")
            #endif
            return
        }
        #if DEBUG
        logger.info("Processing Universal Link: \(url.host ?? "nil", privacy: .public)/...")
        #endif
        handleIncomingURL(url)
    }

    // MARK: - Deep Link Setup

    private func setupDeepLinkHandler() {
        #if DEBUG
        logger.info("Setting up deep link handler callback")
        #endif
        DeepLinkHandler.shared.onDeepLinkReceived = { [weak self] parsedLink in
            #if DEBUG
            self?.logger.info("Deep link handler callback invoked")
            #endif
            self?.processDeepLink(parsedLink)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        #if DEBUG
        logger.info("handleIncomingURL called with scheme: \(url.scheme ?? "nil", privacy: .public)")
        #endif
        _ = DeepLinkHandler.shared.handleURL(url)
    }

    private func checkClipboardForInvite() {
        // Slight delay to let UI settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let parsedLink = DeepLinkHandler.shared.checkClipboardForInvite() {
                self?.showClipboardInvitePrompt(parsedLink)
            }
        }
    }

    // MARK: - Deep Link Processing

    private func processDeepLink(_ parsedLink: DeepLinkHandler.ParsedDeepLink) {
        #if DEBUG
        logger.info("processDeepLink called with type: \(String(describing: parsedLink.type), privacy: .public)")
        #endif
        switch parsedLink.type {
        case .joinRoom(let token):
            #if DEBUG
            logger.info("Processing joinRoom deep link, token length: \(token.count)")
            #endif
            presentJoinRoomFlow(token: token)
        case .unknown:
            #if DEBUG
            logger.warning("Unknown deep link type - ignoring")
            #endif
            break
        }
    }

    private func presentJoinRoomFlow(token: String) {
        #if DEBUG
        logger.info("presentJoinRoomFlow started, token length: \(token.count)")
        #endif

        // Show waiting UI while we prepare
        showTorWaitingUI()

        // Store the token for validation after Tor is ready
        pendingValidationToken = token
        #if DEBUG
        logger.debug("Stored pending validation token")
        #endif

        // Check if Tor is already ready
        let torReady = EphemeralTorManager.shared.verifyTorReady()
        #if DEBUG
        logger.info("Tor ready check: \(torReady)")
        #endif

        if torReady {
            // Tor is ready - validate and join immediately
            #if DEBUG
            logger.info("Tor is ready - proceeding to validate immediately")
            #endif
            validateAndJoinRoom(token: token)
        } else {
            // Need to wait for Tor
            // Use the coordinator to handle Tor waiting with token-only invite
            // (roomId will be discovered via token validation after Tor is ready)
            #if DEBUG
            logger.info("Tor not ready - delegating to inviteCoordinator with token-only invite")
            #endif
            inviteCoordinator.handleTokenOnlyInvite(token: token)
        }
    }

    /// Token waiting for validation (stored while waiting for Tor)
    private var pendingValidationToken: String?

    private func navigateToJoinRoom(roomID: String, token: String) {
        guard let nav = navigationController else { return }

        // Pop to root first if needed
        nav.popToRootViewController(animated: false)

        // Create join room view controller
        // Note: This would integrate with existing JoinRoomViewController
        // For now, show confirmation that we received the invite
        let alert = UIAlertController(
            title: "Join Room?",
            message: "You've been invited to a secure room. Join now?",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self] _ in
            // TODO: Navigate to actual join flow with roomID
            // This would call existing room joining logic
            self?.initiateRoomJoin(roomID: roomID, token: token)
        })

        nav.present(alert, animated: true)
    }

    private func initiateRoomJoin(roomID: String, token: String) {
        guard let nav = navigationController else { return }

        // Create room configuration with Tor settings
        var config = RoomConfiguration.default
        HighSecurityMode.shared.applyTo(&config)

        // Create session
        let session = RoomSession(configuration: config)
        session.delegate = self
        currentSession = session

        do {
            // Begin joining process with invite token
            try session.joinRoom(roomIdString: roomID, inviteToken: token)

            // Show loading indicator
            let loadingAlert = UIAlertController(
                title: nil,
                message: "Joining secure room...",
                preferredStyle: .alert
            )
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.startAnimating()
            loadingAlert.view.addSubview(indicator)

            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: loadingAlert.view.centerXAnchor),
                indicator.bottomAnchor.constraint(equalTo: loadingAlert.view.bottomAnchor, constant: -20)
            ])

            joiningLoadingAlert = loadingAlert
            nav.present(loadingAlert, animated: true)

        } catch {
            showInviteError("Failed to join: \(error.localizedDescription)")
        }
    }

    private func dismissJoiningAlert(completion: (() -> Void)? = nil) {
        if let alert = joiningLoadingAlert {
            alert.dismiss(animated: true) {
                completion?()
            }
            joiningLoadingAlert = nil
        } else {
            completion?()
        }
    }

    private func showRoomScreen() {
        guard let session = currentSession, let nav = navigationController else { return }

        dismissJoiningAlert { [weak self] in
            let roomVC = RoomViewController(session: session)
            nav.pushViewController(roomVC, animated: true)
            self?.currentSession = nil
        }
    }

    private func showClipboardInvitePrompt(_ parsedLink: DeepLinkHandler.ParsedDeepLink) {
        guard let nav = navigationController,
              case .joinRoom(let token) = parsedLink.type else {
            return
        }

        let alert = UIAlertController(
            title: "Invite Detected",
            message: "You have a SecretR00M invite link in your clipboard. Would you like to join?",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Ignore", style: .cancel) { _ in
            DeepLinkHandler.shared.clearPendingDeepLink()
        })

        alert.addAction(UIAlertAction(title: "Join Room", style: .default) { [weak self] _ in
            self?.presentJoinRoomFlow(token: token)
        })

        nav.present(alert, animated: true)
    }

    private func showInviteError(_ message: String) {
        guard let nav = navigationController else { return }

        let alert = UIAlertController(
            title: "Invalid Invite",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        nav.present(alert, animated: true)
    }

    // MARK: - Tor Waiting UI

    private func showTorWaitingUI() {
        guard let nav = navigationController else { return }

        // Dismiss any existing alerts
        nav.presentedViewController?.dismiss(animated: false)

        let waitingVC = TorWaitingViewController()
        waitingVC.modalPresentationStyle = .overFullScreen
        waitingVC.modalTransitionStyle = .crossDissolve
        waitingVC.onCancel = { [weak self] in
            self?.inviteCoordinator.cancelPendingInvite()
            self?.dismissTorWaitingUI()
        }

        torWaitingViewController = waitingVC
        nav.present(waitingVC, animated: true)
    }

    private func dismissTorWaitingUI(completion: (() -> Void)? = nil) {
        if let waitingVC = torWaitingViewController {
            waitingVC.dismiss(animated: true) {
                completion?()
            }
            torWaitingViewController = nil
        } else {
            completion?()
        }
    }

    private func updateTorWaitingProgress(_ progress: Int) {
        if let waitingVC = torWaitingViewController as? TorWaitingViewController {
            waitingVC.updateProgress(progress)
        }
    }

    private func showTorWaitingError(_ message: String) {
        if let waitingVC = torWaitingViewController as? TorWaitingViewController {
            waitingVC.showError(message) { [weak self] in
                self?.inviteCoordinator.retry()
            }
        }
    }

    private func getRelayURL() -> URL {
        // Use the .onion relay server (same as RoomConfiguration.default)
        // HTTP for REST API calls (invite endpoints)
        return URL(string: "http://xihrxmtwitgihtxllygrgoxixuu6ib7kzmgvosv7467tnij5svgyabid.onion")!
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Scene is being released - wipe any active session
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.activeSession?.quickExit()
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Remove privacy splash
        removePrivacySplash()

        // SECURITY: Clear clipboard of any invite tokens/sensitive data on foreground
        clearClipboardIfSensitive()

        // Check if still recording
        if UIScreen.main.isCaptured {
            // Still recording - keep privacy overlay on chat screens
            // The RoomViewController handles this via SecurityMonitor
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // App losing focus - show privacy splash IMMEDIATELY
        // This appears in the app switcher
        showPrivacySplash()

        // SECURITY: Clear clipboard when leaving app to prevent data leakage
        // to other apps via pasteboard
        clearClipboardIfSensitive()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        #if DEBUG
        logger.info("sceneWillEnterForeground called")
        #endif
        // Coming back from background - splash will be removed in didBecomeActive

        // Ensure Tor is connected when returning from background
        EphemeralTorManager.shared.ensureConnected()

        // CRITICAL: Ensure handler is registered
        if DeepLinkHandler.shared.onDeepLinkReceived == nil {
            #if DEBUG
            logger.warning("Deep link handler was nil on foreground - re-registering")
            #endif
            setupDeepLinkHandler()
        }

        // Process any pending deep links that arrived while in background
        let hasPending = DeepLinkHandler.shared.hasPendingDeepLink
        #if DEBUG
        logger.info("Has pending deep link: \(hasPending)")
        #endif
        if hasPending {
            #if DEBUG
            logger.info("Processing pending deep link from foreground")
            #endif
            DeepLinkHandler.shared.processPendingDeepLink()
        }

        // Re-evaluate Tor state if there's a pending invite
        inviteCoordinator.appDidEnterForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Entered background - session should already be destroyed by AppDelegate
        // Ensure privacy splash is shown
        showPrivacySplash()
    }

    // MARK: - Clipboard Evidence Reduction

    /// SECURITY: Clear the clipboard if it contains data that could link to this app.
    /// This prevents invite tokens, room URLs, or copied messages from persisting
    /// in the system pasteboard where other apps or forensic tools could access them.
    private func clearClipboardIfSensitive() {
        let pasteboard = UIPasteboard.general

        // Check if clipboard contains our custom URL scheme or invite URLs
        if let urlString = pasteboard.string {
            let isSensitive = urlString.contains("secretr00m://")
                || urlString.contains("secretr00m.app/join")
                || urlString.contains(".onion")
            if isSensitive {
                pasteboard.items = [] // Clear all pasteboard items
                #if DEBUG
                logger.debug("Cleared sensitive clipboard content")
                #endif
            }
        }

        if let url = pasteboard.url {
            let isSensitive = url.scheme == "secretr00m"
                || url.host?.hasSuffix(".onion") == true
                || url.host?.contains("secretr00m") == true
            if isSensitive {
                pasteboard.items = []
                #if DEBUG
                logger.debug("Cleared sensitive clipboard URL")
                #endif
            }
        }
    }

    // MARK: - Privacy Splash

    /// Show an overlay for app switcher privacy protection.
    ///
    /// This overlay is shown in:
    /// - App switcher snapshots
    /// - Background state
    /// - Losing focus scenarios
    private func showPrivacySplash() {
        guard let window = window, privacySplashView == nil else { return }

        // Use a simple blur overlay for privacy
        let overlay = UIView(frame: window.bounds)
        overlay.tag = 999
        overlay.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.18, alpha: 1.0)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Add blur effect
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.frame = overlay.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(blur)

        // Add centered app branding
        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = .systemBlue
        iconContainer.layer.cornerRadius = 18
        overlay.addSubview(iconContainer)

        let lockIcon = UIImageView()
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.image = UIImage(systemName: "lock.shield.fill")
        lockIcon.tintColor = .white
        iconContainer.addSubview(lockIcon)

        let appName = UILabel()
        appName.translatesAutoresizingMaskIntoConstraints = false
        appName.text = "SecretR00M"
        appName.font = .systemFont(ofSize: 20, weight: .semibold)
        appName.textColor = .white
        overlay.addSubview(appName)

        NSLayoutConstraint.activate([
            iconContainer.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            iconContainer.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -30),
            iconContainer.widthAnchor.constraint(equalToConstant: 70),
            iconContainer.heightAnchor.constraint(equalToConstant: 70),

            lockIcon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            lockIcon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 36),
            lockIcon.heightAnchor.constraint(equalToConstant: 36),

            appName.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            appName.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 12)
        ])

        window.addSubview(overlay)
        privacySplashView = overlay
    }

    /// Remove the privacy overlay
    private func removePrivacySplash() {
        privacySplashView?.removeFromSuperview()
        privacySplashView = nil
    }
}

// MARK: - RoomSessionDelegate

extension SceneDelegate: RoomSessionDelegate {

    func roomSession(_ session: RoomSession, didChangeState state: RoomState) {
        DispatchQueue.main.async { [weak self] in
            #if DEBUG
            self?.logger.info("RoomSession state changed: \(String(describing: state), privacy: .public)")
            #endif
            switch state {
            case .creating:
                // Connected to server - now waiting for host approval
                if session.role == .client {
                    #if DEBUG
                    self?.logger.info("Client connected - waiting for host approval")
                    #endif
                    self?.inviteCoordinator.joinRequestSent()
                }

            case .active:
                // Successfully joined - show room screen
                if session.role == .client {
                    #if DEBUG
                    self?.logger.info("Room active as client - join succeeded!")
                    #endif
                    self?.inviteCoordinator.joinDidSucceed()
                    self?.dismissTorWaitingUI {
                        self?.showRoomScreen()
                    }
                }

            case .destroyed(let reason):
                #if DEBUG
                self?.logger.error("Room destroyed: \(reason.rawValue, privacy: .public)")
                #endif
                self?.inviteCoordinator.joinDidFail(reason: reason.rawValue)
                self?.dismissJoiningAlert()
                self?.dismissTorWaitingUI {
                    self?.showInviteError("Room ended: \(reason.rawValue)")
                }
                self?.currentSession = nil

            default:
                break
            }
        }
    }

    func roomSession(_ session: RoomSession, didReceiveEvent event: RoomEvent) {
        DispatchQueue.main.async { [weak self] in
            #if DEBUG
            self?.logger.info("RoomSession event: \(String(describing: event), privacy: .public)")
            #endif
            switch event {
            case .joinRejected(let reason):
                #if DEBUG
                self?.logger.error("Join rejected by server: \(reason, privacy: .public)")
                #endif
                self?.inviteCoordinator.joinDidFail(reason: reason)
                self?.dismissJoiningAlert()
                self?.dismissTorWaitingUI {
                    self?.showInviteError("Join rejected: \(reason)")
                }
                self?.currentSession = nil

            case .error(let message):
                #if DEBUG
                self?.logger.error("Room error: \(message, privacy: .public)")
                #endif
                self?.inviteCoordinator.joinDidFail(reason: message)
                self?.dismissJoiningAlert()
                self?.dismissTorWaitingUI {
                    self?.showInviteError(message)
                }
                self?.currentSession = nil

            case .joinApproved:
                // Host approved our join request - update coordinator state
                #if DEBUG
                self?.logger.info("Join approved by host!")
                #endif
                self?.inviteCoordinator.joinApproved()

            default:
                break
            }
        }
    }

    func roomSession(_ session: RoomSession, didReceiveMessage message: DecryptedMessage) {
        // Not used in deep link join flow - handled by RoomViewController
    }

    func roomSession(_ session: RoomSession, didReceiveJoinRequest request: PendingJoinRequest) {
        // Not used in deep link join flow - only relevant for hosts
    }
}

// MARK: - InviteCoordinatorDelegate

extension SceneDelegate: InviteCoordinatorDelegate {

    func inviteCoordinatorDidReceiveInvite(_ coordinator: InviteCoordinator) {
        #if DEBUG
        logger.info("InviteCoordinator: invite received")
        #endif
        // Invite received - UI is already shown in presentJoinRoomFlow
    }

    func inviteCoordinator(_ coordinator: InviteCoordinator, didChangeState state: InviteCoordinatorState) {
        DispatchQueue.main.async { [weak self] in
            #if DEBUG
            self?.logger.info("InviteCoordinator state changed: \(String(describing: state), privacy: .public)")
            #endif
            switch state {
            case .waitingForTor(let progress):
                #if DEBUG
                self?.logger.debug("Waiting for Tor: \(progress)%")
                #endif
                self?.updateTorWaitingProgress(progress)

            case .validatingInvite:
                #if DEBUG
                self?.logger.info("State: validating invite")
                #endif
                // Update UI to show "Validating..."
                if let waitingVC = self?.torWaitingViewController as? TorWaitingViewController {
                    waitingVC.showValidating()
                }

            case .joiningRoom:
                #if DEBUG
                self?.logger.info("State: joining room")
                #endif
                // Update UI to show "Connecting..."
                if let waitingVC = self?.torWaitingViewController as? TorWaitingViewController {
                    waitingVC.showJoining()
                }

            case .connectedWaitingApproval:
                #if DEBUG
                self?.logger.info("State: connected, waiting for host approval")
                #endif
                // Update UI to show "Waiting for host approval..."
                if let waitingVC = self?.torWaitingViewController as? TorWaitingViewController {
                    waitingVC.showWaitingForApproval()
                }

            case .approved:
                #if DEBUG
                self?.logger.info("State: approved by host")
                #endif
                // Update UI to show "Approved!"
                if let waitingVC = self?.torWaitingViewController as? TorWaitingViewController {
                    waitingVC.showApproved()
                }

            case .joined:
                #if DEBUG
                self?.logger.info("State: joined successfully")
                #endif
                // Success - UI will be updated when room becomes active
                break

            case .failed(let reason):
                #if DEBUG
                self?.logger.error("State: failed - \(reason, privacy: .public)")
                #endif
                self?.showTorWaitingError(reason)

            case .cancelled:
                #if DEBUG
                self?.logger.info("State: cancelled")
                #endif
                self?.dismissTorWaitingUI()

            case .idle:
                break
            }
        }
    }

    func inviteCoordinator(_ coordinator: InviteCoordinator, didUpdateTorProgress progress: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.updateTorWaitingProgress(progress)
        }
    }

    func inviteCoordinator(_ coordinator: InviteCoordinator, shouldJoinRoom roomId: String, withToken token: String) {
        // Tor is now ready - we can safely make network calls
        // Check if this is a token-only invite (empty roomId means we need to validate first)
        if roomId.isEmpty, let validationToken = pendingValidationToken {
            #if DEBUG
            logger.info("InviteCoordinator: token-only invite - will validate token first")
            #endif
            pendingValidationToken = nil
            validateAndJoinRoom(token: validationToken)
        } else if roomId.isEmpty {
            // Empty roomId but no pending token - use the provided token
            #if DEBUG
            logger.info("InviteCoordinator: token-only invite - validating provided token")
            #endif
            validateAndJoinRoom(token: token)
        } else {
            // Direct join (roomId already known)
            #if DEBUG
            logger.info("InviteCoordinator: direct join flow, roomId=\(roomId.prefix(8), privacy: .public)...")
            #endif
            initiateRoomJoin(roomID: roomId, token: token)
        }
    }

    func inviteCoordinator(_ coordinator: InviteCoordinator, didFailWithError error: InviteCoordinatorError) {
        #if DEBUG
        logger.error("InviteCoordinator error: \(error.localizedDescription, privacy: .public)")
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.showTorWaitingError(error.localizedDescription)
        }
    }

    func inviteCoordinatorDidCancel(_ coordinator: InviteCoordinator) {
        #if DEBUG
        logger.info("InviteCoordinator: cancelled")
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.pendingValidationToken = nil
            self?.dismissTorWaitingUI()
        }
    }

    /// Validate token and then join room (called after Tor is ready)
    private func validateAndJoinRoom(token: String) {
        #if DEBUG
        logger.info("validateAndJoinRoom started, token length: \(token.count)")
        #endif

        // Update UI
        if let waitingVC = torWaitingViewController as? TorWaitingViewController {
            waitingVC.showValidating()
        }

        let relayURL = getRelayURL()
        #if DEBUG
        logger.debug("Using relay URL: \(relayURL.absoluteString, privacy: .public)")
        #endif

        // SECURITY: Tor is now verified ready by InviteCoordinator
        InviteManager.shared.validateToken(token, relayURL: relayURL) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let validation):
                    #if DEBUG
                    self?.logger.info("Token validation response: valid=\(validation.isValid), roomID=\(validation.roomID ?? "nil", privacy: .public)")
                    #endif
                    if validation.isValid, let roomID = validation.roomID {
                        // Proceed to join
                        #if DEBUG
                        self?.logger.info("Token valid - proceeding to join room")
                        #endif
                        self?.initiateRoomJoinFromCoordinator(roomID: roomID, token: token)
                    } else {
                        let errorMsg = validation.error ?? "Invalid invite link"
                        #if DEBUG
                        self?.logger.error("Token invalid: \(errorMsg, privacy: .public)")
                        #endif
                        self?.inviteCoordinator.joinDidFail(reason: errorMsg)
                        self?.showTorWaitingError(errorMsg)
                    }

                case .failure(let error):
                    #if DEBUG
                    self?.logger.error("Token validation failed: \(error.localizedDescription, privacy: .public)")
                    #endif
                    self?.inviteCoordinator.joinDidFail(reason: error.localizedDescription)
                    self?.showTorWaitingError(error.localizedDescription)
                }
            }
        }
    }

    /// Initiate room join after validation (called from coordinator flow)
    private func initiateRoomJoinFromCoordinator(roomID: String, token: String) {
        #if DEBUG
        logger.info("initiateRoomJoinFromCoordinator started for room: \(roomID.prefix(8), privacy: .public)...")
        #endif

        guard let _ = navigationController else {
            #if DEBUG
            logger.error("No navigation controller available - cannot join room")
            #endif
            return
        }

        // Update UI
        if let waitingVC = torWaitingViewController as? TorWaitingViewController {
            waitingVC.showJoining()
        }

        // SECURITY: Final Tor check before any network operation
        let torReady = EphemeralTorManager.shared.verifyTorReady()
        #if DEBUG
        logger.info("Final Tor ready check: \(torReady)")
        #endif

        guard torReady else {
            #if DEBUG
            logger.error("Tor connection lost before join")
            #endif
            inviteCoordinator.joinDidFail(reason: "Secure connection lost")
            showTorWaitingError("Secure connection lost. Please try again.")
            return
        }

        // Create room configuration with Tor settings
        var config = RoomConfiguration.default
        HighSecurityMode.shared.applyTo(&config)

        // Create session
        let session = RoomSession(configuration: config)
        session.delegate = self
        currentSession = session
        #if DEBUG
        logger.debug("RoomSession created with Tor configuration")
        #endif

        do {
            // Begin joining process with invite token
            // SECURITY: Token is passed to server for consumption (single-use validation)
            #if DEBUG
            logger.info("Calling session.joinRoom with token")
            #endif
            try session.joinRoom(roomIdString: roomID, inviteToken: token)
            #if DEBUG
            logger.info("joinRoom call succeeded - waiting for connection")
            #endif
        } catch {
            #if DEBUG
            logger.error("joinRoom threw error: \(error.localizedDescription, privacy: .public)")
            #endif
            inviteCoordinator.joinDidFail(reason: error.localizedDescription)
            showTorWaitingError("Failed to join: \(error.localizedDescription)")
        }
    }
}
