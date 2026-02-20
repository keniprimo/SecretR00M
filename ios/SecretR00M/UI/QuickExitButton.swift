import UIKit

/// QuickExitButton provides an always-visible exit control for leaving conversations.
final class QuickExitButton: UIButton {

    // MARK: - Properties

    /// Callback when exit is triggered
    var onExit: (() -> Void)?

    /// Whether to require confirmation before exit
    var requiresConfirmation = false

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
        // Appearance
        backgroundColor = .systemRed
        setTitleColor(.white, for: .normal)
        setTitle("EXIT", for: .normal)
        titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)

        // Shape
        layer.cornerRadius = 20
        clipsToBounds = true

        // Size
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 60),
            heightAnchor.constraint(equalToConstant: 40)
        ])

        // Action
        addTarget(self, action: #selector(buttonPressed), for: .touchUpInside)

        // Accessibility
        accessibilityLabel = "Exit"
        accessibilityHint = "Double tap to exit the conversation"
    }

    // MARK: - Actions

    @objc private func buttonPressed() {
        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)

        if requiresConfirmation {
            // Show confirmation (handled by view controller)
            // For now, just trigger
            onExit?()
        } else {
            onExit?()
        }
    }

    // MARK: - Animation

    /// Pulse animation for attention
    func pulse() {
        UIView.animate(withDuration: 0.2, animations: {
            self.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
        }) { _ in
            UIView.animate(withDuration: 0.2) {
                self.transform = .identity
            }
        }
    }
}
