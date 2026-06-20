//
//  LocalMicrophoneVoiceMonitor.swift
//  notchprompt
//

import AVFoundation
import Foundation
import Speech

final class LocalMicrophoneVoiceMonitor {
    private let engine = AVAudioEngine()
    private let onVoiceActivityChanged: @MainActor (Bool) -> Void
    private let onSpeakingPaceChanged: @MainActor (Double) -> Void
    private let onInputLevelChanged: @MainActor (Double) -> Void
    private let onTranscriptChanged: @MainActor (String, Double?) -> Void
    private let onUnavailable: @MainActor (String?) -> Void
    private let onTranscriptUnavailable: @MainActor (String?) -> Void

    private var isMonitoring = false
    private var isVoiceActive = false
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var shouldRestartRecognition = false
    private var recognitionLocaleIdentifier = "en-US"
    private var detectedLocaleIdentifier = "en-US"
    private var voiceStartDate: Date?
    private var lastVoiceDate = Date.distantPast
    private var lastPeakDate = Date.distantPast
    private var recentPeakDates: [Date] = []
    private var wasAbovePeakThreshold = false
    private var lastReportedInputLevelDb: Float = -160

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

    init(
        onVoiceActivityChanged: @escaping @MainActor (Bool) -> Void,
        onSpeakingPaceChanged: @escaping @MainActor (Double) -> Void,
        onInputLevelChanged: @escaping @MainActor (Double) -> Void,
        onTranscriptChanged: @escaping @MainActor (String, Double?) -> Void,
        onUnavailable: @escaping @MainActor (String?) -> Void,
        onTranscriptUnavailable: @escaping @MainActor (String?) -> Void
    ) {
        self.onVoiceActivityChanged = onVoiceActivityChanged
        self.onSpeakingPaceChanged = onSpeakingPaceChanged
        self.onInputLevelChanged = onInputLevelChanged
        self.onTranscriptChanged = onTranscriptChanged
        self.onUnavailable = onUnavailable
        self.onTranscriptUnavailable = onTranscriptUnavailable
    }

    func start() {
        if transcriptTrackingEnabled {
            authorizeSpeechIfNeeded { [weak self] in
                self?.startWithMicrophoneAuthorization()
            }
        } else {
            stopRecognition()
            Task { @MainActor in
                onTranscriptUnavailable(nil)
            }
            startWithMicrophoneAuthorization()
        }
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
                        Task { @MainActor in
                            self?.onUnavailable("Microphone permission was denied.")
                        }
                    }
                }
            }
        case .denied, .restricted:
            stop()
            Task { @MainActor in
                onUnavailable("Microphone permission is unavailable. Enable it in System Settings.")
            }
        @unknown default:
            stop()
            Task { @MainActor in
                onUnavailable("Microphone permission could not be determined.")
            }
        }
    }

    func stop() {
        guard isMonitoring || engine.isRunning || recognitionTask != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stopRecognition()
        isMonitoring = false
        setVoiceActive(false)
        voiceStartDate = nil
        lastVoiceDate = .distantPast
        lastPeakDate = .distantPast
        recentPeakDates.removeAll()
        wasAbovePeakThreshold = false
    }

    func resetTranscriptState() {
        shouldRestartRecognition = false
        stopRecognition()
        recentPeakDates.removeAll()
        lastPeakDate = .distantPast
        wasAbovePeakThreshold = false
        Task { @MainActor in
            onTranscriptChanged("", nil)
        }

        guard isMonitoring, transcriptTrackingEnabled else { return }
        configureRecognitionIfNeeded()
    }

    private func startEngine() {
        stop()
        configureRecognitionIfNeeded()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            Task { @MainActor in
                onUnavailable("No local microphone input was found.")
            }
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            self?.process(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isMonitoring = true
            Task { @MainActor in
                onUnavailable(nil)
            }
        } catch {
            input.removeTap(onBus: 0)
            stopRecognition()
            isMonitoring = false
            Task { @MainActor in
                onUnavailable("Could not start local microphone monitoring.")
            }
        }
    }

    private func authorizeSpeechIfNeeded(_ completion: @escaping () -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            Task { @MainActor in
                onTranscriptUnavailable(nil)
            }
            completion()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    if status == .authorized {
                        Task { @MainActor in
                            self?.onTranscriptUnavailable(nil)
                        }
                    } else {
                        Task { @MainActor in
                            self?.onTranscriptUnavailable("Speech recognition is unavailable; using microphone pace estimate.")
                        }
                    }
                    completion()
                }
            }
        case .denied, .restricted:
            Task { @MainActor in
                onTranscriptUnavailable("Speech recognition is unavailable; using microphone pace estimate.")
            }
            completion()
        @unknown default:
            Task { @MainActor in
                onTranscriptUnavailable("Speech recognition could not be determined; using microphone pace estimate.")
            }
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
        recognitionRequest = request
        shouldRestartRecognition = false
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let transcript = result.bestTranscription.formattedString
                let wordsPerMinute = self.wordsPerMinute(from: result.bestTranscription.segments)
                Task { @MainActor in
                    self.onTranscriptChanged(transcript, wordsPerMinute)
                }
            }

            if error != nil || result?.isFinal == true {
                self.shouldRestartRecognition = self.isMonitoring && self.transcriptTrackingEnabled
                self.stopRecognition()
                self.restartRecognitionIfNeeded()
            }
        }
    }

    private func stopRecognition() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func restartRecognitionIfNeeded() {
        guard shouldRestartRecognition else { return }
        shouldRestartRecognition = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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

        let lowercased = script.lowercased()
        let wordSignals: [(String, [String])] = [
            ("es-ES", [" el ", " la ", " de ", " que ", " para ", " con ", " una ", " los "]),
            ("fr-FR", [" le ", " la ", " de ", " des ", " que ", " pour ", " avec ", " nous "]),
            ("de-DE", [" der ", " die ", " das ", " und ", " mit ", " für ", " nicht ", " eine "]),
            ("it-IT", [" il ", " la ", " che ", " per ", " con ", " una ", " gli ", " non "]),
            ("pt-BR", [" o ", " a ", " que ", " para ", " com ", " uma ", " não ", " os "]),
            ("nl-NL", [" de ", " het ", " een ", " van ", " voor ", " met ", " niet ", " zijn "])
        ]
        let padded = " " + lowercased + " "
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
        reportInputLevelIfNeeded(db)
        let now = Date()
        let activationThresholdDb = Float(voiceDetectionThresholdDb)

        if db >= activationThresholdDb {
            if voiceStartDate == nil {
                voiceStartDate = now
            }
            lastVoiceDate = now
            trackSpeakingPeak(db: db, at: now)

            if !isVoiceActive,
               let voiceStartDate,
               now.timeIntervalSince(voiceStartDate) >= activationDuration {
                setVoiceActive(true)
            }
            return
        }

        voiceStartDate = nil
        wasAbovePeakThreshold = false
        if isVoiceActive, now.timeIntervalSince(lastVoiceDate) >= releaseDuration {
            setVoiceActive(false)
        }
    }

    private func reportInputLevelIfNeeded(_ db: Float) {
        guard abs(db - lastReportedInputLevelDb) >= 1 else { return }
        lastReportedInputLevelDb = db
        Task { @MainActor in
            onInputLevelChanged(Double(db))
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
        let wordsPerMinute = syllablesPerMinute / 1.45

        Task { @MainActor in
            onSpeakingPaceChanged(wordsPerMinute)
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
        guard isVoiceActive != active else { return }
        isVoiceActive = active
        Task { @MainActor in
            onVoiceActivityChanged(active)
        }
    }
}
