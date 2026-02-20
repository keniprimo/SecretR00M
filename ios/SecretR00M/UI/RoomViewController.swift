import UIKit
import AVKit

/// RoomViewController displays the chat interface for an active room.
final class RoomViewController: UIViewController {

    // MARK: - UI Components

    private let tableView: UITableView = {
        let table = UITableView()
        table.translatesAutoresizingMaskIntoConstraints = false
        table.separatorStyle = .none
        table.backgroundColor = .systemBackground
        table.keyboardDismissMode = .interactive
        return table
    }()

    private let inputContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemBackground
        return view
    }()

    private let attachButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        button.setImage(UIImage(systemName: "plus.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .systemBlue
        return button
    }()

    private let inputTextField: UITextField = {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = "Message"
        field.borderStyle = .roundedRect
        field.backgroundColor = .systemBackground
        // Disable autocorrect and suggestions for privacy
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        return field
    }()

    private let sendButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        button.tintColor = .systemBlue
        return button
    }()

    private let exitButton = QuickExitButton()

    private let privacyOverlay = PrivacyOverlay()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    /// Sending indicator shown while large media is uploading
    private let sendingIndicatorView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        view.layer.cornerRadius = 12
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.2
        view.layer.shadowRadius = 8
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.isHidden = true
        return view
    }()

    private let sendingSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        return spinner
    }()

    private let sendingLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .label
        label.text = "Sending..."
        return label
    }()

    private let sendingSizeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.text = ""
        return label
    }()

    #if DEBUG
    /// Debug capacity overlay - only shown in DEBUG builds
    private let capacityOverlay: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.numberOfLines = 0
        label.textAlignment = .left
        label.layer.cornerRadius = 4
        label.clipsToBounds = true
        label.isHidden = true // Hidden by default, toggle with triple-tap
        return label
    }()

    private var capacityUpdateTimer: Timer?

    /// Test Mode diagnostics view (floats at bottom of screen)
    private var testDiagnosticsView: TestDiagnosticsView?
    #endif

    // MARK: - Properties

    private var session: RoomSession
    private var messages: [DecryptedMessage] = []
    private var securityMonitor = SecurityMonitor()
    private var pendingRequests: [PendingJoinRequest] = []

    private var inputContainerBottomConstraint: NSLayoutConstraint?

    /// Badge for pending join requests (shown on settings button)
    private var pendingRequestsBadge: UILabel?

    // MARK: - Initialization

    init(session: RoomSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        #if DEBUG
        print("[RoomViewController] init - Session role: \(String(describing: session.role)), roomId: \(session.roomIdString ?? "nil")")
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupSession()
        setupSecurityMonitor()
        setupKeyboardObservers()

        #if DEBUG
        // If test mode is enabled and this is a host session, show diagnostics
        if TestModeManager.shared.isEnabled && session.role == .host {
            setupTestModeDiagnostics()
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Show navigation bar (it's hidden in HomeViewController)
        navigationController?.setNavigationBarHidden(false, animated: animated)

        securityMonitor.startMonitoring()

        // Check if recording is active
        if securityMonitor.isScreenBeingCaptured {
            showRecordingOverlay()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        clearVisibleContent()
        // SECURITY: Clean up any temp video files when leaving the view
        cleanupAllTempVideos()

        #if DEBUG
        // Stop capacity overlay updates
        capacityUpdateTimer?.invalidate()
        capacityUpdateTimer = nil
        #endif
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "Secure Room"

        // Navigation
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Leave",
            style: .plain,
            target: self,
            action: #selector(leaveRoom)
        )

        // Settings button for host only
        if let role = session.role {
            if role == .host {
                let settingsButton = UIBarButtonItem(
                    image: UIImage(systemName: "gearshape.fill"),
                    style: .plain,
                    target: self,
                    action: #selector(openRoomSettings)
                )
                navigationItem.rightBarButtonItem = settingsButton
            }
        }

        // Table view
        view.addSubview(tableView)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(MessageCell.self, forCellReuseIdentifier: "MessageCell")

        // Input container
        view.addSubview(inputContainerView)
        inputContainerView.addSubview(attachButton)
        inputContainerView.addSubview(inputTextField)
        inputContainerView.addSubview(sendButton)

        attachButton.addTarget(self, action: #selector(showMediaPicker), for: .touchUpInside)
        sendButton.addTarget(self, action: #selector(sendMessage), for: .touchUpInside)
        inputTextField.delegate = self

        // Quick exit button
        view.addSubview(exitButton)
        exitButton.onExit = { [weak self] in
            self?.triggerQuickExit()
        }

        // Status label
        view.addSubview(statusLabel)
        updateStatusLabel()

        // Privacy overlay (hidden initially)
        view.addSubview(privacyOverlay)
        privacyOverlay.translatesAutoresizingMaskIntoConstraints = false
        privacyOverlay.isHidden = true
        privacyOverlay.onResume = { [weak self] in
            self?.hideOverlay()
        }

        // Sending indicator
        view.addSubview(sendingIndicatorView)
        sendingIndicatorView.addSubview(sendingSpinner)
        sendingIndicatorView.addSubview(sendingLabel)
        sendingIndicatorView.addSubview(sendingSizeLabel)

        // Layout
        let bottomConstraint = inputContainerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        inputContainerBottomConstraint = bottomConstraint

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputContainerView.topAnchor),

            inputContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
            inputContainerView.heightAnchor.constraint(equalToConstant: 60),

            attachButton.leadingAnchor.constraint(equalTo: inputContainerView.leadingAnchor, constant: 12),
            attachButton.centerYAnchor.constraint(equalTo: inputContainerView.centerYAnchor),
            attachButton.widthAnchor.constraint(equalToConstant: 36),
            attachButton.heightAnchor.constraint(equalToConstant: 36),

            inputTextField.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 8),
            inputTextField.centerYAnchor.constraint(equalTo: inputContainerView.centerYAnchor),
            inputTextField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            inputTextField.heightAnchor.constraint(equalToConstant: 36),

            sendButton.trailingAnchor.constraint(equalTo: inputContainerView.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: inputContainerView.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),

            exitButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            exitButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            statusLabel.bottomAnchor.constraint(equalTo: inputContainerView.topAnchor, constant: -4),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            privacyOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            privacyOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            privacyOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            privacyOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Sending indicator - centered above input
            sendingIndicatorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sendingIndicatorView.bottomAnchor.constraint(equalTo: inputContainerView.topAnchor, constant: -16),
            sendingIndicatorView.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

            sendingSpinner.leadingAnchor.constraint(equalTo: sendingIndicatorView.leadingAnchor, constant: 16),
            sendingSpinner.centerYAnchor.constraint(equalTo: sendingIndicatorView.centerYAnchor),

            sendingLabel.leadingAnchor.constraint(equalTo: sendingSpinner.trailingAnchor, constant: 12),
            sendingLabel.topAnchor.constraint(equalTo: sendingIndicatorView.topAnchor, constant: 12),
            sendingLabel.trailingAnchor.constraint(equalTo: sendingIndicatorView.trailingAnchor, constant: -16),

            sendingSizeLabel.leadingAnchor.constraint(equalTo: sendingLabel.leadingAnchor),
            sendingSizeLabel.topAnchor.constraint(equalTo: sendingLabel.bottomAnchor, constant: 2),
            sendingSizeLabel.trailingAnchor.constraint(equalTo: sendingLabel.trailingAnchor),
            sendingSizeLabel.bottomAnchor.constraint(equalTo: sendingIndicatorView.bottomAnchor, constant: -12)
        ])

        // High security mode visibility
        exitButton.isHidden = !HighSecurityMode.shared.isEnabled

        #if DEBUG
        // Debug capacity overlay
        view.addSubview(capacityOverlay)
        NSLayoutConstraint.activate([
            capacityOverlay.topAnchor.constraint(equalTo: exitButton.bottomAnchor, constant: 8),
            capacityOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            capacityOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: 200)
        ])

        // Triple-tap gesture to toggle capacity overlay
        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(toggleCapacityOverlay))
        tripleTap.numberOfTapsRequired = 3
        view.addGestureRecognizer(tripleTap)
        #endif
    }

    #if DEBUG
    @objc private func toggleCapacityOverlay() {
        capacityOverlay.isHidden.toggle()

        if !capacityOverlay.isHidden {
            // Start updating capacity info
            updateCapacityOverlay()
            capacityUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.updateCapacityOverlay()
            }
        } else {
            capacityUpdateTimer?.invalidate()
            capacityUpdateTimer = nil
        }
    }

    private func updateCapacityOverlay() {
        let snapshot = CapacityMonitor.shared.getCurrentSnapshot()

        // Color based on level
        switch snapshot.overallLevel {
        case .healthy:
            capacityOverlay.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.8)
        case .warning:
            capacityOverlay.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.8)
        case .critical, .exceeded:
            capacityOverlay.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
        }

        capacityOverlay.text = "  " + CapacityMonitor.shared.debugSummary().replacingOccurrences(of: "\n", with: "\n  ") + "  "
    }
    #endif

    private func setupSession() {
        session.delegate = self
        messages = session.messages
    }

    private func setupSecurityMonitor() {
        securityMonitor.delegate = self
    }

    #if DEBUG
    private func setupTestModeDiagnostics() {
        let diagView = TestDiagnosticsView()
        diagView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(diagView)
        testDiagnosticsView = diagView

        // Position at the bottom above the input container
        NSLayoutConstraint.activate([
            diagView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            diagView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            diagView.bottomAnchor.constraint(equalTo: inputContainerView.topAnchor, constant: -8)
        ])

        // Bring to front
        view.bringSubviewToFront(diagView)
    }
    #endif

    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    // MARK: - Actions

    @objc private func sendMessage() {
        guard let text = inputTextField.text, !text.isEmpty else { return }

        do {
            try session.sendMessage(content: text)
            inputTextField.text = ""

            // Clear undo history for privacy
            inputTextField.undoManager?.removeAllActions()
        } catch {
            // Show error
            showError("Failed to send message")
        }
    }

    @objc private func showMediaPicker() {
        // Camera-only media capture for privacy
        // Photo library access removed to comply with App Store guidelines
        let alert = UIAlertController(
            title: "Capture Media",
            message: "For privacy, only new captures are supported.",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Take Photo", style: .default) { [weak self] _ in
            self?.presentCamera(for: .photo)
        })

        alert.addAction(UIAlertAction(title: "Record Video", style: .default) { [weak self] _ in
            self?.presentCamera(for: .video)
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad support
        if let popover = alert.popoverPresentationController {
            popover.sourceView = attachButton
            popover.sourceRect = attachButton.bounds
        }

        present(alert, animated: true)
    }

    private func presentCamera(for type: UIImagePickerController.CameraCaptureMode) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            showError("Camera not available")
            return
        }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = type
        picker.delegate = self
        picker.mediaTypes = type == .video ? ["public.movie"] : ["public.image"]
        present(picker, animated: true)
    }

    @objc private func leaveRoom() {
        let alert = UIAlertController(
            title: "Leave Room?",
            message: "All messages will be cleared.",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in
            self?.session.closeRoom()
            self?.navigationController?.popToRootViewController(animated: true)
        })

        present(alert, animated: true)
    }

    @objc private func openRoomSettings() {
        guard let role = session.role, role == .host else { return }

        let settingsVC = RoomSettingsViewController(
            session: session,
            roomId: session.roomIdString ?? "Unknown",
            pendingRequests: pendingRequests
        )
        settingsVC.delegate = self
        let navController = UINavigationController(rootViewController: settingsVC)
        navController.modalPresentationStyle = .pageSheet

        if let sheet = navController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }

        present(navController, animated: true)
    }

    /// Update the badge count on settings button
    private func updateSettingsBadge() {
        guard let role = session.role, role == .host else { return }

        let count = pendingRequests.count
        if count > 0 {
            // Add badge to navigation bar button if not already present
            if navigationItem.rightBarButtonItem?.customView == nil {
                let buttonWithBadge = createSettingsButtonWithBadge()
                navigationItem.rightBarButtonItem = UIBarButtonItem(customView: buttonWithBadge)
            }
            pendingRequestsBadge?.text = "\(count)"
            pendingRequestsBadge?.isHidden = false
        } else {
            pendingRequestsBadge?.isHidden = true
        }
    }

    private func createSettingsButtonWithBadge() -> UIView {
        let containerView = UIView()
        containerView.translatesAutoresizingMaskIntoConstraints = false

        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        button.addTarget(self, action: #selector(openRoomSettings), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        let badge = UILabel()
        badge.backgroundColor = .systemRed
        badge.textColor = .white
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        pendingRequestsBadge = badge

        containerView.addSubview(button)
        containerView.addSubview(badge)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: containerView.topAnchor),
            button.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),

            badge.topAnchor.constraint(equalTo: button.topAnchor, constant: -4),
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 4),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            badge.heightAnchor.constraint(equalToConstant: 16)
        ])

        return containerView
    }

    private func triggerQuickExit() {
        // Immediate exit and cleanup
        session.quickExit()
        clearUI()

        // Dismiss to root
        view.window?.rootViewController?.dismiss(animated: false)
    }

    // MARK: - Media Handling

    private func sendImage(_ image: UIImage) {
        // Compress the image
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            showError("Failed to process image")
            return
        }

        // Check size limit (e.g., 5MB)
        let maxSize = 5 * 1024 * 1024
        if imageData.count > maxSize {
            showError("Image too large. Maximum size is 5MB.")
            return
        }

        // Show sending indicator for images over 100KB (large for Tor)
        let showIndicator = imageData.count > 100 * 1024
        if showIndicator {
            showSendingIndicator(type: "image", sizeBytes: imageData.count)
        }

        // Send on background queue to not block UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.session.sendImage(imageData: imageData, mimeType: "image/jpeg")
                DispatchQueue.main.async {
                    if showIndicator {
                        self.hideSendingIndicator()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if showIndicator {
                        self.hideSendingIndicator()
                    }
                    self.showError("Failed to send image: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendVideo(url: URL) {
        // Get video data
        guard let videoData = try? Data(contentsOf: url) else {
            showError("Failed to read video")
            return
        }

        // Check size limit (e.g., 25MB)
        let maxSize = 25 * 1024 * 1024
        if videoData.count > maxSize {
            showError("Video too large. Maximum size is 25MB.")
            return
        }

        // Generate thumbnail
        let thumbnail = generateVideoThumbnail(from: url)
        let thumbnailData = thumbnail?.jpegData(compressionQuality: 0.5)

        // Get duration
        let asset = AVAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)

        // Calculate total size including thumbnail
        let totalSize = videoData.count + (thumbnailData?.count ?? 0)

        // Show sending indicator for videos (always show since they're larger)
        showSendingIndicator(type: "video", sizeBytes: totalSize)

        // Send on background queue to not block UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.session.sendVideo(
                    videoData: videoData,
                    mimeType: "video/mp4",
                    thumbnailData: thumbnailData,
                    duration: duration
                )
                DispatchQueue.main.async {
                    self.hideSendingIndicator()
                }
            } catch {
                DispatchQueue.main.async {
                    self.hideSendingIndicator()
                    self.showError("Failed to send video: \(error.localizedDescription)")
                }
            }
        }
    }

    private func generateVideoThumbnail(from url: URL) -> UIImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private func showFullScreenImage(_ imageData: Data) {
        guard let image = UIImage(data: imageData) else { return }

        let imageVC = FullScreenImageViewController(image: image)
        imageVC.modalPresentationStyle = .fullScreen
        present(imageVC, animated: true)
    }

    /// Track temp video URLs for secure deletion
    private var pendingTempVideoURLs: [URL] = []

    private func playVideo(_ videoData: Data) {
        // Write video to temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")

        do {
            try videoData.write(to: tempURL)
            pendingTempVideoURLs.append(tempURL)

            let player = AVPlayer(url: tempURL)
            let playerVC = AVPlayerViewController()
            playerVC.player = player

            present(playerVC, animated: true) {
                player.play()
            }

            // SECURITY: Clean up temp file after a delay when player is likely dismissed
            // Also register for background notification
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cleanupAllTempVideos()
            }

        } catch {
            showError("Failed to play video")
        }
    }

    /// Clean up all pending temp video files
    private func cleanupAllTempVideos() {
        for url in pendingTempVideoURLs {
            deleteTempFile(at: url)
        }
        pendingTempVideoURLs.removeAll()
    }

    /// Delete a temporary file
    /// Note: Uses standard FileManager deletion - temp files are automatically
    /// cleaned by the system and don't require special handling.
    private func deleteTempFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Keyboard

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            return
        }

        let keyboardHeight = keyboardFrame.height - view.safeAreaInsets.bottom
        inputContainerBottomConstraint?.constant = -keyboardHeight

        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }

        scrollToBottom()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            return
        }

        inputContainerBottomConstraint?.constant = 0

        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Privacy

    private func showRecordingOverlay() {
        clearVisibleContent()
        privacyOverlay.showRecordingDetected()
    }

    private func showScreenshotOverlay() {
        privacyOverlay.showScreenshotDetected()
    }

    private func hideOverlay() {
        privacyOverlay.hide()
        tableView.reloadData()
    }

    private func clearVisibleContent() {
        for cell in tableView.visibleCells {
            (cell as? MessageCell)?.clearContent()
        }
    }

    private func clearUI() {
        messages.removeAll()
        tableView.reloadData()
        inputTextField.text = ""
    }

    // MARK: - Status

    private func updateStatusLabel() {
        let participantCount = messages.map { $0.senderId }.uniqued().count
        statusLabel.text = "Encrypted \u{2022} \(participantCount) participant(s)"
    }

    private func scrollToBottom() {
        guard !messages.isEmpty else { return }
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
    }

    private func showError(_ message: String) {
        // Don't show error if we're already showing an alert
        guard presentedViewController == nil else {
            return
        }
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Sending Indicator

    /// Show the sending indicator with file size info
    private func showSendingIndicator(type: String, sizeBytes: Int) {
        let sizeString = formatFileSize(sizeBytes)
        sendingLabel.text = "Sending \(type)..."
        sendingSizeLabel.text = "\(sizeString) securely"
        sendingIndicatorView.isHidden = false
        sendingSpinner.startAnimating()

        // Disable attach button while sending
        attachButton.isEnabled = false
        attachButton.alpha = 0.5
    }

    /// Hide the sending indicator
    private func hideSendingIndicator() {
        sendingIndicatorView.isHidden = true
        sendingSpinner.stopAnimating()

        // Re-enable attach button
        attachButton.isEnabled = true
        attachButton.alpha = 1.0
    }

    /// Format file size for display
    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0)
        }
    }
}

// MARK: - UITableViewDataSource

extension RoomViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MessageCell", for: indexPath) as! MessageCell
        let message = messages[indexPath.row]

        let isOwnMessage = message.senderId == session.participantId
        let senderName = isOwnMessage ? "You" : "Participant \(message.senderId.uuidString.prefix(4))"
        let requiresReveal = HighSecurityMode.shared.isEnabled && HighSecurityMode.shared.settings.requirePressAndHoldToReveal

        if message.isSystemMessage {
            cell.configureAsSystemMessage(message)
        } else {
            cell.configure(
                with: message,
                senderName: senderName,
                isOwnMessage: isOwnMessage,
                requiresReveal: requiresReveal && !isOwnMessage
            )

            // Handle media taps
            cell.onMediaTap = { [weak self] tappedMessage in
                self?.handleMediaTap(tappedMessage)
            }
        }

        return cell
    }

    private func handleMediaTap(_ message: DecryptedMessage) {
        switch message.contentType {
        case .image(let data, _):
            showFullScreenImage(data)
        case .video(let data, _, _, _):
            playVideo(data)
        default:
            break
        }
    }
}

// MARK: - UITableViewDelegate

extension RoomViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return 80
    }
}

// MARK: - UITextFieldDelegate

extension RoomViewController: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendMessage()
        return true
    }
}

// MARK: - UIImagePickerControllerDelegate

extension RoomViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)

        if let videoURL = info[.mediaURL] as? URL {
            sendVideo(url: videoURL)
        } else if let image = info[.originalImage] as? UIImage {
            sendImage(image)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

// MARK: - RoomSessionDelegate

extension RoomViewController: RoomSessionDelegate {

    func roomSession(_ session: RoomSession, didChangeState state: RoomState) {
        DispatchQueue.main.async { [weak self] in
            if case .destroyed(let reason) = state {
                self?.handleRoomDestroyed(reason: reason)
            }
        }
    }

    func roomSession(_ session: RoomSession, didReceiveEvent event: RoomEvent) {
        DispatchQueue.main.async { [weak self] in
            switch event {
            case .securityEvent(let securityEvent):
                self?.handleSecurityEvent(securityEvent)
            case .error(let message):
                self?.showError(message)
            default:
                break
            }
        }
    }

    func roomSession(_ session: RoomSession, didReceiveMessage message: DecryptedMessage) {
        DispatchQueue.main.async { [weak self] in
            self?.messages.append(message)
            self?.tableView.reloadData()
            self?.scrollToBottom()
            self?.updateStatusLabel()
        }
    }

    func roomSession(_ session: RoomSession, didReceiveJoinRequest request: PendingJoinRequest) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let role = self.session.role,
                  role == .host else { return }

            self.pendingRequests.append(request)
            self.updateSettingsBadge()

            // Show brief notification
            self.showJoinRequestNotification(request)
        }
    }

    private func showJoinRequestNotification(_ request: PendingJoinRequest) {
        let name = request.request.displayName ?? "Someone"
        let banner = UIView()
        banner.backgroundColor = .systemBlue
        banner.layer.cornerRadius = 12
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.alpha = 0

        let label = UILabel()
        label.text = "\(name) wants to join"
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "person.badge.plus"))
        icon.tintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false

        banner.addSubview(icon)
        banner.addSubview(label)
        view.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.heightAnchor.constraint(equalToConstant: 36),

            icon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor)
        ])

        // Animate in
        UIView.animate(withDuration: 0.3) {
            banner.alpha = 1
        }

        // Auto-dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            UIView.animate(withDuration: 0.3, animations: {
                banner.alpha = 0
            }) { _ in
                banner.removeFromSuperview()
            }
        }

        // Tap to open settings
        let tap = UITapGestureRecognizer(target: self, action: #selector(openRoomSettings))
        banner.addGestureRecognizer(tap)
        banner.isUserInteractionEnabled = true
    }

    private func handleRoomDestroyed(reason: DestructionReason) {
        clearUI()

        // Use user-facing description from the DestructionReason
        let alert = UIAlertController(
            title: "Room Ended",
            message: reason.userFacingDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.navigationController?.popToRootViewController(animated: true)
        })
        present(alert, animated: true)
    }

    private func handleSecurityEvent(_ event: SecurityEventType) {
        switch event {
        case .screenshotDetected:
            showScreenshotOverlay()
        case .screenRecordingStarted:
            showRecordingOverlay()
        case .screenRecordingStopped:
            privacyOverlay.showRecordingStopped()
        case .backgrounded, .deviceLocked:
            // Handled by app delegate
            break
        }
    }
}

// MARK: - SecurityMonitorDelegate

extension RoomViewController: SecurityMonitorDelegate {

    func securityMonitor(_ monitor: SecurityMonitor, didDetect event: SecurityEventType) {
        session.handleSecurityEvent(event)
    }
}

// MARK: - RoomSettingsViewControllerDelegate

extension RoomViewController: RoomSettingsViewControllerDelegate {

    func roomSettingsDidApproveRequest(_ request: PendingJoinRequest) {
        // Remove from pending list
        if let index = pendingRequests.firstIndex(where: { $0.clientId == request.clientId }) {
            pendingRequests.remove(at: index)
            updateSettingsBadge()
        }
    }

    func roomSettingsDidRejectRequest(_ request: PendingJoinRequest) {
        // Remove from pending list
        if let index = pendingRequests.firstIndex(where: { $0.clientId == request.clientId }) {
            pendingRequests.remove(at: index)
            updateSettingsBadge()
        }
    }

    func roomSettingsDidUpdatePendingRequests(_ requests: [PendingJoinRequest]) {
        pendingRequests = requests
        updateSettingsBadge()
    }
}

// MARK: - Array Extension

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Full Screen Image Viewer

final class FullScreenImageViewController: UIViewController {

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.isUserInteractionEnabled = true
        return iv
    }()

    private let closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        button.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        return button
    }()

    private let image: UIImage

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        view.addSubview(imageView)
        view.addSubview(closeButton)

        imageView.image = image

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let tap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        imageView.addGestureRecognizer(tap)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}
