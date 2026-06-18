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

        let title = app.staticTexts["Presentation Companion"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        addScreenshot(named: "portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)

        XCTAssertTrue(title.exists)
        addScreenshot(named: "landscape-left")
    }

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
