import UIKit

/// Main settings view controller with all privacy and security options
final class SettingsViewController: UITableViewController {

    // MARK: - Properties

    #if DEBUG
    private enum Section: Int, CaseIterable {
        case privacy
        case debug  // DEBUG only section
        case about
    }
    #else
    private enum Section: Int, CaseIterable {
        case privacy
        case about
    }
    #endif

    private enum PrivacyRow: Int, CaseIterable {
        case appLock
        case torNetwork
    }

    #if DEBUG
    private enum DebugRow: Int, CaseIterable {
        case testMode
        case viewDiagnostics
    }

    private lazy var testModeSwitch: UISwitch = {
        let toggle = UISwitch()
        toggle.isOn = TestModeManager.shared.isEnabled
        toggle.addTarget(self, action: #selector(testModeToggled(_:)), for: .valueChanged)
        return toggle
    }()
    #endif

    private enum AboutRow: Int, CaseIterable {
        case version
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        title = "Settings"
        view.backgroundColor = .systemGroupedBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let sectionType = Section(rawValue: section) else { return 0 }

        switch sectionType {
        case .privacy:
            return PrivacyRow.allCases.count
        #if DEBUG
        case .debug:
            return DebugRow.allCases.count
        #endif
        case .about:
            return AboutRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let sectionType = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryType = .disclosureIndicator

        switch sectionType {
        case .privacy:
            configurePrivacyCell(cell, for: indexPath)
        #if DEBUG
        case .debug:
            configureDebugCell(cell, for: indexPath)
        #endif
        case .about:
            configureAboutCell(cell, for: indexPath)
        }

        return cell
    }

    private func configurePrivacyCell(_ cell: UITableViewCell, for indexPath: IndexPath) {
        guard let row = PrivacyRow(rawValue: indexPath.row) else { return }

        switch row {
        case .appLock:
            cell.textLabel?.text = "App Lock"
            cell.imageView?.image = UIImage(systemName: "lock.shield.fill")
            cell.imageView?.tintColor = .systemBlue

            // Show status badge
            if AppLockManager.shared.isEnabled {
                let badge = UILabel()
                badge.text = "ON"
                badge.font = .systemFont(ofSize: 12, weight: .medium)
                badge.textColor = .white
                badge.backgroundColor = .systemGreen
                badge.layer.cornerRadius = 4
                badge.clipsToBounds = true
                badge.textAlignment = .center
                badge.frame = CGRect(x: 0, y: 0, width: 30, height: 20)
                cell.accessoryView = badge
            } else {
                cell.accessoryView = nil
                cell.accessoryType = .disclosureIndicator
            }

        case .torNetwork:
            cell.textLabel?.text = "Tor Network"
            cell.imageView?.image = UIImage(systemName: "network.badge.shield.half.filled")
            cell.imageView?.tintColor = .systemPurple
            cell.accessoryType = .disclosureIndicator

            // Show connection status badge
            let badge = UILabel()
            let state = EphemeralTorManager.shared.state
            switch state {
            case .connected:
                badge.text = "ON"
                badge.backgroundColor = .systemGreen
            case .bootstrapping, .reconnecting:
                badge.text = "..."
                badge.backgroundColor = .systemOrange
            case .disconnected:
                badge.text = "OFF"
                badge.backgroundColor = .systemGray
            case .failed:
                badge.text = "ERR"
                badge.backgroundColor = .systemRed
            }
            badge.font = .systemFont(ofSize: 12, weight: .medium)
            badge.textColor = .white
            badge.layer.cornerRadius = 4
            badge.clipsToBounds = true
            badge.textAlignment = .center
            badge.frame = CGRect(x: 0, y: 0, width: 30, height: 20)
            cell.accessoryView = badge
        }
    }

    #if DEBUG
    private func configureDebugCell(_ cell: UITableViewCell, for indexPath: IndexPath) {
        guard let row = DebugRow(rawValue: indexPath.row) else { return }

        switch row {
        case .testMode:
            cell.textLabel?.text = "Internal Test Mode"
            cell.imageView?.image = UIImage(systemName: "ant.fill")
            cell.imageView?.tintColor = .systemOrange
            cell.accessoryView = testModeSwitch
            cell.accessoryType = .none
            cell.selectionStyle = .none

        case .viewDiagnostics:
            cell.textLabel?.text = "View Diagnostics"
            cell.imageView?.image = UIImage(systemName: "chart.bar.doc.horizontal.fill")
            cell.imageView?.tintColor = .systemOrange
            cell.accessoryType = .disclosureIndicator

            // Disable if test mode is off
            let enabled = TestModeManager.shared.isEnabled
            cell.textLabel?.textColor = enabled ? .label : .tertiaryLabel
            cell.imageView?.alpha = enabled ? 1.0 : 0.4
            cell.isUserInteractionEnabled = enabled
        }
    }

    @objc private func testModeToggled(_ sender: UISwitch) {
        TestModeManager.shared.isEnabled = sender.isOn

        // Reload the debug section to update diagnostics row
        if let debugSection = Section.allCases.firstIndex(of: .debug) {
            tableView.reloadSections(IndexSet(integer: debugSection), with: .automatic)
        }
    }
    #endif

    private func configureAboutCell(_ cell: UITableViewCell, for indexPath: IndexPath) {
        guard let row = AboutRow(rawValue: indexPath.row) else { return }

        switch row {
        case .version:
            cell.textLabel?.text = "Version"
            cell.imageView?.image = UIImage(systemName: "info.circle.fill")
            cell.imageView?.tintColor = .systemGray

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

            let versionLabel = UILabel()
            versionLabel.text = "\(version) (\(build))"
            versionLabel.font = .systemFont(ofSize: 15)
            versionLabel.textColor = .secondaryLabel
            versionLabel.sizeToFit()
            cell.accessoryView = versionLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }

        switch sectionType {
        case .privacy:
            return "Privacy & Security"
        #if DEBUG
        case .debug:
            return "Developer Tools"
        #endif
        case .about:
            return "About"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }

        switch sectionType {
        case .privacy:
            return "Privacy Lock shows a lock screen when opening the app. Enter your passcode to unlock."
        #if DEBUG
        case .debug:
            return "Test Mode simulates a second client joining your room for debugging message delivery. Uses all real code paths."
        #endif
        default:
            return nil
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let sectionType = Section(rawValue: indexPath.section) else { return }

        switch sectionType {
        case .privacy:
            if let row = PrivacyRow(rawValue: indexPath.row) {
                switch row {
                case .appLock:
                    let appLockVC = AppLockSettingsViewController(style: .insetGrouped)
                    navigationController?.pushViewController(appLockVC, animated: true)

                case .torNetwork:
                    let torSettingsVC = TorSettingsViewController(style: .insetGrouped)
                    navigationController?.pushViewController(torSettingsVC, animated: true)
                }
            }

        #if DEBUG
        case .debug:
            if let row = DebugRow(rawValue: indexPath.row) {
                switch row {
                case .testMode:
                    break  // Handled by switch

                case .viewDiagnostics:
                    guard TestModeManager.shared.isEnabled else { return }
                    let diagnosticsVC = TestDiagnosticsViewController()
                    let navVC = UINavigationController(rootViewController: diagnosticsVC)
                    present(navVC, animated: true)
                }
            }
        #endif

        case .about:
            break  // Version cell is not tappable
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh to show updated status
        tableView.reloadData()
    }
}
