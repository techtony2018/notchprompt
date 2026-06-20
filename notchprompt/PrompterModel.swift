//
//  PrompterModel.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import Foundation
import Combine
import CoreGraphics
import AppKit

@MainActor
final class PrompterModel: ObservableObject {
    enum ScrollMode: String, CaseIterable {
        case infinite
        case stopAtEnd
    }
    
    enum CountdownBehavior: String, CaseIterable {
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

    struct TranscriptLanguageOption: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let shared = PrompterModel()

    @Published var script: String = """
Paste your script here.

Tip: Use the menu bar icon to start/pause or reset the scroll.
"""
    @Published var sourceLink: String = ""

    @Published var isRunning: Bool = false
    @Published var manualScrollEnabled: Bool = false
    @Published var isOverlayVisible: Bool = true
    @Published var privacyModeEnabled: Bool = true
    @Published var clickContentTogglesPlayback: Bool = true
    @Published var autoPauseResumeWithLocalMic: Bool = false
    @Published var transcriptBasedPrompt: Bool = false
    @Published var transcriptLanguageIdentifier: String = "auto"
    @Published private(set) var detectedTranscriptLanguageIdentifier: String = "en-US"
    @Published var transcriptMatchConsecutiveWords: Int = 3
    @Published var transcriptMaxForwardLookingWords: Int = 20
    @Published var voiceDetectionThresholdDb: Double = -30
    @Published private(set) var voiceInputLevelDb: Double = -160
    @Published var voiceControlUnavailableMessage: String?
    @Published var transcriptUnavailableMessage: String?
    @Published private(set) var detectedVoiceWordsPerMinute: Double?
    @Published private(set) var recognizedTranscript: String = ""
    @Published private(set) var recognizedTranscriptDisplayLine: String = ""
    @Published private(set) var transcriptProgressFraction: Double = 0
    @Published private(set) var transcriptSpokenCharacterEnd: Int = 0
    @Published private(set) var scriptProgressCharacterEnd: Int = 0
    @Published private(set) var transcriptProgressToken: UUID = UUID()
    @Published private(set) var hasStartedSession: Bool = false
    @Published private(set) var isCountingDown: Bool = false
    @Published var countdownSeconds: Int = 3
    @Published var countdownBehavior: CountdownBehavior = .freshStartOnly
    @Published private(set) var countdownRemaining: Int = 0
    @Published private(set) var didReachEndInStopMode: Bool = false

    // Visual / behavior tuning
    @Published var secondsPerLine: Double = 5
    @Published var fontSize: Double = 20
    @Published var overlayWidth: Double = 600
    @Published var overlayHeight: Double = 150
    @Published var backgroundOpacity: Double = 0.58
    @Published var scrollingPaceLines: Double = 2
    @Published var scrollMode: ScrollMode = .infinite
    /// 0 means "auto" (prefer built-in display)
    @Published var selectedScreenID: CGDirectDisplayID = 0
    // Fraction of the viewport height to fade at top and bottom.
    let edgeFadeFraction: Double = 0.20

    // Used to signal an immediate reset to the scrolling view.
    @Published private(set) var resetToken: UUID = UUID()
    @Published private(set) var jumpBackToken: UUID = UUID()
    @Published private(set) var jumpBackDistancePoints: CGFloat = 0
    @Published private(set) var manualScrollToken: UUID = UUID()
    @Published private(set) var manualScrollDeltaPoints: CGFloat = 0
    @Published private(set) var isManuallyPaused: Bool = false
    @Published private(set) var isWaitingForMicStart: Bool = false
    private(set) var savedScrollPhaseForResume: CGFloat?

    private var countdownTask: Task<Void, Never>?
    private var shouldUseCountdownOnNextStart: Bool = true
    private var isPausedByVoiceMonitor: Bool = false
    private var isVoiceResumeBlockedByMousePause: Bool = false
    private var transcriptMatchedTokenIndex: Int = -1
    private var transcriptConsumedTokenCount: Int = 0
    private var transcriptVisibleUTF16Range: Range<Int> = 0..<Int.max
    private var previousRecognizedTranscript = ""

    static let secondsPerLineRange: ClosedRange<Double> = 1...20
    static let secondsPerLineStep: Double = 1
    static let scrollingPaceLinesRange: ClosedRange<Double> = 1...10
    static let overlayHeightRange: ClosedRange<Double> = 120...720

    private enum DefaultsKey {
        static let hasSavedSession = "hasSavedSession"
        static let script = "script"
        static let sourceLink = "sourceLink"
        static let isRunning = "isRunning"
        static let isOverlayVisible = "isOverlayVisible"
        static let privacyModeEnabled = "privacyModeEnabled"
        static let clickContentTogglesPlayback = "clickContentTogglesPlayback"
        static let clickContentDefaultEnabledMigration = "clickContentDefaultEnabledMigration"
        static let autoPauseResumeWithLocalMic = "autoPauseResumeWithLocalMic"
        static let transcriptBasedPrompt = "transcriptBasedPrompt"
        static let transcriptLanguageIdentifier = "transcriptLanguageIdentifier"
        static let transcriptMatchConsecutiveWords = "transcriptMatchConsecutiveWords"
        static let transcriptMaxForwardLookingWords = "transcriptMaxForwardLookingWords"
        static let voiceDetectionThresholdDb = "voiceDetectionThresholdDb"
        static let secondsPerLine = "secondsPerLine"
        static let lineBasedSpeedMigration = "lineBasedSpeedMigration"
        static let fontSize = "fontSize"
        static let overlayWidth = "overlayWidth"
        static let overlayHeight = "overlayHeight"
        static let backgroundOpacity = "backgroundOpacity"
        static let translucentBackgroundDefaultMigration = "translucentBackgroundDefaultMigration"
        static let scrollingPaceLines = "scrollingPaceLines"
        static let lineBasedPaceMigration = "lineBasedPaceMigration"
        static let countdownSeconds = "countdownSeconds"
        static let countdownBehavior = "countdownBehavior"
        static let scrollMode = "scrollMode"
        static let selectedScreenID = "selectedScreenID"
    }

    private init() {}

    static let transcriptLanguageOptions: [TranscriptLanguageOption] = [
        TranscriptLanguageOption(id: "auto", label: "Auto"),
        TranscriptLanguageOption(id: "en-US", label: "English"),
        TranscriptLanguageOption(id: "zh-Hans", label: "Chinese (Simplified)"),
        TranscriptLanguageOption(id: "zh-Hant", label: "Chinese (Traditional)"),
        TranscriptLanguageOption(id: "ja-JP", label: "Japanese"),
        TranscriptLanguageOption(id: "ko-KR", label: "Korean"),
        TranscriptLanguageOption(id: "es-ES", label: "Spanish"),
        TranscriptLanguageOption(id: "fr-FR", label: "French"),
        TranscriptLanguageOption(id: "de-DE", label: "German"),
        TranscriptLanguageOption(id: "it-IT", label: "Italian"),
        TranscriptLanguageOption(id: "pt-BR", label: "Portuguese"),
        TranscriptLanguageOption(id: "nl-NL", label: "Dutch"),
        TranscriptLanguageOption(id: "ru-RU", label: "Russian"),
        TranscriptLanguageOption(id: "ar-SA", label: "Arabic"),
        TranscriptLanguageOption(id: "he-IL", label: "Hebrew"),
        TranscriptLanguageOption(id: "hi-IN", label: "Hindi"),
        TranscriptLanguageOption(id: "th-TH", label: "Thai")
    ]

    var effectiveTranscriptLanguageIdentifier: String {
        transcriptLanguageIdentifier == "auto" ? detectedTranscriptLanguageIdentifier : transcriptLanguageIdentifier
    }

    var detectedTranscriptLanguageLabel: String {
        Self.transcriptLanguageLabel(for: detectedTranscriptLanguageIdentifier)
    }

    var effectiveTranscriptLanguageLabel: String {
        Self.transcriptLanguageLabel(for: effectiveTranscriptLanguageIdentifier)
    }

    var voiceAutoPauseStatusText: String {
        isVoiceAutoPauseTalking ? "talking" : "paused, talk to continue"
    }

    var promptControlShowsPause: Bool {
        !isManuallyPaused && (isRunning || isCountingDown || isWaitingForMicStart)
    }

    var isVoiceAutoPauseTalking: Bool {
        voiceInputLevelDb >= voiceDetectionThresholdDb
    }

    private var shouldWaitForMicInputOnStart: Bool {
        autoPauseResumeWithLocalMic || transcriptBasedPrompt
    }

    static func transcriptLanguageLabel(for identifier: String) -> String {
        if let option = transcriptLanguageOptions.first(where: { $0.id == identifier }) {
            return option.label
        }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    func refreshDetectedTranscriptLanguage() {
        detectedTranscriptLanguageIdentifier = LocalMicrophoneVoiceMonitor.bestSpeechLocaleIdentifier(for: script)
    }

    func resetTranscriptProgress() {
        recognizedTranscript = ""
        recognizedTranscriptDisplayLine = ""
        previousRecognizedTranscript = ""
        transcriptProgressFraction = 0
        transcriptSpokenCharacterEnd = 0
        scriptProgressCharacterEnd = 0
        transcriptMatchedTokenIndex = -1
        transcriptConsumedTokenCount = 0
        transcriptProgressToken = UUID()
    }

    deinit {
        countdownTask?.cancel()
    }

    func pasteScript(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let wasEmpty = script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        resetTranscriptProgress()
        script = text
        if wasEmpty {
            hasStartedSession = true
        }
    }

    func pasteScript(_ text: String, sourceLink: String) {
        pasteScript(text)
        self.sourceLink = sourceLink.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setAutoPauseResumeWithLocalMic(_ enabled: Bool) {
        autoPauseResumeWithLocalMic = enabled
        if enabled {
            transcriptBasedPrompt = false
        }
    }

    func setTranscriptBasedPrompt(_ enabled: Bool) {
        transcriptBasedPrompt = enabled
        if enabled {
            autoPauseResumeWithLocalMic = false
        }
    }

    func resetScroll() {
        didReachEndInStopMode = false
        shouldUseCountdownOnNextStart = true
        savedScrollPhaseForResume = nil
        isManuallyPaused = false
        resetToken = UUID()
    }

    func resetToFreshStart() {
        stop()
        manualScrollEnabled = false
        isManuallyPaused = false
        isWaitingForMicStart = false
        isPausedByVoiceMonitor = false
        isVoiceResumeBlockedByMousePause = false
        didReachEndInStopMode = false
        hasStartedSession = false
        shouldUseCountdownOnNextStart = true
        savedScrollPhaseForResume = nil
        resetTranscriptProgress()
        resetToken = UUID()
    }

    func saveScrollPhaseForResume(_ phase: CGFloat) {
        savedScrollPhaseForResume = phase
    }

    var promptLineHeightPoints: CGFloat {
        max(CGFloat(fontSize) * 1.25, 1)
    }

    func jumpBack(lines: Double? = nil) {
        let lineCount = lines ?? scrollingPaceLines
        guard lineCount > 0 else { return }
        didReachEndInStopMode = false
        jumpBackDistancePoints = promptLineHeightPoints * CGFloat(lineCount)
        jumpBackToken = UUID()
    }

    func jumpForward(lines: Double? = nil) {
        let lineCount = lines ?? scrollingPaceLines
        guard lineCount > 0 else { return }
        didReachEndInStopMode = false
        hasStartedSession = true
        manualScrollDeltaPoints = promptLineHeightPoints * CGFloat(lineCount)
        manualScrollToken = UUID()
    }

    func handleContentClick(horizontalFraction: CGFloat, clickCount: Int) {
        let multiplier = clickCount >= 2 ? 2.0 : 1.0
        let lines = scrollingPaceLines * multiplier

        if horizontalFraction < (1.0 / 3.0) {
            jumpBack(lines: lines)
        } else if horizontalFraction > (2.0 / 3.0) {
            jumpForward(lines: lines)
        } else {
            toggleFromContentClick()
        }
    }

    func switchPlaybackModeFromOverlayControl() {
        if promptControlShowsPause {
            pauseFromMouseInteraction()
            manualScrollEnabled = true
            didReachEndInStopMode = false
            hasStartedSession = true
            shouldUseCountdownOnNextStart = false
            return
        }

        manualScrollEnabled = false
        resumeFromMouseInteraction()
    }

    func toggleFromContentClick() {
        guard clickContentTogglesPlayback else { return }
        toggleFromMouseInteraction()
    }

    func pauseBecauseVoiceStopped() {
        guard autoPauseResumeWithLocalMic, isRunning || isCountingDown else { return }
        stop()
        isPausedByVoiceMonitor = true
        isManuallyPaused = false
        isWaitingForMicStart = false
        manualScrollEnabled = false
    }

    func resumeBecauseVoiceStarted() {
        guard autoPauseResumeWithLocalMic,
              !isVoiceResumeBlockedByMousePause,
              isPausedByVoiceMonitor,
              !isRunning,
              !isCountingDown else { return }
        isPausedByVoiceMonitor = false
        resumeWithoutCountdown()
    }

    func handleManualScroll(deltaPoints: CGFloat) {
        guard abs(deltaPoints) > 0.01 else { return }

        if !manualScrollEnabled {
            manualScrollEnabled = true
        }

        if isRunning || isCountingDown {
            stop()
            isManuallyPaused = false
            isWaitingForMicStart = false
        }

        didReachEndInStopMode = false
        hasStartedSession = true
        shouldUseCountdownOnNextStart = false
        manualScrollDeltaPoints = deltaPoints
        manualScrollToken = UUID()
    }

    func toggleRunning() {
        if promptControlShowsPause {
            stop()
            isManuallyPaused = true
        } else {
            start()
        }
    }

    func start() {
        if isRunning || isCountingDown {
            return
        }

        isManuallyPaused = false
        isPausedByVoiceMonitor = false
        manualScrollEnabled = false

        if scrollMode == .stopAtEnd, didReachEndInStopMode {
            // Keyboard "start" from end should restart from the top without requiring manual reset.
            resetScroll()
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
            } else {
                beginRunningNow()
            }
            return
        }
        
        beginCountdown(seconds: delay)
    }

    func markReachedEndInStopMode() {
        guard scrollMode == .stopAtEnd else { return }
        didReachEndInStopMode = true
        stop()
    }

    func setScrollMode(_ newMode: ScrollMode) {
        // Entire transition is deferred to avoid publishing inside SwiftUI view updates.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let oldMode = self.scrollMode
            guard oldMode != newMode else { return }
            let wasTerminalStopState = (oldMode == .stopAtEnd && self.didReachEndInStopMode)

            self.scrollMode = newMode

            if newMode == .infinite {
                self.didReachEndInStopMode = false
                if wasTerminalStopState {
                    self.hasStartedSession = true
                    self.isCountingDown = false
                    self.countdownRemaining = 0
                    self.countdownTask?.cancel()
                    self.countdownTask = nil
                    self.shouldUseCountdownOnNextStart = false
                    self.isRunning = true
                }
            }
        }
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        isCountingDown = false
        countdownRemaining = 0
        isRunning = false
        isWaitingForMicStart = false
    }

    func setVoiceMonitorUnavailable(_ message: String?) {
        voiceControlUnavailableMessage = message
        if message != nil {
            autoPauseResumeWithLocalMic = false
            isPausedByVoiceMonitor = false
        }
    }

    func clearVoiceMonitorState() {
        voiceControlUnavailableMessage = nil
        transcriptUnavailableMessage = nil
        isPausedByVoiceMonitor = false
        isVoiceResumeBlockedByMousePause = false
        detectedVoiceWordsPerMinute = nil
        resetTranscriptProgress()
    }

    func updateVoicePace(wordsPerMinute: Double) {
        let clampedWordsPerMinute = clamp(wordsPerMinute, lower: 90, upper: 230)
        detectedVoiceWordsPerMinute = clampedWordsPerMinute
    }

    func updateVoiceInputLevel(db: Double) {
        voiceInputLevelDb = clamp(db, lower: -160, upper: 20)
    }

    func setTranscriptUnavailable(_ message: String?) {
        transcriptUnavailableMessage = message
    }

    func updateTranscript(_ transcript: String, wordsPerMinute: Double?) {
        recognizedTranscript = transcript
        updateRecognizedTranscriptDisplayLine(from: transcript)
        if let wordsPerMinute {
            updateVoicePace(wordsPerMinute: wordsPerMinute)
        }
        guard transcriptBasedPrompt else { return }
        let progress = estimateScriptProgress(from: transcript)
        guard abs(progress.lineCompletedFraction - transcriptProgressFraction) > 0.01 ||
                progress.spokenCharacterEnd != transcriptSpokenCharacterEnd else { return }
        transcriptProgressFraction = progress.lineCompletedFraction
        transcriptSpokenCharacterEnd = progress.spokenCharacterEnd
        scriptProgressCharacterEnd = progress.spokenCharacterEnd
        transcriptProgressToken = UUID()
    }

    func updateTranscriptVisibleUTF16Range(_ range: Range<Int>) {
        let clampedLower = min(max(range.lowerBound, 0), script.utf16.count)
        let clampedUpper = min(max(range.upperBound, clampedLower), script.utf16.count)
        transcriptVisibleUTF16Range = clampedLower..<clampedUpper
        if !transcriptBasedPrompt {
            scriptProgressCharacterEnd = hasStartedSession ? clampedLower : 0
        }
    }

    func setSecondsPerLine(_ value: Double) {
        secondsPerLine = clampedSecondsPerLine(value)
    }

    func adjustSpeed(delta: Double) {
        setSecondsPerLine(secondsPerLine - delta)
    }

    func applySpeedPreset(_ preset: Double) {
        setSecondsPerLine(preset)
    }

    func resizeOverlay(widthDelta: Double, heightDelta: Double) {
        overlayWidth = clamp(overlayWidth + widthDelta, lower: 400, upper: 1200)
        overlayHeight = clamp(overlayHeight + heightDelta, lower: Self.overlayHeightRange.lowerBound, upper: maximumOverlayHeight())
    }

    func maximumOverlayHeight() -> Double {
        let screenHeight = Double(NSScreen.main?.frame.height ?? CGFloat(Self.overlayHeightRange.upperBound))
        return min(Self.overlayHeightRange.upperBound, max(Self.overlayHeightRange.lowerBound, screenHeight - 80))
    }

    var estimatedReadDuration: TimeInterval {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let renderedLineEstimate = max(1, Double(script.utf16.count) / 52.0)
        return renderedLineEstimate * secondsPerLine
    }

    var scriptWordCount: Int {
        script
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .count
    }

    private func estimateScriptProgress(from transcript: String) -> (lineCompletedFraction: Double, spokenCharacterEnd: Int) {
        let scriptTokens = scriptTokenInfos(in: script)
        let transcriptTokens = normalizedTokens(transcript)
        guard !scriptTokens.isEmpty, !transcriptTokens.isEmpty else { return (0, 0) }
        if transcriptConsumedTokenCount > transcriptTokens.count {
            transcriptConsumedTokenCount = 0
        }

        let visibleTokenRange = visibleTokenRange(in: scriptTokens)
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
        guard searchStart < searchEnd else {
            guard transcriptMatchedTokenIndex >= 0 else { return (0, 0) }
            return scriptProgress(at: transcriptMatchedTokenIndex, in: scriptTokens)
        }

        var matchedIndex = anchorIndex
        var matchedTranscriptEnd = transcriptConsumedTokenCount
        let overlap = transcriptMatchedTokenIndex < 0 || !isCurrentAnchorVisible ? 0 : 2
        let transcriptSearchStart = max(0, transcriptConsumedTokenCount - overlap)

        for transcriptStart in transcriptSearchStart..<transcriptTokens.count {
            for scriptStart in searchStart..<searchEnd where scriptTokens[scriptStart].text == transcriptTokens[transcriptStart] {
                var runLength = 0
                while transcriptStart + runLength < transcriptTokens.count,
                      scriptStart + runLength < scriptTokens.count,
                      scriptTokens[scriptStart + runLength].text == transcriptTokens[transcriptStart + runLength] {
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
        return scriptProgress(at: matchedIndex, in: scriptTokens)
    }

    private func visibleTokenRange(in scriptTokens: [ScriptTokenInfo]) -> Range<Int> {
        guard !scriptTokens.isEmpty else { return 0..<0 }
        let lower = scriptTokens.firstIndex { $0.range.upperBound > transcriptVisibleUTF16Range.lowerBound } ?? scriptTokens.count
        let upper = scriptTokens.firstIndex { $0.range.lowerBound >= transcriptVisibleUTF16Range.upperBound } ?? scriptTokens.count
        return lower..<max(lower, upper)
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

        let maxCharacters = max(10, Int(overlayWidth / max(fontSize * 0.42, 7)))
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

    private func scriptProgress(at matchedIndex: Int, in scriptTokens: [ScriptTokenInfo]) -> (lineCompletedFraction: Double, spokenCharacterEnd: Int) {
        let spokenEnd = scriptTokens[matchedIndex].range.upperBound
        let lineEndOffsets = lineEndOffsets(in: script)
        let currentLine = scriptTokens[matchedIndex].lineIndex
        let isLastScriptToken = matchedIndex == scriptTokens.count - 1
        let completedLine = isLastScriptToken ? currentLine : currentLine - 1
        let completedOffset = completedLine >= 0 && completedLine < lineEndOffsets.count ? lineEndOffsets[completedLine] : 0
        let fraction = script.utf16.isEmpty ? 0 : Double(completedOffset) / Double(script.utf16.count)
        return (min(max(fraction, 0), 1), min(max(spokenEnd, 0), script.utf16.count))
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
                text: current.lowercased(),
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
                tokens.append(ScriptTokenInfo(text: scalarText.lowercased(), range: start..<end, lineIndex: lineIndex))
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

    func formattedEstimatedReadDuration() -> String {
        let duration = Int(round(estimatedReadDuration))
        guard duration > 0 else { return "~0s" }
        if duration < 60 {
            return "~\(duration)s"
        }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "~%dm %02ds", minutes, seconds)
    }

    func loadFromDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: DefaultsKey.hasSavedSession) else {
            return
        }

        if let savedScript = defaults.string(forKey: DefaultsKey.script) {
            script = savedScript
        }
        refreshDetectedTranscriptLanguage()
        sourceLink = defaults.string(forKey: DefaultsKey.sourceLink) ?? sourceLink

        privacyModeEnabled = defaults.object(forKey: DefaultsKey.privacyModeEnabled) as? Bool ?? privacyModeEnabled
        if defaults.object(forKey: DefaultsKey.clickContentDefaultEnabledMigration) == nil {
            clickContentTogglesPlayback = true
            defaults.set(true, forKey: DefaultsKey.clickContentDefaultEnabledMigration)
        } else {
            clickContentTogglesPlayback = defaults.object(forKey: DefaultsKey.clickContentTogglesPlayback) as? Bool ?? clickContentTogglesPlayback
        }
        autoPauseResumeWithLocalMic = defaults.object(forKey: DefaultsKey.autoPauseResumeWithLocalMic) as? Bool ?? autoPauseResumeWithLocalMic
        transcriptBasedPrompt = defaults.object(forKey: DefaultsKey.transcriptBasedPrompt) as? Bool ?? transcriptBasedPrompt
        transcriptLanguageIdentifier = defaults.string(forKey: DefaultsKey.transcriptLanguageIdentifier) ?? transcriptLanguageIdentifier
        if !Self.transcriptLanguageOptions.contains(where: { $0.id == transcriptLanguageIdentifier }) {
            transcriptLanguageIdentifier = "auto"
        }
        transcriptMatchConsecutiveWords = Int(clamp(Double(defaults.object(forKey: DefaultsKey.transcriptMatchConsecutiveWords) as? Int ?? transcriptMatchConsecutiveWords), lower: 1, upper: 10))
        transcriptMaxForwardLookingWords = Int(clamp(Double(defaults.object(forKey: DefaultsKey.transcriptMaxForwardLookingWords) as? Int ?? transcriptMaxForwardLookingWords), lower: 5, upper: 100))
        if transcriptBasedPrompt {
            autoPauseResumeWithLocalMic = false
        }
        voiceDetectionThresholdDb = clamp(defaults.object(forKey: DefaultsKey.voiceDetectionThresholdDb) as? Double ?? voiceDetectionThresholdDb, lower: -70, upper: 20)
        isOverlayVisible = defaults.object(forKey: DefaultsKey.isOverlayVisible) as? Bool ?? true
        // Never auto-start on launch; require explicit user start each session.
        isRunning = false
        isCountingDown = false
        countdownRemaining = 0
        hasStartedSession = false
        shouldUseCountdownOnNextStart = true
        isPausedByVoiceMonitor = false
        isVoiceResumeBlockedByMousePause = false
        if defaults.object(forKey: DefaultsKey.lineBasedSpeedMigration) == nil {
            secondsPerLine = 5
            defaults.set(true, forKey: DefaultsKey.lineBasedSpeedMigration)
        } else {
            secondsPerLine = clampedSecondsPerLine(defaults.object(forKey: DefaultsKey.secondsPerLine) as? Double ?? secondsPerLine)
        }
        fontSize = clamp(defaults.object(forKey: DefaultsKey.fontSize) as? Double ?? fontSize, lower: 12, upper: 40)
        overlayWidth = clamp(defaults.object(forKey: DefaultsKey.overlayWidth) as? Double ?? overlayWidth, lower: 400, upper: 1200)
        overlayHeight = clamp(
            defaults.object(forKey: DefaultsKey.overlayHeight) as? Double ?? overlayHeight,
            lower: Self.overlayHeightRange.lowerBound,
            upper: maximumOverlayHeight()
        )
        let savedBackgroundOpacity = defaults.object(forKey: DefaultsKey.backgroundOpacity) as? Double
        if defaults.object(forKey: DefaultsKey.translucentBackgroundDefaultMigration) == nil,
           savedBackgroundOpacity == nil || (savedBackgroundOpacity ?? 0) >= 0.95 {
            backgroundOpacity = 0.58
            defaults.set(true, forKey: DefaultsKey.translucentBackgroundDefaultMigration)
        } else {
            backgroundOpacity = clamp(savedBackgroundOpacity ?? backgroundOpacity, lower: 0.08, upper: 0.92)
        }
        if defaults.object(forKey: DefaultsKey.lineBasedPaceMigration) == nil {
            scrollingPaceLines = 2
            defaults.set(true, forKey: DefaultsKey.lineBasedPaceMigration)
        } else {
            scrollingPaceLines = clamp(defaults.object(forKey: DefaultsKey.scrollingPaceLines) as? Double ?? scrollingPaceLines, lower: Self.scrollingPaceLinesRange.lowerBound, upper: Self.scrollingPaceLinesRange.upperBound)
        }
        countdownSeconds = Int(clamp(Double(defaults.object(forKey: DefaultsKey.countdownSeconds) as? Int ?? countdownSeconds), lower: 0, upper: 10))
        if let rawValue = defaults.string(forKey: DefaultsKey.countdownBehavior),
           let savedBehavior = CountdownBehavior(rawValue: rawValue) {
            countdownBehavior = savedBehavior
        } else {
            countdownBehavior = .freshStartOnly
        }
        if let rawValue = defaults.string(forKey: DefaultsKey.scrollMode),
           let savedMode = ScrollMode(rawValue: rawValue) {
            scrollMode = savedMode
        } else {
            scrollMode = .infinite
        }
        selectedScreenID = CGDirectDisplayID(defaults.object(forKey: DefaultsKey.selectedScreenID) as? UInt32 ?? 0)
    }

    func saveToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: DefaultsKey.hasSavedSession)
        defaults.set(script, forKey: DefaultsKey.script)
        defaults.set(sourceLink, forKey: DefaultsKey.sourceLink)
        defaults.set(isRunning, forKey: DefaultsKey.isRunning)
        defaults.set(isOverlayVisible, forKey: DefaultsKey.isOverlayVisible)
        defaults.set(privacyModeEnabled, forKey: DefaultsKey.privacyModeEnabled)
        defaults.set(clickContentTogglesPlayback, forKey: DefaultsKey.clickContentTogglesPlayback)
        defaults.set(autoPauseResumeWithLocalMic, forKey: DefaultsKey.autoPauseResumeWithLocalMic)
        defaults.set(transcriptBasedPrompt, forKey: DefaultsKey.transcriptBasedPrompt)
        defaults.set(transcriptLanguageIdentifier, forKey: DefaultsKey.transcriptLanguageIdentifier)
        defaults.set(transcriptMatchConsecutiveWords, forKey: DefaultsKey.transcriptMatchConsecutiveWords)
        defaults.set(transcriptMaxForwardLookingWords, forKey: DefaultsKey.transcriptMaxForwardLookingWords)
        defaults.set(voiceDetectionThresholdDb, forKey: DefaultsKey.voiceDetectionThresholdDb)
        defaults.set(secondsPerLine, forKey: DefaultsKey.secondsPerLine)
        defaults.set(fontSize, forKey: DefaultsKey.fontSize)
        defaults.set(overlayWidth, forKey: DefaultsKey.overlayWidth)
        defaults.set(overlayHeight, forKey: DefaultsKey.overlayHeight)
        defaults.set(backgroundOpacity, forKey: DefaultsKey.backgroundOpacity)
        defaults.set(scrollingPaceLines, forKey: DefaultsKey.scrollingPaceLines)
        defaults.set(countdownSeconds, forKey: DefaultsKey.countdownSeconds)
        defaults.set(countdownBehavior.rawValue, forKey: DefaultsKey.countdownBehavior)
        defaults.set(scrollMode.rawValue, forKey: DefaultsKey.scrollMode)
        defaults.set(selectedScreenID, forKey: DefaultsKey.selectedScreenID)
    }

    private func beginCountdown(seconds: Int) {
        countdownTask?.cancel()
        isCountingDown = true
        countdownRemaining = seconds

        countdownTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    isCountingDown = false
                    countdownRemaining = 0
                    countdownTask = nil
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
        countdownTask?.cancel()
        countdownTask = nil
        isCountingDown = false
        countdownRemaining = 0
        hasStartedSession = true
        shouldUseCountdownOnNextStart = false
        isRunning = false
        manualScrollEnabled = false
        isManuallyPaused = false
        isWaitingForMicStart = true
        isVoiceResumeBlockedByMousePause = false
        if autoPauseResumeWithLocalMic {
            isPausedByVoiceMonitor = true
        }
    }
    
    private func beginRunningNow() {
        isCountingDown = false
        countdownRemaining = 0
        hasStartedSession = true
        shouldUseCountdownOnNextStart = false
        isWaitingForMicStart = false
        isManuallyPaused = false
        isRunning = true
    }

    private func resumeWithoutCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        isCountingDown = false
        countdownRemaining = 0
        hasStartedSession = true
        shouldUseCountdownOnNextStart = false
        manualScrollEnabled = false
        isWaitingForMicStart = false
        isManuallyPaused = false
        isRunning = true
    }

    private func toggleFromMouseInteraction() {
        if promptControlShowsPause {
            pauseFromMouseInteraction()
        } else {
            resumeFromMouseInteraction()
        }
    }

    private func pauseFromMouseInteraction() {
        stop()
        isManuallyPaused = true
        isWaitingForMicStart = false
        isPausedByVoiceMonitor = false
        isVoiceResumeBlockedByMousePause = true
    }

    private func resumeFromMouseInteraction() {
        isManuallyPaused = false
        isVoiceResumeBlockedByMousePause = false
        start()
    }

    private func clampedSecondsPerLine(_ value: Double) -> Double {
        let clamped = clamp(value, lower: Self.secondsPerLineRange.lowerBound, upper: Self.secondsPerLineRange.upperBound)
        let step = Self.secondsPerLineStep
        return (clamped / step).rounded() * step
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
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
        case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }
}
