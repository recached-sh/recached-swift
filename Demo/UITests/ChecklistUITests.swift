import XCTest

/// The demo's promises, driven through its UI on a simulator.
final class ChecklistUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(server: String, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-server", server] + (reset ? ["-reset", "YES"] : [])
        app.launch()
        return app
    }

    private func add(_ title: String, in app: XCUIApplication) {
        let field = app.textFields["new-item"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(title)
        app.buttons["add"].tap()
    }

    private func label(_ id: String, in app: XCUIApplication, becomes value: String) {
        let element = app.staticTexts[id]
        let matches = NSPredicate(format: "label == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed, "\(id) never read \(value)")
    }

    /// Durable queued writes and local reads, with no server at all: nothing
    /// listens on port 1, so the app stays offline.
    func testAnItemAddedOfflineSurvivesARelaunchStillQueued() {
        var app = launch(server: "ws://127.0.0.1:1", reset: true)
        add("Bought offline", in: app)
        XCTAssertTrue(app.staticTexts["Bought offline"].waitForExistence(timeout: 5))
        label("pending", in: app, becomes: "1 unsynced")

        app.terminate()
        app = launch(server: "ws://127.0.0.1:1", reset: false)
        XCTAssertTrue(app.staticTexts["Bought offline"].waitForExistence(timeout: 10))
        label("pending", in: app, becomes: "1 unsynced")
    }

    /// Syncing with a real server, when CI provides one (the simulator shares
    /// the Mac's network): TEST_RUNNER_RECACHED_DEMO_SERVER=ws://127.0.0.1:6380.
    func testConnectsAndSyncsWithAServer() throws {
        guard let server = ProcessInfo.processInfo.environment["RECACHED_DEMO_SERVER"] else {
            throw XCTSkip("set TEST_RUNNER_RECACHED_DEMO_SERVER to run against a server")
        }
        let app = launch(server: server, reset: true)
        label("connection", in: app, becomes: "Connected")
        add("Synced item", in: app)
        XCTAssertTrue(app.staticTexts["Synced item"].waitForExistence(timeout: 5))
        label("pending", in: app, becomes: "Synced")
    }
}
