import UIKit

/// HostRoomViewController manages the host's view of a room including join approvals.
final class HostRoomViewController: UIViewController {

    // MARK: - UI Components

    private let roomIdLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let copyButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Copy Room ID", for: .normal)
        return button
    }()

    private let inviteButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("📨 Create Invite Link", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = .systemIndigo
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        return button
    }()

    private let inviteActivityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        indicator.color = .white
        return indicator
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.text = "Waiting for participants..."
        return label
    }()

    private let participantCountLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    private let pendingRequestsLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .headline)
        label.text = "Pending Join Requests"
        return label
    }()

    private let pendingTableView: UITableView = {
        let table = UITableView()
        table.translatesAutoresizingMaskIntoConstraints = false
        return table
    }()

    private let openChatButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Open Chat", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.isEnabled = false
        return button
    }()

    private let closeRoomButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Close Room", for: .normal)
        button.setTitleColor(.systemRed, for: .normal)
        return button
    }()

    // MARK: - Properties

    private let session: RoomSession
    private let roomId: String
    private var pendingRequests: [PendingJoinRequest] = []
    private var participantCount = 0

    #if DEBUG
    /// Diagnostics view for test mode (shown when test mode is enabled)
    private var diagnosticsView: TestDiagnosticsView?
    #endif

    // MARK: - Initialization

    init(session: RoomSession, roomId: String) {
        self.session = session
        self.roomId = roomId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupSession()

        // Open the room for joins
        session.openRoom()

        #if DEBUG
        // If test mode is enabled, spawn the test client and show diagnostics
        if TestModeManager.shared.isEnabled {
            setupTestMode()
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Show navigation bar (it's hidden in HomeViewController)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        #if DEBUG
        // If we're being popped (not just presenting), clean up test mode
        if isMovingFromParent || isBeingDismissed {
            cleanupTestMode()
        }
        #endif
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "Host Room"
        navigationItem.hidesBackButton = true

        view.addSubview(roomIdLabel)
        view.addSubview(copyButton)
        view.addSubview(inviteButton)
        inviteButton.addSubview(inviteActivityIndicator)
        view.addSubview(statusLabel)
        view.addSubview(participantCountLabel)
        view.addSubview(pendingRequestsLabel)
        view.addSubview(pendingTableView)
        view.addSubview(openChatButton)
        view.addSubview(closeRoomButton)

        roomIdLabel.text = roomId

        pendingTableView.delegate = self
        pendingTableView.dataSource = self
        pendingTableView.register(JoinRequestCell.self, forCellReuseIdentifier: "JoinRequestCell")

        copyButton.addTarget(self, action: #selector(copyRoomId), for: .touchUpInside)
        inviteButton.addTarget(self, action: #selector(createInviteLink), for: .touchUpInside)
        openChatButton.addTarget(self, action: #selector(openChat), for: .touchUpInside)
        closeRoomButton.addTarget(self, action: #selector(closeRoom), for: .touchUpInside)

        NSLayoutConstraint.activate([
            roomIdLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            roomIdLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            roomIdLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            copyButton.topAnchor.constraint(equalTo: roomIdLabel.bottomAnchor, constant: 8),
            copyButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            inviteButton.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 16),
            inviteButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            inviteButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            inviteButton.heightAnchor.constraint(equalToConstant: 44),

            inviteActivityIndicator.centerYAnchor.constraint(equalTo: inviteButton.centerYAnchor),
            inviteActivityIndicator.trailingAnchor.constraint(equalTo: inviteButton.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: inviteButton.bottomAnchor, constant: 20),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            participantCountLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            participantCountLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            pendingRequestsLabel.topAnchor.constraint(equalTo: participantCountLabel.bottomAnchor, constant: 30),
            pendingRequestsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            pendingTableView.topAnchor.constraint(equalTo: pendingRequestsLabel.bottomAnchor, constant: 8),
            pendingTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pendingTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pendingTableView.bottomAnchor.constraint(equalTo: openChatButton.topAnchor, constant: -20),

            openChatButton.bottomAnchor.constraint(equalTo: closeRoomButton.topAnchor, constant: -16),
            openChatButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            openChatButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            openChatButton.heightAnchor.constraint(equalToConstant: 50),

            closeRoomButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            closeRoomButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        updateUI()
    }

    private func setupSession() {
        session.delegate = self
    }

    #if DEBUG
    // MARK: - Test Mode

    private func setupTestMode() {
        print("[TestMode] Setting up test mode for room: \(roomId.prefix(8))...")

        // Add diagnostics view at the top of the screen
        let diagView = TestDiagnosticsView()
        diagView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(diagView)
        diagnosticsView = diagView

        NSLayoutConstraint.activate([
            diagView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            diagView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            diagView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        ])

        // Move room ID label down to make room for diagnostics
        if let roomIdTopConstraint = roomIdLabel.constraints.first(where: {
            $0.firstAttribute == .top && $0.firstItem === roomIdLabel
        }) {
            roomIdTopConstraint.isActive = false
        }
        roomIdLabel.topAnchor.constraint(equalTo: diagView.bottomAnchor, constant: 12).isActive = true

        // Spawn test client after a brief delay to allow room to fully open
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.spawnTestClient()
        }
    }

    private func spawnTestClient() {
        // Get the same configuration the host is using
        var config = RoomConfiguration.default
        HighSecurityMode.shared.applyTo(&config)

        TestModeManager.shared.spawnTestClient(roomId: roomId, configuration: config)
    }

    private func cleanupTestMode() {
        TestModeManager.shared.destroyTestClient()
        diagnosticsView?.removeFromSuperview()
        diagnosticsView = nil
    }
    #endif

    private func updateUI() {
        participantCountLabel.text = "\(participantCount) participant(s)"
        openChatButton.isEnabled = participantCount > 0

        if participantCount > 0 {
            statusLabel.text = "Room active"
            statusLabel.textColor = .systemGreen
        }
    }

    // MARK: - Actions

    @objc private func copyRoomId() {
        UIPasteboard.general.string = roomId

        // Show confirmation
        let alert = UIAlertController(title: "Copied", message: "Room ID copied to clipboard", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func createInviteLink() {
        // Show loading state
        inviteButton.isEnabled = false
        inviteActivityIndicator.startAnimating()
        inviteButton.setTitle("Creating...", for: .normal)

        // Get relay URL - in production this would be the .onion address
        let relayURL = getRelayURL()

        InviteManager.shared.createInviteToken(roomID: roomId, relayURL: relayURL) { [weak self] result in
            guard let self = self else { return }

            // Reset button state
            self.inviteButton.isEnabled = true
            self.inviteActivityIndicator.stopAnimating()
            self.inviteButton.setTitle("📨 Create Invite Link", for: .normal)

            switch result {
            case .success(let token):
                self.showInviteShareSheet(token: token.token)

            case .failure(let error):
                self.showError("Failed to create invite: \(error.localizedDescription)")
            }
        }
    }

    private func showInviteShareSheet(token: String) {
        guard let shareContent = InviteManager.shared.generateShareContent(token: token) else {
            showError("Failed to generate invite link")
            return
        }

        // Only share the text (which already contains the URL) - avoid duplicate links
        let activityItems: [Any] = [shareContent.text]

        let activityVC = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )

        // Exclude some activity types that don't make sense for secure invites
        activityVC.excludedActivityTypes = [
            .postToFacebook,
            .postToTwitter,
            .postToWeibo,
            .addToReadingList,
            .assignToContact,
            .openInIBooks
        ]

        // iPad requires popover configuration
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = inviteButton
            popover.sourceRect = inviteButton.bounds
        }

        present(activityVC, animated: true)
    }

    private func getRelayURL() -> URL {
        // Use the .onion relay server (same as RoomConfiguration.default)
        // HTTP for REST API calls (invite endpoints)
        return URL(string: "http://xihrxmtwitgihtxllygrgoxixuu6ib7kzmgvosv7467tnij5svgyabid.onion")!
    }

    @objc private func openChat() {
        let roomVC = RoomViewController(session: session)
        navigationController?.pushViewController(roomVC, animated: true)
    }

    @objc private func closeRoom() {
        let alert = UIAlertController(
            title: "Close Room?",
            message: "This will disconnect all participants and destroy the room.",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Close", style: .destructive) { [weak self] _ in
            #if DEBUG
            // Clean up test client before closing room
            self?.cleanupTestMode()
            #endif

            self?.session.closeRoom()
            self?.navigationController?.popToRootViewController(animated: true)
        })

        present(alert, animated: true)
    }

    private func approveRequest(_ request: PendingJoinRequest) {
        do {
            try session.approveJoin(clientId: request.clientId)
        } catch {
            showError("Failed to approve: \(error.localizedDescription)")
        }
    }

    private func rejectRequest(_ request: PendingJoinRequest) {
        session.rejectJoin(clientId: request.clientId)
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
}

// MARK: - UITableViewDataSource

extension HostRoomViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return pendingRequests.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "JoinRequestCell", for: indexPath) as! JoinRequestCell
        let request = pendingRequests[indexPath.row]

        cell.configure(with: request)
        cell.onApprove = { [weak self] in
            self?.approveRequest(request)
        }
        cell.onReject = { [weak self] in
            self?.rejectRequest(request)
        }

        return cell
    }
}

// MARK: - UITableViewDelegate

extension HostRoomViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 80
    }
}

// MARK: - RoomSessionDelegate

extension HostRoomViewController: RoomSessionDelegate {

    func roomSession(_ session: RoomSession, didChangeState state: RoomState) {
        DispatchQueue.main.async { [weak self] in
            if case .destroyed = state {
                self?.navigationController?.popToRootViewController(animated: true)
            }
        }
    }

    func roomSession(_ session: RoomSession, didReceiveEvent event: RoomEvent) {
        DispatchQueue.main.async { [weak self] in
            switch event {
            case .participantJoined:
                self?.participantCount += 1
                self?.updateUI()

            case .error(let message):
                self?.showError(message)

            default:
                break
            }
        }
    }

    func roomSession(_ session: RoomSession, didReceiveMessage message: DecryptedMessage) {
        // Not displayed on this screen
    }

    func roomSession(_ session: RoomSession, didReceiveJoinRequest request: PendingJoinRequest) {
        DispatchQueue.main.async { [weak self] in
            self?.pendingRequests.append(request)
            self?.pendingTableView.reloadData()
        }
    }
}

// MARK: - JoinRequestCell

final class JoinRequestCell: UITableViewCell {

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        return label
    }()

    private let fingerprintLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        return label
    }()

    private let approveButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Approve", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemGreen
        button.layer.cornerRadius = 8
        return button
    }()

    private let rejectButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Reject", for: .normal)
        button.setTitleColor(.systemRed, for: .normal)
        return button
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .systemGreen
        label.isHidden = true
        return label
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        return indicator
    }()

    var onApprove: (() -> Void)?
    var onReject: (() -> Void)?

    private var isApproved = false
    private var isRejected = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Reset state when cell is reused
        isApproved = false
        isRejected = false
        approveButton.isHidden = false
        approveButton.isEnabled = true
        approveButton.setTitle("Approve", for: .normal)
        approveButton.backgroundColor = .systemGreen
        rejectButton.isHidden = false
        rejectButton.isEnabled = true
        statusLabel.isHidden = true
        activityIndicator.stopAnimating()
    }

    private func setupUI() {
        selectionStyle = .none

        contentView.addSubview(nameLabel)
        contentView.addSubview(fingerprintLabel)
        contentView.addSubview(approveButton)
        contentView.addSubview(rejectButton)
        contentView.addSubview(statusLabel)
        contentView.addSubview(activityIndicator)

        approveButton.addTarget(self, action: #selector(approveTapped), for: .touchUpInside)
        rejectButton.addTarget(self, action: #selector(rejectTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            fingerprintLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            fingerprintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            approveButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            approveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            approveButton.widthAnchor.constraint(equalToConstant: 80),
            approveButton.heightAnchor.constraint(equalToConstant: 32),

            rejectButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            rejectButton.trailingAnchor.constraint(equalTo: approveButton.leadingAnchor, constant: -8),

            statusLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            activityIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            activityIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])
    }

    func configure(with request: PendingJoinRequest) {
        nameLabel.text = request.request.displayName ?? "Anonymous"

        // Show public key fingerprint
        let fingerprint = request.request.clientPublicKey.prefix(8).map { String(format: "%02x", $0) }.joined()
        fingerprintLabel.text = "Key: \(fingerprint)"
    }

    @objc private func approveTapped() {
        guard !isApproved && !isRejected else { return }

        // Immediately update UI to show approval is in progress
        isApproved = true
        approveButton.isEnabled = false
        rejectButton.isEnabled = false
        rejectButton.isHidden = true

        // Show "Approving..." with activity indicator
        approveButton.setTitle("Approving...", for: .normal)
        approveButton.backgroundColor = .systemGray4

        // Call the approval handler
        onApprove?()

        // After a brief moment, show "Approved" status
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showApprovedState()
        }
    }

    private func showApprovedState() {
        approveButton.isHidden = true
        statusLabel.text = "Approved"
        statusLabel.textColor = .systemGreen
        statusLabel.isHidden = false

        // Animate the status appearance
        statusLabel.alpha = 0
        UIView.animate(withDuration: 0.2) {
            self.statusLabel.alpha = 1
        }
    }

    @objc private func rejectTapped() {
        guard !isApproved && !isRejected else { return }

        isRejected = true
        approveButton.isEnabled = false
        rejectButton.isEnabled = false
        approveButton.isHidden = true

        // Show "Rejected" status
        rejectButton.isHidden = true
        statusLabel.text = "Rejected"
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false

        onReject?()
    }
}
