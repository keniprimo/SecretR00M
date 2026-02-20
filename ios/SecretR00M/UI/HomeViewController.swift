import UIKit
#if DEBUG
import os.log
#endif

/// HomeViewController provides the main entry point for creating or joining rooms.
/// All connections are routed through Tor for maximum privacy.
final class HomeViewController: UIViewController {

    #if DEBUG
    private let logger = Logger(subsystem: "com.ephemeral.rooms", category: "HomeViewController")
    #endif

    // MARK: - UI Components

    private let gradientLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.colors = [
            UIColor.systemBackground.cgColor,
            UIColor.systemBackground.cgColor,
            UIColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 0.05).cgColor
        ]
        layer.locations = [0.0, 0.5, 1.0]
        return layer
    }()

    private let logoContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let shieldImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .systemBlue
        // Create a shield with lock symbol
        let config = UIImage.SymbolConfiguration(pointSize: 60, weight: .light)
        imageView.image = UIImage(systemName: "lock.shield.fill", withConfiguration: config)
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "SecretR00M"
        label.font = .systemFont(ofSize: 34, weight: .bold)
        label.textAlignment = .center
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Secure, ephemeral messaging"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    // Tor Status Card
    private let torCardView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 16
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.05
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.layer.shadowRadius = 8
        return view
    }()

    private let torIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .systemPurple
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        imageView.image = UIImage(systemName: "network", withConfiguration: config)
        return imageView
    }()

    private let torTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Secure Network"
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        return label
    }()

    private let torDescriptionLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "All traffic securely routed. Your IP is never exposed."
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    private lazy var torStatusView: TorStatusView = {
        let view = TorStatusView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    // Action Buttons
    private let buttonsStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        return stack
    }()

    private let createRoomButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.filled()
        config.title = "Create Room"
        config.image = UIImage(systemName: "plus.circle.fill")
        config.imagePadding = 8
        config.cornerStyle = .large
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = .white
        button.configuration = config

        return button
    }()

    private let joinRoomButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.tinted()
        config.title = "Join Room"
        config.image = UIImage(systemName: "arrow.right.circle.fill")
        config.imagePadding = 8
        config.cornerStyle = .large
        config.baseBackgroundColor = .systemBlue
        button.configuration = config

        return button
    }()

    // Security Mode Card
    private let securityCardView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 16
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.05
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.layer.shadowRadius = 8
        return view
    }()

    private let securityIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .systemOrange
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        imageView.image = UIImage(systemName: "exclamationmark.shield.fill", withConfiguration: config)
        return imageView
    }()

    private let highSecurityLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "High Security Mode"
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        return label
    }()

    private let highSecurityToggle: UISwitch = {
        let toggle = UISwitch()
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.isOn = HighSecurityMode.shared.isEnabled
        toggle.onTintColor = .systemOrange
        return toggle
    }()

    private let securityInfoLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Press-to-reveal messages, auto-rekey on capture, quick exit"
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    // Footer
    private let footerLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "End-to-end encrypted"
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        return label
    }()

    private let footerIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .tertiaryLabel
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        imageView.image = UIImage(systemName: "checkmark.seal.fill", withConfiguration: config)
        return imageView
    }()

    // MARK: - Properties

    private var currentSession: RoomSession?

    // MARK: - Lifecycle

    private var hasCheckedIntegrity = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupTorObserver()

        // Start Tor connection immediately
        startTorConnection()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Ensure Tor reconnects when returning to home screen (e.g., after closing a room)
        ensureTorConnected()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Check device integrity after view is in hierarchy (to avoid presenting alert from detached VC)
        if !hasCheckedIntegrity {
            hasCheckedIntegrity = true
            checkDeviceIntegrity()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = view.bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateGradientColors()
    }

    private func updateGradientColors() {
        gradientLayer.colors = [
            UIColor.systemBackground.cgColor,
            UIColor.systemBackground.cgColor,
            UIColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 0.05).cgColor
        ]
    }

    private func setupTorObserver() {
        // Observe Tor state changes to update UI
        EphemeralTorManager.shared.delegate = self
    }

    private func startTorConnection() {
        // Disable buttons until Tor is connected
        updateButtonStates()

        // Start Tor connection
        EphemeralTorManager.shared.connect()
    }

    /// Ensure Tor is connected when returning to home screen
    /// This handles reconnection after closing a room or if connection was lost
    private func ensureTorConnected() {
        // Update UI based on current state
        updateButtonStates()

        // Ensure delegate is set for state updates
        EphemeralTorManager.shared.delegate = self

        // Use TorManager's ensureConnected which handles all states
        EphemeralTorManager.shared.ensureConnected()
    }

    // Settings button
    private let settingsButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        button.setImage(UIImage(systemName: "gearshape.fill", withConfiguration: config), for: .normal)
        button.tintColor = .secondaryLabel
        return button
    }()

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground
        navigationController?.setNavigationBarHidden(true, animated: false)

        // Add gradient background
        view.layer.insertSublayer(gradientLayer, at: 0)

        // Settings button
        view.addSubview(settingsButton)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        // Logo section
        view.addSubview(logoContainerView)
        logoContainerView.addSubview(shieldImageView)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)

        // Tor card
        view.addSubview(torCardView)
        torCardView.addSubview(torIconView)
        torCardView.addSubview(torTitleLabel)
        torCardView.addSubview(torDescriptionLabel)
        torCardView.addSubview(torStatusView)

        // Buttons
        view.addSubview(buttonsStackView)
        buttonsStackView.addArrangedSubview(createRoomButton)
        buttonsStackView.addArrangedSubview(joinRoomButton)

        // Security card
        view.addSubview(securityCardView)
        securityCardView.addSubview(securityIconView)
        securityCardView.addSubview(highSecurityLabel)
        securityCardView.addSubview(highSecurityToggle)
        securityCardView.addSubview(securityInfoLabel)

        // Footer
        view.addSubview(footerIconView)
        view.addSubview(footerLabel)

        // Actions
        createRoomButton.addTarget(self, action: #selector(createRoomTapped), for: .touchUpInside)
        joinRoomButton.addTarget(self, action: #selector(joinRoomTapped), for: .touchUpInside)
        highSecurityToggle.addTarget(self, action: #selector(securityToggleChanged), for: .valueChanged)

        let padding: CGFloat = 24

        NSLayoutConstraint.activate([
            // Settings button
            settingsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            settingsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            settingsButton.widthAnchor.constraint(equalToConstant: 44),
            settingsButton.heightAnchor.constraint(equalToConstant: 44),

            // Logo container
            logoContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            logoContainerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logoContainerView.widthAnchor.constraint(equalToConstant: 80),
            logoContainerView.heightAnchor.constraint(equalToConstant: 80),

            shieldImageView.centerXAnchor.constraint(equalTo: logoContainerView.centerXAnchor),
            shieldImageView.centerYAnchor.constraint(equalTo: logoContainerView.centerYAnchor),
            shieldImageView.widthAnchor.constraint(equalToConstant: 70),
            shieldImageView.heightAnchor.constraint(equalToConstant: 70),

            // Title
            titleLabel.topAnchor.constraint(equalTo: logoContainerView.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),

            // Subtitle
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Tor Card
            torCardView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 24),
            torCardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            torCardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),

            torIconView.topAnchor.constraint(equalTo: torCardView.topAnchor, constant: 16),
            torIconView.leadingAnchor.constraint(equalTo: torCardView.leadingAnchor, constant: 16),
            torIconView.widthAnchor.constraint(equalToConstant: 32),
            torIconView.heightAnchor.constraint(equalToConstant: 32),

            torTitleLabel.centerYAnchor.constraint(equalTo: torIconView.centerYAnchor),
            torTitleLabel.leadingAnchor.constraint(equalTo: torIconView.trailingAnchor, constant: 12),
            torTitleLabel.trailingAnchor.constraint(equalTo: torCardView.trailingAnchor, constant: -16),

            torDescriptionLabel.topAnchor.constraint(equalTo: torIconView.bottomAnchor, constant: 8),
            torDescriptionLabel.leadingAnchor.constraint(equalTo: torCardView.leadingAnchor, constant: 16),
            torDescriptionLabel.trailingAnchor.constraint(equalTo: torCardView.trailingAnchor, constant: -16),

            torStatusView.topAnchor.constraint(equalTo: torDescriptionLabel.bottomAnchor, constant: 12),
            torStatusView.leadingAnchor.constraint(equalTo: torCardView.leadingAnchor, constant: 16),
            torStatusView.trailingAnchor.constraint(equalTo: torCardView.trailingAnchor, constant: -16),
            torStatusView.bottomAnchor.constraint(equalTo: torCardView.bottomAnchor, constant: -16),

            // Buttons Stack
            buttonsStackView.topAnchor.constraint(equalTo: torCardView.bottomAnchor, constant: 24),
            buttonsStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            buttonsStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),

            createRoomButton.heightAnchor.constraint(equalToConstant: 54),
            joinRoomButton.heightAnchor.constraint(equalToConstant: 54),

            // Security Card
            securityCardView.topAnchor.constraint(equalTo: buttonsStackView.bottomAnchor, constant: 24),
            securityCardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            securityCardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),

            securityIconView.topAnchor.constraint(equalTo: securityCardView.topAnchor, constant: 16),
            securityIconView.leadingAnchor.constraint(equalTo: securityCardView.leadingAnchor, constant: 16),
            securityIconView.widthAnchor.constraint(equalToConstant: 32),
            securityIconView.heightAnchor.constraint(equalToConstant: 32),

            highSecurityLabel.centerYAnchor.constraint(equalTo: securityIconView.centerYAnchor),
            highSecurityLabel.leadingAnchor.constraint(equalTo: securityIconView.trailingAnchor, constant: 12),

            highSecurityToggle.centerYAnchor.constraint(equalTo: securityIconView.centerYAnchor),
            highSecurityToggle.trailingAnchor.constraint(equalTo: securityCardView.trailingAnchor, constant: -16),

            securityInfoLabel.topAnchor.constraint(equalTo: securityIconView.bottomAnchor, constant: 8),
            securityInfoLabel.leadingAnchor.constraint(equalTo: securityCardView.leadingAnchor, constant: 16),
            securityInfoLabel.trailingAnchor.constraint(equalTo: securityCardView.trailingAnchor, constant: -16),
            securityInfoLabel.bottomAnchor.constraint(equalTo: securityCardView.bottomAnchor, constant: -16),

            // Footer
            footerIconView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            footerIconView.trailingAnchor.constraint(equalTo: footerLabel.leadingAnchor, constant: -4),
            footerIconView.widthAnchor.constraint(equalToConstant: 14),
            footerIconView.heightAnchor.constraint(equalToConstant: 14),

            footerLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            footerLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 8),
        ])
    }

    // MARK: - Actions

    @objc private func settingsTapped() {
        let settingsVC = SettingsViewController(style: .insetGrouped)
        let navController = UINavigationController(rootViewController: settingsVC)
        settingsVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissSettings)
        )
        present(navController, animated: true)
    }

    @objc private func dismissSettings() {
        dismiss(animated: true)
    }

    @objc private func createRoomTapped() {
        showCreateRoomDialog()
    }

    private func showCreateRoomDialog() {
        let alert = UIAlertController(
            title: "Create Room",
            message: "Enter a custom room ID or leave empty for a random one",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "Custom Room ID (optional)"
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            let customRoomId = alert.textFields?.first?.text
            self?.createRoom(customRoomId: customRoomId)
        })

        present(alert, animated: true)
    }

    @objc private func joinRoomTapped() {
        showJoinRoomDialog()
    }

    @objc private func securityToggleChanged() {
        if highSecurityToggle.isOn {
            HighSecurityMode.shared.enable()
        } else {
            HighSecurityMode.shared.disable()
        }

        // Visual feedback
        UIView.animate(withDuration: 0.2) {
            self.securityIconView.tintColor = self.highSecurityToggle.isOn ? .systemOrange : .systemGray
        }
    }

    private func updateButtonStates() {
        // Buttons are only enabled when Tor is connected
        if case .connected = EphemeralTorManager.shared.state {
            createRoomButton.isEnabled = true
            joinRoomButton.isEnabled = true
            createRoomButton.alpha = 1.0
            joinRoomButton.alpha = 1.0

            // Update Tor icon to green when connected
            UIView.animate(withDuration: 0.3) {
                self.torIconView.tintColor = .systemGreen
            }
        } else {
            createRoomButton.isEnabled = false
            joinRoomButton.isEnabled = false
            createRoomButton.alpha = 0.5
            joinRoomButton.alpha = 0.5

            // Keep Tor icon purple while connecting
            torIconView.tintColor = .systemPurple
        }
    }

    // MARK: - Room Creation

    private func createRoom(customRoomId: String? = nil) {
        // Always use Tor with the .onion hidden service
        var config = RoomConfiguration.default
        HighSecurityMode.shared.applyTo(&config)

        let session = RoomSession(configuration: config)
        session.delegate = self
        currentSession = session

        do {
            try session.createRoom(customRoomId: customRoomId)
            let message = customRoomId?.isEmpty == false
                ? "Creating secure room '\(customRoomId!)'..."
                : "Creating secure room..."
            showLoadingAlert(message: message)
        } catch {
            showError("Failed to create room: \(error.localizedDescription)")
        }
    }

    // MARK: - Room Joining

    private func showJoinRoomDialog() {
        let alert = UIAlertController(
            title: "Join Room",
            message: "Enter the room ID to request joining.\nThe host will need to approve your request.",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "Room ID"
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self] _ in
            if let roomId = alert.textFields?.first?.text, !roomId.isEmpty {
                self?.joinRoomById(roomId: roomId)
            }
        })

        present(alert, animated: true)
    }

    private func joinRoomById(roomId: String) {
        #if DEBUG
        logger.info("joinRoomById called for room: \(roomId.prefix(8), privacy: .public)...")
        #endif

        // SECURITY: Verify Tor is ready before any network operation
        let torReady = EphemeralTorManager.shared.verifyTorReady()
        #if DEBUG
        logger.info("Tor ready check: \(torReady)")
        #endif

        guard torReady else {
            #if DEBUG
            logger.warning("Tor not ready - blocking join")
            #endif
            showError("Secure connection not ready. Please wait a moment and try again.")
            return
        }

        showLoadingAlert(message: "Connecting securely to room...")

        // Join without invite token - will require host approval
        joinRoom(roomId: roomId, inviteToken: nil)
    }

    private func joinRoom(roomId: String, inviteToken: String?) {
        #if DEBUG
        logger.info("joinRoom called for room: \(roomId.prefix(8), privacy: .public)..., hasToken: \(inviteToken != nil)")
        #endif

        // Always use Tor with the .onion hidden service
        var config = RoomConfiguration.default
        HighSecurityMode.shared.applyTo(&config)

        let session = RoomSession(configuration: config)
        session.delegate = self
        currentSession = session
        #if DEBUG
        logger.debug("RoomSession created with Tor configuration")
        #endif

        do {
            if let token = inviteToken {
                #if DEBUG
                logger.info("Calling session.joinRoom with invite token (pre-authorized)")
                #endif
                try session.joinRoom(roomIdString: roomId, inviteToken: token)
                updateLoadingMessage("Connecting to room...")
            } else {
                #if DEBUG
                logger.info("Calling session.joinRoom without token (will require host approval)")
                #endif
                try session.joinRoomPendingApproval(roomIdString: roomId)
                updateLoadingMessage("Waiting for host approval...")
            }
            #if DEBUG
            logger.info("joinRoom call succeeded - waiting for connection")
            #endif
        } catch {
            #if DEBUG
            logger.error("joinRoom threw error: \(error.localizedDescription, privacy: .public)")
            #endif
            dismissLoadingAlert()
            showError("Failed to join room: \(error.localizedDescription)")
        }
    }

    private func updateLoadingMessage(_ message: String) {
        if let alert = presentedViewController as? UIAlertController {
            alert.message = message
        }
    }

    // MARK: - Host Room Management

    private func showHostRoomScreen(roomId: String) {
        guard let session = currentSession else { return }

        dismissLoadingAlert { [weak self] in
            let hostVC = HostRoomViewController(session: session, roomId: roomId)
            self?.navigationController?.pushViewController(hostVC, animated: true)
        }
    }

    private func showRoomScreen() {
        guard let session = currentSession else { return }

        dismissLoadingAlert { [weak self] in
            let roomVC = RoomViewController(session: session)
            self?.navigationController?.pushViewController(roomVC, animated: true)
        }
    }

    // MARK: - Device Integrity

    private func checkDeviceIntegrity() {
        let result = DeviceIntegrityChecker.performCheck()

        if result.hasRisks {
            showIntegrityWarning(result)
        }
    }

    private func showIntegrityWarning(_ result: DeviceIntegrityChecker.IntegrityResult) {
        let message = DeviceIntegrityChecker.riskDescription(for: result)

        let alert = UIAlertController(
            title: "Security Notice",
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Continue", style: .default))

        present(alert, animated: true)
    }

    // MARK: - Alerts

    private var loadingAlert: UIAlertController?

    private func showLoadingAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        alert.view.addSubview(indicator)

        NSLayoutConstraint.activate([
            indicator.centerYAnchor.constraint(equalTo: alert.view.centerYAnchor),
            indicator.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 20)
        ])

        loadingAlert = alert
        present(alert, animated: true)
    }

    private func dismissLoadingAlert(completion: (() -> Void)? = nil) {
        if let alert = loadingAlert {
            alert.dismiss(animated: true) {
                completion?()
            }
            loadingAlert = nil
        } else {
            completion?()
        }
    }

    private func showError(_ message: String) {
        dismissLoadingAlert()

        // Don't show error if we're already showing an alert
        guard presentedViewController == nil else {
            return
        }
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - RoomSessionDelegate

extension HomeViewController: RoomSessionDelegate {

    func roomSession(_ session: RoomSession, didChangeState state: RoomState) {
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .created(let roomId):
                // Room created, show host screen
                self?.showHostRoomScreen(roomId: roomId)

            case .active:
                // Successfully joined or room became active
                if session.role == .client {
                    self?.showRoomScreen()
                }

            case .destroyed(let reason):
                self?.dismissLoadingAlert()
                self?.showError("Room ended: \(reason.rawValue)")

            default:
                break
            }
        }
    }

    func roomSession(_ session: RoomSession, didReceiveEvent event: RoomEvent) {
        DispatchQueue.main.async { [weak self] in
            switch event {
            case .joinRejected(let reason):
                self?.dismissLoadingAlert()
                self?.showError("Join rejected: \(reason)")

            case .error(let message):
                self?.showError(message)

            default:
                break
            }
        }
    }

    func roomSession(_ session: RoomSession, didReceiveMessage message: DecryptedMessage) {
        // Not used in home screen
    }

    func roomSession(_ session: RoomSession, didReceiveJoinRequest request: PendingJoinRequest) {
        // Not used in home screen
    }
}

// MARK: - TorManagerDelegate

extension HomeViewController: TorManagerDelegate {

    func torManager(_ manager: EphemeralTorManager, didChangeState state: TorConnectionState) {
        DispatchQueue.main.async { [weak self] in
            self?.updateButtonStates()
        }
    }

    func torManager(_ manager: EphemeralTorManager, didUpdateCircuitHealth health: CircuitHealth) {
        // Health updates are shown in TorStatusView
    }

    func torManager(_ manager: EphemeralTorManager, didEncounterError error: Error) {
        // Don't show alert dialogs for Tor connection errors - the TorStatusView
        // already displays the error state inline. Showing alerts on every retry
        // failure causes alert stacking and a poor user experience.
        // The user can tap "Retry" in the TorStatusView or go to Tor Settings.
    }
}
