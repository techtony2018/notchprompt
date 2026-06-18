//
//  IOSLocalMicrophoneVoiceMonitor.swift
//  Presentation Companion
//

import AVFoundation
import Foundation

final class IOSLocalMicrophoneVoiceMonitor: ObservableObject {
    @Published private(set) var isVoiceActive = false
    @Published private(set) var detectedWordsPerMinute: Double?
    @Published private(set) var unavailableMessage: String?

    private let engine = AVAudioEngine()
    private var isMonitoring = false
    private var currentVoiceActive = false
    private var voiceStartDate: Date?
    private var lastVoiceDate = Date.distantPast
    private var lastPeakDate = Date.distantPast
    private var recentPeakDates: [Date] = []
    private var wasAbovePeakThreshold = false

    private let activationThresholdDb: Float = -42
    private let peakThresholdDb: Float = -32
    private let activationDuration: TimeInterval = 0.14
    private let releaseDuration: TimeInterval = 0.85
    private let minimumPeakSpacing: TimeInterval = 0.16

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
        guard isMonitoring || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isMonitoring = false
        setVoiceActive(false)
        detectedWordsPerMinute = nil
        voiceStartDate = nil
        lastVoiceDate = .distantPast
        lastPeakDate = .distantPast
        recentPeakDates.removeAll()
        wasAbovePeakThreshold = false
    }

    private func startEngine() {
        stop()

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
            self?.process(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isMonitoring = true
            unavailableMessage = nil
        } catch {
            input.removeTap(onBus: 0)
            isMonitoring = false
            unavailableMessage = "Could not start local microphone monitoring."
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let db = rmsDb(buffer)
        let now = Date()

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
}
