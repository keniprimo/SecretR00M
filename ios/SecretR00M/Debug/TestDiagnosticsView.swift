// TestDiagnosticsView.swift
// EphemeralRooms - Internal Test Mode
//
// SECURITY: This entire file is compiled out of Release builds.
// Provides an in-memory diagnostics panel since logging is disabled.

#if DEBUG

import UIKit

/// TestDiagnosticsView displays real-time diagnostics for the test client.
/// Shows: connection state, join status, messages sent/received, epoch, errors.
final class TestDiagnosticsView: UIView {

    // MARK: - UI Components

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Test Client Diagnostics"
        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = .systemOrange
        return label
    }()

    private let connectionStateLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .label
        return label
    }()

    private let joinStatusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .label
        return label
    }()

    private let epochLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .label
        return label
    }()

    private let messageStatsLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .label
        return label
    }()

    private let lastSentLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private let lastReceivedLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .systemRed
        label.numberOfLines = 2
        label.isHidden = true
        return label
    }()

    private let eventLogTextView: UITextView = {
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        textView.textColor = .secondaryLabel
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return textView
    }()

    private let toggleButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("−", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        button.setTitleColor(.systemOrange, for: .normal)
        return button
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }()

    // MARK: - State

    private var isExpanded = true
    private var contentHeightConstraint: NSLayoutConstraint?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        setupObservers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupObservers()
    }

    deinit {
        TestModeManager.shared.clearObservers()
    }

    // MARK: - Setup

    private func setupUI() {
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        layer.cornerRadius = 8
        layer.borderWidth = 1
        layer.borderColor = UIColor.systemOrange.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 4

        // Header
        let headerStack = UIStackView(arrangedSubviews: [titleLabel, toggleButton])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .horizontal
        headerStack.distribution = .equalSpacing

        addSubview(headerStack)
        addSubview(contentStack)

        // Add content to stack
        contentStack.addArrangedSubview(connectionStateLabel)
        contentStack.addArrangedSubview(joinStatusLabel)
        contentStack.addArrangedSubview(epochLabel)
        contentStack.addArrangedSubview(messageStatsLabel)
        contentStack.addArrangedSubview(lastSentLabel)
        contentStack.addArrangedSubview(lastReceivedLabel)
        contentStack.addArrangedSubview(errorLabel)
        contentStack.addArrangedSubview(eventLogTextView)

        toggleButton.addTarget(self, action: #selector(toggleExpanded), for: .touchUpInside)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            contentStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            eventLogTextView.heightAnchor.constraint(equalToConstant: 80)
        ])

        // Initial state
        updateUI(with: TestDiagnostics())
    }

    private func setupObservers() {
        TestModeManager.shared.observeDiagnostics { [weak self] diagnostics in
            DispatchQueue.main.async {
                self?.updateUI(with: diagnostics)
            }
        }
    }

    // MARK: - UI Updates

    private func updateUI(with diagnostics: TestDiagnostics) {
        // Connection state with color
        let stateColor: UIColor
        switch diagnostics.connectionState {
        case .disconnected:
            stateColor = .systemGray
        case .connecting, .joining:
            stateColor = .systemYellow
        case .connected:
            stateColor = .systemBlue
        case .active:
            stateColor = .systemGreen
        case .disconnecting:
            stateColor = .systemOrange
        }
        connectionStateLabel.text = "State: \(diagnostics.connectionState.description)"
        connectionStateLabel.textColor = stateColor

        // Join status
        if let joined = diagnostics.joinSucceeded {
            joinStatusLabel.text = joined ? "Join: Success" : "Join: Failed"
            joinStatusLabel.textColor = joined ? .systemGreen : .systemRed
        } else {
            joinStatusLabel.text = "Join: Pending"
            joinStatusLabel.textColor = .secondaryLabel
        }

        // Epoch
        epochLabel.text = "Epoch: \(diagnostics.currentEpoch)"

        // Message stats
        messageStatsLabel.text = "Msgs: Sent=\(diagnostics.messagesSentCount) Rcvd=\(diagnostics.messagesReceivedCount)"

        // Last sent
        if let lastSent = diagnostics.lastMessageSent {
            lastSentLabel.text = "Last sent: \(lastSent.prefix(40))..."
            lastSentLabel.isHidden = false
        } else {
            lastSentLabel.isHidden = true
        }

        // Last received
        if let lastReceived = diagnostics.lastMessageReceived {
            lastReceivedLabel.text = "Last rcvd: \(lastReceived.prefix(40))..."
            lastReceivedLabel.isHidden = false
        } else {
            lastReceivedLabel.isHidden = true
        }

        // Error
        if let error = diagnostics.lastError {
            errorLabel.text = "Error: \(error)"
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }

        // Event log
        let logText = diagnostics.events.suffix(20).map { event in
            "[\(event.formattedTimestamp)] \(event.message)"
        }.joined(separator: "\n")
        eventLogTextView.text = logText

        // Auto-scroll to bottom
        if !logText.isEmpty {
            let bottom = NSRange(location: eventLogTextView.text.count - 1, length: 1)
            eventLogTextView.scrollRangeToVisible(bottom)
        }
    }

    // MARK: - Actions

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        toggleButton.setTitle(isExpanded ? "−" : "+", for: .normal)

        UIView.animate(withDuration: 0.2) {
            self.contentStack.isHidden = !self.isExpanded
            self.contentStack.alpha = self.isExpanded ? 1 : 0
            self.superview?.layoutIfNeeded()
        }
    }
}

// MARK: - TestDiagnosticsViewController

/// Full-screen diagnostics view controller for detailed inspection
final class TestDiagnosticsViewController: UIViewController {

    private let diagnosticsView = TestDiagnosticsView()

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Test Mode Diagnostics"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissVC)
        )

        view.addSubview(diagnosticsView)
        diagnosticsView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            diagnosticsView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            diagnosticsView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            diagnosticsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            diagnosticsView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    @objc private func dismissVC() {
        dismiss(animated: true)
    }
}

#endif
