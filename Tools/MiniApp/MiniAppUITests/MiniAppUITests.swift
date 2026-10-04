//
//  MiniAppUITests.swift
//  MiniAppUITests
//
//  Created by Kazuki Nakashima on 2026/03/05.
//

import XCTest

final class MiniAppUITests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testMenuSelectionFlow() throws {
        XCTAssertTrue(openMenuButton.waitForExistence(timeout: 5))
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 2))
        XCTAssertTrue(navigationNumberLabel.waitForExistence(timeout: 2))
        let menuReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: openMenuButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [menuReady], timeout: 120), .completed)

        XCTAssertEqual(statusLabel.label, "Tap button to open menu")
        XCTAssertEqual(navigationNumberLabel.label, "Number: 3")

        openMenuButton.tap()
        let blueButton = app.buttons["Blue"]
        XCTAssertTrue(blueButton.waitForExistence(timeout: 2))
        blueButton.tap()

        XCTAssertEqual(statusLabel.label, "Selected: Blue")
        XCTAssertEqual(navigationNumberLabel.label, "Number: 3")

        let moreButton = app.buttons["More"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 2))
        moreButton.tap()
        let purpleButton = app.buttons["Purple"]
        XCTAssertTrue(purpleButton.waitForExistence(timeout: 2))
        purpleButton.tap()
        XCTAssertTrue(purpleButton.waitForNonExistence(timeout: 2))
        XCTAssertEqual(statusLabel.label, "Selected: Purple")

        openMenuButton.tap()
        XCTAssertTrue(blueButton.waitForExistence(timeout: 2))
        blueButton.tap()
        XCTAssertEqual(statusLabel.label, "Selected: Blue")
        XCTAssertEqual(navigationNumberLabel.label, "Number: 3")
    }

    private var openMenuButton: XCUIElement {
        app.buttons["MiniApp.openMenuButton"]
    }

    private var statusLabel: XCUIElement {
        app.staticTexts["MiniApp.statusLabel"]
    }

    private var navigationNumberLabel: XCUIElement {
        app.staticTexts["MiniApp.navigationNumberLabel"]
    }
}
