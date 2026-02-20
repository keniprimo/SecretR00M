import UIKit

/// A standard PIN pad lock screen for app authentication.
///
/// Users enter their configured PIN to unlock the app.
final class PINPadViewController: UIViewController {

    // MARK: - Properties

    private let displayContainer = UIView()
    private let titleLabel = UILabel()
    private let pinDotsStack = UIStackView()
    private let lockoutLabel = UILabel()
    private var pinDots: [UIView] = []

    /// Current entered PIN
    private var enteredPIN = ""

    /// Maximum PIN length
    private let maxPINLength = 8

    /// Callback when unlock is triggered
    var onUnlockRequested: (() -> Void)?

    /// Reference to app lock manager
    private let lockManager = AppLockManager.shared

    /// Timer for lockout countdown
    private var lockoutTimer: Timer?

    // MARK: - Theme Colors

    private static let bgColor = UIColor(red: 0.11, green: 0.11, blue: 0.18, alpha: 1.0)
    private static let numBtnColor = UIColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1.0)
    private static let accentColor = UIColor.systemBlue

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        checkLockoutStatus()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        lockoutTimer?.invalidate()
        lockoutTimer = nil
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = Self.bgColor

        setupLockoutLabel()
        setupHeader()
        setupPINDots()
        setupButtons()
    }

    private func setupHeader() {
        // Lock icon
        let lockIcon = UIImageView()
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.image = UIImage(systemName: "lock.shield.fill")
        lockIcon.tintColor = Self.accentColor
        lockIcon.contentMode = .scaleAspectFit
        view.addSubview(lockIcon)

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Enter PIN"
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            lockIcon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lockIcon.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            lockIcon.widthAnchor.constraint(equalToConstant: 60),
            lockIcon.heightAnchor.constraint(equalToConstant: 60),

            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: lockIcon.bottomAnchor, constant: 20)
        ])
    }

    private func setupPINDots() {
        pinDotsStack.translatesAutoresizingMaskIntoConstraints = false
        pinDotsStack.axis = .horizontal
        pinDotsStack.spacing = 16
        pinDotsStack.distribution = .equalSpacing
        view.addSubview(pinDotsStack)

        // Create 6 dots (standard PIN length display)
        for _ in 0..<6 {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = UIColor.white.withAlphaComponent(0.3)
            dot.layer.cornerRadius = 8
            pinDotsStack.addArrangedSubview(dot)
            pinDots.append(dot)

            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 16),
                dot.heightAnchor.constraint(equalToConstant: 16)
            ])
        }

        NSLayoutConstraint.activate([
            pinDotsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pinDotsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 40)
        ])
    }

    private func setupButtons() {
        // Standard number pad layout: 1-9, then 0 with delete
        let buttonTitles: [[String]] = [
            ["1", "2", "3"],
            ["4", "5", "6"],
            ["7", "8", "9"],
            ["", "0", "⌫"]
        ]

        let buttonStack = UIStackView()
        buttonStack.axis = .vertical
        buttonStack.spacing = 16
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(buttonStack)

        for row in buttonTitles {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 24
            rowStack.distribution = .fillEqually

            for title in row {
                let button = createButton(title: title)
                rowStack.addArrangedSubview(button)
            }

            buttonStack.addArrangedSubview(rowStack)
        }

        NSLayoutConstraint.activate([
            buttonStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            buttonStack.widthAnchor.constraint(equalToConstant: 280),
            buttonStack.heightAnchor.constraint(equalToConstant: 340)
        ])
    }

    private func createButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 32, weight: .regular)

        if title.isEmpty {
            button.isEnabled = false
            button.backgroundColor = .clear
        } else if title == "⌫" {
            button.backgroundColor = .clear
            button.setTitleColor(.white, for: .normal)
        } else {
            button.backgroundColor = Self.numBtnColor
            button.setTitleColor(.white, for: .normal)
            button.layer.cornerRadius = 40
            button.clipsToBounds = true
        }

        button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)

        return button
    }

    // MARK: - Button Actions

    @objc private func buttonTapped(_ sender: UIButton) {
        guard let title = sender.currentTitle, !title.isEmpty else { return }

        // Animate button press
        if title != "⌫" {
            UIView.animate(withDuration: 0.08, animations: {
                sender.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            }) { _ in
                UIView.animate(withDuration: 0.08) {
                    sender.transform = .identity
                }
            }
        }

        if title == "⌫" {
            handleDelete()
        } else {
            handleDigit(title)
        }
    }

    private func handleDigit(_ digit: String) {
        guard enteredPIN.count < maxPINLength else { return }

        enteredPIN += digit
        updatePINDots()

        // Auto-submit when PIN is at least 4 digits
        if enteredPIN.count >= 4 {
            validatePIN()
        }
    }

    private func handleDelete() {
        guard !enteredPIN.isEmpty else { return }
        enteredPIN.removeLast()
        updatePINDots()
    }

    private func updatePINDots() {
        for (index, dot) in pinDots.enumerated() {
            if index < enteredPIN.count {
                dot.backgroundColor = Self.accentColor
            } else {
                dot.backgroundColor = UIColor.white.withAlphaComponent(0.3)
            }
        }
    }

    // MARK: - PIN Validation

    private func validatePIN() {
        if lockManager.validatePasscode(enteredPIN) {
            triggerUnlock()
        } else if lockManager.isLockedOut {
            showLockoutMessage()
            clearPIN()
        } else {
            showWrongPIN()
        }
    }

    private func showWrongPIN() {
        // Shake animation
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [-12, 12, -8, 8, -4, 4, 0]
        pinDotsStack.layer.add(animation, forKey: "shake")

        // Red flash
        pinDots.forEach { $0.backgroundColor = .systemRed }

        // Reset after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.clearPIN()
        }
    }

    private func clearPIN() {
        enteredPIN = ""
        updatePINDots()
    }

    // MARK: - Unlock

    private func triggerUnlock() {
        // Success feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Green flash on dots
        pinDots.forEach { $0.backgroundColor = .systemGreen }

        // Check if biometric auth is required after PIN
        if lockManager.requireBiometricsAfterPasscode {
            lockManager.authenticateWithBiometrics { [weak self] success in
                if success {
                    self?.onUnlockRequested?()
                } else {
                    self?.lockManager.lock()
                    self?.showBiometricFailedMessage()
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.onUnlockRequested?()
            }
        }
    }

    private func showBiometricFailedMessage() {
        titleLabel.text = "Authentication Failed"
        titleLabel.textColor = .systemRed

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.titleLabel.text = "Enter PIN"
            self?.titleLabel.textColor = .white
            self?.clearPIN()
        }
    }

    // MARK: - Lockout Handling

    private func checkLockoutStatus() {
        if lockManager.isLockedOut {
            showLockoutMessage()
            startLockoutTimer()
        }
    }

    private func showLockoutMessage() {
        let remaining = Int(lockManager.lockoutTimeRemaining)
        let minutes = remaining / 60
        let seconds = remaining % 60

        lockoutLabel.text = String(format: "Try again in %d:%02d", minutes, seconds)
        lockoutLabel.isHidden = false

        if lockoutTimer == nil {
            startLockoutTimer()
        }
    }

    private func startLockoutTimer() {
        lockoutTimer?.invalidate()
        lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            if self.lockManager.isLockedOut {
                self.showLockoutMessage()
            } else {
                self.lockoutLabel.isHidden = true
                self.lockoutTimer?.invalidate()
                self.lockoutTimer = nil
            }
        }
    }

    private func setupLockoutLabel() {
        lockoutLabel.translatesAutoresizingMaskIntoConstraints = false
        lockoutLabel.font = .systemFont(ofSize: 14, weight: .medium)
        lockoutLabel.textColor = .systemRed
        lockoutLabel.textAlignment = .center
        lockoutLabel.isHidden = true

        view.addSubview(lockoutLabel)

        NSLayoutConstraint.activate([
            lockoutLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lockoutLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
        ])
    }
}
