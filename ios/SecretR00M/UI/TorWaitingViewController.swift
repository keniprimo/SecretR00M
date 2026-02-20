import UIKit

/// View controller shown while waiting for Tor to connect before joining a room
final class TorWaitingViewController: UIViewController {

    // MARK: - Callbacks

    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?

    // MARK: - UI Components

    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 20
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.layer.shadowRadius = 12
        view.layer.shadowOpacity = 0.15
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let iconView: UIImageView = {
        let imageView = UIImageView()
        imageView.image = UIImage(systemName: "lock.shield.fill")
        imageView.tintColor = .systemBlue
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Preparing Secure Connection"
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let progressView: UIProgressView = {
        let progress = UIProgressView(progressViewStyle: .default)
        progress.progressTintColor = .systemBlue
        progress.trackTintColor = .systemGray5
        progress.layer.cornerRadius = 4
        progress.clipsToBounds = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        return progress
    }()

    private let progressLabel: UILabel = {
        let label = UILabel()
        label.text = "0%"
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let descriptionLabel: UILabel = {
        let label = UILabel()
        label.text = "This may take a moment for your privacy protection."
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Cancel", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.setTitleColor(.systemRed, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return button
    }()

    private lazy var retryButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Retry", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 12
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        button.isHidden = true
        return button
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    // MARK: - State

    private var isShowingError = false
    private var currentRetryHandler: (() -> Void)?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)

        view.addSubview(containerView)
        containerView.addSubview(iconView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(progressView)
        containerView.addSubview(progressLabel)
        containerView.addSubview(descriptionLabel)
        containerView.addSubview(cancelButton)
        containerView.addSubview(retryButton)
        containerView.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            // Container
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            containerView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            containerView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),

            // Icon
            iconView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 32),
            iconView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            // Title
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -24),

            // Progress view
            progressView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            progressView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 32),
            progressView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -32),
            progressView.heightAnchor.constraint(equalToConstant: 8),

            // Progress label
            progressLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 8),
            progressLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),

            // Activity indicator (same position as progress)
            activityIndicator.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: progressView.centerYAnchor),

            // Description
            descriptionLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 16),
            descriptionLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 24),
            descriptionLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -24),

            // Cancel button
            cancelButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 24),
            cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -24),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),

            // Retry button (same position as cancel, shown on error)
            retryButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            retryButton.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),
            retryButton.widthAnchor.constraint(equalToConstant: 120),
            retryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: - Public Methods

    func updateProgress(_ progress: Int) {
        guard !isShowingError else { return }

        let clampedProgress = max(0, min(100, progress))

        UIView.animate(withDuration: 0.3) {
            self.progressView.setProgress(Float(clampedProgress) / 100.0, animated: true)
        }
        progressLabel.text = "\(clampedProgress)%"

        // Update message based on progress
        switch clampedProgress {
        case 0..<25:
            titleLabel.text = "Establishing Secure Tunnel"
            descriptionLabel.text = "Connecting to privacy network..."
        case 25..<50:
            titleLabel.text = "Building Encrypted Path"
            descriptionLabel.text = "Creating secure route for your data..."
        case 50..<75:
            titleLabel.text = "Securing Your Connection"
            descriptionLabel.text = "Almost there..."
        case 75..<100:
            titleLabel.text = "Finalizing Connection"
            descriptionLabel.text = "Just a moment..."
        default:
            titleLabel.text = "Connection Secured"
            descriptionLabel.text = "Ready to join room."
        }
    }

    func showValidating() {
        isShowingError = false
        progressView.isHidden = true
        progressLabel.isHidden = true
        activityIndicator.startAnimating()

        titleLabel.text = "Validating Invite"
        descriptionLabel.text = "Checking if the room is available..."
        iconView.image = UIImage(systemName: "checkmark.shield.fill")
        iconView.tintColor = .systemBlue

        retryButton.isHidden = true
        cancelButton.isHidden = false
    }

    func showJoining() {
        isShowingError = false
        progressView.isHidden = true
        progressLabel.isHidden = true
        activityIndicator.startAnimating()

        titleLabel.text = "Connecting to Room"
        descriptionLabel.text = "Establishing encrypted connection..."
        iconView.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        iconView.tintColor = .systemBlue

        retryButton.isHidden = true
        cancelButton.isHidden = false
    }

    func showConnected() {
        isShowingError = false
        progressView.isHidden = true
        progressLabel.isHidden = true
        activityIndicator.startAnimating()

        titleLabel.text = "Connected"
        descriptionLabel.text = "Sending join request to host..."
        iconView.image = UIImage(systemName: "checkmark.circle.fill")
        iconView.tintColor = .systemGreen

        retryButton.isHidden = true
        cancelButton.isHidden = false
    }

    func showWaitingForApproval() {
        isShowingError = false
        progressView.isHidden = true
        progressLabel.isHidden = true
        activityIndicator.startAnimating()

        titleLabel.text = "Waiting for Host Approval"
        descriptionLabel.text = "The host will review your request to join."
        iconView.image = UIImage(systemName: "person.badge.clock.fill")
        iconView.tintColor = .systemOrange

        retryButton.isHidden = true
        cancelButton.isHidden = false
    }

    func showApproved() {
        isShowingError = false
        activityIndicator.stopAnimating()
        progressView.isHidden = true
        progressLabel.isHidden = true

        titleLabel.text = "Approved!"
        descriptionLabel.text = "Entering secure room..."
        iconView.image = UIImage(systemName: "person.badge.shield.checkmark.fill")
        iconView.tintColor = .systemGreen

        retryButton.isHidden = true
        cancelButton.isHidden = true
    }

    func showError(_ message: String, retryHandler: (() -> Void)? = nil) {
        isShowingError = true
        currentRetryHandler = retryHandler
        activityIndicator.stopAnimating()
        progressView.isHidden = true
        progressLabel.isHidden = true

        titleLabel.text = "Connection Failed"
        descriptionLabel.text = message
        iconView.image = UIImage(systemName: "exclamationmark.shield.fill")
        iconView.tintColor = .systemRed

        retryButton.isHidden = retryHandler == nil
        cancelButton.isHidden = false
    }

    func showExtendedWaitMessage() {
        guard !isShowingError else { return }

        descriptionLabel.text = """
        Taking longer than usual. This can happen on slower networks.

        Your privacy is worth the wait.
        """
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func retryTapped() {
        // Reset UI to waiting state
        isShowingError = false
        progressView.isHidden = false
        progressLabel.isHidden = false
        progressView.setProgress(0, animated: false)
        progressLabel.text = "0%"

        titleLabel.text = "Preparing Secure Connection"
        descriptionLabel.text = "This may take a moment for your privacy protection."
        iconView.image = UIImage(systemName: "lock.shield.fill")
        iconView.tintColor = .systemBlue

        retryButton.isHidden = true

        // Call retry handler
        currentRetryHandler?()
        onRetry?()
    }
}
