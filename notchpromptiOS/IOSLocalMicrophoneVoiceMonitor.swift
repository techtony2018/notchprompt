//
//  IOSLocalMicrophoneVoiceMonitor.swift
//  Presentation Companion
//

import AVFoundation
import Foundation
import Speech

final class IOSLocalMicrophoneVoiceMonitor: ObservableObject {
    @Published private(set) var isVoiceActive = false
    @Published private(set) var detectedWordsPerMinute: Double?
    @Published private(set) var recognizedTranscript = ""
    @Published private(set) var inputLevelDb: Float = -160
    @Published private(set) var isMonitoring = false
    @Published private(set) var unavailableMessage: String?
    @Published private(set) var transcriptUnavailableMessage: String?

    private let engine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var shouldRestartRecognition = false
    private var recognitionLocaleIdentifier = "en-US"
    private var detectedLocaleIdentifier = "en-US"
    private var currentVoiceActive = false
    private var voiceStartDate: Date?
    private var lastVoiceDate = Date.distantPast
    private var lastPeakDate = Date.distantPast
    private var lastMeterDate = Date.distantPast
    private var lastAudioBufferDate = Date.distantPast
    private var audioStreamSeconds: TimeInterval = 0
    private var recognitionStartAudioSeconds: TimeInterval = 0
    private var lastRecognitionRestartDate = Date.distantPast
    private var recentPeakDates: [Date] = []
    private var wasAbovePeakThreshold = false

    var voiceDetectionThresholdDb: Double = -30 {
        didSet {
            voiceDetectionThresholdDb = min(max(voiceDetectionThresholdDb, -70), 20)
        }
    }
    var transcriptTrackingEnabled = false
    var preferredRecognitionLocaleIdentifier: String? {
        didSet {
            applyRecognitionLocale()
        }
    }
    var scriptText = "" {
        didSet {
            detectedLocaleIdentifier = Self.bestSpeechLocaleIdentifier(for: scriptText)
            applyRecognitionLocale()
        }
    }

    private let peakThresholdOffsetDb: Float = 10
    private let activationDuration: TimeInterval = 0.14
    private let releaseDuration: TimeInterval = 0.85
    private let minimumPeakSpacing: TimeInterval = 0.16

    func start() {
        if transcriptTrackingEnabled {
            authorizeSpeechIfNeeded { [weak self] in
                self?.startWithMicrophoneAuthorization()
            }
            return
        }

        stopRecognition()
        transcriptUnavailableMessage = nil
        startWithMicrophoneAuthorization()
    }

    private func startWithMicrophoneAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startEngine()
                    } else {
                        self?.stop()
                        self?.unavailableMessage = "Microphone permission was denied."
                    }
                }
            }
        case .denied, .restricted:
            stop()
            unavailableMessage = "Microphone permission is unavailable. Enable it in Settings."
        @unknown default:
            stop()
            unavailableMessage = "Microphone permission could not be determined."
        }
    }

    func stop() {
        guard isMonitoring || engine.isRunning || recognitionTask != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stopRecognition()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isMonitoring = false
        setVoiceActive(false)
        detectedWordsPerMinute = nil
        recognizedTranscript = ""
        inputLevelDb = -160
        currentVoiceActive = false
        voiceStartDate = nil
        lastVoiceDate = .distantPast
        lastPeakDate = .distantPast
        lastMeterDate = .distantPast
        lastAudioBufferDate = .distantPast
        audioStreamSeconds = 0
        recognitionStartAudioSeconds = 0
        lastRecognitionRestartDate = .distantPast
        recentPeakDates.removeAll()
        wasAbovePeakThreshold = false
    }

    func resetTranscriptState() {
        shouldRestartRecognition = false
        stopRecognition()
        detectedWordsPerMinute = nil
        recognizedTranscript = ""
        recentPeakDates.removeAll()
        lastPeakDate = .distantPast
        wasAbovePeakThreshold = false
        recognitionStartAudioSeconds = audioStreamSeconds
        lastRecognitionRestartDate = Date()

        guard isMonitoring, transcriptTrackingEnabled else { return }
        configureRecognitionIfNeeded()
    }

    private func startEngine() {
        stop()
        configureRecognitionIfNeeded()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            unavailableMessage = "Could not activate local microphone monitoring."
            return
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            unavailableMessage = "No local microphone input was found."
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lastAudioBufferDate = Date()
            self.audioStreamSeconds += TimeInterval(buffer.frameLength) / max(buffer.format.sampleRate, 1)
            self.recognitionRequest?.append(buffer)
            self.process(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isMonitoring = true
            unavailableMessage = nil
        } catch {
            input.removeTap(onBus: 0)
            stopRecognition()
            isMonitoring = false
            unavailableMessage = "Could not start local microphone monitoring."
        }
    }

    private func authorizeSpeechIfNeeded(_ completion: @escaping () -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            transcriptUnavailableMessage = nil
            completion()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    if status == .authorized {
                        self?.transcriptUnavailableMessage = nil
                    } else {
                        self?.transcriptUnavailableMessage = "Speech recognition is unavailable; using microphone pace estimate."
                    }
                    completion()
                }
            }
        case .denied, .restricted:
            transcriptUnavailableMessage = "Speech recognition is unavailable; using microphone pace estimate."
            completion()
        @unknown default:
            transcriptUnavailableMessage = "Speech recognition could not be determined; using microphone pace estimate."
            completion()
        }
    }

    private func configureRecognitionIfNeeded() {
        guard transcriptTrackingEnabled,
              SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = speechRecognizer,
              recognizer.isAvailable else {
            recognitionRequest = nil
            recognitionTask = nil
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionRequest = request
        shouldRestartRecognition = false
        recognitionStartAudioSeconds = audioStreamSeconds
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let transcript = result.bestTranscription.formattedString
                let wordsPerMinute = self.wordsPerMinute(from: result.bestTranscription.segments)
                let segmentEndAudioSeconds = self.segmentEndAudioSeconds(for: result)
                let recognizerBacklogSeconds = self.audioStreamSeconds - segmentEndAudioSeconds
                #if DEBUG
                let audioLag = Date().timeIntervalSince(self.lastAudioBufferDate)
                NSLog(
                    "PCompanionPerf speech partial=%@ final=%@ onDevice=%@ callbackLag=%.2fs recognizerBacklog=%.2fs stream=%.2fs segmentEnd=%.2fs locale=%@ segments=%d chars=%d",
                    String(!result.isFinal),
                    String(result.isFinal),
                    String(request.requiresOnDeviceRecognition),
                    audioLag,
                    recognizerBacklogSeconds,
                    self.audioStreamSeconds,
                    segmentEndAudioSeconds,
                    self.recognitionLocaleIdentifier,
                    result.bestTranscription.segments.count,
                    transcript.count
                )
                #endif
                if self.shouldRestartRecognitionForBacklog(recognizerBacklogSeconds) {
                    #if DEBUG
                    NSLog(
                        "PCompanionPerf speech restartForBacklog %.2fs stream=%.2fs segmentEnd=%.2fs locale=%@",
                        recognizerBacklogSeconds,
                        self.audioStreamSeconds,
                        segmentEndAudioSeconds,
                        self.recognitionLocaleIdentifier
                    )
                    #endif
                    self.shouldRestartRecognition = self.isMonitoring && self.transcriptTrackingEnabled
                    self.stopRecognition()
                    self.restartRecognitionIfNeeded(delay: 0.05)
                    return
                }
                Task { @MainActor in
                    self.recognizedTranscript = transcript
                    if let wordsPerMinute {
                        self.detectedWordsPerMinute = min(max(wordsPerMinute, 90), 230)
                    }
                }
            }

            if error != nil || result?.isFinal == true {
                self.shouldRestartRecognition = self.isMonitoring && self.transcriptTrackingEnabled
                self.stopRecognition()
                self.restartRecognitionIfNeeded(delay: 0.2)
            }
        }
    }

    private func segmentEndAudioSeconds(for result: SFSpeechRecognitionResult) -> TimeInterval {
        guard let lastSegment = result.bestTranscription.segments.last else {
            return recognitionStartAudioSeconds
        }
        return recognitionStartAudioSeconds + lastSegment.timestamp + lastSegment.duration
    }

    private func shouldRestartRecognitionForBacklog(_ backlogSeconds: TimeInterval) -> Bool {
        guard transcriptTrackingEnabled, backlogSeconds > 3.0 else { return false }
        return Date().timeIntervalSince(lastRecognitionRestartDate) > 2.0
    }

    private func stopRecognition() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func restartRecognitionIfNeeded(delay: TimeInterval) {
        guard shouldRestartRecognition else { return }
        shouldRestartRecognition = false
        lastRecognitionRestartDate = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.isMonitoring,
                  self.transcriptTrackingEnabled,
                  self.recognitionTask == nil else { return }
            self.configureRecognitionIfNeeded()
        }
    }

    private func wordsPerMinute(from segments: [SFTranscriptionSegment]) -> Double? {
        guard let first = segments.first,
              let last = segments.last,
              segments.count >= 2 else { return nil }
        let duration = max(1, (last.timestamp + last.duration) - first.timestamp)
        return Double(segments.count) / duration * 60
    }

    private func applyRecognitionLocale() {
        let localeIdentifier = preferredRecognitionLocaleIdentifier ?? detectedLocaleIdentifier
        guard localeIdentifier != recognitionLocaleIdentifier else { return }
        recognitionLocaleIdentifier = localeIdentifier
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard isMonitoring, transcriptTrackingEnabled else { return }
        stopRecognition()
        configureRecognitionIfNeeded()
    }

    static func bestSpeechLocaleIdentifier(for script: String) -> String {
        let preferred = detectedLocaleCandidates(for: script)
        let supported = SFSpeechRecognizer.supportedLocales()
        for identifier in preferred {
            let locale = Locale(identifier: identifier)
            if supported.contains(locale) {
                return identifier
            }
        }
        for identifier in preferred {
            let prefix = identifier.split(separator: "-").first.map(String.init) ?? identifier
            if let locale = supported.first(where: { $0.identifier == prefix || $0.identifier.hasPrefix(prefix + "_") || $0.identifier.hasPrefix(prefix + "-") }) {
                return locale.identifier.replacingOccurrences(of: "_", with: "-")
            }
        }
        return SFSpeechRecognizer(locale: Locale(identifier: Locale.current.identifier))?.isAvailable == true
            ? Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
            : "en-US"
    }

    static func detectedLocaleCandidates(for script: String) -> [String] {
        var counts: [String: Int] = [:]
        for scalar in script.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF:
                counts["zh-Hans"] = (counts["zh-Hans"] ?? 0) + 1
            case 0x3040...0x30FF:
                counts["ja-JP"] = (counts["ja-JP"] ?? 0) + 3
            case 0xAC00...0xD7AF:
                counts["ko-KR"] = (counts["ko-KR"] ?? 0) + 3
            case 0x0400...0x04FF:
                counts["ru-RU"] = (counts["ru-RU"] ?? 0) + 2
            case 0x0600...0x06FF:
                counts["ar-SA"] = (counts["ar-SA"] ?? 0) + 2
            case 0x0590...0x05FF:
                counts["he-IL"] = (counts["he-IL"] ?? 0) + 2
            case 0x0900...0x097F:
                counts["hi-IN"] = (counts["hi-IN"] ?? 0) + 2
            case 0x0E00...0x0E7F:
                counts["th-TH"] = (counts["th-TH"] ?? 0) + 2
            default:
                break
            }
        }

        let padded = " " + script.lowercased() + " "
        let wordSignals: [(String, [String])] = [
            ("es-ES", [" el ", " la ", " de ", " que ", " para ", " con ", " una ", " los "]),
            ("fr-FR", [" le ", " la ", " de ", " des ", " que ", " pour ", " avec ", " nous "]),
            ("de-DE", [" der ", " die ", " das ", " und ", " mit ", " für ", " nicht ", " eine "]),
            ("it-IT", [" il ", " la ", " che ", " per ", " con ", " una ", " gli ", " non "]),
            ("pt-BR", [" o ", " a ", " que ", " para ", " com ", " uma ", " não ", " os "]),
            ("nl-NL", [" de ", " het ", " een ", " van ", " voor ", " met ", " niet ", " zijn "])
        ]
        for (identifier, words) in wordSignals {
            let score = words.reduce(0) { $0 + (padded.contains($1) ? 1 : 0) }
            if score > 0 {
                counts[identifier] = (counts[identifier] ?? 0) + score
            }
        }

        let ranked = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map(\.key)
        return ranked + ["en-US"]
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let db = rmsDb(buffer)
        let now = Date()
        updateInputLevel(db, at: now)
        let activationThresholdDb = Float(voiceDetectionThresholdDb)

        if db >= activationThresholdDb {
            voiceStartDate = voiceStartDate ?? now
            lastVoiceDate = now
            trackSpeakingPeak(db: db, at: now)

            if !currentVoiceActive {
                setVoiceActive(true)
            }
            return
        }

        voiceStartDate = nil
        wasAbovePeakThreshold = false
        if currentVoiceActive, now.timeIntervalSince(lastVoiceDate) >= releaseDuration {
            setVoiceActive(false)
        }
    }

    private func trackSpeakingPeak(db: Float, at now: Date) {
        let peakThresholdDb = Float(voiceDetectionThresholdDb) + peakThresholdOffsetDb
        let isAbovePeakThreshold = db >= peakThresholdDb
        defer { wasAbovePeakThreshold = isAbovePeakThreshold }

        guard isAbovePeakThreshold, !wasAbovePeakThreshold else { return }
        guard now.timeIntervalSince(lastPeakDate) >= minimumPeakSpacing else { return }

        lastPeakDate = now
        recentPeakDates.append(now)
        let windowStart = now.addingTimeInterval(-8)
        recentPeakDates.removeAll { $0 < windowStart }

        guard recentPeakDates.count >= 3,
              let first = recentPeakDates.first,
              let last = recentPeakDates.last else { return }

        let duration = max(1, last.timeIntervalSince(first))
        let syllablesPerMinute = Double(recentPeakDates.count - 1) / duration * 60
        let wordsPerMinute = min(max(syllablesPerMinute / 1.45, 90), 230)

        Task { @MainActor in
            self.detectedWordsPerMinute = wordsPerMinute
        }
    }

    private func rmsDb(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return -160 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return -160 }

        var sum: Float = 0
        var sampleCount = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
            sampleCount += frameLength
        }

        guard sampleCount > 0 else { return -160 }
        let rms = sqrt(sum / Float(sampleCount))
        return 20 * log10(max(rms, 0.000_000_1))
    }

    private func setVoiceActive(_ active: Bool) {
        guard currentVoiceActive != active else { return }
        currentVoiceActive = active
        Task { @MainActor in
            self.isVoiceActive = active
        }
    }

    private func updateInputLevel(_ db: Float, at now: Date) {
        guard now.timeIntervalSince(lastMeterDate) >= 0.2 else { return }
        lastMeterDate = now
        Task { @MainActor in
            self.inputLevelDb = db
        }
    }
}
