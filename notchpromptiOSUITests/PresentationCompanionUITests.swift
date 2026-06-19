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
        let configuration = app.descendants(matching: .any)["configurationSurface"].firstMatch
        XCTAssertTrue(configuration.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["V1.1"].firstMatch.exists || app.staticTexts["Version"].firstMatch.exists)
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

    func testConfigurationCanAutoScrollAfterPlaybackStarts() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let editor = app.textViews["scriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))

        let configuration = app.descendants(matching: .any)["configurationSurface"].firstMatch
        XCTAssertTrue(configuration.waitForExistence(timeout: 4))
        let startingOffset = Int((configuration.value as? String) ?? "0") ?? 0

        firstExistingButton(identifier: "playPauseButton", label: "Play").tap()
        sleep(5)

        let endingOffset = Int((configuration.value as? String) ?? "0") ?? 0
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
