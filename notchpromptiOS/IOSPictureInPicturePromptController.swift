//
//  IOSPictureInPicturePromptController.swift
//  Presentation Companion
//

import AVFoundation
import AVKit
import CoreMedia
import os
import SwiftUI
import UIKit

private let pipLogger = Logger(subsystem: "notch.presentation-companion", category: "PiP")

private func pipLog(_ message: String) {
    NSLog("Presentation Companion PiP: %@", message)
    pipLogger.notice("\(message, privacy: .public)")
}

struct PictureInPicturePromptConfiguration: Equatable {
    var script: String
    var fontSize: CGFloat
    var scrollOffset: CGFloat
    var isRunning: Bool
    var keepsSystemPlaybackActive: Bool
    var voiceLevelDb: Float
    var recognizedTranscript: String
    var spokenCharacterEnd: Int
    var isWaitingForVoiceStart: Bool
    var recognitionLanguage: String
    var preferredContentSize: CGSize
}

struct PictureInPicturePromptActions {
    var togglePlayback: () -> Void
    var setPlayback: (Bool) -> Void
    var jumpBackward: (Int) -> Void
    var jumpForward: (Int) -> Void
    var openSettings: () -> Void

    static let empty = PictureInPicturePromptActions(
        togglePlayback: {},
        setPlayback: { _ in },
        jumpBackward: { _ in },
        jumpForward: { _ in },
        openSettings: {}
    )
}

@MainActor
final class IOSPictureInPicturePromptController: NSObject, ObservableObject {
    @Published private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isActive = false
    @Published var statusMessage: String?
    var onDidStart: (() -> Void)?
    var onDidStop: (() -> Void)?
    var onRestoreUserInterfaceRequested: (() -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pictureInPictureController: AVPictureInPictureController?
    private weak var sourceView: UIView?
    private var latestConfiguration = PictureInPicturePromptConfiguration(
        script: "",
        fontSize: 30,
        scrollOffset: 0,
        isRunning: false,
        keepsSystemPlaybackActive: false,
        voiceLevelDb: -160,
        recognizedTranscript: "",
        spokenCharacterEnd: 0,
        isWaitingForVoiceStart: false,
        recognitionLanguage: "English",
        preferredContentSize: CGSize(width: 420, height: 260)
    )
    private var actions = PictureInPicturePromptActions.empty
    private var frameIndex: Int64 = 0
    private var lastPlaybackState: Bool?
    private var ignorePauseRequestUntil: Date?

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        renderFrame()
    }

    func attach(to sourceView: UIView) {
        self.sourceView = sourceView
        layoutDisplayLayer(in: sourceView)
        rebuildControllerIfNeeded()
    }

    func layoutDisplayLayer(in sourceView: UIView) {
        if displayLayer.superlayer !== sourceView.layer {
            displayLayer.removeFromSuperlayer()
            sourceView.layer.addSublayer(displayLayer)
        }
        displayLayer.frame = sourceView.bounds
    }

    func update(configuration: PictureInPicturePromptConfiguration) {
        let didChangePlaybackState = lastPlaybackState != configuration.isRunning
        latestConfiguration = configuration
        lastPlaybackState = configuration.isRunning
        renderFrame()
        if didChangePlaybackState {
            pictureInPictureController?.invalidatePlaybackState()
        }
    }

    func update(actions: PictureInPicturePromptActions) {
        self.actions = actions
    }

    func showUnsupportedMessage() {
        statusMessage = "Picture in Picture is not available on this device."
    }

    @discardableResult
    func start() -> Bool {
        pipLog("sample start requested active=\(pictureInPictureController?.isPictureInPictureActive == true) possible=\(pictureInPictureController?.isPictureInPicturePossible == true)")
        guard isSupported else {
            showUnsupportedMessage()
            return false
        }

        rebuildControllerIfNeeded()
        renderFrame()

        guard let pictureInPictureController else {
            statusMessage = "Picture in Picture is not ready yet."
            return false
        }

        guard !pictureInPictureController.isPictureInPictureActive else { return true }

        configureAudioSession()

        if pictureInPictureController.isPictureInPicturePossible {
            pipLog("sample startPictureInPicture")
            pictureInPictureController.startPictureInPicture()
            return true
        } else {
            statusMessage = nil
            pipLog("sample start rejected: PiP not possible")
            return false
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
        pipLog("sample stop requested")
        pictureInPictureController?.stopPictureInPicture()
    }

    func stopAndRestoreUserInterface() {
        pipLog("sample stopAndRestore requested")
        pictureInPictureController?.stopPictureInPicture()
    }

    private func rebuildControllerIfNeeded() {
        guard pictureInPictureController == nil else { return }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.requiresLinearPlayback = false
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

    private func renderFrame() {
        let pointSize = CGSize(
            width: max(latestConfiguration.preferredContentSize.width, 240),
            height: max(latestConfiguration.preferredContentSize.height, 140)
        )
        let scale = max(UIScreen.main.scale, 2)
        let pixelWidth = max(Int(pointSize.width * scale), 1)
        let pixelHeight = max(Int(pointSize.height * scale), 1)

        guard let pixelBuffer = makePixelBuffer(width: pixelWidth, height: pixelHeight) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }

        context.translateBy(x: CGFloat(pixelWidth), y: CGFloat(pixelHeight))
        context.rotate(by: .pi)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: pointSize.width, y: 0)
        context.scaleBy(x: -1, y: 1)
        drawPrompt(in: context, size: pointSize)
        enqueue(pixelBuffer: pixelBuffer)
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func drawPrompt(in context: CGContext, size: CGSize) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let bounds = CGRect(origin: .zero, size: size)
        context.clear(bounds)
        UIColor.black.setFill()
        UIRectFill(bounds)

        let topBarHeight: CGFloat = 48
        UIColor(white: 1, alpha: 0.12).setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: size.width, height: topBarHeight))

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let status = latestConfiguration.isRunning ? "Playing" : "Paused"
        NSString(string: "Presentation Companion - \(status)").draw(
            in: CGRect(x: 14, y: 13, width: size.width * 0.44, height: 22),
            withAttributes: titleAttributes
        )

        voiceStatusText().draw(
            in: CGRect(x: size.width * 0.44, y: 8, width: size.width * 0.52, height: 18)
        )

        languageStatusText().draw(
            in: CGRect(x: size.width * 0.44, y: 25, width: size.width * 0.52, height: 17)
        )

        let bottomStatusHeight: CGFloat = 22
        let promptRect = CGRect(
            x: 16,
            y: topBarHeight + 8,
            width: size.width - 32,
            height: size.height - topBarHeight - 14 - bottomStatusHeight
        )
        context.saveGState()
        context.clip(to: promptRect)
        if latestConfiguration.isWaitingForVoiceStart {
            drawVoiceStartTip(in: promptRect)
        }
        let promptAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.roundedSystemFont(ofSize: max(latestConfiguration.fontSize * 0.78, 17), weight: .regular),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle(lineSpacing: 5)
        ]
        attributedPromptString(attributes: promptAttributes).draw(
            in: CGRect(
                x: promptRect.minX,
                y: promptRect.minY + (latestConfiguration.isWaitingForVoiceStart ? 42 : 0) - latestConfiguration.scrollOffset,
                width: promptRect.width,
                height: 20_000
            )
        )
        context.restoreGState()

        if !latestConfiguration.recognizedTranscript.isEmpty {
            drawRecognizedTranscript(in: CGRect(
                x: 16,
                y: size.height - bottomStatusHeight - 2,
                width: size.width - 32,
                height: bottomStatusHeight
            ))
        }
    }

    private func voiceStatusText() -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: "Voice Detected: ",
            attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.72)
            ]
        )
        let levelText: String
        if latestConfiguration.voiceLevelDb <= -150 {
            levelText = "-- dB"
        } else {
            levelText = "\(Int(latestConfiguration.voiceLevelDb.rounded())) dB"
        }
        base.append(
            NSAttributedString(
                string: levelText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: UIColor.systemRed
                ]
            )
        )
        return base
    }

    private func languageStatusText() -> NSAttributedString {
        NSAttributedString(
            string: latestConfiguration.recognitionLanguage,
            attributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: UIColor.systemBlue
            ]
        )
    }

    private func attributedPromptString(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: latestConfiguration.script, attributes: attributes)
        let length = (latestConfiguration.script as NSString).length
        let spokenEnd = min(max(latestConfiguration.spokenCharacterEnd, 0), length)
        if spokenEnd > 0 {
            attributed.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: NSRange(location: 0, length: spokenEnd))
        }
        return attributed
    }

    private func drawVoiceStartTip(in promptRect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.88)
        ]
        NSString(string: "Start talking to move prompt forward").draw(
            in: CGRect(
                x: promptRect.minX,
                y: promptRect.minY + 8,
                width: promptRect.width,
                height: 28
            ),
            withAttributes: attributes
        )
    }

    private func drawRecognizedTranscript(in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(
            string: latestConfiguration.recognizedTranscript,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.systemBlue,
                .paragraphStyle: paragraph
            ]
        ).draw(in: rect)
    }

    private func paragraphStyle(lineSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.alignment = .left
        return style
    }

    private func enqueue(pixelBuffer: CVPixelBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
              let formatDescription else { return }

        let timestamp = CMTime(value: frameIndex, timescale: 30)
        frameIndex += 1

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
              let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }
}

extension IOSPictureInPicturePromptController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            pipLog("sample delegate willStart")
            self.statusMessage = nil
            self.isActive = true
            self.onDidStart?()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            pipLog("sample delegate didStop")
            self.isActive = false
            self.onDidStop?()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            pipLog("sample delegate failedToStart: \(error.localizedDescription)")
            self.isActive = false
            self.statusMessage = error.localizedDescription
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            pipLog("sample delegate restoreUI -> settings")
            self.onRestoreUserInterfaceRequested?()
            completionHandler(true)
        }
    }
}

extension IOSPictureInPicturePromptController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        Task { @MainActor in
            pipLog("sample PiP setPlaying=\(playing)")
            if !playing,
               let ignorePauseRequestUntil,
               Date() < ignorePauseRequestUntil {
                pipLog("sample PiP ignored pause immediately after skip")
                self.pictureInPictureController?.invalidatePlaybackState()
                self.renderFrame()
                return
            }

            ignorePauseRequestUntil = nil
            self.actions.setPlayback(playing)
            self.pictureInPictureController?.invalidatePlaybackState()
            self.renderFrame()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 24 * 60 * 60, preferredTimescale: 600)
        )
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        MainActor.assumeIsolated {
            !latestConfiguration.isRunning && !latestConfiguration.keepsSystemPlaybackActive
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Task { @MainActor in
            pipLog("sample PiP render size \(newRenderSize.width)x\(newRenderSize.height)")
            self.renderFrame()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            let seconds = skipInterval.seconds
            pipLog("sample PiP skip seconds=\(seconds)")
            let shouldResumeAfterSkip = self.latestConfiguration.isRunning
            if seconds < 0 {
                self.actions.jumpBackward(1)
            } else {
                self.actions.jumpForward(1)
            }
            if shouldResumeAfterSkip {
                self.ignorePauseRequestUntil = Date().addingTimeInterval(0.75)
                self.actions.setPlayback(true)
            }
            self.pictureInPictureController?.invalidatePlaybackState()
            self.renderFrame()
            completionHandler()
        }
    }
}

struct PictureInPictureSourceView: UIViewRepresentable {
    @ObservedObject var controller: IOSPictureInPicturePromptController
    let configuration: PictureInPicturePromptConfiguration
    let actions: PictureInPicturePromptActions

    func makeUIView(context: Context) -> SourceUIView {
        let view = SourceUIView()
        view.backgroundColor = .black
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.controller = controller
        controller.attach(to: view)
        controller.update(configuration: configuration)
        controller.update(actions: actions)
        return view
    }

    func updateUIView(_ uiView: SourceUIView, context: Context) {
        uiView.controller = controller
        controller.attach(to: uiView)
        controller.update(configuration: configuration)
        controller.update(actions: actions)
    }

    final class SourceUIView: UIView {
        weak var controller: IOSPictureInPicturePromptController?

        override func layoutSubviews() {
            super.layoutSubviews()
            controller?.layoutDisplayLayer(in: self)
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
