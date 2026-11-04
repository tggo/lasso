import XCTest

/// End-to-end against the local integration sshd + herdr (`make test-ui` starts them).
/// Skips when LASSO_IT_* is not provided.
@MainActor final class LiveFlowUITests: XCTestCase {
    func testHostToAgentToTerminal() throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["LASSO_IT_KEY"], let host = env["LASSO_IT_HOST"], let port = env["LASSO_IT_PORT"],
              let user = env["LASSO_IT_USER"], let sock = env["LASSO_IT_SOCK"] else { throw XCTSkip("no integration env") }
        let app = XCUIApplication()
        app.launchEnvironment["LASSO_SEED_KEY"] = key
        app.launchEnvironment["LASSO_SEED_HOST"] = "\(host):\(port):\(user):\(sock)"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 3) { springboard.buttons["Allow"].tap() }

        // Seeded host is an unverified draft: tapping opens the editor; verify and trust it.
        app.staticTexts["Local herdr"].tap()
        XCTAssertTrue(app.staticTexts["Not verified"].exists || app.buttons["Connect & show host key"].waitForExistence(timeout: 3))
        app.buttons["Connect & show host key"].tap()
        let trust = app.buttons["Trust & save"]
        XCTAssertTrue(trust.waitForExistence(timeout: 10), "host key shown")
        shot(app, "0-trust")
        trust.tap()
        app.staticTexts["Local herdr"].tap()
        let blocked = app.staticTexts["blocked"].firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 10), "blocked agent listed")
        shot(app, "1-session")

        blocked.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'hello from'")).firstMatch.waitForExistence(timeout: 10))
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        field.tap()
        field.typeText("echo from-phone")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'from-phone'")).firstMatch.waitForExistence(timeout: 10))
        shot(app, "2-agent")

        app.buttons["Open terminal"].tap()
        sleep(3)
        shot(app, "3-terminal")
        app.buttons["Close"].tap()
    }

    /// Herdr.app on this Mac (developer machines only): the seeded host has no socket, so Lasso
    /// must detect herdr-core itself and list the real spaces.
    func testHerdrAppSessionList() throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["LASSO_IT_KEY"], let host = env["LASSO_IT_HOST"], let port = env["LASSO_IT_PORT"],
              let user = env["LASSO_IT_USER"], env["LASSO_IT_CORE"] == "1" else { throw XCTSkip("no Herdr.app") }
        let app = XCUIApplication()
        app.launchEnvironment["LASSO_SEED_KEY"] = key
        app.launchEnvironment["LASSO_SEED_HOST"] = "\(host):\(port):\(user):"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 3) { springboard.buttons["Allow"].tap() }
        app.staticTexts["Local herdr"].tap()
        app.buttons["Connect & show host key"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Herdr 0.'")).firstMatch.waitForExistence(timeout: 10),
                      "probe reports Herdr.app")
        app.buttons["Trust & save"].tap()
        app.staticTexts["Local herdr"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'tab'")).firstMatch.waitForExistence(timeout: 10),
                      "spaces listed")
        shot(app, "4-herdr-app")
        // A Claude Code agent opens as chat read from its session log.
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'done' OR label CONTAINS 'working'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Show screen"].waitForExistence(timeout: 10), "chat mode available")
        sleep(1)
        shot(app, "5-chat")
        app.buttons["Show screen"].tap()
        sleep(2)
        shot(app, "6-screen")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["LASSO_SHOTS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
