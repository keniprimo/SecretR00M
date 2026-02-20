import UIKit
import AVKit

/// MessageCell displays a single message with optional press-to-reveal behavior.
/// Supports text, image, and video content.
final class MessageCell: UITableViewCell {

    // MARK: - UI Components

    private let containerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
        return view
    }()

    private let senderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        return label
    }()

    private let contentLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.numberOfLines = 0
        return label
    }()

    private let mediaImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.isUserInteractionEnabled = true
        imageView.isHidden = true
        return imageView
    }()

    private let playButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        button.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.isHidden = true
        return button
    }()

    private let videoDurationLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 4
        label.clipsToBounds = true
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .tertiaryLabel
        label.text = "Hold to reveal"
        label.textAlignment = .center
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .tertiaryLabel
        return label
    }()

    // MARK: - Properties

    private var isRevealed = false
    private var revealTimer: Timer?
    private var requiresReveal = false
    private var currentMessage: DecryptedMessage?

    /// Time before auto-hiding revealed content
    var revealTimeout: TimeInterval = 3.0

    /// Callback when content is revealed
    var onReveal: (() -> Void)?

    /// Callback when media is tapped
    var onMediaTap: ((DecryptedMessage) -> Void)?

    // MARK: - Constraints

    private var mediaHeightConstraint: NSLayoutConstraint?
    private var contentLabelBottomConstraint: NSLayoutConstraint?
    private var mediaImageViewBottomConstraint: NSLayoutConstraint?

    // MARK: - Initialization

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupGestures()
    }

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(containerView)
        containerView.addSubview(senderLabel)
        containerView.addSubview(contentLabel)
        containerView.addSubview(mediaImageView)
        containerView.addSubview(playButton)
        containerView.addSubview(videoDurationLabel)
        containerView.addSubview(placeholderLabel)
        containerView.addSubview(timeLabel)

        mediaHeightConstraint = mediaImageView.heightAnchor.constraint(equalToConstant: 200)
        contentLabelBottomConstraint = contentLabel.bottomAnchor.constraint(equalTo: timeLabel.topAnchor, constant: -4)
        mediaImageViewBottomConstraint = mediaImageView.bottomAnchor.constraint(equalTo: timeLabel.topAnchor, constant: -4)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            containerView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -60),

            senderLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            senderLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            senderLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),

            contentLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 4),
            contentLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            contentLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            contentLabelBottomConstraint!,

            mediaImageView.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 4),
            mediaImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            mediaImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            mediaImageView.widthAnchor.constraint(lessThanOrEqualToConstant: 250),
            mediaHeightConstraint!,

            playButton.centerXAnchor.constraint(equalTo: mediaImageView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: mediaImageView.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 50),
            playButton.heightAnchor.constraint(equalToConstant: 50),

            videoDurationLabel.trailingAnchor.constraint(equalTo: mediaImageView.trailingAnchor, constant: -8),
            videoDurationLabel.bottomAnchor.constraint(equalTo: mediaImageView.bottomAnchor, constant: -8),
            videoDurationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            videoDurationLabel.heightAnchor.constraint(equalToConstant: 20),

            placeholderLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 4),
            placeholderLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),

            timeLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            timeLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            timeLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8)
        ])

        playButton.addTarget(self, action: #selector(mediaTapped), for: .touchUpInside)
    }

    private func setupGestures() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.3
        addGestureRecognizer(longPress)

        let mediaTap = UITapGestureRecognizer(target: self, action: #selector(mediaTapped))
        mediaImageView.addGestureRecognizer(mediaTap)
    }

    // MARK: - Configuration

    /// Configure the cell with a message
    func configure(
        with message: DecryptedMessage,
        senderName: String,
        isOwnMessage: Bool,
        requiresReveal: Bool
    ) {
        self.requiresReveal = requiresReveal
        self.currentMessage = message

        senderLabel.text = senderName
        timeLabel.text = formatTime(message.receivedAt)

        // Style based on own message vs received
        if isOwnMessage {
            containerView.backgroundColor = .systemBlue.withAlphaComponent(0.2)
        } else {
            containerView.backgroundColor = .secondarySystemBackground
        }

        // Configure based on content type
        switch message.contentType {
        case .text(let text):
            configureForText(text)
        case .image(let data, _):
            configureForImage(data)
        case .video(_, _, let thumbnail, let duration):
            configureForVideo(thumbnail: thumbnail, duration: duration)
        case .system(let text):
            configureForText(text)
        }

        // Handle reveal state
        if requiresReveal {
            hide()
        } else {
            reveal()
        }
    }

    private func configureForText(_ text: String) {
        contentLabel.text = text
        contentLabel.isHidden = false
        mediaImageView.isHidden = true
        playButton.isHidden = true
        videoDurationLabel.isHidden = true

        contentLabelBottomConstraint?.isActive = true
        mediaImageViewBottomConstraint?.isActive = false
    }

    private func configureForImage(_ imageData: Data) {
        contentLabel.isHidden = true
        mediaImageView.isHidden = false
        playButton.isHidden = true
        videoDurationLabel.isHidden = true

        contentLabelBottomConstraint?.isActive = false
        mediaImageViewBottomConstraint?.isActive = true

        if let image = UIImage(data: imageData) {
            mediaImageView.image = image
            // Adjust height based on aspect ratio
            // Guard against zero width to prevent division by zero crash
            if image.size.width > 0 {
                let aspectRatio = image.size.height / image.size.width
                let maxWidth: CGFloat = 250
                mediaHeightConstraint?.constant = min(maxWidth * aspectRatio, 300)
            } else {
                mediaHeightConstraint?.constant = 200 // Default height for invalid images
            }
        }
    }

    private func configureForVideo(thumbnail: Data?, duration: Double) {
        contentLabel.isHidden = true
        mediaImageView.isHidden = false
        playButton.isHidden = false
        videoDurationLabel.isHidden = false

        contentLabelBottomConstraint?.isActive = false
        mediaImageViewBottomConstraint?.isActive = true

        if let thumbData = thumbnail, let image = UIImage(data: thumbData), image.size.width > 0 {
            mediaImageView.image = image
            let aspectRatio = image.size.height / image.size.width
            let maxWidth: CGFloat = 250
            mediaHeightConstraint?.constant = min(maxWidth * aspectRatio, 300)
        } else {
            // Default placeholder for video without thumbnail
            mediaImageView.image = UIImage(systemName: "video.fill")
            mediaImageView.tintColor = .systemGray3
            mediaHeightConstraint?.constant = 150
        }

        // Format duration
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        videoDurationLabel.text = String(format: " %d:%02d ", minutes, seconds)
    }

    /// Configure for a system message
    func configureAsSystemMessage(_ message: DecryptedMessage) {
        requiresReveal = false
        currentMessage = message
        senderLabel.text = nil
        contentLabel.text = message.content
        contentLabel.textColor = .secondaryLabel
        contentLabel.textAlignment = .center
        containerView.backgroundColor = .clear
        timeLabel.text = formatTime(message.receivedAt)

        contentLabel.isHidden = false
        mediaImageView.isHidden = true
        playButton.isHidden = true
        videoDurationLabel.isHidden = true
        placeholderLabel.isHidden = true

        contentLabelBottomConstraint?.isActive = true
        mediaImageViewBottomConstraint?.isActive = false
    }

    // MARK: - Reveal/Hide

    private func reveal() {
        guard !isRevealed else { return }
        isRevealed = true

        switch currentMessage?.contentType {
        case .text, .system:
            contentLabel.isHidden = false
        case .image, .video:
            mediaImageView.isHidden = false
            if case .video = currentMessage?.contentType {
                playButton.isHidden = false
                videoDurationLabel.isHidden = false
            }
        case .none:
            contentLabel.isHidden = false
        }

        placeholderLabel.isHidden = true
        onReveal?()
    }

    private func hide() {
        guard requiresReveal else { return }
        isRevealed = false
        contentLabel.isHidden = true
        mediaImageView.isHidden = true
        playButton.isHidden = true
        videoDurationLabel.isHidden = true
        placeholderLabel.isHidden = false
    }

    private func scheduleHide() {
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: revealTimeout, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    // MARK: - Gesture Handling

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard requiresReveal else { return }

        switch gesture.state {
        case .began:
            reveal()
        case .ended, .cancelled:
            scheduleHide()
        default:
            break
        }
    }

    @objc private func mediaTapped() {
        guard let message = currentMessage else { return }
        onMediaTap?(message)
    }

    // MARK: - Clear Content

    /// Clear all displayed content (for security)
    func clearContent() {
        contentLabel.text = nil
        senderLabel.text = nil
        timeLabel.text = nil
        mediaImageView.image = nil
        hide()
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        revealTimer?.invalidate()
        revealTimer = nil
        isRevealed = false
        requiresReveal = false
        currentMessage = nil
        contentLabel.textColor = .label
        contentLabel.textAlignment = .natural
        contentLabel.isHidden = true
        mediaImageView.isHidden = true
        mediaImageView.image = nil
        playButton.isHidden = true
        videoDurationLabel.isHidden = true
        placeholderLabel.isHidden = false
        onMediaTap = nil
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
