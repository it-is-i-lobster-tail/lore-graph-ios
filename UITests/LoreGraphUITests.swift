import XCTest

/// End-to-end journeys against a running loregraph server.
///
/// The server tests read their settings from the test runner's environment, which `xcodebuild`
/// fills from variables prefixed `TEST_RUNNER_`:
///
///     TEST_RUNNER_LG_SERVER=localhost:8000 \
///     TEST_RUNNER_LG_EMAIL=… TEST_RUNNER_LG_PASSWORD=… \
///     TEST_RUNNER_LG_TOKEN=lgp_… \
///     xcodebuild test -scheme LoreGraph -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
///
/// Without `LG_SERVER` the server journeys report themselves skipped, with the reason.
final class LoreGraphUITests: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Starts the app from nothing: no saved sign-in, settings or cache.
    @MainActor
    func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
    }

    // MARK: journeys

    /// The sign-in screen explains itself and refuses an address that isn't a server.
    @MainActor
    func testSignInScreenRejectsABadAddress() throws {
        launch()
        let server = app.textFields["server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        snapshot("01-sign-in")
        server.replaceText("not a server")
        app.buttons["signIn"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["signInError"].waitForExistence(timeout: 10))
    }

    /// Sign in on the server's own page, read the wiki, clear the cache and sign out (F-1.1, F-1.6, F-11.4).
    @MainActor
    func testOAuthSignInReadAndSignOut() throws {
        let env = try settings(needs: ["LG_SERVER", "LG_EMAIL", "LG_PASSWORD"])
        launch()
        signInWithOAuth(server: env["LG_SERVER"]!, email: env["LG_EMAIL"]!, password: env["LG_PASSWORD"]!)
        chooseWorldIfAsked()
        XCTAssertTrue(app.buttons["browse-individual"].waitForExistence(timeout: 30), "the wiki home never loaded")
        snapshot("02-wiki-home")
        clearCache()
        signOut()
    }

    /// The personal token route, then a walk through every tab with a picture of each.
    @MainActor
    func testTokenSignInAndTour() throws {
        let env = try settings(needs: ["LG_SERVER", "LG_TOKEN"])
        launch()
        let server = app.textFields["server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.replaceText(env["LG_SERVER"]!)
        app.descendants(matching: .any)["tokenDisclosure"].firstMatch.tap()
        let token = app.secureTextFields["token"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        token.tap()
        token.typeText(env["LG_TOKEN"]!)
        app.buttons["signInWithToken"].tap()
        chooseWorldIfAsked()
        XCTAssertTrue(app.buttons["browse-individual"].waitForExistence(timeout: 30), "the wiki home never loaded")
        snapshot("03-token-wiki-home")

        // a page
        app.buttons["browse-individual"].tap()
        // the list's first cell is the sort picker; the page rows come after it
        let firstPage = app.buttons.matching(identifier: "pageRow").firstMatch
        if firstPage.waitForExistence(timeout: 20) {
            snapshot("04-browse-individuals")
            firstPage.tap()
            XCTAssertTrue(app.staticTexts["pageTitle"].waitForExistence(timeout: 20), "the page never opened")
            snapshot("05-page")
            pullToRefresh()
            XCTAssertTrue(app.staticTexts["pageTitle"].waitForExistence(timeout: 20))
        }

        for (tab, name) in [("Map", "06-map"), ("Timeline", "07-timeline"), ("Family", "08-family"), ("Graph", "09-graph")] {
            openTab(tab)
            if tab == "Family" || tab == "Graph" {
                // these open on a picker; draw the page read above, from its recently read row
                let recent = app.collectionViews.buttons.firstMatch
                if recent.waitForExistence(timeout: 5) { recent.tap() }
            }
            sleep(4)
            snapshot(name)
        }
        openTab("Search")
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            field.typeText("a")
            // submit: one letter is too short for suggestions, and the keyboard would cover the tab bar
            field.typeText("\n")
            _ = app.collectionViews.buttons.firstMatch.waitForExistence(timeout: 15)
            snapshot("10-search")
        }
        openTab("Wiki")
        signOut()
    }

    // MARK: steps

    @MainActor
    func signInWithOAuth(server address: String, email: String, password: String) {
        let server = app.textFields["server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.replaceText(address)
        app.buttons["signIn"].tap()

        // older systems ask before opening the sign-in sheet
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let proceed = springboard.buttons["Continue"]
        if proceed.waitForExistence(timeout: 3) { proceed.tap() }

        let web = webContent()
        let emailField = web.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 20), "the server's sign-in page never appeared")
        snapshot("01b-server-sign-in")
        emailField.tap()
        emailField.typeText(email)
        let passwordField = web.secureTextFields.firstMatch
        passwordField.tap()
        passwordField.typeText(password)
        web.buttons["Sign in"].firstMatch.tap()

        // the system offers to save the password over the next page; decline it
        let notNow = app.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }

        let approve = web.buttons["Approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 20), "the consent page never appeared")
        snapshot("01c-consent")
        approve.tap()
    }

    /// The sign-in sheet's page, wherever the system hosts it.
    @MainActor
    func webContent() -> XCUIElement {
        let inApp = app.webViews.firstMatch
        if inApp.waitForExistence(timeout: 10) { return inApp }
        return XCUIApplication(bundleIdentifier: "com.apple.SafariViewService").webViews.firstMatch
    }

    @MainActor
    func chooseWorldIfAsked() {
        let picker = app.navigationBars["Choose a world"]
        guard picker.waitForExistence(timeout: 8) else { return }
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'world-'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
    }

    @MainActor
    func openSettings() {
        let settings = app.buttons["settings"].firstMatch
        // settings sits on a tab's first screen; go back up from a page opened earlier
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        for _ in 0..<5 where !settings.waitForExistence(timeout: 2) && back.exists { back.tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    func clearCache() {
        openSettings()
        XCTAssertTrue(app.descendants(matching: .any)["cacheSize"].waitForExistence(timeout: 5))
        snapshot("11-settings")
        app.buttons["clearCache"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Clear cache' AND identifier != 'clearCache'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cacheSize"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
    }

    @MainActor
    func signOut() {
        openSettings()
        let button = app.buttons["signOut"]
        app.swipeUp()
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign out' AND identifier != 'signOut'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 15), "sign-out didn't return to the sign-in screen")
    }

    @MainActor
    func openTab(_ title: String) {
        let tab = app.tabBars.buttons[title].firstMatch
        let more = app.tabBars.buttons["More"].firstMatch
        if tab.waitForExistence(timeout: 3) {
            tab.tap()
        } else if more.exists {
            // iPhone: the tabs that don't fit sit in More's list
            more.tap()
            let row = app.cells.staticTexts[title].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(title) isn't in More")
            row.tap()
        } else {
            app.buttons[title].firstMatch.tap()
        }
    }

    @MainActor
    func pullToRefresh() {
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let bottom = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        top.press(forDuration: 0.05, thenDragTo: bottom)
    }

    // MARK: support

    func settings(needs keys: [String]) throws -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let missing = keys.filter { (env[$0] ?? "").isEmpty }
        if !missing.isEmpty {
            throw XCTSkip("Needs a running server: set \(missing.map { "TEST_RUNNER_" + $0 }.joined(separator: ", ")).")
        }
        return env
    }

    @MainActor
    func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension XCUIElement {
    /// Clears a text field, types new text, checks the field holds exactly that text, and closes
    /// the keyboard so it doesn't cover the controls below. The check matters: a field that kept
    /// part of its old value (the default server) must never be signed in to.
    @MainActor
    func replaceText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        // a plain tap puts the cursor where the finger lands, mid-text; start from the end instead
        coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        if let current = value as? String, !current.isEmpty, current != placeholderValue {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        typeText(text)
        XCTAssertEqual(value as? String, text, "the field didn't take the new text", file: file, line: line)
        typeText("\n")
    }
}
