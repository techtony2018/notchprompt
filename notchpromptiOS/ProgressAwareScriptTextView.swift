//
//  ProgressAwareScriptTextView.swift
//  Presentation Companion
//
//  Created by Codex on 2026-06-20.
//

import SwiftUI
import UIKit

struct ProgressAwareScriptTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var progressUTF16Offset: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = EditableScriptTextView()
        textView.onUserTouch = {
            isFocused = true
        }
        textView.accessibilityIdentifier = "scriptEditor"
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        let tapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.focusTextView)
        )
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delaysTouchesBegan = false
        tapRecognizer.delaysTouchesEnded = false
        textView.addGestureRecognizer(tapRecognizer)
        context.coordinator.textView = textView
        context.coordinator.applyText(text, progressUTF16Offset: progressUTF16Offset, to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let clampedOffset = min(max(progressUTF16Offset, 0), (text as NSString).length)
        let needsTextUpdate = textView.text != text
        let needsProgressUpdate = clampedOffset != context.coordinator.lastAppliedProgressOffset
        if needsTextUpdate || (needsProgressUpdate && !textView.isFirstResponder) {
            context.coordinator.applyText(
                text,
                progressUTF16Offset: clampedOffset,
                shouldScrollToProgress: !textView.isFirstResponder,
                to: textView
            )
        }

        if isFocused, !textView.isFirstResponder {
            DispatchQueue.main.async {
                if let editableTextView = textView as? EditableScriptTextView {
                    editableTextView.focusForEditing(retry: true)
                } else {
                    textView.becomeFirstResponder()
                    textView.reloadInputViews()
                }
            }
        } else if !isFocused, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var isFocused: Bool
        weak var textView: UITextView?
        var isApplyingExternalUpdate = false
        var lastAppliedProgressOffset = -1
        var lastScrolledProgressOffset = -1

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            _text = text
            _isFocused = isFocused
        }

        func applyText(
            _ string: String,
            progressUTF16Offset: Int,
            shouldScrollToProgress: Bool = true,
            to textView: UITextView
        ) {
            let textLength = (string as NSString).length
            let selectedRange = textView.selectedRange
            let clampedSelection = NSRange(
                location: min(selectedRange.location, textLength),
                length: min(selectedRange.length, max(0, textLength - min(selectedRange.location, textLength)))
            )
            let contentOffset = textView.contentOffset
            let clampedOffset = min(max(progressUTF16Offset, 0), textLength)
            let shouldScroll = shouldScrollToProgress && clampedOffset != lastScrolledProgressOffset
            let attributed = NSMutableAttributedString(
                string: string,
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                    .foregroundColor: UIColor.label
                ]
            )
            if clampedOffset > 0 {
                attributed.addAttribute(
                    .foregroundColor,
                    value: UIColor.systemBlue,
                    range: NSRange(location: 0, length: clampedOffset)
                )
            }

            isApplyingExternalUpdate = true
            textView.attributedText = attributed
            textView.selectedRange = clampedSelection
            if shouldScroll {
                if clampedOffset > 0 {
                    textView.scrollRangeToVisible(NSRange(location: clampedOffset, length: 0))
                } else {
                    textView.setContentOffset(.zero, animated: false)
                }
                lastScrolledProgressOffset = clampedOffset
            } else {
                textView.setContentOffset(contentOffset, animated: false)
            }
            lastAppliedProgressOffset = clampedOffset
            isApplyingExternalUpdate = false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalUpdate else { return }
            text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isFocused = false
        }

        @objc func focusTextView() {
            isFocused = true
            guard let textView else { return }
            DispatchQueue.main.async {
                if let editableTextView = textView as? EditableScriptTextView {
                    editableTextView.focusForEditing(retry: true)
                } else {
                    textView.becomeFirstResponder()
                    textView.reloadInputViews()
                }
            }
        }
    }
}

private final class EditableScriptTextView: UITextView {
    var onUserTouch: (() -> Void)?

    override var canBecomeFirstResponder: Bool {
        true
    }

    @discardableResult
    func focusForEditing(retry: Bool = false) -> Bool {
        onUserTouch?()
        guard window != nil else { return false }
        let becameFirstResponder = becomeFirstResponder()
        reloadInputViews()
        if retry, !becameFirstResponder {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                _ = self?.focusForEditing()
            }
        }
        return becameFirstResponder
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        DispatchQueue.main.async { [weak self] in
            _ = self?.focusForEditing(retry: true)
        }
    }

    override func accessibilityActivate() -> Bool {
        focusForEditing()
    }
}
