import UIKit

/// A view that displays Tor connection status with retry controls
final class TorStatusView: UIView {

    // MARK: - UI Components

    private let containerStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }()

    private let statusIndicator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 5
        view.backgroundColor = .systemGray
        return view
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.text = "Secure: Disconnected"
        return label
    }()

    private let progressView: UIProgressView = {
        let progress = UIProgressView(progressViewStyle: .default)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.trackTintColor = .systemGray5
        progress.progressTintColor = .systemPurple
        progress.isHidden = true
        return progress
    }()

    private let onionIcon: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .systemPurple

        // Create onion icon using SF Symbols (network.badge.shield.half.filled as placeholder)
        if let image = UIImage(systemName: "network.badge.shield.half.filled") {
            imageView.image = image
        }
        return imageView
    }()

    private let retryButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Retry", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        button.setTitleColor(.systemBlue, for: .normal)
        button.isHidden = true
        return button
    }()

    private let bridgeTypeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .tertiaryLabel
        label.text = ""
        label.isHidden = true
        return label
    }()

    // MARK: - Properties

    private var pulseAnimation: CABasicAnimation?

    /// Callback when retry button is tapped
    var onRetryTapped: (() -> Void)?

    /// Callback when settings/bridge options should be shown
    var onSettingsTapped: (() -> Void)?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        setupTorObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupTorObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupUI() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8

        addSubview(containerStack)
        addSubview(progressView)
        addSubview(bridgeTypeLabel)

        containerStack.addArrangedSubview(onionIcon)
        containerStack.addArrangedSubview(statusIndicator)
        containerStack.addArrangedSubview(statusLabel)
        containerStack.addArrangedSubview(retryButton)

        retryButton.addTarget(self, action: #selector(retryButtonTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            onionIcon.widthAnchor.constraint(equalToConstant: 20),
            onionIcon.heightAnchor.constraint(equalToConstant: 20),

            statusIndicator.widthAnchor.constraint(equalToConstant: 10),
            statusIndicator.heightAnchor.constraint(equalToConstant: 10),

            bridgeTypeLabel.topAnchor.constraint(equalTo: containerStack.bottomAnchor, constant: 2),
            bridgeTypeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bridgeTypeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            progressView.topAnchor.constraint(equalTo: bridgeTypeLabel.bottomAnchor, constant: 4),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progressView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            progressView.heightAnchor.constraint(equalToConstant: 4)
        ])

        updateUI(for: EphemeralTorManager.shared.state)
    }

    @objc private func retryButtonTapped() {
        if let callback = onRetryTapped {
            callback()
        } else {
            // Default behavior: retry with current settings
            EphemeralTorManager.shared.retryNow()
        }
    }

    private func setupTorObserver() {
        // Use NotificationCenter to allow multiple observers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(torStateDidChange(_:)),
            name: .torStateDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(torCircuitHealthDidChange(_:)),
            name: .torCircuitHealthDidChange,
            object: nil
        )
    }

    @objc private func torStateDidChange(_ notification: Notification) {
        if let state = notification.userInfo?["state"] as? TorConnectionState {
            updateUI(for: state)
        }
    }

    @objc private func torCircuitHealthDidChange(_ notification: Notification) {
        if let health = notification.userInfo?["health"] as? CircuitHealth {
            updateCircuitHealth(health)
        }
    }

    // MARK: - UI Updates

    private func updateUI(for state: TorConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let torManager = EphemeralTorManager.shared
            let bridgeType = torManager.currentBridgeType

            switch state {
            case .disconnected:
                self.statusLabel.text = "Secure: Disconnected"
                self.statusIndicator.backgroundColor = .systemGray
                self.progressView.isHidden = true
                self.retryButton.isHidden = true
                self.bridgeTypeLabel.isHidden = true
                self.stopPulseAnimation()
                self.onionIcon.tintColor = .systemGray

            case .bootstrapping(let progress):
                self.statusLabel.text = "Secure: Connecting... \(progress)%"
                self.statusIndicator.backgroundColor = .systemYellow
                self.progressView.isHidden = false
                self.progressView.setProgress(Float(progress) / 100.0, animated: true)
                self.retryButton.isHidden = true
                self.bridgeTypeLabel.text = "Using: \(bridgeType.displayName)"
                self.bridgeTypeLabel.isHidden = false
                self.startPulseAnimation()
                self.onionIcon.tintColor = .systemYellow

            case .connected:
                self.statusLabel.text = "Secure: Connected"
                self.statusIndicator.backgroundColor = .systemGreen
                self.progressView.isHidden = true
                self.retryButton.isHidden = true
                self.bridgeTypeLabel.text = "Bridge: \(bridgeType.displayName)"
                self.bridgeTypeLabel.isHidden = false
                self.stopPulseAnimation()
                self.onionIcon.tintColor = .systemGreen

            case .reconnecting(let attempt):
                let maxRetries = torManager.retryConfiguration.maxRetries
                self.statusLabel.text = "Retrying (\(attempt)/\(maxRetries))..."
                self.statusIndicator.backgroundColor = .systemOrange
                self.progressView.isHidden = true
                self.retryButton.isHidden = true
                self.bridgeTypeLabel.text = "Trying: \(bridgeType.displayName)"
                self.bridgeTypeLabel.isHidden = false
                self.startPulseAnimation()
                self.onionIcon.tintColor = .systemOrange

            case .failed(let reason):
                self.statusLabel.text = "Connection Failed"
                self.statusIndicator.backgroundColor = .systemRed
                self.progressView.isHidden = true
                self.retryButton.isHidden = false
                self.retryButton.setTitle("Retry", for: .normal)
                self.bridgeTypeLabel.text = "Tap Retry or try different settings"
                self.bridgeTypeLabel.isHidden = false
                self.stopPulseAnimation()
                self.onionIcon.tintColor = .systemRed

                // Show error briefly
                #if DEBUG
                NSLog("[TorStatus] Failed: \(reason)")
                #endif
            }
        }
    }

    private func updateCircuitHealth(_ health: CircuitHealth) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Only show circuit health when connected
            guard case .connected = EphemeralTorManager.shared.state else { return }

            switch health {
            case .healthy:
                self.statusLabel.text = "Secure: Connected"
                self.statusIndicator.backgroundColor = .systemGreen

            case .degraded:
                self.statusLabel.text = "Secure: Degraded"
                self.statusIndicator.backgroundColor = .systemYellow

            case .unhealthy:
                self.statusLabel.text = "Secure: Unhealthy"
                self.statusIndicator.backgroundColor = .systemOrange
                self.startPulseAnimation()

            case .unknown:
                break
            }
        }
    }

    // MARK: - Animations

    private func startPulseAnimation() {
        guard pulseAnimation == nil else { return }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.3
        animation.duration = 0.5
        animation.autoreverses = true
        animation.repeatCount = .infinity

        statusIndicator.layer.add(animation, forKey: "pulse")
        pulseAnimation = animation
    }

    private func stopPulseAnimation() {
        statusIndicator.layer.removeAnimation(forKey: "pulse")
        pulseAnimation = nil
        statusIndicator.layer.opacity = 1.0
    }
}

// MARK: - Compact Status Bar View

/// A more compact version for use in navigation bars
final class TorStatusBarView: UIView {

    private let statusIndicator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 4
        view.backgroundColor = .systemGray
        return view
    }()

    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .secondaryLabel
        label.text = "Secure"
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        setupObserver()
        updateUI(for: EphemeralTorManager.shared.state)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupObserver()
        updateUI(for: EphemeralTorManager.shared.state)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        addSubview(statusIndicator)
        addSubview(label)

        NSLayoutConstraint.activate([
            statusIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: 8),
            statusIndicator.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: statusIndicator.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    private func setupObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(torStateDidChange(_:)),
            name: .torStateDidChange,
            object: nil
        )
    }

    @objc private func torStateDidChange(_ notification: Notification) {
        if let state = notification.userInfo?["state"] as? TorConnectionState {
            updateUI(for: state)
        }
    }

    private func updateUI(for state: TorConnectionState) {
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .disconnected:
                self?.statusIndicator.backgroundColor = .systemGray
            case .bootstrapping:
                self?.statusIndicator.backgroundColor = .systemYellow
            case .connected:
                self?.statusIndicator.backgroundColor = .systemGreen
            case .reconnecting:
                self?.statusIndicator.backgroundColor = .systemOrange
            case .failed:
                self?.statusIndicator.backgroundColor = .systemRed
            }
        }
    }
}
