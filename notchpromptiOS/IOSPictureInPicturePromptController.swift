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
        promptView.update(configuration)
    }

    func showUnsupportedMessage() {
        statusMessage = "Picture in Picture is not available on this device."
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
        } else if pictureInPictureController.isPictureInPicturePossible {
            configureAudioSession()
            pictureInPictureController.startPictureInPicture()
        } else {
            statusMessage = "Picture in Picture is not possible right now."
        }
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

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        controller.attach(to: view)
        controller.update(configuration: configuration)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.attach(to: uiView)
        controller.update(configuration: configuration)
    }
}

private final class PictureInPicturePromptView: UIView {
    private let label = UILabel()
    private let statusLabel = UILabel()
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

        addSubview(label)
        addSubview(statusLabel)

        let offsetConstraint = label.topAnchor.constraint(equalTo: topAnchor, constant: 54)
        self.offsetConstraint = offsetConstraint

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            offsetConstraint,

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12)
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
        offsetConstraint?.constant = 54 - configuration.scrollOffset
        setNeedsLayout()
    }
}

private extension UIFont {
    static func roundedSystemFont(ofSize fontSize: CGFloat, weight: UIFont.Weight) -> UIFont {
        let descriptor = UIFont.systemFont(ofSize: fontSize, weight: weight).fontDescriptor
            .withDesign(.rounded) ?? UIFont.systemFont(ofSize: fontSize, weight: weight).fontDescriptor
        return UIFont(descriptor: descriptor, size: fontSize)
    }
}
