import UIKit

@MainActor
final class StreamoraRecoveryView: UIScrollView {
    private let heading = UILabel()
    private let message = UILabel()
    private let retryButton = UIButton(type: .system)

    init(background: UIColor, retry: @escaping () -> Void, showMusic: @escaping () -> Void) {
        super.init(frame: .zero)
        backgroundColor = background
        translatesAutoresizingMaskIntoConstraints = false

        heading.font = .preferredFont(forTextStyle: .title2)
        heading.textColor = .label
        heading.accessibilityTraits = .header
        message.font = .preferredFont(forTextStyle: .body)
        message.textColor = .secondaryLabel
        for label in [heading, message] {
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }

        var retryStyle = UIButton.Configuration.filled()
        retryStyle.title = "Try Again"
        retryStyle.cornerStyle = .capsule
        retryStyle.baseBackgroundColor = .systemPink
        retryButton.configuration = retryStyle
        retryButton.addAction(UIAction { _ in retry() }, for: .touchUpInside)

        let music = UIButton(type: .system)
        var musicStyle = UIButton.Configuration.plain()
        musicStyle.title = "Back to Music"
        musicStyle.baseForegroundColor = .label
        music.configuration = musicStyle
        music.addAction(UIAction { _ in showMusic() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [heading, message, retryButton, music])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let centered = stack.centerYAnchor.constraint(equalTo: frameLayoutGuide.centerYAnchor)
        centered.priority = .defaultHigh
        let preferredHeight = contentLayoutGuide.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(greaterThanOrEqualTo: contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentLayoutGuide.bottomAnchor, constant: -24),
            contentLayoutGuide.heightAnchor.constraint(greaterThanOrEqualTo: frameLayoutGuide.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -24),
            contentLayoutGuide.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            music.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            centered,
            preferredHeight,
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ failure: StreamoraLoadFailure) {
        heading.text = failure.title
        message.text = failure.detail
        retryButton.isEnabled = true
    }

    func showConnecting() {
        heading.text = "Connecting to Streamora…"
        message.text = nil
        retryButton.isEnabled = false
    }
}
