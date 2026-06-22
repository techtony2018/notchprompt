//
//  AppDelegate.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option]

    private let model = PrompterModel.shared

    private var statusItem: NSStatusItem?
    private var overlayController: OverlayWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var scriptEditorWindowController: ScriptEditorWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var voiceMonitor: LocalMicrophoneVoiceMonitor?

    private var startPauseItem: NSMenuItem?
    private var showOverlayItem: NSMenuItem?
    private var privacyModeItem: NSMenuItem?
    private var speedUpItem: NSMenuItem?
    private var speedDownItem: NSMenuItem?
    private var shortcutWarningItem: NSMenuItem?
    private var shortcutWarningDetailItem: NSMenuItem?
    private var shortcutWarningSeparator: NSMenuItem?
    private lazy var hotkeyManager = GlobalHotkeyManager { [weak self] command in
        self?.performShortcut(command)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.loadFromDefaults()
        overlayController = OverlayWindowController(model: model)
        overlayController?.setVisible(model.isOverlayVisible)

        setupEditMenu()
        wireModel()
        setVoiceMonitorEnabled(model.autoPauseResumeWithLocalMic || model.transcriptBasedPrompt)
        hotkeyManager.registerAll()
        setupStatusBar()
        installEditKeyHandler()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveToDefaults()
        hotkeyManager.unregisterAll()
        cancellables.removeAll()
    }

    private func wireModel() {
        model.$privacyModeEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.overlayController?.setPrivacyMode(enabled)
            }
            .store(in: &cancellables)
        
        model.$isOverlayVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] isVisible in
                self?.overlayController?.setVisible(isVisible)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(model.$overlayWidth, model.$overlayHeight)
            .removeDuplicates { lhs, rhs in
                Int(lhs.0) == Int(rhs.0) && Int(lhs.1) == Int(rhs.1)
            }
            .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.overlayController?.scheduleReposition()
            }
            .store(in: &cancellables)

        model.$selectedScreenID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.overlayController?.scheduleReposition()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            model.$autoPauseResumeWithLocalMic,
            model.$transcriptBasedPrompt
        )
            .map { $0 || $1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.setVoiceMonitorEnabled(enabled)
            }
            .store(in: &cancellables)

        model.$voiceDetectionThresholdDb
            .removeDuplicates { Int($0.rounded()) == Int($1.rounded()) }
            .receive(on: RunLoop.main)
            .sink { [weak self] thresholdDb in
                self?.voiceMonitor?.voiceDetectionThresholdDb = thresholdDb
            }
            .store(in: &cancellables)

        model.$transcriptBasedPrompt
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldTrackTranscript in
                guard let self, let voiceMonitor = self.voiceMonitor else { return }
                voiceMonitor.transcriptTrackingEnabled = shouldTrackTranscript
                if self.model.autoPauseResumeWithLocalMic || self.model.transcriptBasedPrompt {
                    voiceMonitor.start()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.overlayController?.scheduleReposition()
            }
            .store(in: &cancellables)

        let autosavePublishers: [AnyPublisher<Void, Never>] = [
            model.$script.map { _ in () }.eraseToAnyPublisher(),
            model.$sourceLink.map { _ in () }.eraseToAnyPublisher(),
            model.$isRunning.map { _ in () }.eraseToAnyPublisher(),
            model.$privacyModeEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$clickContentTogglesPlayback.map { _ in () }.eraseToAnyPublisher(),
            model.$autoPauseResumeWithLocalMic.map { _ in () }.eraseToAnyPublisher(),
            model.$transcriptBasedPrompt.map { _ in () }.eraseToAnyPublisher(),
            model.$transcriptLanguageIdentifier.map { _ in () }.eraseToAnyPublisher(),
            model.$transcriptMatchConsecutiveWords.map { _ in () }.eraseToAnyPublisher(),
            model.$transcriptMaxForwardLookingWords.map { _ in () }.eraseToAnyPublisher(),
            model.$fuzzyTranscriptMatching.map { _ in () }.eraseToAnyPublisher(),
            model.$voiceDetectionThresholdDb.map { _ in () }.eraseToAnyPublisher(),
            model.$secondsPerLine.map { _ in () }.eraseToAnyPublisher(),
            model.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            model.$overlayWidth.map { _ in () }.eraseToAnyPublisher(),
            model.$overlayHeight.map { _ in () }.eraseToAnyPublisher(),
            model.$backgroundOpacity.map { _ in () }.eraseToAnyPublisher(),
            model.$promptBackgroundColorHex.map { _ in () }.eraseToAnyPublisher(),
            model.$promptTextColorHex.map { _ in () }.eraseToAnyPublisher(),
            model.$scrollingPaceLines.map { _ in () }.eraseToAnyPublisher(),
            model.$countdownSeconds.map { _ in () }.eraseToAnyPublisher(),
            model.$countdownBehavior.map { _ in () }.eraseToAnyPublisher(),
            model.$scrollMode.map { _ in () }.eraseToAnyPublisher(),
            model.$showTimer.map { _ in () }.eraseToAnyPublisher(),
            model.$timeWarningEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$timeWarningDurationMinutes.map { _ in () }.eraseToAnyPublisher(),
            model.$timeWarningYellowThresholdMinutes.map { _ in () }.eraseToAnyPublisher(),
            model.$timeWarningRedThresholdMinutes.map { _ in () }.eraseToAnyPublisher(),
            model.$timerOverlayOffsetX.map { _ in () }.eraseToAnyPublisher(),
            model.$timerOverlayOffsetY.map { _ in () }.eraseToAnyPublisher(),
            model.$speechVoiceIdentifier.map { _ in () }.eraseToAnyPublisher(),
            model.$speechRate.map { _ in () }.eraseToAnyPublisher(),
            model.$speechPitch.map { _ in () }.eraseToAnyPublisher(),
            model.$speechVolume.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedScreenID.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(autosavePublishers)
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.model.saveToDefaults()
        }
        .store(in: &cancellables)

        model.$script
            .receive(on: RunLoop.main)
            .sink { [weak self] script in
                self?.model.refreshDetectedTranscriptLanguage()
                self?.model.resetTranscriptProgress()
                self?.voiceMonitor?.scriptText = script
                self?.voiceMonitor?.resetTranscriptState()
            }
            .store(in: &cancellables)

        model.$resetToken
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.voiceMonitor?.resetTranscriptState()
            }
            .store(in: &cancellables)

        model.$transcriptLanguageIdentifier
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] identifier in
                self?.voiceMonitor?.preferredRecognitionLocaleIdentifier = identifier == "auto" ? nil : identifier
            }
            .store(in: &cancellables)

        Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.model.tickPresentationTimer(now: date)
            }
            .store(in: &cancellables)
    }

    private func setVoiceMonitorEnabled(_ enabled: Bool) {
        guard enabled else {
            voiceMonitor?.stop()
            voiceMonitor = nil
            model.clearVoiceMonitorState()
            return
        }

        if voiceMonitor == nil {
            voiceMonitor = LocalMicrophoneVoiceMonitor(
                onVoiceActivityChanged: { [weak self] isVoiceActive in
                    guard let self else { return }
                    if isVoiceActive {
                        self.model.resumeBecauseVoiceStarted()
                    } else {
                        self.model.pauseBecauseVoiceStopped()
                    }
                },
                onSpeakingPaceChanged: { [weak self] wordsPerMinute in
                    self?.model.updateVoicePace(wordsPerMinute: wordsPerMinute)
                },
                onInputLevelChanged: { [weak self] db in
                    self?.model.updateVoiceInputLevel(db: db)
                },
                onTranscriptChanged: { [weak self] transcript, wordsPerMinute in
                    self?.model.updateTranscript(transcript, wordsPerMinute: wordsPerMinute)
                },
                onUnavailable: { [weak self] message in
                    self?.model.setVoiceMonitorUnavailable(message)
                },
                onTranscriptUnavailable: { [weak self] message in
                    self?.model.setTranscriptUnavailable(message)
                }
            )
        }

        voiceMonitor?.voiceDetectionThresholdDb = model.voiceDetectionThresholdDb
        voiceMonitor?.transcriptTrackingEnabled = model.transcriptBasedPrompt
        voiceMonitor?.preferredRecognitionLocaleIdentifier = model.transcriptLanguageIdentifier == "auto" ? nil : model.transcriptLanguageIdentifier
        voiceMonitor?.scriptText = model.script
        voiceMonitor?.start()
    }

    private func setupEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        if let mainMenu = NSApp.mainMenu {
            mainMenu.addItem(editMenuItem)
        } else {
            let mainMenu = NSMenu()
            mainMenu.addItem(editMenuItem)
            NSApp.mainMenu = mainMenu
        }
    }

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "PC"
        item.button?.toolTip = "Presentation Companion"

        let menu = NSMenu()

        let startPause = NSMenuItem(
            title: "Start/Pause",
            action: #selector(toggleRunning),
            keyEquivalent: ShortcutCommand.startPause.keyEquivalent
        )
        startPause.target = self
        startPause.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(startPause)
        startPauseItem = startPause

        let reset = NSMenuItem(
            title: "Reset Scroll",
            action: #selector(resetScroll),
            keyEquivalent: ShortcutCommand.reset.keyEquivalent
        )
        reset.target = self
        reset.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(reset)

        let jumpBack = NSMenuItem(
            title: "Jump Back 5s",
            action: #selector(jumpBack),
            keyEquivalent: ShortcutCommand.jumpBack.keyEquivalent
        )
        jumpBack.target = self
        jumpBack.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(jumpBack)

        let privacyMode = NSMenuItem(
            title: "Privacy Mode",
            action: #selector(togglePrivacyMode),
            keyEquivalent: ShortcutCommand.togglePrivacy.keyEquivalent
        )
        privacyMode.target = self
        privacyMode.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(privacyMode)
        privacyModeItem = privacyMode

        let showOverlay = NSMenuItem(
            title: "Show Overlay",
            action: #selector(toggleOverlayVisibility),
            keyEquivalent: ShortcutCommand.toggleOverlay.keyEquivalent
        )
        showOverlay.target = self
        showOverlay.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(showOverlay)
        showOverlayItem = showOverlay

        let speedUp = NSMenuItem(
            title: "Increase Speed",
            action: #selector(increaseSpeed),
            keyEquivalent: ShortcutCommand.speedUp.keyEquivalent
        )
        speedUp.target = self
        speedUp.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(speedUp)
        speedUpItem = speedUp

        let speedDown = NSMenuItem(
            title: "Decrease Speed",
            action: #selector(decreaseSpeed),
            keyEquivalent: ShortcutCommand.speedDown.keyEquivalent
        )
        speedDown.target = self
        speedDown.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(speedDown)
        speedDownItem = speedDown

        refreshShortcutWarningItems(in: menu)

        menu.addItem(.separator())

        let openScriptEditor = NSMenuItem(title: "Script Editor…", action: #selector(openScriptEditorWindow), keyEquivalent: "")
        openScriptEditor.target = self
        menu.addItem(openScriptEditor)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Settings…", action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Presentation Companion", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    // MARK: - Edit key handler (Cmd+C/V/X/A/Z bypass for menu-bar apps)

    private func installEditKeyHandler() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command ||
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] else {
                return event
            }
            let key = event.charactersIgnoringModifiers ?? ""
            let action: Selector? = switch key {
            case "x": #selector(NSText.cut(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z" where event.modifierFlags.contains(.shift): NSSelectorFromString("redo:")
            case "z": NSSelectorFromString("undo:")
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: nil) {
                return nil
            }
            return event
        }
    }

    // MARK: - Actions

    @objc private func toggleRunning() {
        model.toggleRunning()
    }

    @objc private func resetScroll() {
        model.resetScroll()
    }

    @objc private func jumpBack() {
        model.jumpBack()
    }

    @objc private func togglePrivacyMode() {
        model.privacyModeEnabled.toggle()
    }
    
    @objc private func toggleOverlayVisibility() {
        model.isOverlayVisible.toggle()
    }

    @objc private func increaseSpeed() {
        model.adjustSpeed(delta: PrompterModel.secondsPerLineStep)
    }

    @objc private func decreaseSpeed() {
        model.adjustSpeed(delta: -PrompterModel.secondsPerLineStep)
    }

    @objc private func openMainWindow() {
        Task { @MainActor in
            if settingsWindowController == nil {
                settingsWindowController = SettingsWindowController()
            }
            settingsWindowController?.show()
        }
    }
    
    @objc private func openScriptEditorWindow() {
        Task { @MainActor in
            if scriptEditorWindowController == nil {
                scriptEditorWindowController = ScriptEditorWindowController()
            }
            scriptEditorWindowController?.show()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func performShortcut(_ command: ShortcutCommand) {
        switch command {
        case .startPause:
            model.toggleRunning()
        case .reset:
            model.resetScroll()
        case .jumpBack:
            model.jumpBack()
        case .togglePrivacy:
            model.privacyModeEnabled.toggle()
        case .toggleOverlay:
            model.isOverlayVisible.toggle()
        case .speedUp:
            model.adjustSpeed(delta: PrompterModel.secondsPerLineStep)
        case .speedDown:
            model.adjustSpeed(delta: -PrompterModel.secondsPerLineStep)
        }
    }

    private func refreshShortcutWarningItems(in menu: NSMenu) {
        if let shortcutWarningItem {
            menu.removeItem(shortcutWarningItem)
            self.shortcutWarningItem = nil
        }
        if let shortcutWarningDetailItem {
            menu.removeItem(shortcutWarningDetailItem)
            self.shortcutWarningDetailItem = nil
        }
        if let shortcutWarningSeparator {
            menu.removeItem(shortcutWarningSeparator)
            self.shortcutWarningSeparator = nil
        }

        let unavailable = hotkeyManager.failedRegistrations
        guard !unavailable.isEmpty else { return }

        if unavailable.count == 1, let first = unavailable.first {
            let warning = NSMenuItem(
                title: "Shortcut unavailable: \(first.displayShortcut) (in use by another app)",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.insertItem(warning, at: 0)
            shortcutWarningItem = warning
        } else {
            let warning = NSMenuItem(
                title: "Shortcuts unavailable (\(unavailable.count))",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.insertItem(warning, at: 0)
            shortcutWarningItem = warning

            let detail = unavailable
                .map(\.displayShortcut)
                .joined(separator: ", ")
            let detailItem = NSMenuItem(
                title: "In use by another app: \(detail)",
                action: nil,
                keyEquivalent: ""
            )
            detailItem.isEnabled = false
            menu.insertItem(detailItem, at: 1)
            shortcutWarningDetailItem = detailItem
        }

        let separator = NSMenuItem.separator()
        menu.insertItem(separator, at: unavailable.count == 1 ? 1 : 2)
        shortcutWarningSeparator = separator
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === startPauseItem {
            menuItem.title = model.isRunning ? "Pause" : "Start"
            return true
        }

        if menuItem === privacyModeItem {
            menuItem.state = model.privacyModeEnabled ? .on : .off
            return true
        }
        
        if menuItem === showOverlayItem {
            menuItem.state = model.isOverlayVisible ? .on : .off
            return true
        }

        if menuItem === speedUpItem || menuItem === speedDownItem {
            return true
        }

        return true
    }
}
