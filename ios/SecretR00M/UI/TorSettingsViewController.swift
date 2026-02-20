import UIKit

/// Settings view controller for Tor bridge configuration
final class TorSettingsViewController: UITableViewController {

    // MARK: - Properties

    private enum Section: Int, CaseIterable {
        case status
        case bridgeType
        case retrySettings
        case actions
    }

    private enum BridgeRow: Int, CaseIterable {
        case direct      // Default - no bridges
        case obfs4       // Recommended bridge
        case snowflake   // For censored networks
        case meek        // Slowest but most resistant
    }

    private enum ActionRow: Int, CaseIterable {
        case reconnect
        case newCircuit
    }

    private var selectedBridgeType: BridgeTransportType {
        get { EphemeralTorManager.selectedBridgeType }
        set { EphemeralTorManager.selectedBridgeType = newValue }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupUI() {
        title = "Connection Settings"
        view.backgroundColor = .systemGroupedBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.register(TorStatusTableCell.self, forCellReuseIdentifier: "StatusCell")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(torStateDidChange),
            name: .torStateDidChange,
            object: nil
        )
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    @objc private func torStateDidChange() {
        tableView.reloadSections(IndexSet(integer: Section.status.rawValue), with: .none)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let sectionType = Section(rawValue: section) else { return 0 }

        switch sectionType {
        case .status:
            return 1
        case .bridgeType:
            return BridgeRow.allCases.count
        case .retrySettings:
            return 1
        case .actions:
            return ActionRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let sectionType = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch sectionType {
        case .status:
            let cell = tableView.dequeueReusableCell(withIdentifier: "StatusCell", for: indexPath) as! TorStatusTableCell
            cell.configure(with: EphemeralTorManager.shared.state)
            cell.selectionStyle = .none
            return cell

        case .bridgeType:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            configureBridgeCell(cell, for: indexPath)
            return cell

        case .retrySettings:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            configureRetryCell(cell)
            return cell

        case .actions:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            configureActionCell(cell, for: indexPath)
            return cell
        }
    }

    private func configureBridgeCell(_ cell: UITableViewCell, for indexPath: IndexPath) {
        guard let row = BridgeRow(rawValue: indexPath.row) else { return }

        let bridgeType: BridgeTransportType
        switch row {
        case .direct: bridgeType = .direct
        case .obfs4: bridgeType = .obfs4
        case .snowflake: bridgeType = .snowflake
        case .meek: bridgeType = .meek
        }

        cell.textLabel?.text = bridgeType.displayName
        cell.detailTextLabel?.text = bridgeType.description
        // For .automatic in keychain, treat as .direct for UI display
        let currentType = selectedBridgeType
        let isSelected = (currentType == bridgeType) || (currentType == .automatic && bridgeType == .direct)
        cell.accessoryType = isSelected ? .checkmark : .none
        cell.selectionStyle = .default

        // Add icon based on type
        switch bridgeType {
        case .direct:
            cell.imageView?.image = UIImage(systemName: "bolt.horizontal.circle")
        case .obfs4:
            cell.imageView?.image = UIImage(systemName: "shield.lefthalf.filled")
        case .snowflake:
            cell.imageView?.image = UIImage(systemName: "snowflake")
        case .meek:
            cell.imageView?.image = UIImage(systemName: "cloud.fill")
        case .automatic:
            cell.imageView?.image = UIImage(systemName: "wand.and.stars")
        }
        cell.imageView?.tintColor = .systemPurple
    }

    private func configureRetryCell(_ cell: UITableViewCell) {
        cell.textLabel?.text = "Auto-Retry"
        cell.selectionStyle = .none

        let toggle = UISwitch()
        toggle.isOn = EphemeralTorManager.shared.autoRetryEnabled
        toggle.addTarget(self, action: #selector(autoRetryToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        cell.imageView?.image = UIImage(systemName: "arrow.clockwise")
        cell.imageView?.tintColor = .systemBlue
    }

    private func configureActionCell(_ cell: UITableViewCell, for indexPath: IndexPath) {
        guard let row = ActionRow(rawValue: indexPath.row) else { return }

        switch row {
        case .reconnect:
            cell.textLabel?.text = "Reconnect Now"
            cell.textLabel?.textColor = .systemBlue
            cell.imageView?.image = UIImage(systemName: "arrow.triangle.2.circlepath")
            cell.imageView?.tintColor = .systemBlue

        case .newCircuit:
            cell.textLabel?.text = "Request New Circuit"
            cell.textLabel?.textColor = .systemBlue
            cell.imageView?.image = UIImage(systemName: "shuffle")
            cell.imageView?.tintColor = .systemBlue
        }

        cell.accessoryType = .none
        cell.selectionStyle = .default
    }

    @objc private func autoRetryToggled(_ sender: UISwitch) {
        EphemeralTorManager.shared.setAutoRetry(enabled: sender.isOn)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }

        switch sectionType {
        case .status:
            return "Connection Status"
        case .bridgeType:
            return "Bridge Type"
        case .retrySettings:
            return "Retry Settings"
        case .actions:
            return "Actions"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }

        switch sectionType {
        case .bridgeType:
            return "Direct connection is fastest and works on most networks. Use bridges only if you're in a censored region or direct connection fails."
        case .retrySettings:
            return "When enabled, the app will automatically retry if connection fails."
        default:
            return nil
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let sectionType = Section(rawValue: indexPath.section) else { return }

        switch sectionType {
        case .status:
            break

        case .bridgeType:
            handleBridgeSelection(at: indexPath)

        case .retrySettings:
            break

        case .actions:
            handleActionSelection(at: indexPath)
        }
    }

    private func handleBridgeSelection(at indexPath: IndexPath) {
        guard let row = BridgeRow(rawValue: indexPath.row) else { return }

        let bridgeType: BridgeTransportType
        switch row {
        case .direct: bridgeType = .direct
        case .obfs4: bridgeType = .obfs4
        case .snowflake: bridgeType = .snowflake
        case .meek: bridgeType = .meek
        }

        // Update selection
        selectedBridgeType = bridgeType
        EphemeralTorManager.shared.setBridgeType(bridgeType)

        // Reload to update checkmarks
        tableView.reloadSections(IndexSet(integer: Section.bridgeType.rawValue), with: .none)
    }

    private func handleActionSelection(at indexPath: IndexPath) {
        guard let row = ActionRow(rawValue: indexPath.row) else { return }

        switch row {
        case .reconnect:
            EphemeralTorManager.shared.forceReconnect()

        case .newCircuit:
            EphemeralTorManager.shared.requestNewCircuit { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self?.showAlert(title: "Success", message: "New circuit established")
                    case .failure(let error):
                        self?.showAlert(title: "Error", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - TorStatusTableCell

/// Custom cell that shows detailed Tor status
final class TorStatusTableCell: UITableViewCell {

    private let statusView = TorStatusView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        statusView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusView)

        NSLayoutConstraint.activate([
            statusView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            statusView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            statusView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])
    }

    func configure(with state: TorConnectionState) {
        // The TorStatusView updates itself via notifications
    }
}
