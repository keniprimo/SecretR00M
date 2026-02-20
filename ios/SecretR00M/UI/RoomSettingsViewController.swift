import UIKit

/// Delegate for RoomSettingsViewController actions
protocol RoomSettingsViewControllerDelegate: AnyObject {
    func roomSettingsDidApproveRequest(_ request: PendingJoinRequest)
    func roomSettingsDidRejectRequest(_ request: PendingJoinRequest)
    func roomSettingsDidUpdatePendingRequests(_ requests: [PendingJoinRequest])
}

/// View controller for room settings - manage pending join requests and create invite links
final class RoomSettingsViewController: UIViewController {

    // MARK: - UI Components

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.alwaysBounceVertical = true
        return sv
    }()

    private let contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    // Invite Section
    private let inviteSectionLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Invite Link"
        label.font = .systemFont(ofSize: 20, weight: .bold)
        return label
    }()

    private let inviteDescriptionLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Create a secure invite link to share with participants."
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    private let inviteButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Create Invite Link", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = .systemIndigo
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        return button
    }()

    private let inviteActivityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        indicator.color = .white
        return indicator
    }()

    // Pending Requests Section
    private let pendingRequestsSectionLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Pending Join Requests"
        label.font = .systemFont(ofSize: 20, weight: .bold)
        return label
    }()

    private let noRequestsLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "No pending requests"
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    private let pendingTableView: UITableView = {
        let table = UITableView()
        table.translatesAutoresizingMaskIntoConstraints = false
        table.isScrollEnabled = false
        table.layer.cornerRadius = 12
        table.clipsToBounds = true
        return table
    }()

    private var tableViewHeightConstraint: NSLayoutConstraint?

    // Room Info Section
    private let roomInfoSectionLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Room Info"
        label.font = .systemFont(ofSize: 20, weight: .bold)
        return label
    }()

    private let roomIdLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    private let copyRoomIdButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Copy Room ID", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        return button
    }()

    // MARK: - Properties

    private let session: RoomSession
    private let roomId: String
    private var pendingRequests: [PendingJoinRequest]
    weak var delegate: RoomSettingsViewControllerDelegate?

    // MARK: - Initialization

    init(session: RoomSession, roomId: String, pendingRequests: [PendingJoinRequest]) {
        self.session = session
        self.roomId = roomId
        self.pendingRequests = pendingRequests
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupActions()
        updateUI()
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        title = "Room Settings"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Done",
            style: .done,
            target: self,
            action: #selector(dismissSettings)
        )

        // Add scroll view
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        // Add sections to content view
        contentView.addSubview(inviteSectionLabel)
        contentView.addSubview(inviteDescriptionLabel)
        contentView.addSubview(inviteButton)
        inviteButton.addSubview(inviteActivityIndicator)

        contentView.addSubview(pendingRequestsSectionLabel)
        contentView.addSubview(noRequestsLabel)
        contentView.addSubview(pendingTableView)

        contentView.addSubview(roomInfoSectionLabel)
        contentView.addSubview(roomIdLabel)
        contentView.addSubview(copyRoomIdButton)

        // Setup table view
        pendingTableView.delegate = self
        pendingTableView.dataSource = self
        pendingTableView.register(SettingsJoinRequestCell.self, forCellReuseIdentifier: "SettingsJoinRequestCell")

        roomIdLabel.text = "Room ID: \(roomId)"

        // Layout
        let tableHeight = CGFloat(max(pendingRequests.count, 1)) * 80

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            // Invite Section
            inviteSectionLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            inviteSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            inviteSectionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            inviteDescriptionLabel.topAnchor.constraint(equalTo: inviteSectionLabel.bottomAnchor, constant: 8),
            inviteDescriptionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            inviteDescriptionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            inviteButton.topAnchor.constraint(equalTo: inviteDescriptionLabel.bottomAnchor, constant: 16),
            inviteButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            inviteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            inviteButton.heightAnchor.constraint(equalToConstant: 50),

            inviteActivityIndicator.centerYAnchor.constraint(equalTo: inviteButton.centerYAnchor),
            inviteActivityIndicator.trailingAnchor.constraint(equalTo: inviteButton.trailingAnchor, constant: -16),

            // Pending Requests Section
            pendingRequestsSectionLabel.topAnchor.constraint(equalTo: inviteButton.bottomAnchor, constant: 32),
            pendingRequestsSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            pendingRequestsSectionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            noRequestsLabel.topAnchor.constraint(equalTo: pendingRequestsSectionLabel.bottomAnchor, constant: 16),
            noRequestsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            noRequestsLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            pendingTableView.topAnchor.constraint(equalTo: pendingRequestsSectionLabel.bottomAnchor, constant: 12),
            pendingTableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            pendingTableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // Room Info Section
            roomInfoSectionLabel.topAnchor.constraint(equalTo: pendingTableView.bottomAnchor, constant: 32),
            roomInfoSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            roomInfoSectionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            roomIdLabel.topAnchor.constraint(equalTo: roomInfoSectionLabel.bottomAnchor, constant: 12),
            roomIdLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            roomIdLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            copyRoomIdButton.topAnchor.constraint(equalTo: roomIdLabel.bottomAnchor, constant: 8),
            copyRoomIdButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            copyRoomIdButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40)
        ])

        tableViewHeightConstraint = pendingTableView.heightAnchor.constraint(equalToConstant: tableHeight)
        tableViewHeightConstraint?.isActive = true
    }

    private func setupActions() {
        inviteButton.addTarget(self, action: #selector(createInviteLink), for: .touchUpInside)
        copyRoomIdButton.addTarget(self, action: #selector(copyRoomId), for: .touchUpInside)
    }

    private func updateUI() {
        let hasRequests = !pendingRequests.isEmpty
        noRequestsLabel.isHidden = hasRequests
        pendingTableView.isHidden = !hasRequests

        // Update table height
        let tableHeight = CGFloat(max(pendingRequests.count, 1)) * 80
        tableViewHeightConstraint?.constant = tableHeight

        pendingTableView.reloadData()

        // Update section label with count
        if hasRequests {
            pendingRequestsSectionLabel.text = "Pending Join Requests (\(pendingRequests.count))"
        } else {
            pendingRequestsSectionLabel.text = "Pending Join Requests"
        }
    }

    // MARK: - Actions

    @objc private func dismissSettings() {
        dismiss(animated: true)
    }

    @objc private func createInviteLink() {
        // Show loading state
        inviteButton.isEnabled = false
        inviteActivityIndicator.startAnimating()
        inviteButton.setTitle("Creating...", for: .normal)

        let relayURL = getRelayURL()

        InviteManager.shared.createInviteToken(roomID: roomId, relayURL: relayURL) { [weak self] result in
            guard let self = self else { return }

            // Reset button state
            self.inviteButton.isEnabled = true
            self.inviteActivityIndicator.stopAnimating()
            self.inviteButton.setTitle("Create Invite Link", for: .normal)

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
        return URL(string: "http://xihrxmtwitgihtxllygrgoxixuu6ib7kzmgvosv7467tnij5svgyabid.onion")!
    }

    @objc private func copyRoomId() {
        UIPasteboard.general.string = roomId

        // Show confirmation
        let alert = UIAlertController(title: "Copied", message: "Room ID copied to clipboard", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func approveRequest(_ request: PendingJoinRequest) {
        do {
            try session.approveJoin(clientId: request.clientId)
            delegate?.roomSettingsDidApproveRequest(request)

            // Remove from local list
            if let index = pendingRequests.firstIndex(where: { $0.clientId == request.clientId }) {
                pendingRequests.remove(at: index)
                updateUI()
                delegate?.roomSettingsDidUpdatePendingRequests(pendingRequests)
            }
        } catch {
            showError("Failed to approve: \(error.localizedDescription)")
        }
    }

    private func rejectRequest(_ request: PendingJoinRequest) {
        session.rejectJoin(clientId: request.clientId)
        delegate?.roomSettingsDidRejectRequest(request)

        // Remove from local list
        if let index = pendingRequests.firstIndex(where: { $0.clientId == request.clientId }) {
            pendingRequests.remove(at: index)
            updateUI()
            delegate?.roomSettingsDidUpdatePendingRequests(pendingRequests)
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Add a new pending request (called from parent when new requests arrive)
    func addPendingRequest(_ request: PendingJoinRequest) {
        pendingRequests.append(request)
        updateUI()
    }
}

// MARK: - UITableViewDataSource

extension RoomSettingsViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return pendingRequests.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsJoinRequestCell", for: indexPath) as! SettingsJoinRequestCell
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

extension RoomSettingsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 80
    }
}

// MARK: - SettingsJoinRequestCell

final class SettingsJoinRequestCell: UITableViewCell {

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        return label
    }()

    private let fingerprintLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        return label
    }()

    private let approveButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Approve", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.backgroundColor = .systemGreen
        button.layer.cornerRadius = 8
        return button
    }()

    private let rejectButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Reject", for: .normal)
        button.setTitleColor(.systemRed, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        return button
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.isHidden = true
        return label
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
        isApproved = false
        isRejected = false
        approveButton.isHidden = false
        approveButton.isEnabled = true
        approveButton.setTitle("Approve", for: .normal)
        approveButton.backgroundColor = .systemGreen
        rejectButton.isHidden = false
        rejectButton.isEnabled = true
        statusLabel.isHidden = true
    }

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .secondarySystemGroupedBackground

        contentView.addSubview(nameLabel)
        contentView.addSubview(fingerprintLabel)
        contentView.addSubview(approveButton)
        contentView.addSubview(rejectButton)
        contentView.addSubview(statusLabel)

        approveButton.addTarget(self, action: #selector(approveTapped), for: .touchUpInside)
        rejectButton.addTarget(self, action: #selector(rejectTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: rejectButton.leadingAnchor, constant: -8),

            fingerprintLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            fingerprintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            fingerprintLabel.trailingAnchor.constraint(lessThanOrEqualTo: rejectButton.leadingAnchor, constant: -8),

            approveButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            approveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            approveButton.widthAnchor.constraint(equalToConstant: 80),
            approveButton.heightAnchor.constraint(equalToConstant: 32),

            rejectButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            rejectButton.trailingAnchor.constraint(equalTo: approveButton.leadingAnchor, constant: -8),

            statusLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
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

        isApproved = true
        approveButton.isEnabled = false
        rejectButton.isEnabled = false
        rejectButton.isHidden = true

        approveButton.setTitle("Approving...", for: .normal)
        approveButton.backgroundColor = .systemGray4

        onApprove?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showApprovedState()
        }
    }

    private func showApprovedState() {
        approveButton.isHidden = true
        statusLabel.text = "Approved"
        statusLabel.textColor = .systemGreen
        statusLabel.isHidden = false

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
        rejectButton.isHidden = true

        statusLabel.text = "Rejected"
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false

        onReject?()
    }
}
