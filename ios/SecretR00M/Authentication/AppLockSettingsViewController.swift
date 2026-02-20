import UIKit
import LocalAuthentication

/// View controller for configuring App Lock settings.
///
/// App Lock is an optional feature that shows a PIN lock screen
/// on app launch. Users must enter their PIN to access the app.
final class AppLockSettingsViewController: UITableViewController {

    // MARK: - Properties

    private let manager = AppLockManager.shared

    private enum Section: Int, CaseIterable {
        case info
        case toggle
        case passcode
        case options
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        title = "App Lock"
        view.backgroundColor = .systemGroupedBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.register(SwitchCell.self, forCellReuseIdentifier: SwitchCell.reuseIdentifier)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let sectionType = Section(rawValue: section) else { return 0 }

        switch sectionType {
        case .info:
            return 1
        case .toggle:
            return 1
        case .passcode:
            if manager.hasPasscode {
                return 2  // Change + Remove
            } else {
                return 1  // Set only
            }
        case .options:
            return manager.isEnabled ? 1 : 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let sectionType = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch sectionType {
        case .info:
            return createInfoCell()
        case .toggle:
            return createToggleCell(for: indexPath)
        case .passcode:
            return createPasscodeCell(for: indexPath)
        case .options:
            return createOptionsCell(for: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }

        switch sectionType {
        case .info:
            return nil
        case .toggle:
            return "App Lock"
        case .passcode:
            return "Unlock PIN"
        case .options:
            return manager.isEnabled ? "Additional Security" : nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }

        switch sectionType {
        case .toggle:
            return "When enabled, the app shows a PIN lock screen on launch."
        case .passcode:
            return manager.hasPasscode
                ? "Choose a memorable numeric PIN (4-8 digits)."
                : "Set a numeric PIN to lock the app."
        default:
            return nil
        }
    }

    // MARK: - Cell Creation

    private func createInfoCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = .systemGroupedBackground

        let containerView = UIView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.backgroundColor = .secondarySystemGroupedBackground
        containerView.layer.cornerRadius = 12

        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "lock.shield.fill")
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "PIN Lock Screen"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let descLabel = UILabel()
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.text = "Require a PIN to access the app. This adds an extra layer of privacy protection."
        descLabel.font = .preferredFont(forTextStyle: .subheadline)
        descLabel.textColor = .secondaryLabel
        descLabel.numberOfLines = 0

        containerView.addSubview(iconView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(descLabel)
        cell.contentView.addSubview(containerView)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            containerView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            containerView.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            containerView.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),

            iconView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            iconView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            descLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            descLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            descLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16)
        ])

        return cell
    }

    private func createToggleCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: SwitchCell.reuseIdentifier,
            for: indexPath
        ) as? SwitchCell else {
            return UITableViewCell()
        }

        cell.configure(
            title: "Enable App Lock",
            isOn: manager.isEnabled && manager.hasPasscode,
            isEnabled: manager.hasPasscode
        ) { [weak self] isOn in
            self?.handleToggleChange(isOn)
        }

        if !manager.hasPasscode {
            cell.accessoryType = .none
            cell.detailTextLabel?.text = "Set PIN first"
        }

        return cell
    }

    private func createPasscodeCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "Cell")
        cell.accessoryType = .disclosureIndicator

        if manager.hasPasscode {
            if indexPath.row == 0 {
                cell.textLabel?.text = "Change PIN"
                cell.textLabel?.textColor = .label
                cell.imageView?.image = UIImage(systemName: "key.fill")
                cell.imageView?.tintColor = .systemBlue
            } else {
                cell.textLabel?.text = "Remove PIN"
                cell.textLabel?.textColor = .systemRed
                cell.imageView?.image = UIImage(systemName: "trash.fill")
                cell.imageView?.tintColor = .systemRed
                cell.accessoryType = .none
            }
        } else {
            cell.textLabel?.text = "Set PIN"
            cell.textLabel?.textColor = .systemBlue
            cell.imageView?.image = UIImage(systemName: "key.fill")
            cell.imageView?.tintColor = .systemBlue
        }

        return cell
    }

    private func createOptionsCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: SwitchCell.reuseIdentifier,
            for: indexPath
        ) as? SwitchCell else {
            return UITableViewCell()
        }

        let context = LAContext()
        let biometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let biometricType = context.biometryType == .faceID ? "Face ID" : "Touch ID"

        cell.configure(
            title: "Require \(biometricType) After PIN",
            isOn: manager.requireBiometricsAfterPasscode,
            isEnabled: biometricsAvailable
        ) { [weak self] isOn in
            self?.manager.requireBiometricsAfterPasscode = isOn
        }

        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let sectionType = Section(rawValue: indexPath.section) else { return }

        switch sectionType {
        case .passcode:
            if manager.hasPasscode {
                if indexPath.row == 0 {
                    showChangePINFlow()
                } else {
                    showRemovePINConfirmation()
                }
            } else {
                showSetPINFlow()
            }

        default:
            break
        }
    }

    // MARK: - Actions

    private func handleToggleChange(_ isOn: Bool) {
        if isOn && !manager.hasPasscode {
            showSetPINFlow()
            tableView.reloadData()
            return
        }

        manager.isEnabled = isOn
        tableView.reloadData()

        if isOn {
            showEnabledConfirmation()
        }
    }

    private func showSetPINFlow() {
        let alert = UIAlertController(
            title: "Set Unlock PIN",
            message: "Enter a numeric PIN (4-8 digits).",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "PIN"
            textField.keyboardType = .numberPad
            textField.isSecureTextEntry = true
        }

        alert.addTextField { textField in
            textField.placeholder = "Confirm PIN"
            textField.keyboardType = .numberPad
            textField.isSecureTextEntry = true
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self] _ in
            let pin = alert.textFields?[0].text ?? ""
            let confirm = alert.textFields?[1].text ?? ""
            self?.validateAndSetPIN(pin, confirm: confirm)
        })

        present(alert, animated: true)
    }

    private func validateAndSetPIN(_ pin: String, confirm: String) {
        guard pin.count >= 4 && pin.count <= 8 else {
            showError("PIN must be 4-8 digits")
            return
        }

        guard pin.allSatisfy({ $0.isNumber }) else {
            showError("PIN must contain only numbers")
            return
        }

        guard pin == confirm else {
            showError("PINs do not match")
            return
        }

        if manager.setPasscode(pin) {
            tableView.reloadData()
            showSuccess("PIN set successfully")
        } else {
            showError("Failed to save PIN")
        }
    }

    private func showChangePINFlow() {
        let alert = UIAlertController(
            title: "Change PIN",
            message: "Enter your current PIN, then set a new one.",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "Current PIN"
            textField.keyboardType = .numberPad
            textField.isSecureTextEntry = true
        }

        alert.addTextField { textField in
            textField.placeholder = "New PIN"
            textField.keyboardType = .numberPad
            textField.isSecureTextEntry = true
        }

        alert.addTextField { textField in
            textField.placeholder = "Confirm New PIN"
            textField.keyboardType = .numberPad
            textField.isSecureTextEntry = true
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Change", style: .default) { [weak self] _ in
            let current = alert.textFields?[0].text ?? ""
            let newPIN = alert.textFields?[1].text ?? ""
            let confirm = alert.textFields?[2].text ?? ""
            self?.validateAndChangePIN(current: current, new: newPIN, confirm: confirm)
        })

        present(alert, animated: true)
    }

    private func validateAndChangePIN(current: String, new: String, confirm: String) {
        guard manager.validatePasscode(current) else {
            showError("Current PIN is incorrect")
            manager.lock()
            return
        }
        manager.lock()

        validateAndSetPIN(new, confirm: confirm)
    }

    private func showRemovePINConfirmation() {
        let alert = UIAlertController(
            title: "Remove PIN?",
            message: "This will disable App Lock. Enter your current PIN to confirm.",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "Current PIN"
            textField.keyboardType = .numberPad
            textField.isSecureTextEntry = true
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            let pin = alert.textFields?.first?.text ?? ""
            self?.verifyAndRemovePIN(pin)
        })

        present(alert, animated: true)
    }

    private func verifyAndRemovePIN(_ pin: String) {
        guard manager.validatePasscode(pin) else {
            showError("Incorrect PIN")
            manager.lock()
            return
        }

        manager.removePasscode()
        tableView.reloadData()
        showSuccess("PIN removed")
    }

    private func showEnabledConfirmation() {
        let alert = UIAlertController(
            title: "App Lock Enabled",
            message: "Next time you open the app, you'll see a PIN lock screen.\n\nTry it now by force-quitting and reopening the app.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Got it", style: .default))
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showSuccess(_ message: String) {
        let alert = UIAlertController(title: "Success", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - SwitchCell

private class SwitchCell: UITableViewCell {

    static let reuseIdentifier = "SwitchCell"

    private let toggle = UISwitch()
    private var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCell()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCell() {
        selectionStyle = .none
        accessoryView = toggle
        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
    }

    func configure(title: String, isOn: Bool, isEnabled: Bool = true, onToggle: @escaping (Bool) -> Void) {
        textLabel?.text = title
        toggle.isOn = isOn
        toggle.isEnabled = isEnabled
        self.onToggle = onToggle

        textLabel?.textColor = isEnabled ? .label : .secondaryLabel
    }

    @objc private func toggleChanged() {
        onToggle?(toggle.isOn)
    }
}
