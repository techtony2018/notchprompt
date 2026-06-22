//
//  ContentView.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import SwiftUI
import AppKit
import CoreGraphics

private enum PromptMode: String, CaseIterable {
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

struct ContentView: View {
    @ObservedObject private var model = PrompterModel.shared
    @State private var isLoadLinkSheetPresented = false
    @State private var linkInput = ""
    @State private var isLoadingLink = false
    @State private var loadLinkErrorMessage: String?
    @AppStorage("scriptEditorHeight") private var scriptEditorHeight: Double = 220
    @State private var scriptEditorResizeStartHeight: Double?

    private let rowLabelWidth: CGFloat = 164
    private let valueWidth: CGFloat = 64

    private var promptMode: PromptMode {
        if model.transcriptBasedPrompt {
            return .transcript
        }
        if model.autoPauseResumeWithLocalMic {
            return .voice
        }
        return .speed
    }

    private var promptModeBinding: Binding<PromptMode> {
        Binding(
            get: { promptMode },
            set: { mode in
                switch mode {
                case .speed:
                    model.setAutoPauseResumeWithLocalMic(false)
                    model.setTranscriptBasedPrompt(false)
                case .voice:
                    model.setAutoPauseResumeWithLocalMic(true)
                    model.setTranscriptBasedPrompt(false)
                case .transcript:
                    model.setAutoPauseResumeWithLocalMic(false)
                    model.setTranscriptBasedPrompt(true)
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                scriptSection
                playbackSection
                timeWarningSection
                appearanceSection
                displaySection
                privacySection
                shortcutsSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(ScrollBounceBehaviorModifier())
        .frame(minWidth: 620, minHeight: 460)
        .onChange(of: model.script) { _, _ in
            model.refreshDetectedTranscriptLanguage()
        }
        .onChange(of: model.transcriptMatchConsecutiveWords) { _, _ in
            model.resetTranscriptProgress()
        }
        .onChange(of: model.transcriptMaxForwardLookingWords) { _, _ in
            model.resetTranscriptProgress()
        }
        .onChange(of: model.fuzzyTranscriptMatching) { _, _ in
            model.resetTranscriptProgress()
        }
        .onChange(of: model.timeWarningDurationMinutes) { _, _ in
            model.syncDefaultTimeWarningThresholds()
        }
        .onChange(of: model.timeWarningYellowThresholdMinutes) { _, _ in
            model.normalizeTimeWarningSettings()
        }
        .onChange(of: model.timeWarningRedThresholdMinutes) { _, _ in
            model.normalizeTimeWarningSettings()
        }
        .sheet(isPresented: $isLoadLinkSheetPresented) {
            LoadLinkSheet(
                linkInput: $linkInput,
                isLoading: isLoadingLink,
                errorMessage: loadLinkErrorMessage,
                onCancel: {
                    isLoadLinkSheetPresented = false
                },
                onLoad: {
                    Task {
                        await loadScriptFromLink()
                    }
                }
            )
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Presentation Companion")
                    .font(.title3.weight(.semibold))
                Text("Configure playback, appearance, and display behavior for the overlay.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link(appVersionText, destination: URL(string: "https://github.com/techtony2018/notchprompt")!)
                    .font(.footnote.weight(.medium))
            }

            Spacer(minLength: 16)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.bottom, 2)
    }

    private var scriptSection: some View {
        SettingsSection(title: "Presentation Script") {
            VStack(alignment: .leading, spacing: 6) {
                ProgressAwareScriptTextView(
                    text: $model.script,
                    progressUTF16Offset: model.scriptProgressCharacterEnd
                )
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .frame(height: scriptEditorHeight)

                scriptEditorResizeHandle

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(model.scriptWordCount) words · Estimated read time: \(model.formattedEstimatedReadDuration())")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    HStack(spacing: 4) {
                        Text("Detected: \(model.detectedTranscriptLanguageLabel). Using:")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $model.transcriptLanguageIdentifier) {
                            Text("Auto (\(model.detectedTranscriptLanguageLabel))").tag("auto")
                            ForEach(PrompterModel.transcriptLanguageOptions.filter { $0.id != "auto" }) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                if !model.sourceLink.isEmpty {
                    if let url = URL(string: model.sourceLink) {
                        Link(model.sourceLink, destination: url)
                            .font(.footnote)
                            .lineLimit(2)
                    } else {
                        Text(model.sourceLink)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        model.resetScroll()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }

                    Button {
                        linkInput = ""
                        loadLinkErrorMessage = nil
                        isLoadLinkSheetPresented = true
                    } label: {
                        Label("Load from Link", systemImage: "link")
                    }

                    if isLoadingLink {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading link...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var playbackSection: some View {
        SettingsSection(title: "Playback") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Play in loops",
                    isOn: Binding(
                        get: { model.scrollMode == .infinite },
                        set: { model.setScrollMode($0 ? .infinite : .stopAtEnd) }
                    )
                )

                HStack {
                    Text("Countdown")
                        .frame(width: rowLabelWidth, alignment: .leading)
                    Picker("", selection: $model.countdownBehavior) {
                        ForEach(PrompterModel.CountdownBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer(minLength: 0)
                }

                sliderRow(
                    title: "Countdown duration",
                    valueText: "\(model.countdownSeconds)s",
                    slider: Slider(
                        value: Binding(
                            get: { Double(model.countdownSeconds) },
                            set: { model.countdownSeconds = Int($0.rounded()) }
                        ),
                        in: 0...10,
                        step: 1
                    )
                    .disabled(model.countdownBehavior == .never)
                )

                sliderRow(
                    title: "Forward/backward pace",
                    valueText: "\(Int(model.scrollingPaceLines)) lines",
                    slider: Slider(value: $model.scrollingPaceLines, in: PrompterModel.scrollingPaceLinesRange, step: 1)
                )

                Toggle("Click content area to start, pause, or resume", isOn: $model.clickContentTogglesPlayback)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Scroll mode")
                            .frame(width: rowLabelWidth, alignment: .leading)
                        Picker("", selection: promptModeBinding) {
                            ForEach(PromptMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    if promptMode == .speed {
                        sliderRow(
                            title: "Scroll speed",
                            valueText: "\(Int(model.secondsPerLine.rounded()))s/line",
                            slider: Slider(value: $model.secondsPerLine, in: PrompterModel.secondsPerLineRange, step: PrompterModel.secondsPerLineStep)
                        )
                        .padding(.leading, 18)
                    }

                    if promptMode == .voice {
                        sliderRow(
                            title: "Voice detection threshold",
                            valueText: "\(Int(model.voiceDetectionThresholdDb.rounded())) dB",
                            slider: Slider(value: $model.voiceDetectionThresholdDb, in: -70...20, step: 1)
                        )
                        .padding(.leading, 18)
                    }

                    if promptMode == .transcript {
                        HStack {
                            Text("Match consecutive words")
                                .frame(width: rowLabelWidth, alignment: .leading)
                            Stepper(
                                "\(model.transcriptMatchConsecutiveWords)",
                                value: $model.transcriptMatchConsecutiveWords,
                                in: 1...10
                            )
                            .frame(width: 96, alignment: .leading)
                        }
                        .padding(.leading, 18)

                        HStack {
                            Text("Max forward looking words")
                                .frame(width: rowLabelWidth, alignment: .leading)
                            Stepper(
                                "\(model.transcriptMaxForwardLookingWords)",
                                value: $model.transcriptMaxForwardLookingWords,
                                in: 5...100
                            )
                            .frame(width: 96, alignment: .leading)
                        }
                        .padding(.leading, 18)

                        Toggle("Fuzzy transcript matching", isOn: $model.fuzzyTranscriptMatching)
                            .padding(.leading, 18)
                    }
                    if promptMode == .voice, let message = model.voiceControlUnavailableMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if promptMode == .transcript, let message = model.transcriptUnavailableMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var timeWarningSection: some View {
        SettingsSection(title: "Presentation timing aid") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show timer", isOn: $model.showTimer)

                Toggle("Colored time warning", isOn: $model.timeWarningEnabled)
                    .disabled(!model.showTimer)
                    .opacity(model.showTimer ? 1 : 0.55)

                sliderRow(
                    title: "Full duration",
                    valueText: "\(Int(max(model.timeWarningDurationMinutes.rounded(), 1))) min",
                    slider: Slider(value: clampedTimeBinding($model.timeWarningDurationMinutes, upper: PrompterModel.timeWarningMinutesRange.upperBound), in: PrompterModel.timeWarningMinutesRange, step: 1)
                )
                .disabled(!model.showTimer || !model.timeWarningEnabled)
                .opacity(model.showTimer && model.timeWarningEnabled ? 1 : 0.55)

                sliderRow(
                    title: "Blinking yellow at",
                    valueText: "\(Int(min(max(model.timeWarningYellowThresholdMinutes.rounded(), 1), max(model.timeWarningRedThresholdMinutes.rounded(), 1)))) min",
                    slider: Slider(value: clampedTimeBinding($model.timeWarningYellowThresholdMinutes, upper: max(model.timeWarningRedThresholdMinutes, 1)), in: PrompterModel.timeWarningMinutesRange, step: 1)
                )
                .disabled(!model.showTimer || !model.timeWarningEnabled)
                .opacity(model.showTimer && model.timeWarningEnabled ? 1 : 0.55)

                sliderRow(
                    title: "Red at",
                    valueText: "\(Int(max(model.timeWarningRedThresholdMinutes.rounded(), 1))) min",
                    slider: Slider(value: clampedTimeBinding($model.timeWarningRedThresholdMinutes, upper: PrompterModel.timeWarningMinutesRange.upperBound), in: PrompterModel.timeWarningMinutesRange, step: 1)
                )
                .disabled(!model.showTimer || !model.timeWarningEnabled)
                .opacity(model.showTimer && model.timeWarningEnabled ? 1 : 0.55)
            }
        }
    }

    private func clampedTimeBinding(_ binding: Binding<Double>, upper: Double) -> Binding<Double> {
        Binding(
            get: { min(max(binding.wrappedValue, 1), max(upper, 1)) },
            set: { binding.wrappedValue = min(max($0.rounded(), 1), max(upper, 1)) }
        )
    }

    private var scriptEditorResizeHandle: some View {
        HStack {
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let startHeight = scriptEditorResizeStartHeight ?? scriptEditorHeight
                            scriptEditorResizeStartHeight = startHeight
                            scriptEditorHeight = min(max(startHeight + Double(value.translation.height), 140), 640)
                        }
                        .onEnded { _ in
                            scriptEditorResizeStartHeight = nil
                        }
                )
                .help("Drag to resize script editor")
        }
    }

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    title: "Font size",
                    valueText: "\(Int(model.fontSize))",
                    slider: Slider(value: $model.fontSize, in: 12...40, step: 1)
                )

                sliderRow(
                    title: "Overlay width",
                    valueText: "\(Int(model.overlayWidth))",
                    slider: Slider(value: $model.overlayWidth, in: 400...1200, step: 10)
                )

                sliderRow(
                    title: "Overlay height",
                    valueText: "\(Int(model.overlayHeight))",
                    slider: Slider(value: $model.overlayHeight, in: PrompterModel.overlayHeightRange.lowerBound...model.maximumOverlayHeight(), step: 2)
                )

                sliderRow(
                    title: "Opacity",
                    valueText: "\(Int((model.backgroundOpacity * 100).rounded()))%",
                    slider: Slider(value: $model.backgroundOpacity, in: 0.08...0.92, step: 0.04)
                )
            }
        }
    }

    private var displaySection: some View {
        SettingsSection(title: "Display") {
            HStack {
                Text("Show overlay on")
                    .frame(width: rowLabelWidth, alignment: .leading)
                Picker("", selection: $model.selectedScreenID) {
                    Text("Auto (Built-in)").tag(CGDirectDisplayID(0))
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        Text(screen.localizedName).tag(screenID(for: screen))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer(minLength: 0)
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(title: "Privacy") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show overlay", isOn: $model.isOverlayVisible)
                Toggle("Limit screen sharing capture", isOn: $model.privacyModeEnabled)
                Text("Best effort only. Capture behavior can vary by app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutsSection: some View {
        SettingsSection(title: "Keyboard Shortcuts") {
            VStack(alignment: .leading, spacing: 6) {
                shortcutRow("Option+Command+P", "Start / Pause")
                shortcutRow("Option+Command+R", "Reset scroll")
                shortcutRow("Option+Command+J", "Jump back by the configured line pace")
                shortcutRow("Option+Command+H", "Toggle privacy mode")
                shortcutRow("Option+Command+O", "Toggle overlay visibility")
                shortcutRow("Option+Command+=", "Increase speed")
                shortcutRow("Option+Command+-", "Decrease speed")
            }
        }
    }

    @ViewBuilder
    private func sliderRow<SliderView: View>(
        title: String,
        valueText: String,
        slider: SliderView
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: rowLabelWidth, alignment: .leading)
            slider
            Text(valueText)
                .foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 175, alignment: .leading)
            Text(action)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
    }

    private func screenID(for screen: NSScreen) -> CGDirectDisplayID {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return CGDirectDisplayID(n.uint32Value)
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.11"
        return "V\(version)"
    }

    private func loadScriptFromLink() async {
        guard !isLoadingLink else { return }
        isLoadingLink = true
        loadLinkErrorMessage = nil
        defer { isLoadingLink = false }

        do {
            model.pasteScript(try await ScriptLinkLoader.loadScript(from: linkInput), sourceLink: linkInput)
            isLoadLinkSheetPresented = false
        } catch {
            loadLinkErrorMessage = error.localizedDescription
        }
    }
}

private struct LoadLinkSheet: View {
    @Binding var linkInput: String
    let isLoading: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onLoad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Load from Link")
                .font(.headline)
            Text("Enter an article link to load clean text into Presentation Script.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("https://example.com/article", text: $linkInput)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                Button("Load") {
                    onLoad()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDisplayName("Default")

        ContentView()
            .frame(width: 620, height: 360)
            .previewDisplayName("Compact Height")
    }
}
#endif

private struct ScrollBounceBehaviorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}
