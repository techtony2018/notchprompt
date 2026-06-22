//
//  OverlayWindowController.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import AppKit
import CoreGraphics
import SwiftUI

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Make panel key BEFORE dispatching mouse events so SwiftUI gesture
    /// recognizers process them in a key-window context.  `sendEvent` fires
    /// before any view dispatch, unlike `mouseDown` which fires after.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !isKeyWindow { makeKey() }
        default:
            break
        }
        super.sendEvent(event)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        Task { @MainActor in
            PrompterModel.shared.pasteScript(text)
        }
    }

    @objc func clearScript(_ sender: Any?) {
        Task { @MainActor in
            PrompterModel.shared.script = ""
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let view = contentView else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear", action: #selector(clearScript(_:)), keyEquivalent: ""))
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum OverlayGeometry {
    static func centeredTopFrame(
        screenFrame: NSRect,
        width: CGFloat,
        height: CGFloat,
        padding: CGFloat
    ) -> NSRect {
        let roundedWidth = width.rounded()
        let roundedHeight = height.rounded()
        return NSRect(
            x: (screenFrame.midX - (roundedWidth / 2)).rounded(),
            y: (screenFrame.maxY - roundedHeight - padding).rounded(),
            width: roundedWidth,
            height: roundedHeight
        )
    }
}

@MainActor
final class OverlayWindowController: NSObject {
    private let model: PrompterModel
    private let panel: NSPanel
    // Keep this at 0 to hug the notch/menu bar boundary like other notch-adjacent apps.
    // We still position using `visibleFrame` so we never enter the reserved top strip.
    private let padding: CGFloat = 0
    private let inMenuBarStrip: Bool = true
    private var lastFrame: NSRect?
    private var isApplyingFrame = false
    private var hasPendingReposition = false

    init(model: PrompterModel) {
        self.model = model

        let hosting = ClickThroughHostingView(rootView: OverlayView(model: model))

        let initialFrame = NSRect(x: 0, y: 0, width: model.overlayWidth, height: model.overlayHeight)
        let panel = OverlayPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = Self.overlayLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // panel.isFloatingPanel = true // This overrides level to .floating (3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 1.0
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.sharingType = model.privacyModeEnabled ? .none : .readOnly

        panel.contentView = hosting
        self.panel = panel

        super.init()

        reposition()
    }

    func setVisible(_ isVisible: Bool) {
        if isVisible {
            reposition()
            panel.level = Self.overlayLevel
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func reposition() {
        hasPendingReposition = false
        guard let screen = targetScreen() ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let width = CGFloat(model.overlayWidth)
        let desiredHeight = CGFloat(model.overlayHeight)

        let height = desiredHeight
        let targetFrame = OverlayGeometry.centeredTopFrame(
            screenFrame: screen.frame,
            width: width,
            height: height,
            padding: padding
        )

        if let lastFrame, lastFrame.equalTo(targetFrame) {
            return
        }

        isApplyingFrame = true
        panel.setFrame(targetFrame, display: true, animate: false)
        isApplyingFrame = false
        lastFrame = targetFrame
        
        panel.level = Self.overlayLevel
        panel.alphaValue = 1.0
    }

    func scheduleReposition() {
        guard !hasPendingReposition, !isApplyingFrame else { return }
        hasPendingReposition = true
        DispatchQueue.main.async { [weak self] in
            self?.reposition()
        }
    }

    func setPrivacyMode(_ enabled: Bool) {
        panel.sharingType = enabled ? .none : .readOnly
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let descriptors = screens.compactMap { screen -> ScreenDescriptor? in
            guard let id = displayID(for: screen) else { return nil }
            return ScreenDescriptor(
                id: id,
                localizedName: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMenuBarScreen: id == CGMainDisplayID()
            )
        }

        guard let targetID = ScreenSelection.chooseScreenID(
            selectedScreenID: model.selectedScreenID,
            screens: descriptors
        ) else {
            return nil
        }

        return screens.first(where: { displayID(for: $0) == targetID })
    }

    private static var overlayLevel: NSWindow.Level {
        .screenSaver
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(n.uint32Value)
    }
}
