//
//  PresentationCompanionView.swift
//  Presentation Companion
//

import SwiftUI
import UIKit

struct PresentationCompanionView: View {
    @StateObject private var voiceMonitor = IOSLocalMicrophoneVoiceMonitor()
    @State private var script = """
Presentation Companion helps you rehearse without losing your place.

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
    @State private var promptWidthFraction: CGFloat = 0.92
    @State private var promptHeightFraction: CGFloat = 0.72
    @State private var resizeStartFractions: CGSize?
    @State private var autoPauseResumeWithLocalMic = false
    @State private var autoAdjustSpeedToVoicePace = false
    @State private var isPausedByVoiceMonitor = false
    @State private var isVoiceResumeBlockedByManualPause = false
    @FocusState private var isScriptFocused: Bool

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                promptWindow(in: proxy.size)
                    .frame(
                        width: promptWidth(for: proxy.size),
                        height: promptHeight(for: proxy.size)
                    )
                    .position(promptPosition(for: proxy.size))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $isSettingsPresented) {
            controls
        }
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
        .onChange(of: voiceMonitor.isVoiceActive) { _, isVoiceActive in
            handleVoiceActivityChanged(isVoiceActive)
        }
        .onChange(of: voiceMonitor.detectedWordsPerMinute) { _, wordsPerMinute in
            updateSpeakingPace(wordsPerMinute)
        }
        .onDisappear {
            voiceMonitor.stop()
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
        HStack(spacing: 10) {
            Text("Presentation Companion")
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.white)
                .accessibilityIdentifier("presentationTitle")

            Spacer(minLength: 8)

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isRunning ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .accessibilityLabel(isRunning ? "Pause" : "Play")
            .accessibilityIdentifier("playPauseButton")

            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.headline)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.16), in: Circle())
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settingsButton")
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
                            Label(isRunning ? "Pause" : "Play", systemImage: isRunning ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    sliderRow("Speed", value: $speed, range: 20...180, step: 5, suffix: " pt/s")
                    sliderRow("Font size", value: $fontSize, range: 16...60, step: 1, suffix: " pt")
                    sliderRow("Opacity", value: $opacity, range: 0.35...1, step: 0.05) { value in
                        "\(Int((value * 100).rounded()))%"
                    }
                    sliderRow("Fast forward/backward scrolling pace", value: $paceSeconds, range: 1...30, step: 1, suffix: "s")
                }

                Section("Voice") {
                    Toggle("Auto pause/resume from local mic", isOn: $autoPauseResumeWithLocalMic)
                    Toggle("Auto adjust speed to speaking pace", isOn: $autoAdjustSpeedToVoicePace)

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
            }
            .navigationTitle("Presentation Companion")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .background(
                KeyboardDismissOnOutsideInput {
                    isScriptFocused = false
                }
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        isScriptFocused = false
                        isSettingsPresented = false
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isScriptFocused = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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

    private func togglePlayback() {
        isScriptFocused = false
        isSettingsPresented = false

        if isRunning {
            isRunning = false
            isPausedByVoiceMonitor = false
            if autoPauseResumeWithLocalMic {
                isVoiceResumeBlockedByManualPause = true
            }
        } else {
            isRunning = true
            isVoiceResumeBlockedByManualPause = false
            isPausedByVoiceMonitor = false
            lastTickDate = nil
        }
    }

    private func handleTap(zone: TapZone, tapCount: Int) {
        switch zone {
        case .left:
            jump(seconds: -paceSeconds * Double(tapCount))
        case .center:
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
        isRunning = false
        scrollOffset = 0
        lastTickDate = nil
        isPausedByVoiceMonitor = false
        isVoiceResumeBlockedByManualPause = false
    }

    private func clampScroll() {
        let maxOffset = max(contentHeight - viewportHeight, 0)
        scrollOffset = min(max(scrollOffset, 0), maxOffset)
        if scrollOffset >= maxOffset, maxOffset > 0 {
            isRunning = false
            isPausedByVoiceMonitor = false
        }
    }

    private func updateVoiceMonitor() {
        guard autoPauseResumeWithLocalMic || autoAdjustSpeedToVoicePace else {
            voiceMonitor.stop()
            isPausedByVoiceMonitor = false
            isVoiceResumeBlockedByManualPause = false
            return
        }

        voiceMonitor.start()
    }

    private func handleVoiceActivityChanged(_ isVoiceActive: Bool) {
        guard autoPauseResumeWithLocalMic else { return }

        if isVoiceActive {
            guard isPausedByVoiceMonitor,
                  !isVoiceResumeBlockedByManualPause,
                  !isRunning else { return }
            isPausedByVoiceMonitor = false
            isRunning = true
            lastTickDate = nil
            return
        }

        guard isRunning else { return }
        isRunning = false
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

    private func promptPosition(for availableSize: CGSize) -> CGPoint {
        let width = promptWidth(for: availableSize)
        let height = promptHeight(for: availableSize)
        let edgePadding: CGFloat = 10
        let isLandscape = availableSize.width > availableSize.height

        if isLandscape {
            return CGPoint(
                x: availableSize.width - (width / 2) - edgePadding,
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
