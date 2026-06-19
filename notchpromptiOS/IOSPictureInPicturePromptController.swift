//
//  IOSPictureInPicturePromptController.swift
//  Presentation Companion
//

import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct PictureInPicturePromptConfiguration: Equatable {
    var script: String
    var fontSize: CGFloat
    var opacity: Double
    var scrollOffset: CGFloat
    var isRunning: Bool
    var preferredContentSize: CGSize
}

enum PictureInPictureTapZone {
    case left
    case center
    case right
}

struct PictureInPicturePromptActions {
    var togglePlayback: () -> Void
    var toggleContentPlayback: () -> Void
    var jumpBackward: (Int) -> Void
    var jumpForward: (Int) -> Void
    var reset: () -> Void
    var openSettings: () -> Void

    static let empty = PictureInPicturePromptActions(
        togglePlayback: {},
        toggleContentPlayback: {},
        jumpBackward: { _ in },
        jumpForward: { _ in },
        reset: {},
        openSettings: {}
    )
}

@MainActor
final class IOSPictureInPicturePromptController: NSObject, ObservableObject {
    @Published private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isActive = false
    @Published var statusMessage: String?

    private let contentViewController = AVPictureInPictureVideoCallViewController()
    private let promptView = PictureInPicturePromptView()
    private var pictureInPictureController: AVPictureInPictureController?
    private weak var sourceView: UIView?
    private var latestConfiguration: PictureInPicturePromptConfiguration?

    override init() {
        super.init()
        contentViewController.preferredContentSize = CGSize(width: 420, height: 260)
        contentViewController.view.backgroundColor = .clear
        contentViewController.view.addSubview(promptView)
        promptView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            promptView.leadingAnchor.constraint(equalTo: contentViewController.view.leadingAnchor),
            promptView.trailingAnchor.constraint(equalTo: contentViewController.view.trailingAnchor),
            promptView.topAnchor.constraint(equalTo: contentViewController.view.topAnchor),
            promptView.bottomAnchor.constraint(equalTo: contentViewController.view.bottomAnchor)
        ])
    }

    func attach(to sourceView: UIView) {
        self.sourceView = sourceView
        rebuildControllerIfNeeded()
    }

    func update(configuration: PictureInPicturePromptConfiguration) {
        latestConfiguration = configuration
        contentViewController.preferredContentSize = configuration.preferredContentSize
        promptView.update(configuration)
    }

    func update(actions: PictureInPicturePromptActions) {
        promptView.update(actions)
    }

    func showUnsupportedMessage() {
        statusMessage = "Picture in Picture is not available on this device."
    }

    func start() {
        guard isSupported else {
            showUnsupportedMessage()
            return
        }

        rebuildControllerIfNeeded()

        guard let pictureInPictureController else {
            statusMessage = "Picture in Picture is not ready yet."
            return
        }

        guard !pictureInPictureController.isPictureInPictureActive else { return }

        if pictureInPictureController.isPictureInPicturePossible {
            configureAudioSession()
            pictureInPictureController.startPictureInPicture()
        } else {
            statusMessage = "Picture in Picture is not possible right now."
        }
    }

    func toggle() {
        guard isSupported else {
            showUnsupportedMessage()
            return
        }

        rebuildControllerIfNeeded()

        guard let pictureInPictureController else {
            statusMessage = "Picture in Picture is not ready yet."
            return
        }

        if pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
        } else {
            start()
        }
    }

    func stop() {
        pictureInPictureController?.stopPictureInPicture()
    }

    private func rebuildControllerIfNeeded() {
        guard pictureInPictureController == nil,
              let sourceView else { return }

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentViewController
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.delegate = self
        pictureInPictureController = controller
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            statusMessage = "Picture in Picture audio session could not be prepared."
        }
    }
}

extension IOSPictureInPicturePromptController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.statusMessage = nil
            self.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isActive = false
            self.statusMessage = error.localizedDescription
        }
    }
}

struct PictureInPictureSourceView: UIViewRepresentable {
    @ObservedObject var controller: IOSPictureInPicturePromptController
    let configuration: PictureInPicturePromptConfiguration
    let actions: PictureInPicturePromptActions

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        controller.attach(to: view)
        controller.update(configuration: configuration)
        controller.update(actions: actions)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.attach(to: uiView)
        controller.update(configuration: configuration)
        controller.update(actions: actions)
    }
}

private final class PictureInPicturePromptView: UIView {
    private let label = UILabel()
    private let statusLabel = UILabel()
    private let controlStack = UIStackView()
    private let playPauseButton = UIButton(type: .system)
    private var actions = PictureInPicturePromptActions.empty
    private var offsetConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = 14

        label.numberOfLines = 0
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        controlStack.axis = .horizontal
        controlStack.alignment = .center
        controlStack.spacing = 6
        controlStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(statusLabel)
        addSubview(controlStack)

        configureControls()

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleContentTap(_:)))
        tapRecognizer.numberOfTapsRequired = 1
        tapRecognizer.cancelsTouchesInView = false
        addGestureRecognizer(tapRecognizer)

        let doubleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleContentTap(_:)))
        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.cancelsTouchesInView = false
        addGestureRecognizer(doubleTapRecognizer)
        tapRecognizer.require(toFail: doubleTapRecognizer)

        let offsetConstraint = label.topAnchor.constraint(equalTo: topAnchor, constant: 58)
        self.offsetConstraint = offsetConstraint

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            offsetConstraint,

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlStack.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: controlStack.centerYAnchor),

            controlStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controlStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            controlStack.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(_ configuration: PictureInPicturePromptConfiguration) {
        backgroundColor = UIColor.black.withAlphaComponent(configuration.opacity)
        label.text = configuration.script
        label.font = .roundedSystemFont(ofSize: max(configuration.fontSize * 0.82, 18), weight: .regular)
        statusLabel.text = configuration.isRunning ? "PCompanion - Playing" : "PCompanion - Paused"
        playPauseButton.setImage(UIImage(systemName: configuration.isRunning ? "pause.fill" : "play.fill"), for: .normal)
        playPauseButton.accessibilityLabel = configuration.isRunning ? "Pause" : "Play"
        offsetConstraint?.constant = 58 - configuration.scrollOffset
        setNeedsLayout()
    }

    func update(_ actions: PictureInPicturePromptActions) {
        self.actions = actions
    }

    private func configureControls() {
        styleControlButton(playPauseButton, systemName: "play.fill")

        let buttons: [(UIButton, String, Selector, String)] = [
            (makeControlButton(systemName: "arrow.counterclockwise"), "Reset", #selector(resetTapped), "Reset"),
            (makeControlButton(systemName: "gobackward"), "Back", #selector(backTapped), "Back"),
            (playPauseButton, "Play", #selector(playPauseTapped), "Play"),
            (makeControlButton(systemName: "goforward"), "Forward", #selector(forwardTapped), "Forward"),
            (makeControlButton(systemName: "gearshape.fill"), "Settings", #selector(settingsTapped), "Settings")
        ]

        for (button, label, selector, identifier) in buttons {
            button.accessibilityLabel = label
            button.accessibilityIdentifier = "pip\(identifier)Button"
            button.addTarget(self, action: selector, for: .touchUpInside)
            controlStack.addArrangedSubview(button)
        }
    }

    private func makeControlButton(systemName: String) -> UIButton {
        let button = UIButton(type: .system)
        styleControlButton(button, systemName: systemName)
        return button
    }

    private func styleControlButton(_ button: UIButton, systemName: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemName)
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)

        button.configuration = configuration
        button.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 13
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    @objc private func playPauseTapped() {
        actions.togglePlayback()
    }

    @objc private func backTapped() {
        actions.jumpBackward(1)
    }

    @objc private func forwardTapped() {
        actions.jumpForward(1)
    }

    @objc private func resetTapped() {
        actions.reset()
    }

    @objc private func settingsTapped() {
        actions.openSettings()
    }

    @objc private func handleContentTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard point.y > 52 else { return }

        let tapCount = recognizer.numberOfTapsRequired
        if point.x < bounds.width / 3 {
            actions.jumpBackward(tapCount)
        } else if point.x > bounds.width * 2 / 3 {
            actions.jumpForward(tapCount)
        } else {
            actions.toggleContentPlayback()
        }
    }
}

private extension UIFont {
    static func roundedSystemFont(ofSize fontSize: CGFloat, weight: UIFont.Weight) -> UIFont {
        let descriptor = UIFont.systemFont(ofSize: fontSize, weight: weight).fontDescriptor
            .withDesign(.rounded) ?? UIFont.systemFont(ofSize: fontSize, weight: weight).fontDescriptor
        return UIFont(descriptor: descriptor, size: fontSize)
    }
}
