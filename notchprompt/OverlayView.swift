//
//  OverlayView.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import AppKit
import SwiftUI

private extension Color {
    /// `#000000` (darkest black for seamless notch blending)
    static let notchBlack = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1.0)
}

/// MacBook-style notch contour:
/// - flat top edge with square top corners
/// - straight side walls
/// - rounded lower corners
private struct AppleNotchShape: InsettableShape {
    /// Lower corner radius relative to height.
    var bottomCornerRadiusRatio: CGFloat = 0.18
    /// Portion of total height used by the straight side wall.
    var sideWallDepthRatio: CGFloat = 0.82
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }

        let w = r.width
        let h = r.height

        // sideWallDepthRatio controls how much vertical wall exists before lower arcs.
        let depthRatio = max(0.60, min(sideWallDepthRatio, 0.95))
        let lowerArcStartY = r.minY + (h * depthRatio)
        let maxBottomRadiusFromDepth = max(0, r.maxY - lowerArcStartY)
        let maxBottomRadiusFromWidth = w * 0.5
        let targetBottomRadius = h * bottomCornerRadiusRatio
        let bottomRadius = max(
            0,
            min(targetBottomRadius, min(maxBottomRadiusFromDepth, maxBottomRadiusFromWidth))
        )

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))

        // Right side wall into large lower corner.
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottomRadius))
        if bottomRadius > 0 {
            p.addArc(
                center: CGPoint(x: r.maxX - bottomRadius, y: r.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        } else {
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }

        p.addLine(to: CGPoint(x: r.minX + bottomRadius, y: r.maxY))
        if bottomRadius > 0 {
            p.addArc(
                center: CGPoint(x: r.minX + bottomRadius, y: r.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        } else {
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }

        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()

        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var s = self
        s.insetAmount += amount
        return s
    }
}

struct OverlayView: View {
    @ObservedObject var model: PrompterModel
    @State private var tooltipText: String?
    @State private var resizeStartSize: CGSize?

    var body: some View {
        // Ratio-driven contour tuned to Apple notch geometry and scaled to the
        // current overlay dimensions.
        let shape = AppleNotchShape()
        let hideTopStrokeHeight: CGFloat = 2

        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(shape)
                // Blur can brighten the surface; keep it effectively off for notch matching.
                .opacity(0.0)

            shape
                .fill(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: model.backgroundOpacity))

            shape
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                // Hard-cut the stroke off at the very top so the edge blends into the notch.
                .mask(
                    VStack(spacing: 0) {
                        Color.clear.frame(height: hideTopStrokeHeight)
                        Color.white
                    }
                )

            // The scroller is hard-clipped (so text truly "cuts off") and we add
            // subtle blur bands at the top/bottom to soften the exit.
            ScrollingTextView(
                text: model.script,
                fontSize: CGFloat(model.fontSize),
                secondsPerLine: model.secondsPerLine,
                isRunning: model.isRunning,
                hasStartedSession: model.hasStartedSession,
                resetToken: model.resetToken,
                jumpBackToken: model.jumpBackToken,
                jumpBackDistancePoints: model.jumpBackDistancePoints,
                manualScrollToken: model.manualScrollToken,
                manualScrollDeltaPoints: model.manualScrollDeltaPoints,
                transcriptProgressToken: model.transcriptProgressToken,
                transcriptProgressFraction: model.transcriptProgressFraction,
                transcriptSpokenCharacterEnd: model.transcriptBasedPrompt ? model.transcriptSpokenCharacterEnd : 0,
                transcriptProgressAllowsBackward: model.transcriptBasedPrompt,
                transcriptDrivenScrolling: model.transcriptBasedPrompt,
                fadeFraction: CGFloat(model.edgeFadeFraction),
                backgroundOpacity: model.backgroundOpacity,
                isHovering: false,
                scrollMode: model.scrollMode,
                savedScrollPhaseForResume: model.savedScrollPhaseForResume,
                onSaveScrollPhaseForResume: { phase in
                    model.saveScrollPhaseForResume(phase)
                },
                onVisibleUTF16RangeChanged: { range in
                    model.updateTranscriptVisibleUTF16Range(range)
                },
                onReachedEnd: {
                    if model.isRunning {
                        model.markReachedEndInStopMode()
                    }
                }
            )
            .padding(.horizontal, 18)
            .padding(.top, 40)
            .padding(.bottom, 44)
            .clipShape(Rectangle())
            .overlay {
                TrackpadScrollCaptureView(
                    onScroll: { delta in
                        model.handleManualScroll(deltaPoints: delta)
                    },
                    onClick: { horizontalFraction, clickCount in
                        model.handleContentClick(horizontalFraction: horizontalFraction, clickCount: clickCount)
                    }
                )
            }

            if shouldShowBottomStatusLine {
                bottomStatusLine
            }

            if !model.isCountingDown {
                HStack {
                    HStack(spacing: 6) {
                        OverlayControlButton(
                            symbol: (model.isRunning || model.isCountingDown) ? "hand.draw.fill" : "play.fill",
                            tooltip: (model.isRunning || model.isCountingDown) ? "Pause and switch to manual trackpad scroll" : "Start auto scroll",
                            onTooltipChange: setTooltip
                        ) {
                            model.switchPlaybackModeFromOverlayControl()
                        }
                        
                        OverlayControlButton(
                            symbol: "arrow.counterclockwise",
                            tooltip: "Reset to fresh start",
                            onTooltipChange: setTooltip
                        ) {
                            model.resetToFreshStart()
                        }

                        OverlayControlButton(
                            symbol: "gearshape",
                            tooltip: "Open settings",
                            onTooltipChange: setTooltip
                        ) {
                            NSApp.sendAction(NSSelectorFromString("openMainWindow"), to: nil, from: nil)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    
                    Spacer(minLength: 8)
                    
                    HStack(spacing: 6) {
                        OverlayControlButton(
                            symbol: "doc.on.clipboard",
                            tooltip: "Paste script from clipboard",
                            onTooltipChange: setTooltip
                        ) {
                            if let text = NSPasteboard.general.string(forType: .string) {
                                model.pasteScript(text)
                            }
                        }

                        OverlayControlButton(
                            symbol: "trash",
                            tooltip: "Clear script",
                            onTooltipChange: setTooltip
                        ) {
                            model.script = ""
                        }

                        OverlayControlButton(
                            symbol: "xmark",
                            tooltip: "Quit Presentation Companion",
                            onTooltipChange: setTooltip
                        ) {
                            NSApp.terminate(nil)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            if let tooltipText {
                Text(tooltipText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: max(model.overlayWidth - 72, 120))
                    .padding(.horizontal, 36)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }

            if model.isCountingDown {
                ZStack {
                    Color.black.opacity(0.92)
                    Text("\(model.countdownRemaining)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }

            resizeHandle
        }
        .frame(width: model.overlayWidth, height: model.overlayHeight)
    }

    private func setTooltip(_ text: String?) {
        tooltipText = text
    }

    private var shouldShowBottomStatusLine: Bool {
        model.autoPauseResumeWithLocalMic || model.transcriptBasedPrompt || !model.recognizedTranscriptDisplayLine.isEmpty
    }

    private var bottomStatusLine: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                statusLeadingLabel
                    .frame(width: 150, alignment: .leading)

                if model.transcriptBasedPrompt {
                    Text(model.recognizedTranscriptDisplayLine)
                        .font(.system(size: max(11, model.fontSize * 0.58), weight: .medium))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.52), in: Capsule())
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var statusLeadingLabel: some View {
        if model.autoPauseResumeWithLocalMic {
            HStack(spacing: 3) {
                Text("Voice:")
                    .foregroundStyle(.white.opacity(0.72))
                Text("\(Int(model.voiceInputLevelDb.rounded())) dB")
                    .foregroundStyle(.red)
            }
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
        } else if model.transcriptBasedPrompt {
            Menu {
                Picker("Speech recognition language", selection: $model.transcriptLanguageIdentifier) {
                    Text("Auto (\(model.detectedTranscriptLanguageLabel))").tag("auto")
                    ForEach(PrompterModel.transcriptLanguageOptions.filter { $0.id != "auto" }) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            } label: {
                Text(model.effectiveTranscriptLanguageLabel)
                    .foregroundStyle(.blue)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.58))
                            .padding(.trailing, 2)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
        } else {
            EmptyView()
        }
    }

    private var resizeHandle: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(10)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let startSize = resizeStartSize ?? CGSize(
                                    width: model.overlayWidth,
                                    height: model.overlayHeight
                                )
                                resizeStartSize = startSize
                                let targetWidth = startSize.width + value.translation.width
                                let targetHeight = startSize.height + value.translation.height
                                model.overlayWidth = min(max(Double(targetWidth), 400), 1200)
                                model.overlayHeight = min(max(Double(targetHeight), PrompterModel.overlayHeightRange.lowerBound), model.maximumOverlayHeight())
                            }
                            .onEnded { _ in
                                resizeStartSize = nil
                            }
                    )
                    .onHover { hovering in
                        setTooltip(hovering ? "Resize prompt window" : nil)
                    }
            }
        }
        .padding(.trailing, 4)
        .padding(.bottom, 4)
    }
}

private struct OverlayControlButton: View {
    let symbol: String
    let tooltip: String
    var isActive: Bool = false
    var repeatWhilePressed: Bool = false
    let onTooltipChange: (String?) -> Void
    let action: () -> Void

    var body: some View {
        // Use SwiftUI Button (not onLongPressGesture) so we benefit from
        // the macOS 15 click-through fix for non-activating panels (FB13720950).
        Button {
            if !repeatWhilePressed { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(
            OverlayCircleButtonStyle(
                isActive: isActive,
                repeatWhilePressed: repeatWhilePressed,
                repeatAction: action
            )
        )
        .onHover { isHovering in
            onTooltipChange(isHovering ? tooltip : nil)
        }
    }
}

/// Button style that provides press-highlight and optional repeat-while-held.
private struct OverlayCircleButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var repeatWhilePressed: Bool = false
    var repeatAction: (() -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed || isActive ? 0.18 : 0.10))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .background {
                if repeatWhilePressed {
                    RepeatWhileHeldHelper(
                        isPressed: configuration.isPressed,
                        action: repeatAction ?? {}
                    )
                }
            }
    }
}

/// Zero-size helper that fires an action on press-down and repeats while held.
private struct RepeatWhileHeldHelper: View {
    let isPressed: Bool
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isPressed) { _, pressed in
                if pressed {
                    action()
                    startRepeating()
                } else {
                    stopRepeating()
                }
            }
            .onDisappear { stopRepeating() }
    }

    private func startRepeating() {
        stopRepeating()
        repeatTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            while !Task.isCancelled {
                await MainActor.run { action() }
                try? await Task.sleep(nanoseconds: 85_000_000)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct TrackpadScrollCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    let onClick: (CGFloat, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll, onClick: onClick)
    }

    func makeNSView(context: Context) -> ScrollCaptureNSView {
        let view = ScrollCaptureNSView()
        view.onScroll = context.coordinator.handleScroll
        view.onClick = context.coordinator.handleClick
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureNSView, context: Context) {
        nsView.onScroll = context.coordinator.handleScroll
        nsView.onClick = context.coordinator.handleClick
    }

    final class Coordinator {
        let onScroll: (CGFloat) -> Void
        let onClick: (CGFloat, Int) -> Void

        init(onScroll: @escaping (CGFloat) -> Void, onClick: @escaping (CGFloat, Int) -> Void) {
            self.onScroll = onScroll
            self.onClick = onClick
        }

        func handleScroll(_ event: NSEvent) {
            let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
            // Use AppKit's system-adjusted delta so manual scrolling follows
            // the user's Natural Scrolling setting.
            onScroll(rawDelta)
        }

        func handleClick(horizontalFraction: CGFloat, clickCount: Int) {
            onClick(horizontalFraction, clickCount)
        }
    }
}

final class ScrollCaptureNSView: NSView {
    var onScroll: ((NSEvent) -> Void)?
    var onClick: ((CGFloat, Int) -> Void)?
    private var pendingSingleClick: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let fraction = bounds.width > 0 ? min(max(location.x / bounds.width, 0), 1) : 0.5
        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onClick?(fraction, event.clickCount)
            return
        }

        let click = DispatchWorkItem { [weak self] in
            self?.onClick?(fraction, 1)
            self?.pendingSingleClick = nil
        }
        pendingSingleClick?.cancel()
        pendingSingleClick = click
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}
