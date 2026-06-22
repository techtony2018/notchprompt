//
//  ScrollingTextView.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import AppKit
import SwiftUI

struct ScrollingTextView: View {
    let text: String
    let fontSize: CGFloat
    let secondsPerLine: Double
    let isRunning: Bool
    let hasStartedSession: Bool
    let resetToken: UUID
    let jumpBackToken: UUID
    let jumpBackDistancePoints: CGFloat
    let manualScrollToken: UUID
    let manualScrollDeltaPoints: CGFloat
    let transcriptProgressToken: UUID
    let transcriptProgressFraction: Double
    let transcriptSpokenCharacterEnd: Int
    let transcriptProgressAllowsBackward: Bool
    let transcriptDrivenScrolling: Bool
    let transcriptScrollUponRemainingLines: Int
    let transcriptKeepMatchedWords: Int
    let fadeFraction: CGFloat
    let backgroundOpacity: Double
    let backgroundColor: Color
    let textColor: Color
    let isHovering: Bool
    let scrollMode: PrompterModel.ScrollMode
    let savedScrollPhaseForResume: CGFloat?
    let onSaveScrollPhaseForResume: ((CGFloat) -> Void)?
    let onVisibleUTF16RangeChanged: ((Range<Int>) -> Void)?
    let onReachedEnd: (() -> Void)?

    private static let loopGap: CGFloat = 24
    private static let activeTickInterval: TimeInterval = 1.0 / 60.0
    private static let idleTickInterval: TimeInterval = 1.0 / 8.0

    @State private var contentHeight: CGFloat = 1
    @State private var viewportHeight: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var phase: CGFloat = 0
    @State private var lastTickDate: Date?
    @State private var targetSpeedMultiplier: Double = 1.0
    @State private var currentSpeedMultiplier: Double = 1.0
    @State private var hasReachedEndInStopMode: Bool = false
    @State private var hasMeasuredContentHeight: Bool = false
    @State private var deferredStopTargetPhase: CGFloat? = nil
    @State private var hasLoopedOnceInInfiniteMode: Bool = false
    @State private var lastReportedVisibleRange: Range<Int> = 0..<0

    // Smooth deceleration/acceleration rate (0-1, higher = faster)
    private let speedLerpFactor: Double = 8.0

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var isActivelyAnimating: Bool {
        (isRunning && !isHovering && hasContent && !transcriptDrivenScrolling) || currentSpeedMultiplier > 0.002
    }
    
    private var tickInterval: TimeInterval {
        isActivelyAnimating ? Self.activeTickInterval : Self.idleTickInterval
    }

    private var emptyStateMessage: String {
        "No script yet.\nOpen Settings and paste your script to begin."
    }

    private var initialStateMessage: String {
        "Ready to prompt.\nPress Start to begin countdown."
    }

    private var clampedFadeFraction: CGFloat {
        min(max(fadeFraction, 0), 0.49)
    }

    private var cycleLength: CGFloat {
        max(contentHeight + Self.loopGap, 1)
    }

    private var topFadeClearInset: CGFloat {
        guard viewportHeight > 1 else { return 0 }
        return viewportHeight * clampedFadeFraction
    }

    private var readabilityPadding: CGFloat {
        max(2, fontSize * 0.12)
    }

    private var startAnchorOffset: CGFloat {
        let fallback = max(2, min(fontSize * 0.12, 6))
        guard viewportHeight > 1 else { return fallback }

        let raw = readabilityPadding
        let capped = min(raw, max(8, viewportHeight * 0.12))
        return max(capped, fallback)
    }

    private var topOfScriptPhaseFloor: CGFloat {
        -startAnchorOffset
    }

    private var topNormalizationThreshold: CGFloat {
        max(12, fontSize * 1.6)
    }

    private var displayLineHeight: CGFloat {
        max(fontSize * 1.25, 1)
    }

    private var scrollPointsPerSecond: CGFloat {
        displayLineHeight / max(CGFloat(secondsPerLine), 0.1)
    }

    private var effectiveOffsetY: CGFloat {
        guard hasContent else { return 0 }
        // Always use truncating remainder so we can keep the multi-copy VStack
        // rendering in every mode. This avoids structural view changes on mode switch.
        return -(phase.truncatingRemainder(dividingBy: cycleLength))
    }

    private var endPhase: CGFloat {
        let bottomReadabilityInset = topFadeClearInset + readabilityPadding
        let lastLinePhase = contentHeight - max(0, viewportHeight - bottomReadabilityInset)
        return max(topOfScriptPhaseFloor, lastLinePhase)
    }

    private func repetitionCount(for viewportHeight: CGFloat) -> Int {
        if scrollMode == .stopAtEnd { return 1 }
        let minimumCopies = 3
        let needed = Int(ceil(viewportHeight / cycleLength)) + 2
        return max(minimumCopies, needed)
    }

    var body: some View {
        GeometryReader { viewportProxy in
            TimelineView(.periodic(from: .now, by: tickInterval)) { timeline in
                ZStack(alignment: .topLeading) {
                    if hasContent && hasStartedSession {
                        // Always render repeated copies so toggling between infinite
                        // and stop-at-end never causes a structural view rebuild.
                        let copies = repetitionCount(for: viewportProxy.size.height)
                        VStack(spacing: Self.loopGap) {
                            ForEach(0..<copies, id: \.self) { index in
                                repeatedScrollingContent(at: index)
                            }
                        }
                        .offset(y: effectiveOffsetY)
                    } else if hasContent {
                        Text(initialStateMessage)
                            .font(.system(size: max(fontSize * 0.72, 13), weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .padding(.horizontal, 12)
                    } else {
                        Text(emptyStateMessage)
                            .font(.system(size: max(fontSize * 0.72, 13), weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .padding(.horizontal, 12)
                    }
                }
                .frame(width: viewportProxy.size.width, height: viewportProxy.size.height, alignment: .topLeading)
                .onAppear {
                    viewportWidth = max(viewportProxy.size.width, 0)
                    viewportHeight = max(viewportProxy.size.height, 0)
                    restoreOrResetPhase()
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: viewportProxy.size.width) { _, newWidth in
                    viewportWidth = max(newWidth, 0)
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: viewportProxy.size.height) { _, newHeight in
                    viewportHeight = max(newHeight, 0)
                    normalizeTopAnchorIfNearStart()
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: resetToken) { _, _ in
                    deferredStopTargetPhase = nil
                    resetPhase()
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: text) { _, _ in
                    hasMeasuredContentHeight = false
                    deferredStopTargetPhase = nil
                    resetPhase()
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: jumpBackToken) { _, _ in
                    guard hasContent else { return }
                    hasReachedEndInStopMode = false
                    deferredStopTargetPhase = nil
                    phase = max(phase - max(0, jumpBackDistancePoints), topOfScriptPhaseFloor)
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: manualScrollToken) { _, _ in
                    guard hasContent else { return }
                    applyManualScrollDelta(manualScrollDeltaPoints)
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: transcriptProgressToken) { _, _ in
                    guard hasContent, hasMeasuredContentHeight else { return }
                    applyTranscriptProgress()
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: fontSize) { _, _ in
                    normalizeTopAnchorIfNearStart()
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: scrollMode) { _, _ in
                    hasReachedEndInStopMode = false
                    // Clear any stale target; tick() will lazily recompute on the
                    // very first frame it runs in the new mode, avoiding the race
                    // where tick fires before this handler.
                    deferredStopTargetPhase = nil
                }
                .onChange(of: isRunning) { _, isNowRunning in
                    if !isNowRunning {
                        onSaveScrollPhaseForResume?(phase)
                    }
                    lastTickDate = timeline.date
                }
                .onChange(of: isHovering) { _, _ in
                    lastTickDate = timeline.date
                }
                .onPreferenceChange(ContentHeightPreferenceKey.self) { measured in
                    contentHeight = max(measured, 1)
                    hasMeasuredContentHeight = measured > 1
                    reportVisibleRangeIfNeeded()
                }
                .onChange(of: timeline.date) { _, date in
                    tick(at: date)
                    reportVisibleRangeIfNeeded()
                }
            }
        }
        .mask(edgeFadeMask)
        .overlay(edgeSofteningOverlay)
    }

    @ViewBuilder
    private func repeatedScrollingContent(at index: Int) -> some View {
        if index == 0 {
            scrollingContent(highlightTranscript: shouldHighlightTranscriptCopy(at: index))
                .measureHeight()
        } else {
            scrollingContent(highlightTranscript: shouldHighlightTranscriptCopy(at: index))
        }
    }

    private func shouldHighlightTranscriptCopy(at index: Int) -> Bool {
        guard index == 0 else { return false }
        guard scrollMode != .infinite || !hasLoopedOnceInInfiniteMode else { return false }
        return true
    }

    private func scrollingContent(highlightTranscript: Bool) -> some View {
        Text(attributedPromptText(highlightTranscript: highlightTranscript))
            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributedPromptText(highlightTranscript: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        if let fullStringRange = Range(text.startIndex..<text.endIndex, in: attributed) {
            attributed[fullStringRange].foregroundColor = textColor
        }
        guard highlightTranscript else { return attributed }
        let clampedEnd = min(max(transcriptSpokenCharacterEnd, 0), (text as NSString).length)
        if clampedEnd > 0,
           let stringRange = Range(NSRange(location: 0, length: clampedEnd), in: text),
           let attributedRange = Range(stringRange, in: attributed) {
            attributed[attributedRange].foregroundColor = .blue
            attributed[attributedRange].underlineStyle = .single
        }
        return attributed
    }

    private var edgeFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 1 - clampedFadeFraction),
                .init(color: .black.opacity(0.75), location: 1 - (clampedFadeFraction * 0.68)),
                .init(color: .black.opacity(0.25), location: 1 - (clampedFadeFraction * 0.28)),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var edgeSofteningOverlay: some View {
        GeometryReader { proxy in
            let bandHeight = max(proxy.size.height * clampedFadeFraction * 0.9, 8)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                LinearGradient(
                    colors: [backgroundColor.opacity(0), backgroundColor.opacity(backgroundOpacity * 0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: bandHeight)
                .blur(radius: 2.8)
            }
        }
        .allowsHitTesting(false)
    }

    private func resetPhase() {
        phase = topOfScriptPhaseFloor
        hasReachedEndInStopMode = false
        deferredStopTargetPhase = nil
        hasLoopedOnceInInfiniteMode = false
        lastTickDate = nil
        let desired = desiredSpeedMultiplier()
        currentSpeedMultiplier = desired
        targetSpeedMultiplier = desired
    }

    private func restoreOrResetPhase() {
        guard hasStartedSession, let saved = savedScrollPhaseForResume else {
            resetPhase()
            return
        }
        phase = max(saved, topOfScriptPhaseFloor)
        hasReachedEndInStopMode = false
        deferredStopTargetPhase = nil
        hasLoopedOnceInInfiniteMode = scrollMode == .infinite && phase >= cycleLength
        lastTickDate = nil
        let desired = desiredSpeedMultiplier()
        currentSpeedMultiplier = desired
        targetSpeedMultiplier = desired
    }

    private func normalizeTopAnchorIfNearStart() {
        guard hasContent else { return }
        guard phase <= topNormalizationThreshold else { return }
        phase = topOfScriptPhaseFloor
    }

    private func desiredSpeedMultiplier() -> Double {
        (isRunning && !isHovering && !transcriptDrivenScrolling) ? 1.0 : 0.0
    }

    private func applyManualScrollDelta(_ delta: CGFloat) {
        hasReachedEndInStopMode = false
        deferredStopTargetPhase = nil
        phase += delta
        if scrollMode == .infinite, phase >= cycleLength {
            hasLoopedOnceInInfiniteMode = true
        }

        if scrollMode == .stopAtEnd, hasMeasuredContentHeight {
            phase = min(max(phase, topOfScriptPhaseFloor), endPhase)
            return
        }

        if phase >= cycleLength * 8 || phase <= -(cycleLength * 8) {
            phase = phase.truncatingRemainder(dividingBy: cycleLength)
        }
        phase = max(phase, topOfScriptPhaseFloor)
    }

    private func applyTranscriptProgress() {
        let visiblePhase = visiblePhaseInCurrentCycle()
        let spokenBottom = renderedHeight(upToUTF16Offset: transcriptSpokenCharacterEnd)
        let lineHeight = promptLineHeight
        let remainingLines = CGFloat(max(transcriptScrollUponRemainingLines, 1))
        let threshold = visiblePhase + max(viewportHeight - (remainingLines * lineHeight), 0)
        guard spokenBottom >= threshold else { return }
        let contextOffset = utf16OffsetBeforeMatchedContext(keepingWords: transcriptKeepMatchedWords)
        let visibleTarget = renderedHeight(upToUTF16Offset: contextOffset)
        let target = phaseBaseForCurrentCycle(visiblePhase: visiblePhase) + visibleTarget
        guard transcriptProgressAllowsBackward || target > phase else { return }
        hasReachedEndInStopMode = false
        deferredStopTargetPhase = nil
        if scrollMode == .stopAtEnd {
            phase = min(max(target, topOfScriptPhaseFloor), endPhase)
        } else {
            phase = max(target, topOfScriptPhaseFloor)
            if phase >= cycleLength * 8 || phase <= -(cycleLength * 8) {
                phase = phase.truncatingRemainder(dividingBy: cycleLength)
            }
        }
    }

    private func visiblePhaseInCurrentCycle() -> CGFloat {
        guard scrollMode == .infinite else { return max(phase, 0) }
        let remainder = phase.truncatingRemainder(dividingBy: cycleLength)
        return max(remainder, 0)
    }

    private func phaseBaseForCurrentCycle(visiblePhase: CGFloat) -> CGFloat {
        guard scrollMode == .infinite else { return 0 }
        return phase - visiblePhase
    }

    private var promptLineHeight: CGFloat {
        max(fontSize * 1.35, 1)
    }

    private func utf16OffsetBeforeMatchedContext(keepingWords wordCount: Int) -> Int {
        let nsText = text as NSString
        let clampedEnd = min(max(transcriptSpokenCharacterEnd, 0), nsText.length)
        guard clampedEnd > 0, wordCount > 0 else { return 0 }

        let range = NSRange(location: 0, length: clampedEnd)
        var tokenRanges: [NSRange] = []
        nsText.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, tokenRange, _, _ in
            tokenRanges.append(tokenRange)
        }

        if tokenRanges.count > wordCount {
            return tokenRanges[tokenRanges.count - wordCount].location
        }

        return 0
    }

    private func reportVisibleRangeIfNeeded() {
        guard hasContent, viewportHeight > 1, viewportWidth > 1 else { return }
        let range = visibleUTF16Range()
        guard range != lastReportedVisibleRange else { return }
        lastReportedVisibleRange = range
        onVisibleUTF16RangeChanged?(range)
    }

    private func visibleUTF16Range() -> Range<Int> {
        let textLength = (text as NSString).length
        guard textLength > 0 else { return 0..<0 }
        let visibleTop = max(0, phase.truncatingRemainder(dividingBy: cycleLength))
        let visibleBottom = min(max(visibleTop + viewportHeight, visibleTop), max(contentHeight, 1))
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
            if renderedHeight(upToUTF16Offset: mid) < targetHeight {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func renderedHeight(upToUTF16Offset utf16Offset: Int) -> CGFloat {
        let nsText = text as NSString
        let clampedOffset = min(max(utf16Offset, 0), nsText.length)
        guard clampedOffset > 0 else { return 0 }

        let prefix = nsText.substring(with: NSRange(location: 0, length: clampedOffset)) as NSString
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let rect = prefix.boundingRect(
            with: CGSize(width: max(viewportWidth, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        return ceil(rect.height)
    }

    private func tick(at date: Date) {
        guard hasContent else {
            lastTickDate = date
            return
        }

        // Authoritative per-frame run state; don't rely on onChange timing.
        let shouldRun = (isRunning && !isHovering && !transcriptDrivenScrolling) && !(scrollMode == .stopAtEnd && hasReachedEndInStopMode)
        targetSpeedMultiplier = shouldRun ? 1.0 : 0.0

        let totalDt: CGFloat
        if let lastTickDate {
            totalDt = max(0, min(CGFloat(date.timeIntervalSince(lastTickDate)), 0.25))
        } else {
            totalDt = CGFloat(Self.activeTickInterval)
        }

        self.lastTickDate = date

        // Integrate in short fixed steps to avoid jitter/jumps at very slow/fast speeds.
        var remaining = totalDt
        let maxStep: CGFloat = CGFloat(Self.activeTickInterval)

        while remaining > 0 {
            let step = min(remaining, maxStep)

            let diff = targetSpeedMultiplier - currentSpeedMultiplier
            if abs(diff) > 0.001 {
                currentSpeedMultiplier += diff * min(1.0, speedLerpFactor * step)
            } else {
                currentSpeedMultiplier = targetSpeedMultiplier
            }

            phase += scrollPointsPerSecond * CGFloat(currentSpeedMultiplier) * step
            if scrollMode == .infinite, phase >= cycleLength {
                hasLoopedOnceInInfiniteMode = true
            }

            // Lazily compute the stop target on the first tick after entering
            // stopAtEnd mode. This runs in the same code path that checks the
            // threshold, so there is no race with onChange timing.
            if scrollMode == .stopAtEnd, deferredStopTargetPhase == nil,
               hasMeasuredContentHeight, !hasReachedEndInStopMode {
                let vis = phase.truncatingRemainder(dividingBy: cycleLength)
                let cs = phase - vis
                deferredStopTargetPhase = vis <= endPhase
                    ? cs + endPhase
                    : cs + cycleLength + endPhase
            }

            if scrollMode == .stopAtEnd, hasMeasuredContentHeight,
               let target = deferredStopTargetPhase, phase >= target {
                phase = target
                targetSpeedMultiplier = 0
                currentSpeedMultiplier = 0
                deferredStopTargetPhase = nil
                remaining = 0

                if !hasReachedEndInStopMode {
                    hasReachedEndInStopMode = true
                    onReachedEnd?()
                }
                break
            }

            remaining -= step
        }

        if !isRunning, currentSpeedMultiplier < 0.002 {
            currentSpeedMultiplier = 0
        }

        if scrollMode == .infinite, phase >= cycleLength * 8 {
            phase = phase.truncatingRemainder(dividingBy: cycleLength)
        }
    }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func measureHeight() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
    }
}
