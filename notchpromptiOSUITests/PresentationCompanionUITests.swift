//
//  PresentationCompanionUITests.swift
//  Presentation CompanionUITests
//

import XCTest

final class PresentationCompanionUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPortraitAndLandscapeLayouts() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let title = app.staticTexts["PCompanion"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let prompt = app.otherElements["promptSurface"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        XCTAssertTrue(firstExistingButton(identifier: "pictureInPictureButton", label: "Start Picture in Picture").exists)
        addScreenshot(named: "portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)

        XCTAssertTrue(title.exists)
        XCTAssertTrue(prompt.exists)
        addScreenshot(named: "landscape-left")

        XCUIDevice.shared.orientation = .landscapeRight
        sleep(2)

        XCTAssertTrue(title.exists)
        XCTAssertTrue(prompt.exists)
        addScreenshot(named: "landscape-right")
    }

    func testSettingsCanHideAndAutoScrollCanRun() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let settingsButton = firstExistingButton(identifier: "settingsButton", label: "Settings")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
        settingsButton.tap()

        let editor = app.textViews["scriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))

        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 4))

        let prompt = app.otherElements["promptSurface"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 4))
        let startingOffset = Int((prompt.value as? String) ?? "0") ?? 0

        firstExistingButton(identifier: "playPauseButton", label: "Play").tap()
        sleep(2)

        let endingOffset = Int((prompt.value as? String) ?? "0") ?? 0
        XCTAssertGreaterThan(endingOffset, startingOffset)
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
