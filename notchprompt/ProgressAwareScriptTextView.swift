//
//  ProgressAwareScriptTextView.swift
//  Presentation Companion
//
//  Created by Codex on 2026-06-19.
//

import AppKit
import SwiftUI

struct ProgressAwareScriptTextView: NSViewRepresentable {
    @Binding var text: String
    var progressUTF16Offset: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        context.coordinator.applyText(text, progressUTF16Offset: progressUTF16Offset, to: textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let clampedOffset = min(max(progressUTF16Offset, 0), (text as NSString).length)
        if textView.string != text || clampedOffset != context.coordinator.lastAppliedProgressOffset {
            context.coordinator.applyText(text, progressUTF16Offset: clampedOffset, to: textView)
        }

        if clampedOffset != context.coordinator.lastScrolledProgressOffset {
            context.coordinator.lastScrolledProgressOffset = clampedOffset
            DispatchQueue.main.async {
                guard textView.window != nil else { return }
                textView.scrollRangeToVisible(NSRange(location: clampedOffset, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        var isApplyingExternalUpdate = false
        var lastAppliedProgressOffset = -1
        var lastScrolledProgressOffset = -1

        init(text: Binding<String>) {
            _text = text
        }

        func applyText(_ string: String, progressUTF16Offset: Int, to textView: NSTextView) {
            let selectedRanges = textView.selectedRanges
            let visibleRect = textView.enclosingScrollView?.contentView.bounds
            let clampedOffset = min(max(progressUTF16Offset, 0), (string as NSString).length)
            let attributed = NSMutableAttributedString(
                string: string,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.textColor
                ]
            )
            if clampedOffset > 0 {
                attributed.addAttribute(
                    .foregroundColor,
                    value: NSColor.systemBlue,
                    range: NSRange(location: 0, length: clampedOffset)
                )
            }

            isApplyingExternalUpdate = true
            textView.textStorage?.setAttributedString(attributed)
            textView.selectedRanges = selectedRanges
            if let visibleRect {
                textView.enclosingScrollView?.contentView.scroll(to: visibleRect.origin)
                textView.enclosingScrollView?.reflectScrolledClipView(textView.enclosingScrollView?.contentView ?? NSClipView())
            }
            lastAppliedProgressOffset = clampedOffset
            isApplyingExternalUpdate = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate,
                  let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
