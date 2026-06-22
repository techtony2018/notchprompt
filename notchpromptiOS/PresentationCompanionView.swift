//
//  PresentationCompanionView.swift
//  Presentation Companion
//

import SwiftUI
import Combine
import Darwin
import os
import UIKit

private let presentationLogger = Logger(subsystem: "notch.presentation-companion", category: "Presentation")
private let timingAidMinutesRange: ClosedRange<Double> = 1...100

private func presentationLog(_ message: String) {
    NSLog("Presentation Companion: %@", message)
    presentationLogger.notice("\(message, privacy: .public)")
}

#if DEBUG
private final class IOSPerformanceTrace {
    static let shared = IOSPerformanceTrace()

    private var tickCount = 0
    private var lastTickReport = CACurrentMediaTime()
    private var lastTranscriptReport = CACurrentMediaTime()

    func recordTick(
        isRunning: Bool,
        transcriptBasedPrompt: Bool,
        isPresentationModeActive: Bool,
        shouldShowSettingsSurface: Bool
    ) {
        tickCount += 1
        let now = CACurrentMediaTime()
        guard now - lastTickReport >= 1 else { return }
        let ticksPerSecond = Double(tickCount) / max(now - lastTickReport, 0.001)
        NSLog(
            "PCompanionPerf tick %.1f/s running=%@ speech=%@ presentation=%@ settings=%@",
            ticksPerSecond,
            String(isRunning),
            String(transcriptBasedPrompt),
            String(isPresentationModeActive),
            String(shouldShowSettingsSurface)
        )
        tickCount = 0
        lastTickReport = now
    }

    func recordTranscriptMatch(
        durationMs: Double,
        transcriptTokens: Int,
        scriptTokens: Int,
        visibleTokens: Int,
        searchTokens: Int,
        matchedIndex: Int
    ) {
        let now = CACurrentMediaTime()
        guard durationMs >= 8 || now - lastTranscriptReport >= 1 else { return }
        NSLog(
            "PCompanionPerf transcript %.2fms transcriptTokens=%d scriptTokens=%d visibleTokens=%d searchTokens=%d matchedIndex=%d",
            durationMs,
            transcriptTokens,
            scriptTokens,
            visibleTokens,
            searchTokens,
            matchedIndex
        )
        lastTranscriptReport = now
    }
}
#endif

private enum IOSScrollMode: String, CaseIterable {
    case infinite
    case stopAtEnd
}

private enum IOSCountdownBehavior: String, CaseIterable {
    case always
    case freshStartOnly
    case never

    var label: String {
        switch self {
        case .always:
            return "Always"
        case .freshStartOnly:
            return "Fresh start only"
        case .never:
            return "Never"
        }
    }
}

private struct IOSTranscriptLanguageOption: Identifiable, Hashable {
    let id: String
    let label: String
}

private enum IOSPromptMode: String, CaseIterable {
    case speed
    case voice
    case transcript

    var label: String {
        switch self {
        case .speed:
            return "Time"
        case .voice:
            return "Voice"
        case .transcript:
            return "Speech"
        }
    }
}

private enum PresentationCompanionDefaults {
    static let script = """
Presentation Companion helps you rehearse without losing your place.

Open settings from the gear button when you want to edit this script.

This sample text is intentionally long enough to scroll on a phone.
Replace it with your own presentation notes when you are ready.

Opening:
Good morning, everyone.
Today I want to walk through the problem, the approach, and the next step.

Problem:
The audience needs a clear path through the talk.
The speaker needs a lightweight cue without fighting the screen.

Approach:
Keep the prompt readable.
Keep the controls close.
Make editing available without taking over the live prompt.

Demo:
Start the prompt.
Pause when questions come in.
Resume when the presentation continues.

Close:
The goal is simple: fewer distractions, better flow, and a calmer delivery.
Thank you.
"""
}

struct PresentationCompanionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voiceMonitor = IOSLocalMicrophoneVoiceMonitor()
    @AppStorage("ios.script") private var script = PresentationCompanionDefaults.script
    @AppStorage("ios.sourceLink") private var sourceLink = ""
    @State private var isRunning = false
    @AppStorage("ios.secondsPerLine") private var secondsPerLine: Double = 5
    @AppStorage("ios.fontSize") private var fontSize: Double = 30
    @AppStorage("ios.paceLines") private var paceLines: Double = 2
    @State private var scrollOffset: CGFloat = 0
    @State private var dragStartScrollOffset: CGFloat?
    @State private var viewportHeight: CGFloat = 1
    @State private var contentHeight: CGFloat = 1
    @State private var lastTickDate: Date?
    @State private var isSettingsPresented = false
    @AppStorage("ios.scrollMode") private var scrollModeRaw = IOSScrollMode.infinite.rawValue
    @AppStorage("ios.countdownBehavior") private var countdownBehaviorRaw = IOSCountdownBehavior.freshStartOnly.rawValue
    @AppStorage("ios.countdownSeconds") private var countdownSeconds = 3
    @State private var isCountingDown = false
    @State private var countdownRemaining = 0
    @State private var shouldUseCountdownOnNextStart = true
    @AppStorage("ios.scriptEditorHeight") private var scriptEditorHeight: Double = 220
    @State private var scriptEditorResizeStartHeight: Double?
    @AppStorage("ios.autoPauseResumeWithLocalMic") private var autoPauseResumeWithLocalMic = false
    @AppStorage("ios.transcriptBasedPrompt") private var transcriptBasedPrompt = false
    @AppStorage("ios.transcriptLanguageIdentifier") private var transcriptLanguageIdentifier = "auto"
    @AppStorage("ios.transcriptMatchConsecutiveWords") private var transcriptMatchConsecutiveWords = 3
    @AppStorage("ios.transcriptMaxForwardLookingWords") private var transcriptMaxForwardLookingWords = 20
    @AppStorage("ios.fuzzyTranscriptMatching") private var fuzzyTranscriptMatching = true
    @State private var detectedTranscriptLanguageIdentifier = "en-US"
    @AppStorage("ios.voiceDetectionThresholdDb") private var voiceDetectionThresholdDb = -30.0
    @State private var isPausedByVoiceMonitor = false
    @State private var isVoiceResumeBlockedByManualPause = false
    @State private var isWaitingForVoiceStart = false
    @State private var isManuallyPaused = false
    @State private var transcriptSpokenCharacterEnd = 0
    @State private var transcriptMatchedTokenIndex = -1
    @State private var transcriptConsumedTokenCount = 0
    @State private var transcriptVisibleUTF16Range: Range<Int> = 0..<Int.max
    @State private var scriptTokenCache: [ScriptTokenInfo] = []
    @State private var scriptLineEndOffsetCache: [Int] = []
    @State private var previousRecognizedTranscript = ""
    @State private var recognizedTranscriptDisplayLine = ""
    @State private var countdownTask: Task<Void, Never>?
    @State private var isPresentationModeActive = false
    @State private var shouldShowSettingsSurface = true
    @State private var promptTextWidth: CGFloat = 1
    @AppStorage("ios.showTimer") private var showTimer = true
    @AppStorage("ios.timeWarningEnabled") private var timeWarningEnabled = false
    @AppStorage("ios.timeWarningDurationMinutes") private var timeWarningDurationMinutes: Double = 5
    @AppStorage("ios.timeWarningYellowThresholdMinutes") private var timeWarningYellowThresholdMinutes: Double = 1
    @AppStorage("ios.timeWarningRedThresholdMinutes") private var timeWarningRedThresholdMinutes: Double = 5
    @AppStorage("ios.timerOverlayOffsetX") private var timerOverlayOffsetX: Double = 0
    @AppStorage("ios.timerOverlayOffsetY") private var timerOverlayOffsetY: Double = 0
    @State private var presentationElapsedSeconds: TimeInterval = 0
    @State private var presentationTimerStartedAt: Date?
    @State private var linkInput = ""
    @State private var isLoadLinkPresented = false
    @State private var isLoadingLink = false
    @State private var loadLinkErrorMessage: String?
    @AppStorage("ios.promptToolbarOffsetX") private var promptToolbarOffsetX: Double = 0
    @AppStorage("ios.promptToolbarOffsetY") private var promptToolbarOffsetY: Double = 0
    @AppStorage("ios.promptToolbarOpacity") private var promptToolbarOpacity: Double = 1
    @State private var promptToolbarDragStartOffset: CGSize?
    @State private var timerOverlayDragStartOffset: CGSize?
    @FocusState private var isScriptFocused: Bool

    private var timerInterval: TimeInterval {
        if isPresentationModeActive && isRunning && !transcriptBasedPrompt {
            return 1.0 / 60.0
        }
        if isRunning {
            return 0.1
        }
        return 1.0
    }

    private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: timerInterval, on: .main, in: .common).autoconnect()
    }
    private let transcriptLanguageOptions: [IOSTranscriptLanguageOption] = [
        IOSTranscriptLanguageOption(id: "auto", label: "Auto"),
        IOSTranscriptLanguageOption(id: "en-US", label: "English"),
        IOSTranscriptLanguageOption(id: "zh-Hans", label: "Chinese (Simplified)"),
        IOSTranscriptLanguageOption(id: "zh-Hant", label: "Chinese (Traditional)"),
        IOSTranscriptLanguageOption(id: "ja-JP", label: "Japanese"),
        IOSTranscriptLanguageOption(id: "ko-KR", label: "Korean"),
        IOSTranscriptLanguageOption(id: "es-ES", label: "Spanish"),
        IOSTranscriptLanguageOption(id: "fr-FR", label: "French"),
        IOSTranscriptLanguageOption(id: "de-DE", label: "German"),
        IOSTranscriptLanguageOption(id: "it-IT", label: "Italian"),
        IOSTranscriptLanguageOption(id: "pt-BR", label: "Portuguese"),
        IOSTranscriptLanguageOption(id: "nl-NL", label: "Dutch"),
        IOSTranscriptLanguageOption(id: "ru-RU", label: "Russian"),
        IOSTranscriptLanguageOption(id: "ar-SA", label: "Arabic"),
        IOSTranscriptLanguageOption(id: "he-IL", label: "Hebrew"),
        IOSTranscriptLanguageOption(id: "hi-IN", label: "Hindi"),
        IOSTranscriptLanguageOption(id: "th-TH", label: "Thai")
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                foregroundSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("--reset-settings-surface") {
                    resetUITestPlaybackSettings()
                    isPresentationModeActive = false
                    shouldShowSettingsSurface = true
                }
                isPresentationModeActive = false
                shouldShowSettingsSurface = true
                UserDefaults.standard.set(false, forKey: "isPresentationModeActive")
                UserDefaults.standard.set(true, forKey: "shouldShowSettingsSurface")
                viewportHeight = proxy.size.height
                promptTextWidth = max(proxy.size.width - 48, 1)
                refreshDetectedTranscriptLanguage()
                refreshScriptAnalysis()
                migrateLineBasedPlaybackDefaultsIfNeeded()
                normalizeVoiceModeSelection()
                normalizeTimeWarningSettings()
                updateVoiceMonitor()
            }
        }
        .onReceive(timer) { date in
            tick(at: date)
        }
        .onChange(of: script) { _, _ in
            refreshDetectedTranscriptLanguage()
            refreshScriptAnalysis()
            voiceMonitor.scriptText = script
            resetScroll(resetTimer: false)
        }
        .onChange(of: autoPauseResumeWithLocalMic) { _, isEnabled in
            if isEnabled {
                transcriptBasedPrompt = false
            }
            updateVoiceMonitor()
        }
        .onChange(of: transcriptBasedPrompt) { _, isEnabled in
            if isEnabled {
                autoPauseResumeWithLocalMic = false
            }
            transcriptSpokenCharacterEnd = 0
            transcriptMatchedTokenIndex = -1
            transcriptConsumedTokenCount = 0
            updateVoiceMonitor()
        }
        .onChange(of: transcriptMatchConsecutiveWords) { _, value in
            transcriptMatchConsecutiveWords = Int(min(max(value, 1), 10))
            transcriptSpokenCharacterEnd = 0
            transcriptMatchedTokenIndex = -1
            transcriptConsumedTokenCount = 0
        }
        .onChange(of: transcriptMaxForwardLookingWords) { _, value in
            transcriptMaxForwardLookingWords = Int(min(max(value, 5), 100))
            transcriptSpokenCharacterEnd = 0
            transcriptMatchedTokenIndex = -1
            transcriptConsumedTokenCount = 0
        }
        .onChange(of: fuzzyTranscriptMatching) { _, _ in
            transcriptSpokenCharacterEnd = 0
            transcriptMatchedTokenIndex = -1
            transcriptConsumedTokenCount = 0
        }
        .onChange(of: timeWarningDurationMinutes) { _, _ in
            syncDefaultTimeWarningThresholds()
        }
        .onChange(of: timeWarningYellowThresholdMinutes) { _, _ in
            normalizeTimeWarningSettings()
        }
        .onChange(of: timeWarningRedThresholdMinutes) { _, _ in
            normalizeTimeWarningSettings()
        }
        .onChange(of: voiceDetectionThresholdDb) { _, thresholdDb in
            voiceMonitor.voiceDetectionThresholdDb = thresholdDb
        }
        .onChange(of: transcriptLanguageIdentifier) { _, _ in
            updateVoiceMonitor()
        }
        .onChange(of: voiceMonitor.isVoiceActive) { _, isVoiceActive in
            handleVoiceActivityChanged(isVoiceActive)
        }
        .onChange(of: voiceMonitor.recognizedTranscript) { _, transcript in
            updateRecognizedTranscriptDisplayLine(from: transcript)
            updateTranscriptProgress(transcript)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            handleAppBecameActive()
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onDisappear {
            countdownTask?.cancel()
            voiceMonitor.stop()
        }
    }

    @ViewBuilder
    private var foregroundSurface: some View {
        if isPresentationModeActive || !shouldShowSettingsSurface {
            presentationForegroundSurface
        } else {
            controls
        }
    }

    private var presentationForegroundSurface: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                promptSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomStatusLine
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            floatingPromptToolbar
            if shouldShowTimerIndicator {
                timerIndicator
            }
            promptOverlayMessage
        }
    }

    private var shouldShowTimerIndicator: Bool {
        showTimer && isPresentationModeActive
    }

    private var timerIndicator: some View {
        Text(timerText)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(timerColor)
            .opacity(timerTextOpacity)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .shadow(color: .black.opacity(0.65), radius: 3, x: 0, y: 1)
            .contentShape(Rectangle())
            .offset(x: timerOverlayOffsetX, y: timerOverlayOffsetY)
            .gesture(timerDragGesture)
            .padding(.top, 88)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var timerDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let startOffset = timerOverlayDragStartOffset ?? CGSize(
                    width: timerOverlayOffsetX,
                    height: timerOverlayOffsetY
                )
                timerOverlayDragStartOffset = startOffset
                timerOverlayOffsetX = Double(startOffset.width + value.translation.width)
                timerOverlayOffsetY = Double(startOffset.height + value.translation.height)
            }
            .onEnded { _ in
                timerOverlayDragStartOffset = nil
            }
    }

    private var timerText: String {
        let elapsed = formattedTimerDuration(presentationElapsedSeconds)
        guard timeWarningEnabled else { return elapsed }
        return "\(elapsed) / \(formattedTimerDuration(timeWarningRedThresholdMinutes * 60))"
    }

    private var timerColor: Color {
        guard timeWarningEnabled else {
            return .white.opacity(0.86)
        }
        let redSeconds = max(timeWarningRedThresholdMinutes * 60, 1)
        let yellowRemainingSeconds = max(timeWarningYellowThresholdMinutes * 60, 1)
        if presentationElapsedSeconds >= redSeconds {
            return .red
        }
        if redSeconds - presentationElapsedSeconds <= yellowRemainingSeconds {
            return .yellow
        }
        return .green
    }

    private var timerTextOpacity: Double {
        guard isTimerInYellowWarningWindow else { return 1 }
        return Int((presentationElapsedSeconds * 10).rounded(.down)).isMultiple(of: 2) ? 1 : 0.28
    }

    private var isTimerInYellowWarningWindow: Bool {
        guard timeWarningEnabled else { return false }
        let redSeconds = max(timeWarningRedThresholdMinutes * 60, 1)
        let yellowRemainingSeconds = max(timeWarningYellowThresholdMinutes * 60, 1)
        return presentationElapsedSeconds < redSeconds &&
            redSeconds - presentationElapsedSeconds <= yellowRemainingSeconds
    }

    private func formattedTimerDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private var promptOverlayMessage: some View {
        if isCountingDown {
            ZStack {
                Color.black.opacity(0.88)
                    .ignoresSafeArea()
                Text("\(countdownRemaining)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .allowsHitTesting(false)
        } else if isManuallyPaused {
            promptInfoCard(symbol: "play.fill", text: "Presentation paused, click Play again to resume")
        } else if shouldShowVoiceStartTip {
            promptInfoCard(symbol: "waveform", text: "Start talking to move prompt forward")
        }
    }

    private func promptInfoCard(symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
            Text(text)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }

    private var promptSurface: some View {
        GeometryReader { viewportProxy in
            ZStack(alignment: .topLeading) {
                Color.black

                Text(attributedPromptText)
                    .font(.system(size: fontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(fontSize * 0.35)
                    .opacity(isManuallyPaused ? 0.28 : 1)
                    .padding(.horizontal, 24)
                    .padding(.top, promptTopPadding)
                    .padding(.bottom, promptBottomPadding)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(
                        GeometryReader { contentProxy in
                            Color.clear
                                .onAppear {
                                    contentHeight = contentProxy.size.height
                                    viewportHeight = viewportProxy.size.height
                                    clampScroll()
                                }
                                .onChange(of: contentProxy.size.height) { _, height in
                                    contentHeight = height
                                    clampScroll()
                                }
                        }
                    )
                    .offset(y: -scrollOffset)

            }
            .clipped()
            .onAppear {
                viewportHeight = viewportProxy.size.height
                promptTextWidth = max(viewportProxy.size.width - 48, 1)
                clampScroll()
            }
            .onChange(of: viewportProxy.size.height) { _, height in
                viewportHeight = height
                clampScroll()
            }
            .onChange(of: viewportProxy.size.width) { _, width in
                promptTextWidth = max(width - 48, 1)
                clampScroll()
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .exclusively(before: SpatialTapGesture(count: 1))
                    .onEnded { result in
                        switch result {
                        case .first(let value):
                            handlePromptTap(at: value.location, in: viewportProxy.size, multiplier: 2)
                        case .second(let value):
                            handlePromptTap(at: value.location, in: viewportProxy.size, multiplier: 1)
                        }
                    }
            )
        }
        .accessibilityIdentifier("presentationForegroundSurface")
        .accessibilityValue("\(Int(scrollOffset.rounded()))")
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    let start = dragStartScrollOffset ?? scrollOffset
                    dragStartScrollOffset = start
                    scrollOffset = start - value.translation.height
                    clampScroll()
                }
                .onEnded { _ in
                    dragStartScrollOffset = nil
                }
        )
    }

    private var shouldShowVoiceStartTip: Bool {
        isWaitingForVoiceStart
            && !isManuallyPaused
            && !voiceMonitor.isVoiceActive
            && Double(voiceMonitor.inputLevelDb) < voiceDetectionThresholdDb
    }

    private var attributedPromptText: AttributedString {
        var attributed = AttributedString(script)
        let clampedEnd = min(max(transcriptBasedPrompt ? transcriptSpokenCharacterEnd : 0, 0), (script as NSString).length)
        if clampedEnd > 0,
           let stringRange = Range(NSRange(location: 0, length: clampedEnd), in: script),
           let attributedRange = Range(stringRange, in: attributed) {
            attributed[attributedRange].foregroundColor = .blue
        }
        return attributed
    }

    private var bottomStatusLine: some View {
        HStack(spacing: 8) {
            statusLeadingLabel
                .frame(width: statusLeadingLabelWidth, alignment: .leading)
            unifiedStatusArea
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(.black)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var unifiedStatusArea: some View {
        if autoPauseResumeWithLocalMic {
            unifiedStatusText(
                voiceMonitor.isVoiceActive ? "talking" : "paused, talk to continue",
                color: voiceMonitor.isVoiceActive ? .blue : .red,
                weight: .semibold
            )
        } else if transcriptBasedPrompt {
            unifiedStatusText(recognizedTranscriptDisplayLine, color: .blue, weight: .medium)
        } else {
            unifiedStatusText("\(Int(secondsPerLine.rounded()))s/line", color: .white.opacity(0.82), weight: .semibold)
        }
    }

    private func unifiedStatusText(_ text: String, color: Color, weight: Font.Weight) -> some View {
        Text(text)
            .foregroundStyle(color)
            .font(.system(size: max(12, fontSize * 0.45), weight: weight))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusLeadingLabel: some View {
        if autoPauseResumeWithLocalMic {
            HStack(spacing: 4) {
                Text("Voice:")
                    .foregroundStyle(.white.opacity(0.72))
                Text("\(Int(voiceMonitor.inputLevelDb.rounded())) dB")
                    .foregroundStyle(voiceMonitor.isVoiceActive ? .blue : .gray)
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
        } else if transcriptBasedPrompt {
            Menu {
                Picker("Speech recognition language", selection: $transcriptLanguageIdentifier) {
                    Text("Auto (\(transcriptLanguageLabel(for: detectedTranscriptLanguageIdentifier)))").tag("auto")
                    ForEach(transcriptLanguageOptions.filter { $0.id != "auto" }) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(transcriptLanguageLabel(for: effectiveTranscriptLanguageIdentifier))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .foregroundStyle(.blue)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            Text("Speed:")
                .foregroundStyle(.white.opacity(0.72))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
    }

    private var statusLeadingLabelWidth: CGFloat {
        if autoPauseResumeWithLocalMic {
            return 86
        }
        if transcriptBasedPrompt {
            return 108
        }
        return 58
    }

    private var floatingPromptToolbar: some View {
        GeometryReader { proxy in
            promptToolbar
                .fixedSize(horizontal: true, vertical: true)
                .position(x: proxy.size.width / 2, y: 44)
                .offset(x: promptToolbarOffsetX, y: promptToolbarOffsetY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = promptToolbarDragStartOffset ?? CGSize(
                                width: promptToolbarOffsetX,
                                height: promptToolbarOffsetY
                            )
                            promptToolbarDragStartOffset = start
                            promptToolbarOffsetX = Double(start.width + value.translation.width)
                            promptToolbarOffsetY = Double(start.height + value.translation.height)
                        }
                        .onEnded { _ in
                            promptToolbarDragStartOffset = nil
                        }
                )
        }
        .allowsHitTesting(true)
    }

    private var promptToolbar: some View {
        HStack(spacing: 8) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: promptControlShowsPause ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .accessibilityLabel(promptControlShowsPause ? "Pause Prompt" : "Start Prompt")
            .accessibilityIdentifier("playPauseButton")
            .layoutPriority(1)

            Button {
                resetScroll()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .accessibilityLabel("Reset")
            .accessibilityIdentifier("resetButton")
            .layoutPriority(1)

            toolbarJumpButton(
                symbol: "gobackward",
                accessibilityLabel: "Back by configured line pace",
                accessibilityIdentifier: "backButton",
                direction: -1
            )

            toolbarJumpButton(
                symbol: "goforward",
                accessibilityLabel: "Forward by configured line pace",
                accessibilityIdentifier: "forwardButton",
                direction: 1
            )

            Button {
                if let text = UIPasteboard.general.string {
                    script = text
                    resetScroll(resetTimer: false)
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .accessibilityLabel("Paste script from clipboard")

            Button {
                script = ""
                resetScroll(resetTimer: false)
            } label: {
                Image(systemName: "trash")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .accessibilityLabel("Clear script")

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settingsButton")
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.78), in: Capsule())
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.26), radius: 14, x: 0, y: 8)
        .opacity(promptToolbarOpacity)
    }

    private func toolbarJumpButton(
        symbol: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        direction: Double
    ) -> some View {
        Image(systemName: symbol)
            .font(.headline)
            .frame(width: 34, height: 34)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .contentShape(Circle())
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture())
                    .onEnded { result in
                        switch result {
                        case .first:
                            jump(lines: paceLines * direction * 2)
                        case .second:
                            jump(lines: paceLines * direction)
                        }
                    }
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
            .layoutPriority(1)
    }

    private var scriptEditorResizeHandle: some View {
        HStack {
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let startHeight = scriptEditorResizeStartHeight ?? scriptEditorHeight
                            scriptEditorResizeStartHeight = startHeight
                            scriptEditorHeight = min(max(startHeight + Double(value.translation.height), 140), 520)
                        }
                        .onEnded { _ in
                            scriptEditorResizeStartHeight = nil
                        }
                )
                .accessibilityLabel("Resize script editor")
        }
    }

    private var controls: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSection("Presentation Script") {
                        TextEditor(text: $script)
                            .font(.system(size: 16, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(.separator).opacity(0.7), lineWidth: 1)
                            )
                            .frame(height: scriptEditorHeight)
                            .focused($isScriptFocused)
                            .accessibilityIdentifier("scriptEditor")

                        scriptEditorResizeHandle

                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(scriptWordCount) words")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Spacer(minLength: 6)

                            HStack(spacing: 4) {
                                Text("Detected: \(transcriptLanguageLabel(for: detectedTranscriptLanguageIdentifier)). Using:")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $transcriptLanguageIdentifier) {
                                    Text("Auto (\(transcriptLanguageLabel(for: detectedTranscriptLanguageIdentifier)))").tag("auto")
                                    ForEach(transcriptLanguageOptions.filter { $0.id != "auto" }) { option in
                                        Text(option.label).tag(option.id)
                                    }
                                }
                                .labelsHidden()
                                .font(.footnote)
                                .pickerStyle(.menu)
                            }
                        }

                        if !sourceLink.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Current link")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                if let url = URL(string: sourceLink) {
                                    Link(sourceLink, destination: url)
                                        .font(.footnote)
                                        .lineLimit(2)
                                } else {
                                    Text(sourceLink)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            Button(role: .destructive) {
                                resetScroll()
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                dismissScriptKeyboard()
                                linkInput = ""
                                isLoadLinkPresented = true
                            } label: {
                                Label("Load from Link", systemImage: "link")
                            }
                            .disabled(isLoadingLink)
                            .buttonStyle(.bordered)
                        }

                        if isLoadingLink {
                            ProgressView("Loading link...")
                        }
                    }

                    settingsSection("Playback") {
                        Toggle("Play in loops", isOn: Binding(
                            get: { scrollMode == .infinite },
                            set: { scrollModeBinding.wrappedValue = $0 ? .infinite : .stopAtEnd }
                        ))

                        HStack {
                            Text("Countdown")
                            Spacer()
                            Picker("Countdown", selection: countdownBehaviorBinding) {
                                ForEach(IOSCountdownBehavior.allCases, id: \.self) { behavior in
                                    Text(behavior.label).tag(behavior)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        sliderRow(
                            "Countdown duration",
                            value: Binding(
                                get: { Double(countdownSeconds) },
                                set: { countdownSeconds = Int($0.rounded()) }
                            ),
                            range: 0...10,
                            step: 1,
                            suffix: "s"
                        )
                        .disabled(countdownBehavior == .never)

                        if isCountingDown {
                            Text("Starting in \(countdownRemaining)s")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        sliderRow("Forward/backward pace", value: $paceLines, range: 1...10, step: 1, suffix: " lines")

                        HStack {
                            Text("Scroll mode")
                            Spacer()
                            Picker("Scroll mode", selection: promptModeBinding) {
                                ForEach(IOSPromptMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 260)
                        }

                        if promptMode == .speed {
                            sliderRow("Scroll speed", value: $secondsPerLine, range: 1...20, step: 1, suffix: "s/line")
                                .padding(.leading, 18)
                        }

                        if promptMode == .voice {
                            sliderRow("Voice detection threshold", value: $voiceDetectionThresholdDb, range: -70...20, step: 1, suffix: " dB")
                                .padding(.leading, 18)
                        }

                        if promptMode == .transcript {
                            Stepper(
                                "Match consecutive words: \(transcriptMatchConsecutiveWords)",
                                value: $transcriptMatchConsecutiveWords,
                                in: 1...10
                            )
                            .padding(.leading, 18)

                            Stepper(
                                "Max forward looking words: \(transcriptMaxForwardLookingWords)",
                                value: $transcriptMaxForwardLookingWords,
                                in: 5...100
                            )
                            .padding(.leading, 18)

                            Toggle("Fuzzy transcript matching", isOn: $fuzzyTranscriptMatching)
                                .padding(.leading, 18)
                        }

                        if promptMode == .voice, voiceMonitor.isMonitoring {
                            Text("Mic: \(voiceMonitor.isVoiceActive ? "voice detected" : "listening") · \(Int(voiceMonitor.inputLevelDb.rounded())) dB")
                                .font(.footnote)
                                .foregroundStyle(voiceMonitor.isVoiceActive ? .green : .secondary)
                        }

                        if promptMode == .voice, let message = voiceMonitor.unavailableMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if promptMode == .transcript, let message = voiceMonitor.transcriptUnavailableMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                    }

                    settingsSection("Presentation timing aid") {
                        Toggle("Show timer", isOn: $showTimer)

                        Toggle("Colored time warning", isOn: $timeWarningEnabled)
                            .disabled(!showTimer)
                            .opacity(showTimer ? 1 : 0.55)

                        sliderRow("Full duration", value: clampedTimeBinding($timeWarningDurationMinutes, upper: timingAidMinutesRange.upperBound), range: timingAidMinutesRange, step: 1, suffix: " min")
                            .disabled(!showTimer || !timeWarningEnabled)
                            .opacity(showTimer && timeWarningEnabled ? 1 : 0.55)

                        sliderRow("Blinking yellow at", value: clampedTimeBinding($timeWarningYellowThresholdMinutes, upper: max(timeWarningRedThresholdMinutes, 1)), range: timingAidMinutesRange, step: 1, suffix: " min")
                            .disabled(!showTimer || !timeWarningEnabled)
                            .opacity(showTimer && timeWarningEnabled ? 1 : 0.55)

                        sliderRow("Red at", value: clampedTimeBinding($timeWarningRedThresholdMinutes, upper: timingAidMinutesRange.upperBound), range: timingAidMinutesRange, step: 1, suffix: " min")
                            .disabled(!showTimer || !timeWarningEnabled)
                            .opacity(showTimer && timeWarningEnabled ? 1 : 0.55)
                    }

                    settingsSection("Appearance") {
                        sliderRow("Font size", value: $fontSize, range: 16...60, step: 1, suffix: " pt")
                        sliderRow("Tool bar opacity", value: $promptToolbarOpacity, range: 0.25...1, step: 0.05) { value in
                            "\(Int((value * 100).rounded()))%"
                        }
                    }

                    Color.clear
                        .frame(height: 82)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("configurationSurface")
            .accessibilityValue("\(Int(scrollOffset.rounded()))")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        dismissScriptKeyboard()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Presentation Companion")
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                            Image("AppIcon")
                                .resizable()
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settingsTitle")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Link(appVersionText, destination: URL(string: "https://github.com/techtony2018/notchprompt")!)
                        .font(.footnote.weight(.medium))
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Button("Done") {
                        dismissScriptKeyboard()
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("configurationSurface")
                    .accessibilityValue("\(Int(scrollOffset.rounded()))")
            }
            .overlay(alignment: .bottom) {
                floatingPresentButton
            }
            .alert("Load from Link", isPresented: $isLoadLinkPresented) {
                TextField("https://example.com/article", text: $linkInput)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Button("Load") {
                    Task {
                        await loadScriptFromLink()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter an article link to load clean text into Presentation Script.")
            }
            .alert(
                "Load Link Failed",
                isPresented: Binding(
                    get: { loadLinkErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            loadLinkErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    loadLinkErrorMessage = nil
                }
            } message: {
                Text(loadLinkErrorMessage ?? "The link could not be loaded.")
            }
        }
    }

    private var floatingPresentButton: some View {
        Button {
            dismissScriptKeyboard()
            presentFromSettings()
        } label: {
            Label("Present", systemImage: "play.fill")
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Color.accentColor, in: Capsule())
        .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 8)
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .accessibilityIdentifier("presentButton")
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        sliderRow(title, value: value, range: range, step: step) { value in
            "\(Int(value.rounded()))\(suffix)"
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formattedValue: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedValue(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func clampedTimeBinding(_ binding: Binding<Double>, upper: Double) -> Binding<Double> {
        Binding(
            get: { min(max(binding.wrappedValue, 1), max(upper, 1)) },
            set: { binding.wrappedValue = min(max($0.rounded(), 1), max(upper, 1)) }
        )
    }

    private func tick(at date: Date) {
        #if DEBUG
        IOSPerformanceTrace.shared.recordTick(
            isRunning: isRunning,
            transcriptBasedPrompt: transcriptBasedPrompt,
            isPresentationModeActive: isPresentationModeActive,
            shouldShowSettingsSurface: shouldShowSettingsSurface
        )
        #endif
        guard isRunning else {
            if lastTickDate != nil {
                lastTickDate = nil
            }
            if presentationTimerStartedAt != nil {
                presentationTimerStartedAt = nil
            }
            return
        }

        tickPresentationTimer(at: date)
        guard !transcriptBasedPrompt else {
            lastTickDate = date
            return
        }

        let deltaTime = min(max(date.timeIntervalSince(lastTickDate ?? date), 0), 0.25)
        scrollOffset += promptLineHeight * CGFloat(deltaTime) / max(CGFloat(secondsPerLine), 0.1)
        clampScroll()
        lastTickDate = date
    }

    private func tickPresentationTimer(at date: Date) {
        guard isRunning else {
            if presentationTimerStartedAt != nil {
                presentationTimerStartedAt = nil
            }
            return
        }

        guard let startedAt = presentationTimerStartedAt else {
            presentationTimerStartedAt = date
            return
        }

        let deltaTime = min(max(date.timeIntervalSince(startedAt), 0), 1.5)
        presentationElapsedSeconds += deltaTime
        presentationTimerStartedAt = date
    }

    private func syncDefaultTimeWarningThresholds() {
        let duration = min(max(timeWarningDurationMinutes.rounded(), timingAidMinutesRange.lowerBound), timingAidMinutesRange.upperBound)
        timeWarningDurationMinutes = duration
        timeWarningYellowThresholdMinutes = max(1, ceil(duration * 0.8))
        timeWarningRedThresholdMinutes = duration
    }

    private func normalizeTimeWarningSettings() {
        timeWarningDurationMinutes = min(max(timeWarningDurationMinutes.rounded(), timingAidMinutesRange.lowerBound), timingAidMinutesRange.upperBound)
        timeWarningRedThresholdMinutes = min(max(timeWarningRedThresholdMinutes.rounded(), timingAidMinutesRange.lowerBound), timingAidMinutesRange.upperBound)
        timeWarningYellowThresholdMinutes = min(
            max(timeWarningYellowThresholdMinutes.rounded(), timingAidMinutesRange.lowerBound),
            max(timeWarningRedThresholdMinutes, 1)
        )
    }

    private func togglePlayback() {
        presentationLog("togglePlayback running=\(isRunning) counting=\(isCountingDown)")
        isScriptFocused = false
        if promptControlShowsPause {
            pauseManually()
        } else {
            resumeManually()
        }
    }

    private func jump(lines: Double) {
        presentationLog("jump lines=\(lines)")
        scrollOffset += promptLineHeight * CGFloat(lines)
        clampScroll()
    }

    private func handlePromptTap(at location: CGPoint, in size: CGSize, multiplier: Double) {
        let third = max(size.width / 3, 1)
        if location.x < third {
            jump(lines: -paceLines * multiplier)
        } else if location.x > third * 2 {
            jump(lines: paceLines * multiplier)
        } else {
            togglePlayback()
        }
    }

    private func resetScroll(resetTimer: Bool = true) {
        presentationLogger.notice("resetScroll")
        stopPlayback()
        isManuallyPaused = false
        scrollOffset = 0
        transcriptSpokenCharacterEnd = 0
        transcriptMatchedTokenIndex = -1
        transcriptConsumedTokenCount = 0
        transcriptVisibleUTF16Range = 0..<Int.max
        previousRecognizedTranscript = ""
        recognizedTranscriptDisplayLine = ""
        if resetTimer {
            presentationElapsedSeconds = 0
            presentationTimerStartedAt = nil
        }
        voiceMonitor.resetTranscriptState()
        lastTickDate = nil
        isPausedByVoiceMonitor = false
        isVoiceResumeBlockedByManualPause = false
        shouldUseCountdownOnNextStart = true
    }

    private func openSettings() {
        presentationLog("openSettings")
        isScriptFocused = false
        isPresentationModeActive = false
        shouldShowSettingsSurface = true
    }

    private func presentFromSettings() {
        presentationLog("presentFromSettings running=\(isRunning) counting=\(isCountingDown) waiting=\(isWaitingForVoiceStart)")
        isScriptFocused = false
        if isRunning || isCountingDown || isWaitingForVoiceStart {
            isPresentationModeActive = true
            shouldShowSettingsSurface = false
            return
        }
        resumeManually()
    }

    private func loadScriptFromLink() async {
        guard !isLoadingLink else { return }
        isLoadingLink = true
        defer { isLoadingLink = false }

        do {
            script = try await ScriptLinkLoader.loadScript(from: linkInput)
            sourceLink = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
            resetScroll(resetTimer: false)
        } catch {
            loadLinkErrorMessage = error.localizedDescription
        }
    }

    private func dismissScriptKeyboard() {
        isScriptFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func migrateLineBasedPlaybackDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let speedMigrationKey = "ios.lineBasedSpeedMigration"
        if defaults.object(forKey: speedMigrationKey) == nil {
            secondsPerLine = 5
            defaults.set(true, forKey: speedMigrationKey)
        }
        let paceMigrationKey = "ios.lineBasedPaceMigration"
        if defaults.object(forKey: paceMigrationKey) == nil {
            paceLines = 2
            defaults.set(true, forKey: paceMigrationKey)
        }
    }

    private func normalizeVoiceModeSelection() {
        if transcriptBasedPrompt {
            autoPauseResumeWithLocalMic = false
        }
    }

    private func resetUITestPlaybackSettings() {
        autoPauseResumeWithLocalMic = false
        transcriptBasedPrompt = false
        transcriptLanguageIdentifier = "auto"
        countdownBehaviorRaw = IOSCountdownBehavior.freshStartOnly.rawValue
        countdownSeconds = 3
        scrollModeRaw = IOSScrollMode.infinite.rawValue
        secondsPerLine = 5
        paceLines = 2
        shouldUseCountdownOnNextStart = true
        resetScroll()
    }

    private var effectiveTranscriptLanguageIdentifier: String {
        transcriptLanguageIdentifier == "auto" ? detectedTranscriptLanguageIdentifier : transcriptLanguageIdentifier
    }

    private var scriptEditorProgressUTF16Offset: Int {
        let visibleProgress = scrollOffset > 0 ? currentVisibleUTF16Range().lowerBound : 0
        return max(transcriptSpokenCharacterEnd, visibleProgress)
    }

    private func refreshDetectedTranscriptLanguage() {
        detectedTranscriptLanguageIdentifier = IOSLocalMicrophoneVoiceMonitor.bestSpeechLocaleIdentifier(for: script)
        if !transcriptLanguageOptions.contains(where: { $0.id == transcriptLanguageIdentifier }) {
            transcriptLanguageIdentifier = "auto"
        }
    }

    private func refreshScriptAnalysis() {
        scriptTokenCache = scriptTokenInfos(in: script)
        scriptLineEndOffsetCache = lineEndOffsets(in: script)
    }

    private func transcriptLanguageLabel(for identifier: String) -> String {
        if let option = transcriptLanguageOptions.first(where: { $0.id == identifier }) {
            return option.label
        }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func clampScroll() {
        let maxOffset = max(contentHeight - viewportHeight, 0)
        if scrollOffset < 0 {
            scrollOffset = 0
        }

        guard maxOffset > 0 else {
            scrollOffset = 0
            return
        }

        if scrollMode == .infinite, isRunning, scrollOffset >= maxOffset {
            scrollOffset = 0
            if transcriptBasedPrompt {
                transcriptSpokenCharacterEnd = 0
                transcriptMatchedTokenIndex = -1
                transcriptConsumedTokenCount = 0
            }
            return
        }

        scrollOffset = min(scrollOffset, maxOffset)
        if scrollMode == .stopAtEnd, scrollOffset >= maxOffset {
            stopPlayback()
        }
    }

    private func pauseManually() {
        presentationLog("pauseManually")
        stopPlayback()
        isManuallyPaused = true
        isPausedByVoiceMonitor = false
        isVoiceResumeBlockedByManualPause = autoPauseResumeWithLocalMic || transcriptBasedPrompt
    }

    private func resumeManually() {
        presentationLog("resumeManually")
        isVoiceResumeBlockedByManualPause = false
        startPlayback()
    }

    private func startPlayback() {
        guard !isRunning, !isCountingDown else { return }

        presentationLog("startPlayback")
        isPausedByVoiceMonitor = false
        continueStartingPlayback()
    }

    private func continueStartingPlayback() {
        isPresentationModeActive = true
        shouldShowSettingsSurface = false

        if scrollMode == .stopAtEnd {
            let maxOffset = max(contentHeight - viewportHeight, 0)
            if maxOffset > 0, scrollOffset >= maxOffset {
                scrollOffset = 0
            }
        }

        let delay = max(0, countdownSeconds)
        let shouldRunCountdown: Bool
        switch countdownBehavior {
        case .always:
            shouldRunCountdown = delay > 0
        case .freshStartOnly:
            shouldRunCountdown = delay > 0 && shouldUseCountdownOnNextStart
        case .never:
            shouldRunCountdown = false
        }

        guard shouldRunCountdown else {
            if shouldWaitForMicInputOnStart {
                beginWaitingForMicStart()
                return
            }
            beginRunningNow()
            return
        }

        beginCountdown(seconds: delay)
    }

    private func stopPlayback() {
        countdownTask?.cancel()
        countdownTask = nil
        isCountingDown = false
        countdownRemaining = 0
        isRunning = false
        isWaitingForVoiceStart = false
        presentationTimerStartedAt = nil
    }

    private func beginCountdown(seconds: Int) {
        countdownTask?.cancel()
        isRunning = false
        isCountingDown = true
        countdownRemaining = seconds

        countdownTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    stopPlayback()
                    return
                }
                remaining -= 1
                countdownRemaining = remaining
            }

            guard !Task.isCancelled else { return }
            if shouldWaitForMicInputOnStart {
                beginWaitingForMicStart()
            } else {
                beginRunningNow()
            }
            countdownTask = nil
        }
    }

    private func beginWaitingForMicStart() {
        presentationLog("beginWaitingForMicStart")
        isCountingDown = false
        countdownRemaining = 0
        shouldUseCountdownOnNextStart = false
        isRunning = false
        isManuallyPaused = false
        isPausedByVoiceMonitor = autoPauseResumeWithLocalMic
        isVoiceResumeBlockedByManualPause = false
        isWaitingForVoiceStart = true
        lastTickDate = nil
        updateVoiceMonitor()
        if voiceMonitor.isVoiceActive {
            handleVoiceActivityChanged(true)
        }
    }

    private func beginRunningNow() {
        presentationLog("beginRunningNow")
        isCountingDown = false
        countdownRemaining = 0
        shouldUseCountdownOnNextStart = false
        isWaitingForVoiceStart = false
        isManuallyPaused = false
        isRunning = true
        presentationTimerStartedAt = nil
        lastTickDate = nil
    }

    private func handleIncomingURL(_ url: URL) {
        let components = [url.host, url.path]
            .compactMap { $0 }
            .flatMap { $0.split(separator: "/").map(String.init) }
            .map { $0.lowercased() }

        guard components.first == "qa" || components.first == "settings" else {
            presentationLog("handleIncomingURL ignored url=\(url.absoluteString)")
            return
        }

        let action = components.dropFirst().first ?? components.first ?? ""
        presentationLog("handleIncomingURL action=\(action) url=\(url.absoluteString)")
        switch action {
        case "play", "start", "resume":
            resumeManually()
        case "pause":
            pauseManually()
        case "toggle":
            togglePlayback()
        case "back", "backward":
            jump(lines: -paceLines)
        case "forward":
            jump(lines: paceLines)
        case "reset":
            resetScroll()
        case "settings":
            openSettings()
        default:
            if components.first == "settings" {
                openSettings()
            }
        }
    }

    private func updateVoiceMonitor() {
        guard autoPauseResumeWithLocalMic || transcriptBasedPrompt else {
            voiceMonitor.stop()
            isPausedByVoiceMonitor = false
            isVoiceResumeBlockedByManualPause = false
            return
        }

        voiceMonitor.voiceDetectionThresholdDb = voiceDetectionThresholdDb
        voiceMonitor.transcriptTrackingEnabled = transcriptBasedPrompt
        voiceMonitor.preferredRecognitionLocaleIdentifier = transcriptLanguageIdentifier == "auto" ? nil : transcriptLanguageIdentifier
        voiceMonitor.scriptText = script
        voiceMonitor.start()
    }

    private func handleVoiceActivityChanged(_ isVoiceActive: Bool) {
        if isVoiceActive {
            guard !isVoiceResumeBlockedByManualPause, !isManuallyPaused else { return }
            if transcriptBasedPrompt, isWaitingForVoiceStart, !isRunning, !isCountingDown {
                beginRunningNow()
                return
            }
            isWaitingForVoiceStart = false
            guard autoPauseResumeWithLocalMic else { return }
            guard isPausedByVoiceMonitor,
                  !isVoiceResumeBlockedByManualPause,
                  !isRunning,
                  !isCountingDown else { return }
            isPausedByVoiceMonitor = false
            beginRunningNow()
            return
        }

        guard autoPauseResumeWithLocalMic else { return }
        guard isRunning || isCountingDown else { return }
        stopPlayback()
        isPausedByVoiceMonitor = true
        lastTickDate = nil
    }

    private func updateTranscriptProgress(_ transcript: String) {
        guard transcriptBasedPrompt else { return }
        if isWaitingForVoiceStart,
           !isVoiceResumeBlockedByManualPause,
           !isManuallyPaused,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            beginRunningNow()
        }
        guard isRunning, !isManuallyPaused else { return }
        transcriptVisibleUTF16Range = currentVisibleUTF16Range()
        let progress = transcriptProgress(for: transcript)
        transcriptSpokenCharacterEnd = progress.spokenCharacterEnd
        guard progress.spokenCharacterEnd > 0 else { return }
        applyTranscriptViewportAnchor(spokenCharacterEnd: progress.spokenCharacterEnd)
    }

    private func applyTranscriptViewportAnchor(spokenCharacterEnd: Int) {
        let maxOffset = max(contentHeight - viewportHeight, 0)
        guard maxOffset > 0 else { return }
        let spokenBottom = renderedPromptHeight(upToUTF16Offset: spokenCharacterEnd)
        let bottomThirdThreshold = scrollOffset + (promptViewportHeight * (2.0 / 3.0))
        guard spokenBottom >= bottomThirdThreshold else { return }
        let targetOffset = spokenBottom - promptLineHeight
        guard targetOffset > scrollOffset + 2 else { return }
        scrollOffset = min(max(targetOffset, 0), maxOffset)
    }

    private func transcriptProgressFraction(for transcript: String) -> Double {
        transcriptProgress(for: transcript).lineCompletedFraction
    }

    private func transcriptProgress(for transcript: String) -> (lineCompletedFraction: Double, spokenCharacterEnd: Int) {
        #if DEBUG
        let traceStart = CACurrentMediaTime()
        var traceTranscriptTokenCount = 0
        var traceScriptTokenCount = 0
        var traceVisibleTokenCount = 0
        var traceSearchTokenCount = 0
        var traceMatchedIndex = transcriptMatchedTokenIndex
        defer {
            IOSPerformanceTrace.shared.recordTranscriptMatch(
                durationMs: (CACurrentMediaTime() - traceStart) * 1000,
                transcriptTokens: traceTranscriptTokenCount,
                scriptTokens: traceScriptTokenCount,
                visibleTokens: traceVisibleTokenCount,
                searchTokens: traceSearchTokenCount,
                matchedIndex: traceMatchedIndex
            )
        }
        #endif
        let scriptTokens = scriptTokenCache.isEmpty ? scriptTokenInfos(in: script) : scriptTokenCache
        let transcriptTokens = normalizedTokens(transcript)
        #if DEBUG
        traceScriptTokenCount = scriptTokens.count
        traceTranscriptTokenCount = transcriptTokens.count
        #endif
        guard !scriptTokens.isEmpty, !transcriptTokens.isEmpty else { return (0, 0) }
        if transcriptConsumedTokenCount > transcriptTokens.count {
            transcriptConsumedTokenCount = 0
        }

        let visibleTokenRange = visibleTokenRange(in: scriptTokens)
        #if DEBUG
        traceVisibleTokenCount = visibleTokenRange.count
        #endif
        guard visibleTokenRange.lowerBound < visibleTokenRange.upperBound else {
            guard transcriptMatchedTokenIndex >= 0 else { return (0, 0) }
            return scriptProgress(at: transcriptMatchedTokenIndex, in: scriptTokens)
        }

        var isCurrentAnchorVisible = visibleTokenRange.contains(transcriptMatchedTokenIndex)
        if !isCurrentAnchorVisible {
            transcriptMatchedTokenIndex = visibleTokenRange.lowerBound - 1
            isCurrentAnchorVisible = false
        }
        let anchorIndex = transcriptMatchedTokenIndex
        let searchStart = isCurrentAnchorVisible
            ? max(visibleTokenRange.lowerBound, transcriptMatchedTokenIndex + 1)
            : visibleTokenRange.lowerBound
        let forwardRangeStart = isCurrentAnchorVisible ? anchorIndex + 1 : visibleTokenRange.lowerBound
        let searchEnd = min(visibleTokenRange.upperBound, forwardRangeStart + transcriptMaxForwardLookingWords)
        #if DEBUG
        traceSearchTokenCount = max(searchEnd - searchStart, 0)
        #endif
        guard searchStart < searchEnd else {
            guard transcriptMatchedTokenIndex >= 0 else { return (0, 0) }
            return scriptProgress(at: transcriptMatchedTokenIndex, in: scriptTokens)
        }

        var matchedIndex = anchorIndex
        var matchedTranscriptEnd = transcriptConsumedTokenCount
        let overlap = transcriptMatchedTokenIndex < 0 || !isCurrentAnchorVisible ? 0 : 2
        let transcriptSearchStart = max(0, transcriptConsumedTokenCount - overlap)

        for transcriptStart in transcriptSearchStart..<transcriptTokens.count {
            for scriptStart in searchStart..<searchEnd where tokensMatch(scriptTokens[scriptStart].text, transcriptTokens[transcriptStart]) {
                var runLength = 0
                while transcriptStart + runLength < transcriptTokens.count,
                      scriptStart + runLength < scriptTokens.count,
                      scriptStart + runLength < searchEnd,
                      tokensMatch(scriptTokens[scriptStart + runLength].text, transcriptTokens[transcriptStart + runLength]) {
                    runLength += 1
                }

                let transcriptEnd = transcriptStart + runLength
                guard runLength >= transcriptMatchConsecutiveWords, transcriptEnd > transcriptConsumedTokenCount else { continue }
                let cappedIndex = min(scriptStart + runLength - 1, searchEnd - 1)
                guard cappedIndex > matchedIndex else { continue }
                matchedIndex = cappedIndex
                matchedTranscriptEnd = transcriptEnd
                break
            }
            if matchedIndex > anchorIndex {
                break
            }
        }

        guard matchedIndex >= 0 else { return (0, 0) }
        transcriptMatchedTokenIndex = matchedIndex
        transcriptConsumedTokenCount = max(transcriptConsumedTokenCount, matchedTranscriptEnd)
        #if DEBUG
        traceMatchedIndex = matchedIndex
        #endif
        return scriptProgress(at: matchedIndex, in: scriptTokens)
    }

    private func tokensMatch(_ scriptToken: String, _ transcriptToken: String) -> Bool {
        guard scriptToken != transcriptToken else { return true }
        guard fuzzyTranscriptMatching else { return false }
        guard scriptToken.count > 3, transcriptToken.count > 3 else { return false }
        guard scriptToken.unicodeScalars.allSatisfy({ !$0.isCJKToken }),
              transcriptToken.unicodeScalars.allSatisfy({ !$0.isCJKToken }) else { return false }

        let lengthDelta = abs(scriptToken.count - transcriptToken.count)
        let maxLength = max(scriptToken.count, transcriptToken.count)
        guard lengthDelta <= max(2, maxLength / 4) else { return false }

        let limit = maxLength >= 8 ? 2 : 1
        return boundedEditDistance(scriptToken, transcriptToken, limit: limit) <= limit
    }

    private func boundedEditDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        if abs(lhsCharacters.count - rhsCharacters.count) > limit {
            return limit + 1
        }

        var previous = Array(0...rhsCharacters.count)
        for (lhsIndex, lhsCharacter) in lhsCharacters.enumerated() {
            var current = [lhsIndex + 1]
            var rowMinimum = current[0]
            for (rhsIndex, rhsCharacter) in rhsCharacters.enumerated() {
                let cost = lhsCharacter == rhsCharacter ? 0 : 1
                let value = min(
                    previous[rhsIndex + 1] + 1,
                    current[rhsIndex] + 1,
                    previous[rhsIndex] + cost
                )
                current.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit {
                return limit + 1
            }
            previous = current
        }
        return previous.last ?? limit + 1
    }

    private func visibleTokenRange(in scriptTokens: [ScriptTokenInfo]) -> Range<Int> {
        guard !scriptTokens.isEmpty else { return 0..<0 }
        let lower = scriptTokens.firstIndex { $0.range.upperBound > transcriptVisibleUTF16Range.lowerBound } ?? scriptTokens.count
        let upper = scriptTokens.firstIndex { $0.range.lowerBound >= transcriptVisibleUTF16Range.upperBound } ?? scriptTokens.count
        return lower..<max(lower, upper)
    }

    private func scriptProgress(at matchedIndex: Int, in scriptTokens: [ScriptTokenInfo]) -> (lineCompletedFraction: Double, spokenCharacterEnd: Int) {
        let spokenEnd = scriptTokens[matchedIndex].range.upperBound
        let lineEndOffsets = scriptLineEndOffsetCache.isEmpty ? lineEndOffsets(in: script) : scriptLineEndOffsetCache
        let currentLine = scriptTokens[matchedIndex].lineIndex
        let isLastScriptToken = matchedIndex == scriptTokens.count - 1
        let completedLine = isLastScriptToken ? currentLine : currentLine - 1
        let completedOffset = completedLine >= 0 && completedLine < lineEndOffsets.count ? lineEndOffsets[completedLine] : 0
        let fraction = script.utf16.isEmpty ? 0 : Double(completedOffset) / Double(script.utf16.count)
        return (min(max(fraction, 0), 1), min(max(spokenEnd, 0), script.utf16.count))
    }

    private var promptViewportHeight: CGFloat {
        max(viewportHeight - promptTopPadding - promptBottomPadding, 1)
    }

    private var promptTopPadding: CGFloat {
        12
    }

    private var promptBottomPadding: CGFloat {
        12
    }

    private var promptMeasurementTextWidth: CGFloat {
        max(promptTextWidth, 1)
    }

    private var promptLineHeight: CGFloat {
        max(fontSize * 1.35, 1)
    }

    private func renderedPromptHeight(upToUTF16Offset utf16Offset: Int) -> CGFloat {
        let nsScript = script as NSString
        let clampedOffset = min(max(utf16Offset, 0), nsScript.length)
        guard clampedOffset > 0 else { return 0 }

        let prefix = nsScript.substring(with: NSRange(location: 0, length: clampedOffset)) as NSString
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.35
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: roundedPromptFont(ofSize: fontSize, weight: .regular),
            .paragraphStyle: style
        ]
        let rect = prefix.boundingRect(
            with: CGSize(width: promptMeasurementTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return ceil(rect.height)
    }

    private func roundedPromptFont(ofSize fontSize: CGFloat, weight: UIFont.Weight) -> UIFont {
        let systemFont = UIFont.systemFont(ofSize: fontSize, weight: weight)
        let descriptor = systemFont.fontDescriptor.withDesign(.rounded) ?? systemFont.fontDescriptor
        return UIFont(descriptor: descriptor, size: fontSize)
    }

    private func currentVisibleUTF16Range() -> Range<Int> {
        let textLength = (script as NSString).length
        guard textLength > 0 else { return 0..<0 }
        let visibleTop = max(0, scrollOffset)
        let visibleBottom = min(max(visibleTop + promptViewportHeight, visibleTop), max(renderedPromptHeight(upToUTF16Offset: textLength), 1))
        let lower = utf16Offset(forRenderedHeight: visibleTop, upperBound: textLength)
        let upper = utf16Offset(forRenderedHeight: visibleBottom, upperBound: textLength)
        return min(lower, upper)..<max(lower, upper)
    }

    private func utf16Offset(forRenderedHeight targetHeight: CGFloat, upperBound: Int) -> Int {
        guard targetHeight > 0 else { return 0 }
        var low = 0
        var high = upperBound
        while low < high {
            let mid = (low + high) / 2
            if renderedPromptHeight(upToUTF16Offset: mid) < targetHeight {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func updateRecognizedTranscriptDisplayLine(from transcript: String) {
        let delta: String
        if transcript.hasPrefix(previousRecognizedTranscript) {
            delta = String(transcript.dropFirst(previousRecognizedTranscript.count))
        } else {
            recognizedTranscriptDisplayLine = ""
            delta = transcript
        }
        previousRecognizedTranscript = transcript

        let maxCharacters = max(10, Int(promptMeasurementTextWidth / max(fontSize * 0.32, 8)))
        for chunk in transcriptDisplayChunks(from: delta) {
            guard !chunk.isEmpty else { continue }
            let separator = recognizedTranscriptDisplayLine.isEmpty || chunk.count == 1 ? "" : " "
            let candidate = recognizedTranscriptDisplayLine + separator + chunk
            if candidate.count > maxCharacters {
                recognizedTranscriptDisplayLine = chunk.count > maxCharacters ? String(chunk.suffix(maxCharacters)) : chunk
            } else {
                recognizedTranscriptDisplayLine = candidate
            }
        }
    }

    private func transcriptDisplayChunks(from text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            let value = String(scalar)
            if scalar.isCJKToken {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(value)
            } else if scalar.properties.isWhitespace || CharacterSet.newlines.contains(scalar) {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
            } else if scalar.isPromptWordToken {
                current.append(value)
            } else if !current.isEmpty {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func normalizedTokens(_ text: String) -> [String] {
        scriptTokenInfos(in: text).map(\.text)
    }

    private struct ScriptTokenInfo {
        let text: String
        let range: Range<Int>
        let lineIndex: Int
    }

    private func scriptTokenInfos(in text: String) -> [ScriptTokenInfo] {
        let lineStarts = lineStartOffsets(in: text)
        var tokens: [ScriptTokenInfo] = []
        var current = ""
        var currentStart: Int?
        var offset = 0

        func flushCurrent(endingAt endOffset: Int) {
            guard let start = currentStart, !current.isEmpty else {
                current = ""
                currentStart = nil
                return
            }
            let lineIndex = max(0, lineStarts.lastIndex(where: { $0 <= start }) ?? 0)
            tokens.append(ScriptTokenInfo(
                text: Self.normalizedPromptToken(current),
                range: start..<endOffset,
                lineIndex: lineIndex
            ))
            current = ""
            currentStart = nil
        }

        for scalar in text.unicodeScalars {
            let scalarText = String(scalar)
            let scalarLength = scalarText.utf16.count
            let start = offset
            let end = offset + scalarLength

            if scalar.isCJKToken {
                flushCurrent(endingAt: start)
                let lineIndex = max(0, lineStarts.lastIndex(where: { $0 <= start }) ?? 0)
                tokens.append(ScriptTokenInfo(text: Self.normalizedPromptToken(scalarText), range: start..<end, lineIndex: lineIndex))
            } else if scalar.isPromptWordToken {
                if currentStart == nil {
                    currentStart = start
                }
                current.append(scalarText)
            } else {
                flushCurrent(endingAt: start)
            }
            offset = end
        }

        flushCurrent(endingAt: offset)
        return tokens
    }

    private static func normalizedPromptToken(_ token: String) -> String {
        token
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func lineStartOffsets(in text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for scalar in text.unicodeScalars {
            offset += String(scalar).utf16.count
            if scalar == "\n" {
                starts.append(offset)
            }
        }
        return starts
    }

    private func lineEndOffsets(in text: String) -> [Int] {
        var ends: [Int] = []
        var offset = 0
        var lineEnd = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                ends.append(lineEnd)
            }
            offset += String(scalar).utf16.count
            lineEnd = offset
        }
        ends.append(lineEnd)
        return ends
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.11"
        return "V\(version)"
    }

    private var scriptWordCount: Int {
        script
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .count
    }

    private var scrollMode: IOSScrollMode {
        IOSScrollMode(rawValue: scrollModeRaw) ?? .infinite
    }

    private var scrollModeBinding: Binding<IOSScrollMode> {
        Binding(
            get: { scrollMode },
            set: { scrollModeRaw = $0.rawValue }
        )
    }

    private var promptMode: IOSPromptMode {
        if transcriptBasedPrompt {
            return .transcript
        }
        if autoPauseResumeWithLocalMic {
            return .voice
        }
        return .speed
    }

    private var promptModeBinding: Binding<IOSPromptMode> {
        Binding(
            get: { promptMode },
            set: { mode in
                switch mode {
                case .speed:
                    autoPauseResumeWithLocalMic = false
                    transcriptBasedPrompt = false
                case .voice:
                    autoPauseResumeWithLocalMic = true
                    transcriptBasedPrompt = false
                case .transcript:
                    autoPauseResumeWithLocalMic = false
                    transcriptBasedPrompt = true
                }
                updateVoiceMonitor()
            }
        )
    }

    private var countdownBehavior: IOSCountdownBehavior {
        IOSCountdownBehavior(rawValue: countdownBehaviorRaw) ?? .freshStartOnly
    }

    private var shouldWaitForMicInputOnStart: Bool {
        autoPauseResumeWithLocalMic || transcriptBasedPrompt
    }

    private var promptControlShowsPause: Bool {
        !isManuallyPaused && (isRunning || isCountingDown || isWaitingForVoiceStart)
    }

    private var countdownBehaviorBinding: Binding<IOSCountdownBehavior> {
        Binding(
            get: { countdownBehavior },
            set: { countdownBehaviorRaw = $0.rawValue }
        )
    }

    private func handleAppBecameActive() {
        presentationLog("handleAppBecameActive presentationMode=\(isPresentationModeActive)")
        if isPresentationModeActive {
            shouldShowSettingsSurface = false
        } else {
            shouldShowSettingsSurface = true
        }
    }
}

private extension UnicodeScalar {
    var isPromptWordToken: Bool {
        CharacterSet.letters.contains(self) ||
        CharacterSet.decimalDigits.contains(self) ||
        self == "'"
    }

    var isCJKToken: Bool {
        switch value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x3040...0x309F,
             0x30A0...0x30FF,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}

#Preview("Portrait") {
    PresentationCompanionView()
        .frame(width: 393, height: 852)
}

#Preview("Landscape") {
    PresentationCompanionView()
        .frame(width: 852, height: 393)
}
