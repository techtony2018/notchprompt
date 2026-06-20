//
//  PresentationCompanionUITests.swift
//  Presentation CompanionUITests
//

import XCTest

final class PresentationCompanionUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--reset-settings-surface"]
    }

    func testPortraitAndLandscapeLayouts() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let title = app.staticTexts["Presentation Companion"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let configuration = app.descendants(matching: .any)["configurationSurface"].firstMatch
        XCTAssertTrue(configuration.waitForExistence(timeout: 8))
        let versionText = app.staticTexts.containing(NSPredicate(format: "label MATCHES 'V[0-9]+\\\\.[0-9]+'")).firstMatch
        XCTAssertTrue(versionText.exists || app.staticTexts["Version"].firstMatch.exists)
        addScreenshot(named: "portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)

        XCTAssertTrue(title.exists)
        XCTAssertTrue(configuration.exists)
        addScreenshot(named: "landscape-left")

        XCUIDevice.shared.orientation = .landscapeRight
        sleep(2)

        XCTAssertTrue(title.exists)
        XCTAssertTrue(configuration.exists)
        addScreenshot(named: "landscape-right")
    }

    func testScriptEditorFocusAndFullscreenPromptLayout() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let editor = app.textViews["scriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))

        let configuration = app.descendants(matching: .any)["configurationSurface"].firstMatch
        XCTAssertTrue(configuration.waitForExistence(timeout: 4))
        let startingOffset = Int((configuration.value as? String) ?? "0") ?? 0
        addScreenshot(named: "keyboard-focus")

        app.staticTexts["Presentation Companion"].firstMatch.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        firstExistingButton(identifier: "presentButton", label: "Present").tap()
        let presentationSurface = app.descendants(matching: .any)["presentationForegroundSurface"].firstMatch
        XCTAssertTrue(presentationSurface.waitForExistence(timeout: 4))
        XCTAssertFalse(configuration.exists)
        XCTAssertTrue(app.buttons["playPauseButton"].firstMatch.exists)
        XCTAssertTrue(app.buttons["settingsButton"].firstMatch.exists)
        addScreenshot(named: "presentation-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCTAssertTrue(presentationSurface.exists)
        XCTAssertTrue(app.buttons["playPauseButton"].firstMatch.exists)
        addScreenshot(named: "presentation-landscape-left")

        XCUIDevice.shared.orientation = .landscapeRight
        sleep(2)
        XCTAssertTrue(presentationSurface.exists)
        XCTAssertTrue(app.buttons["settingsButton"].firstMatch.exists)
        addScreenshot(named: "presentation-landscape-right")

        sleep(5)
        let endingOffset = Int((presentationSurface.value as? String) ?? "0") ?? 0
        XCTAssertGreaterThan(endingOffset, startingOffset)

        presentationSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let pausedOffset = Int((presentationSurface.value as? String) ?? "0") ?? 0
        sleep(1)
        let afterPauseOffset = Int((presentationSurface.value as? String) ?? "0") ?? 0
        XCTAssertLessThanOrEqual(abs(afterPauseOffset - pausedOffset), 2)

        presentationSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).tap()
        usleep(250_000)
        let afterForwardTapOffset = Int((presentationSurface.value as? String) ?? "0") ?? 0
        XCTAssertGreaterThan(afterForwardTapOffset, afterPauseOffset)

        presentationSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45)).tap()
        usleep(250_000)
        let afterBackTapOffset = Int((presentationSurface.value as? String) ?? "0") ?? 0
        XCTAssertLessThan(afterBackTapOffset, afterForwardTapOffset)
    }

    private func firstExistingButton(identifier: String, label: String) -> XCUIElement {
        let identified = app.buttons[identifier].firstMatch
        if identified.exists {
            return identified
        }

        return app.buttons[label].firstMatch
    }

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
