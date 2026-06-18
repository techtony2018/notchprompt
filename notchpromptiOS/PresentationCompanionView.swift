//
//  PresentationCompanionView.swift
//  Presentation Companion
//

import SwiftUI
import UIKit

struct PresentationCompanionView: View {
    @State private var script = """
Paste your script here.

Tap the center of the prompt to start or pause.
Tap the left third to move back, and the right third to move forward.
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

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            Group {
                if isLandscape {
                    HStack(spacing: 0) {
                        promptSurface
                            .frame(width: proxy.size.width * 0.64)
                        Divider()
                        controls
                    }
                } else {
                    VStack(spacing: 0) {
                        promptSurface
                        Divider()
                        controls
                            .frame(maxHeight: min(proxy.size.height * 0.44, 390))
                    }
                }
            }
            .background(Color(.systemBackground))
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(timer) { date in
            tick(at: date)
        }
        .onChange(of: script) { _, _ in
            resetScroll()
        }
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
                    .padding(.vertical, 28)
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

                TapZoneView { zone, tapCount in
                    handleTap(zone: zone, tapCount: tapCount)
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

    private var controls: some View {
        NavigationStack {
            Form {
                Section("Script") {
                    TextEditor(text: $script)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 130)
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
            }
            .navigationTitle("Presentation Companion")
            .navigationBarTitleDisplayMode(.inline)
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

    private func togglePlayback() {
        isRunning.toggle()
        if isRunning {
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
    }

    private func clampScroll() {
        let maxOffset = max(contentHeight - viewportHeight, 0)
        scrollOffset = min(max(scrollOffset, 0), maxOffset)
        if scrollOffset >= maxOffset, maxOffset > 0 {
            isRunning = false
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
