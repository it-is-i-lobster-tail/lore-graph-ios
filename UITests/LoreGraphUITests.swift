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
        let firstPage = app.collectionViews.cells.element(boundBy: 0)
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
            sleep(4)
            snapshot(name)
        }
        openTab("Search")
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            field.typeText("a")
            sleep(2)
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
        if tab.waitForExistence(timeout: 3) {
            tab.tap()
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
    /// Clears a text field and types new text.
    func replaceText(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty, current != placeholderValue {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
