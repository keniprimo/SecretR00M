import UIKit

/// PrivacyOverlay provides a full-screen privacy cover for security events.
///
/// This overlay displays a blur effect with the app logo to protect content.
/// It is used when:
/// - Screen recording is detected
/// - Screenshot is detected
/// - App enters background
/// - Any security event that requires content hiding
///
/// The overlay uses a standard blur effect with the app logo.
final class PrivacyOverlay: UIView {

    // MARK: - UI Components

    /// Blur effect for privacy protection
    private lazy var blurView: UIVisualEffectView = {
        let blur = UIBlurEffect(style: .dark)
        let view = UIVisualEffectView(effect: blur)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// App icon container
    private lazy var iconContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemBlue
        view.layer.cornerRadius = 22
        view.clipsToBounds = true
        return view
    }()

    /// Lock icon inside container
    private lazy var lockIcon: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = UIImage(systemName: "lock.shield.fill")
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    /// App name label
    private lazy var appNameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "SecretR00M"
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        return label
    }()

    /// Optional message container (shown on top for security events)
    private let messageContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        view.layer.cornerRadius = 12
        view.isHidden = true
        return view
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let resumeButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Continue", for: .normal)
        button.setTitleColor(.systemBlue, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body, compatibleWith: nil)
        button.isHidden = true
        return button
    }()

    // MARK: - Properties

    var onResume: (() -> Void)?
    var onExit: (() -> Void)?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.18, alpha: 1.0)

        // Add blur overlay as base
        addSubview(blurView)

        // Add centered branding
        addSubview(iconContainer)
        iconContainer.addSubview(lockIcon)
        addSubview(appNameLabel)

        // Add message container (shown for specific security events)
        addSubview(messageContainer)
        messageContainer.addSubview(messageLabel)
        messageContainer.addSubview(resumeButton)

        NSLayoutConstraint.activate([
            // Blur fills entire view
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Icon container centered
            iconContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            iconContainer.widthAnchor.constraint(equalToConstant: 80),
            iconContainer.heightAnchor.constraint(equalToConstant: 80),

            // Lock icon centered in container
            lockIcon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            lockIcon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 40),
            lockIcon.heightAnchor.constraint(equalToConstant: 40),

            // App name below icon
            appNameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            appNameLabel.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 16),

            // Message container centered at top
            messageContainer.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            messageContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageContainer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            messageContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),

            // Message label inside container
            messageLabel.topAnchor.constraint(equalTo: messageContainer.topAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: messageContainer.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: messageContainer.trailingAnchor, constant: -16),

            // Resume button below message
            resumeButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 8),
            resumeButton.centerXAnchor.constraint(equalTo: messageContainer.centerXAnchor),
            resumeButton.bottomAnchor.constraint(equalTo: messageContainer.bottomAnchor, constant: -12)
        ])

        resumeButton.addTarget(self, action: #selector(resumeTapped), for: .touchUpInside)
    }

    // MARK: - Configuration

    /// Show overlay for screen recording detection
    /// Shows blur with a subtle notification that disappears
    func showRecordingDetected() {
        showMinimalMessage("Recording detected")
        resumeButton.isHidden = true
        isHidden = false

        // Auto-hide message after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.hideMessage()
        }
    }

    /// Show overlay for screenshot detection
    /// Shows blur with option to continue
    func showScreenshotDetected() {
        showMinimalMessage("Screenshot detected")
        resumeButton.isHidden = false
        resumeButton.setTitle("Continue", for: .normal)
        isHidden = false
    }

    /// Show overlay for app switcher / background
    /// Shows only blur UI with no message
    func showBackgrounded() {
        hideMessage()
        resumeButton.isHidden = true
        isHidden = false
    }

    /// Show overlay with recording stopped prompt
    func showRecordingStopped() {
        showMinimalMessage("Recording stopped")
        resumeButton.isHidden = false
        resumeButton.setTitle("Resume", for: .normal)
        isHidden = false
    }

    /// Show generic privacy overlay
    /// Shows blur with optional minimal message
    func showGeneric(message: String? = nil) {
        if let message = message {
            showMinimalMessage(message)
        } else {
            hideMessage()
        }
        resumeButton.isHidden = true
        isHidden = false
    }

    /// Hide the overlay
    func hide() {
        isHidden = true
    }

    // MARK: - Private Methods

    private func showMinimalMessage(_ text: String) {
        messageLabel.text = text
        messageContainer.isHidden = false
        messageContainer.alpha = 0
        UIView.animate(withDuration: 0.2) {
            self.messageContainer.alpha = 1
        }
    }

    private func hideMessage() {
        UIView.animate(withDuration: 0.2) {
            self.messageContainer.alpha = 0
        } completion: { _ in
            self.messageContainer.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func resumeTapped() {
        hideMessage()
        onResume?()
    }
}
