//
//  LocalMicrophoneVoiceMonitor.swift
//  notchprompt
//

import AVFoundation
import Foundation

final class LocalMicrophoneVoiceMonitor {
    private let engine = AVAudioEngine()
    private let onVoiceActivityChanged: @MainActor (Bool) -> Void
    private let onSpeakingPaceChanged: @MainActor (Double) -> Void
    private let onUnavailable: @MainActor (String?) -> Void

    private var isMonitoring = false
    private var isVoiceActive = false
    private var voiceStartDate: Date?
    private var lastVoiceDate = Date.distantPast
    private var lastPeakDate = Date.distantPast
    private var recentPeakDates: [Date] = []
    private var wasAbovePeakThreshold = false

    var voiceDetectionThresholdDb: Double = 5 {
        didSet {
            voiceDetectionThresholdDb = min(max(voiceDetectionThresholdDb, 0), 30)
        }
    }

    private let activationThresholdBaseDb: Float = -47
    private let peakThresholdOffsetDb: Float = 10
    private let activationDuration: TimeInterval = 0.14
    private let releaseDuration: TimeInterval = 0.85
    private let minimumPeakSpacing: TimeInterval = 0.16

    init(
        onVoiceActivityChanged: @escaping @MainActor (Bool) -> Void,
        onSpeakingPaceChanged: @escaping @MainActor (Double) -> Void,
        onUnavailable: @escaping @MainActor (String?) -> Void
    ) {
        self.onVoiceActivityChanged = onVoiceActivityChanged
        self.onSpeakingPaceChanged = onSpeakingPaceChanged
        self.onUnavailable = onUnavailable
    }

    func start() {
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
        guard isMonitoring || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isMonitoring = false
        setVoiceActive(false)
        voiceStartDate = nil
        lastVoiceDate = .distantPast
        lastPeakDate = .distantPast
        recentPeakDates.removeAll()
        wasAbovePeakThreshold = false
    }

    private func startEngine() {
        stop()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            Task { @MainActor in
                onUnavailable("No local microphone input was found.")
            }
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
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
            isMonitoring = false
            Task { @MainActor in
                onUnavailable("Could not start local microphone monitoring.")
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let db = rmsDb(buffer)
        let now = Date()
        let activationThresholdDb = activationThresholdBaseDb + Float(voiceDetectionThresholdDb)

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

    private func trackSpeakingPeak(db: Float, at now: Date) {
        let peakThresholdDb = activationThresholdBaseDb + Float(voiceDetectionThresholdDb) + peakThresholdOffsetDb
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
