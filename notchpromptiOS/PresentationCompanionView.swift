//
//  PresentationCompanionView.swift
//  Presentation Companion
//

import SwiftUI
import UIKit

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

struct PresentationCompanionView: View {
    @StateObject private var voiceMonitor = IOSLocalMicrophoneVoiceMonitor()
    @StateObject private var pictureInPictureController = IOSPictureInPicturePromptController()
    @State private var script = """
PCompanion helps you rehearse without losing your place.

Tap the center of the prompt to start, pause, or resume.
Tap the left third to move back.
Tap the right third to move forward.
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
    @State private var isRunning = false
    @State private var speed: Double = 70
    @State private var fontSize: Double = 30
    @State private var opacity: Double = 1
    @State private var paceSeconds: Double = 5
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 1
    @State private var contentHeight: CGFloat = 1
    @State private var lastTickDate: Date?
    @State private var isSettingsPresented = false
    @State private var clickContentTogglesPlayback = true
    @State private var scrollMode: IOSScrollMode = .infinite
    @State private var countdownBehavior: IOSCountdownBehavior = .freshStartOnly
    @State private var countdownSeconds = 3
    @State private var isCountingDown = false
    @State private var countdownRemaining = 0
    @State private var shouldUseCountdownOnNextStart = true
    @State private var promptWidthFraction: CGFloat = 0.92
    @State private var promptHeightFraction: CGFloat = 0.72
    @State private var pipWidth: Double = 420
    @State private var pipHeight: Double = 260
    @State private var resizeStartFractions: CGSize?
    @State private var autoPauseResumeWithLocalMic = false
    @State private var autoAdjustSpeedToVoicePace = false
    @State private var voiceDetectionThresholdDb = 5.0
    @State private var isPausedByVoiceMonitor = false
    @State private var isVoiceResumeBlockedByManualPause = false
    @State private var countdownTask: Task<Void, Never>?
    @State private var shouldHideAppWhenPictureInPictureStarts = false
    @State private var isReturningToSettings = false
    @FocusState private var isScriptFocused: Bool

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                controls
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                pipMeasurementView(width: pipContentSize.width)
                    .frame(width: pipContentSize.width, height: 1)
                    .opacity(0)
                    .accessibilityHidden(true)

                PictureInPictureSourceView(
                    controller: pictureInPictureController,
                    configuration: pictureInPictureConfiguration,
                    actions: pictureInPictureActions
                )
                .frame(width: 4, height: 4)
                .accessibilityHidden(true)
            }
            .onAppear {
                viewportHeight = pipContentSize.height
                pictureInPictureController.onDidStart = {
                    handlePictureInPictureDidStart()
                }
                pictureInPictureController.onDidStop = {
                    handlePictureInPictureDidStop()
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(timer) { date in
            tick(at: date)
        }
        .onChange(of: script) { _, _ in
            resetScroll()
        }
        .onChange(of: autoPauseResumeWithLocalMic) { _, _ in
            updateVoiceMonitor()
        }
        .onChange(of: autoAdjustSpeedToVoicePace) { _, _ in
            updateVoiceMonitor()
        }
        .onChange(of: voiceDetectionThresholdDb) { _, thresholdDb in
            voiceMonitor.voiceDetectionThresholdDb = thresholdDb
        }
        .onChange(of: voiceMonitor.isVoiceActive) { _, isVoiceActive in
            handleVoiceActivityChanged(isVoiceActive)
        }
        .onChange(of: voiceMonitor.detectedWordsPerMinute) { _, wordsPerMinute in
            updateSpeakingPace(wordsPerMinute)
        }
        .onDisappear {
            countdownTask?.cancel()
            voiceMonitor.stop()
            pictureInPictureController.onDidStart = nil
            pictureInPictureController.onDidStop = nil
        }
    }

    private func promptWindow(in availableSize: CGSize) -> some View {
        promptSurface
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.26), radius: 18, y: 10)
            .overlay(alignment: .top) {
                promptToolbar
            }
            .overlay(alignment: .bottomTrailing) {
                resizeHandle(in: availableSize)
            }
            .accessibilityIdentifier("promptSurface")
            .accessibilityValue("\(Int(scrollOffset.rounded()))")
    }

    private var pipControlSurface: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Text("PCompanion")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("presentationTitle")

                Text(pictureInPictureStatusText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("pictureInPictureStatus")
            }

            HStack(spacing: 16) {
                Button {
                    resetScroll()
                } label: {
                Image(systemName: "arrow.counterclockwise")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityLabel("Reset")

                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: (isRunning || isCountingDown) ? "pause.fill" : "play.fill")
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .accessibilityLabel((isRunning || isCountingDown) ? "Pause" : "Play")
                .accessibilityIdentifier("playPauseButton")

                Button {
                    openPictureInPicture()
                } label: {
                    Image(systemName: "pip.enter")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityLabel("Open Picture in Picture")
                .accessibilityIdentifier("pictureInPictureButton")

                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsButton")
            }

            Text("The script is shown in Picture in Picture. This screen only controls the floating prompt.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.54))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("pipControlSurface")
        .accessibilityValue("\(Int(scrollOffset.rounded()))")
    }

    private func pipMeasurementView(width: CGFloat) -> some View {
        Text(script)
            .font(.system(size: fontSize * 0.82, weight: .regular, design: .rounded))
            .lineSpacing(fontSize * 0.35)
            .padding(.horizontal, 18)
            .padding(.top, 58)
            .padding(.bottom, 18)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
            .background(
                GeometryReader { contentProxy in
                    Color.clear
                        .onAppear {
                            contentHeight = contentProxy.size.height
                            viewportHeight = pipContentSize.height
                            clampScroll()
                        }
                        .onChange(of: contentProxy.size.height) { _, height in
                            contentHeight = height
                            viewportHeight = pipContentSize.height
                            clampScroll()
                        }
                }
            )
    }

    private var promptSurface: some View {
        GeometryReader { viewportProxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(opacity)

                Text(script)
                    .font(.system(size: fontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(fontSize * 0.35)
                    .padding(.horizontal, 24)
                    .padding(.top, 72)
                    .padding(.bottom, 28)
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

                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 60)

                    TapZoneView { zone, tapCount in
                        handleTap(zone: zone, tapCount: tapCount)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()
            .onAppear {
                viewportHeight = viewportProxy.size.height
                clampScroll()
            }
            .onChange(of: viewportProxy.size.height) { _, height in
                viewportHeight = height
                clampScroll()
            }
        }
    }

    private var promptToolbar: some View {
        HStack(spacing: 8) {
            Text("PCompanion")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(.white)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("presentationTitle")
                .layoutPriority(0)

            Button {
                togglePlayback()
            } label: {
                Image(systemName: (isRunning || isCountingDown) ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .accessibilityLabel((isRunning || isCountingDown) ? "Pause" : "Play")
            .accessibilityIdentifier("playPauseButton")
            .layoutPriority(1)

            Button {
                guard pictureInPictureController.isSupported else {
                    pictureInPictureController.showUnsupportedMessage()
                    return
                }
                pictureInPictureController.toggle()
            } label: {
                Image(systemName: pictureInPictureController.isActive ? "pip.exit" : "pip.enter")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .opacity(pictureInPictureController.isSupported ? 1 : 0.48)
            .accessibilityLabel(pictureInPictureController.isActive ? "Stop Picture in Picture" : "Start Picture in Picture")
            .accessibilityIdentifier("pictureInPictureButton")
            .layoutPriority(1)

            Button {
                isSettingsPresented = true
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
        .background(
            LinearGradient(
                colors: [.black.opacity(0.74), .black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var controls: some View {
        NavigationStack {
            Form {
                Section("Script") {
                    TextEditor(text: $script)
                        .font(.system(.body, design: .monospaced))
                        .focused($isScriptFocused)
                        .frame(minHeight: 170)
                        .scrollContentBackground(.hidden)
                        .accessibilityIdentifier("scriptEditor")
                }

                Section("Playback") {
                    HStack {
                        Button {
                            resetScroll()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }

                        Spacer()

                        Button {
                            togglePlayback()
                        } label: {
                            Label(
                                (isRunning || isCountingDown) ? "Pause" : "Play",
                                systemImage: (isRunning || isCountingDown) ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel((isRunning || isCountingDown) ? "Pause" : "Play")
                    }

                    sliderRow("Speed", value: $speed, range: 20...180, step: 5, suffix: " pt/s")

                    Picker("Scroll mode", selection: $scrollMode) {
                        Text("Infinite").tag(IOSScrollMode.infinite)
                        Text("Stop at end").tag(IOSScrollMode.stopAtEnd)
                    }
                    .pickerStyle(.segmented)

                    Picker("Countdown", selection: $countdownBehavior) {
                        ForEach(IOSCountdownBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .pickerStyle(.menu)

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

                    sliderRow("Fast forward/backward scrolling pace", value: $paceSeconds, range: 1...30, step: 1, suffix: "s")
                    Toggle("Click content area to start, pause, or resume", isOn: $clickContentTogglesPlayback)
                }

                Section("Appearance") {
                    sliderRow("Font size", value: $fontSize, range: 16...60, step: 1, suffix: " pt")
                    sliderRow("PiP width", value: $pipWidth, range: 300...640, step: 10, suffix: " pt")
                        .onChange(of: pipWidth) { _, _ in
                            viewportHeight = pipContentSize.height
                            clampScroll()
                        }
                    sliderRow("PiP height", value: $pipHeight, range: 180...420, step: 10, suffix: " pt")
                        .onChange(of: pipHeight) { _, _ in
                            viewportHeight = pipContentSize.height
                            clampScroll()
                        }
                    sliderRow("Opacity", value: $opacity, range: 0.35...1, step: 0.05) { value in
                        "\(Int((value * 100).rounded()))%"
                    }
                }

                Section("Voice") {
                    Toggle("Auto pause/resume from local mic", isOn: $autoPauseResumeWithLocalMic)
                    Toggle("Auto adjust speed to speaking pace", isOn: $autoAdjustSpeedToVoicePace)
                    sliderRow("Voice detection threshold", value: $voiceDetectionThresholdDb, range: 0...30, step: 1, suffix: " dB")

                    if voiceMonitor.isMonitoring {
                        Text("Mic: \(voiceMonitor.isVoiceActive ? "voice detected" : "listening") · \(Int(voiceMonitor.inputLevelDb.rounded())) dB")
                            .font(.footnote)
                            .foregroundStyle(voiceMonitor.isVoiceActive ? .green : .secondary)
                    }

                    if let message = voiceMonitor.unavailableMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let wordsPerMinute = voiceMonitor.detectedWordsPerMinute {
                        Text("Detected pace: \(Int(wordsPerMinute.rounded())) wpm")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Picture in Picture") {
                    Button {
                        openPictureInPicture()
                    } label: {
                        Label(
                            pictureInPictureController.isActive ? "Picture in Picture is active" : "Open Picture in Picture",
                            systemImage: "pip.enter"
                        )
                    }
                    .disabled(!pictureInPictureController.isSupported)

                    if !pictureInPictureController.isSupported {
                        Text("Picture in Picture is not available on this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let message = pictureInPictureController.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: appVersionText)
                }
            }
            .navigationTitle("PCompanion")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("configurationSurface")
            .accessibilityValue("\(Int(scrollOffset.rounded()))")
            .scrollDismissesKeyboard(.interactively)
            .background(
                KeyboardDismissOnOutsideInput {
                    isScriptFocused = false
                }
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(appVersionText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isScriptFocused = false
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
            .safeAreaInset(edge: .bottom) {
                Button {
                    togglePlayback()
                } label: {
                    Label(
                        (isRunning || isCountingDown) ? "Pause PiP Prompt" : "Start PiP Prompt",
                        systemImage: (isRunning || isCountingDown) ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel((isRunning || isCountingDown) ? "Pause" : "Play")
                .accessibilityIdentifier("playPauseButton")
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
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

    private func tick(at date: Date) {
        defer { lastTickDate = date }
        guard isRunning else { return }

        let deltaTime = min(max(date.timeIntervalSince(lastTickDate ?? date), 0), 0.25)
        scrollOffset += CGFloat(speed * deltaTime)
        clampScroll()
    }

    private func openPictureInPicture() {
        guard pictureInPictureController.isSupported else {
            pictureInPictureController.showUnsupportedMessage()
            return
        }
        pictureInPictureController.start()
    }

    private func togglePlayback() {
        isScriptFocused = false
        if isRunning || isCountingDown {
            pauseManually()
        } else {
            resumeManually(hideAppAfterPictureInPictureStarts: true)
        }
    }

    private func handleTap(zone: TapZone, tapCount: Int) {
        switch zone {
        case .left:
            jump(seconds: -paceSeconds * Double(tapCount))
        case .center:
            guard clickContentTogglesPlayback else { return }
            togglePlayback()
        case .right:
            jump(seconds: paceSeconds * Double(tapCount))
        }
    }

    private func jump(seconds: Double) {
        scrollOffset += CGFloat(speed * seconds)
        clampScroll()
    }

    private func resetScroll() {
        stopPlayback()
        scrollOffset = 0
        lastTickDate = nil
        isPausedByVoiceMonitor = false
        isVoiceResumeBlockedByManualPause = false
        shouldUseCountdownOnNextStart = true
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
            return
        }

        scrollOffset = min(scrollOffset, maxOffset)
        if scrollMode == .stopAtEnd, scrollOffset >= maxOffset {
            stopPlayback()
        }
    }

    private func pauseManually() {
        stopPlayback()
        isPausedByVoiceMonitor = false
        if autoPauseResumeWithLocalMic {
            isVoiceResumeBlockedByManualPause = true
        }
    }

    private func resumeManually(hideAppAfterPictureInPictureStarts: Bool) {
        isVoiceResumeBlockedByManualPause = false
        startPlayback(hideAppAfterPictureInPictureStarts: hideAppAfterPictureInPictureStarts)
    }

    private func startPlayback(hideAppAfterPictureInPictureStarts: Bool) {
        guard !isRunning, !isCountingDown else { return }

        isPausedByVoiceMonitor = false
        isReturningToSettings = false
        if hideAppAfterPictureInPictureStarts, !pictureInPictureController.isActive {
            shouldHideAppWhenPictureInPictureStarts = true
            openPictureInPicture()
        }

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
            beginRunningNow()
            countdownTask = nil
        }
    }

    private func beginRunningNow() {
        isCountingDown = false
        countdownRemaining = 0
        shouldUseCountdownOnNextStart = false
        isRunning = true
        lastTickDate = nil
        openPictureInPicture()
    }

    private func updateVoiceMonitor() {
        guard autoPauseResumeWithLocalMic || autoAdjustSpeedToVoicePace else {
            voiceMonitor.stop()
            isPausedByVoiceMonitor = false
            isVoiceResumeBlockedByManualPause = false
            return
        }

        voiceMonitor.voiceDetectionThresholdDb = voiceDetectionThresholdDb
        voiceMonitor.start()
    }

    private func handleVoiceActivityChanged(_ isVoiceActive: Bool) {
        guard autoPauseResumeWithLocalMic else { return }

        if isVoiceActive {
            guard isPausedByVoiceMonitor,
                  !isVoiceResumeBlockedByManualPause,
                  !isRunning,
                  !isCountingDown else { return }
            isPausedByVoiceMonitor = false
            startPlayback(hideAppAfterPictureInPictureStarts: false)
            return
        }

        guard isRunning || isCountingDown else { return }
        stopPlayback()
        isPausedByVoiceMonitor = true
        lastTickDate = nil
    }

    private func updateSpeakingPace(_ wordsPerMinute: Double?) {
        guard autoAdjustSpeedToVoicePace,
              let wordsPerMinute else { return }
        let target = 70 * (wordsPerMinute / 160)
        let smoothed = (speed * 0.82) + (target * 0.18)
        speed = min(max(smoothed, 20), 180)
    }

    private func promptWidth(for availableSize: CGSize) -> CGFloat {
        let minimum = min(availableSize.width * 0.62, 280)
        return max(availableSize.width * promptWidthFraction, minimum)
    }

    private func promptHeight(for availableSize: CGSize) -> CGFloat {
        let minimum = min(availableSize.height * 0.48, 260)
        return max(availableSize.height * promptHeightFraction, minimum)
    }

    private func promptPosition(in proxy: GeometryProxy) -> CGPoint {
        let availableSize = proxy.size
        let width = promptWidth(for: availableSize)
        let height = promptHeight(for: availableSize)
        let edgePadding: CGFloat = 10
        let isLandscape = availableSize.width > availableSize.height

        if isLandscape {
            let safeInsets = proxy.safeAreaInsets
            let shouldPinLeft = safeInsets.leading > safeInsets.trailing
            return CGPoint(
                x: shouldPinLeft
                    ? (width / 2) + edgePadding
                    : availableSize.width - (width / 2) - edgePadding,
                y: availableSize.height / 2
            )
        }

        return CGPoint(
            x: availableSize.width / 2,
            y: (height / 2) + edgePadding
        )
    }

    private func resizeHandle(in availableSize: CGSize) -> some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.48), in: Circle())
            .padding(10)
            .accessibilityLabel("Resize prompt window")
            .accessibilityIdentifier("resizeHandle")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = resizeStartFractions ?? CGSize(
                            width: promptWidthFraction,
                            height: promptHeightFraction
                        )
                        resizeStartFractions = start

                        promptWidthFraction = clamp(
                            start.width + value.translation.width / max(availableSize.width, 1),
                            min: 0.48,
                            max: 0.98
                        )
                        promptHeightFraction = clamp(
                            start.height + value.translation.height / max(availableSize.height, 1),
                            min: 0.36,
                            max: 0.94
                        )
                    }
                    .onEnded { _ in
                        resizeStartFractions = nil
                        clampScroll()
                    }
            )
    }

    private func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }

    private var promptWidthBinding: Binding<Double> {
        Binding(
            get: { Double(promptWidthFraction * 100) },
            set: { promptWidthFraction = CGFloat($0 / 100) }
        )
    }

    private var promptHeightBinding: Binding<Double> {
        Binding(
            get: { Double(promptHeightFraction * 100) },
            set: { promptHeightFraction = CGFloat($0 / 100) }
        )
    }

    private var pipContentSize: CGSize {
        CGSize(width: pipWidth, height: pipHeight)
    }

    private var pictureInPictureStatusText: String {
        if let message = pictureInPictureController.statusMessage {
            return message
        }
        if pictureInPictureController.isActive {
            return "Picture in Picture is active"
        }
        if pictureInPictureController.isSupported {
            return "Opening Picture in Picture"
        }
        return "Picture in Picture is not available on this device"
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
        return "V\(version)"
    }

    private var pictureInPictureConfiguration: PictureInPicturePromptConfiguration {
        PictureInPicturePromptConfiguration(
            script: script,
            fontSize: fontSize,
            opacity: opacity,
            scrollOffset: scrollOffset,
            isRunning: isRunning,
            preferredContentSize: pipContentSize
        )
    }

    private var pictureInPictureActions: PictureInPicturePromptActions {
        PictureInPicturePromptActions(
            togglePlayback: {
                togglePlayback()
            },
            toggleContentPlayback: {
                guard clickContentTogglesPlayback else { return }
                togglePlayback()
            },
            jumpBackward: { tapCount in
                jump(seconds: -paceSeconds * Double(tapCount))
            },
            jumpForward: { tapCount in
                jump(seconds: paceSeconds * Double(tapCount))
            },
            reset: {
                resetScroll()
            },
            openSettings: {
                openSettingsFromPictureInPicture()
            }
        )
    }

    private func openSettingsFromPictureInPicture() {
        isScriptFocused = false
        isReturningToSettings = true
        shouldHideAppWhenPictureInPictureStarts = false
        stopPlayback()
        pictureInPictureController.stop()
        if let url = URL(string: "pcompanion://settings") {
            UIApplication.shared.open(url)
        }
    }

    private func handlePictureInPictureDidStart() {
        guard shouldHideAppWhenPictureInPictureStarts else { return }
        shouldHideAppWhenPictureInPictureStarts = false
        hideForegroundAppForPresentation()
    }

    private func handlePictureInPictureDidStop() {
        guard isReturningToSettings else { return }
        isReturningToSettings = false
    }

    private func hideForegroundAppForPresentation() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            UIApplication.shared.sendAction(
                NSSelectorFromString("suspend"),
                to: UIApplication.shared,
                from: nil,
                for: nil
            )
        }
    }
}

private struct KeyboardDismissOnOutsideInput: UIViewRepresentable {
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.dismiss = dismiss
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: uiView)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var dismiss: () -> Void
        private weak var installedWindow: UIWindow?
        private weak var recognizer: UITapGestureRecognizer?

        init(dismiss: @escaping () -> Void) {
            self.dismiss = dismiss
        }

        deinit {
            if let recognizer, let installedWindow {
                installedWindow.removeGestureRecognizer(recognizer)
            }
        }

        func installIfNeeded(from view: UIView) {
            guard let window = view.window, installedWindow !== window else { return }

            if let recognizer, let installedWindow {
                installedWindow.removeGestureRecognizer(recognizer)
            }

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            installedWindow = window
            self.recognizer = recognizer
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            dismiss()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextView {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private enum TapZone {
    case left
    case center
    case right
}

private struct TapZoneView: UIViewRepresentable {
    let onTap: (TapZone, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject {
        var onTap: (TapZone, Int) -> Void

        init(onTap: @escaping (TapZone, Int) -> Void) {
            self.onTap = onTap
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            handle(recognizer, tapCount: 1)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            handle(recognizer, tapCount: 2)
        }

        private func handle(_ recognizer: UITapGestureRecognizer, tapCount: Int) {
            guard let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x
            let third = view.bounds.width / 3

            if x < third {
                onTap(.left, tapCount)
            } else if x > third * 2 {
                onTap(.right, tapCount)
            } else {
                onTap(.center, 1)
            }
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
