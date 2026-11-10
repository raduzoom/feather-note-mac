import XCTest

@MainActor
final class SmokeTests: XCTestCase {
    var libraryPath: String!

    override func setUp() async throws {
        continueAfterFailure = false
        libraryPath = FileManager.default.temporaryDirectory.appending(path: "FNUI-\(UUID().uuidString)").path
    }

    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FeatherLibraryPath", libraryPath] + extra
        app.launch()
        return app
    }

    func element(_ app: XCUIApplication, labelStartingWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func testAppLaunchesWithMainWindow() {
        let app = launch()
        XCTAssertTrue(app.windows["Feather Note"].waitForExistence(timeout: 10))
    }

    /// Phase 5: Note › New Quick Note, type, ⌘↩, and the note is in the list.
    func testQuickNoteSavesIntoNotebook() {
        let app = launch()
        XCTAssertTrue(app.windows["Feather Note"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Note"].click()
        app.menuItems["New Quick Note"].click()
        let text = app.textViews["quick-note-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText("UI quick note")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(text.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, labelStartingWith: "UI quick note").waitForExistence(timeout: 5))
    }

    /// Phase 5: an Evernote import reaches the report, and Show Imported Notes opens the new notebook.
    func testImportEnexShowsReport() throws {
        let enex = FileManager.default.temporaryDirectory.appending(path: "FNUI-\(UUID().uuidString)/Road trip.enex")
        try FileManager.default.createDirectory(at: enex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?><en-export>\
        <note><title>Packing list</title><content><![CDATA[<en-note><div>Tent</div><table><tr><td>x</td></tr></table></en-note>]]></content></note>\
        <note><title>Route</title><content><![CDATA[<en-note><div>North first</div></en-note>]]></content></note></en-export>
        """.utf8).write(to: enex)
        let app = launch(["-FeatherImportFixture", enex.path])
        XCTAssertTrue(app.staticTexts["Import complete"].waitForExistence(timeout: 15))
        let summary = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Imported 2 notes", "Imported 2 notes")).firstMatch
        XCTAssertTrue(summary.exists)
        app.buttons["Show Imported Notes"].click()
        XCTAssertTrue(app.staticTexts["Import complete"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, labelStartingWith: "Packing list").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, labelStartingWith: "Road trip").exists)
    }

    func testFirstLaunchShowsWelcome() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["A quiet place to write."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Write Your First Note"].exists)
        XCTAssertTrue(app.buttons["Import Notes…"].exists)
    }

    /// Roadmap Phase 3: create notebook, create note, search finds it, trash and restore.
    func testCreateSearchTrashRestore() {
        let app = launch()
        XCTAssertTrue(app.windows["Feather Note"].waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
        app.typeText("Projects\r")
        XCTAssertTrue(element(app, labelStartingWith: "Projects").waitForExistence(timeout: 5))

        app.typeKey("n", modifierFlags: .command)
        let title = app.textViews["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.typeText("Weather station")
        app.textViews["note-body"].click()
        app.typeText("BME280 sensor")

        app.typeKey("1", modifierFlags: .command)
        app.typeKey("f", modifierFlags: [.command, .option])
        app.typeText("bme280")
        XCTAssertTrue(app.staticTexts["1 result"].waitForExistence(timeout: 5))
        let row = element(app, labelStartingWith: "Weather station")
        if !row.waitForExistence(timeout: 5) {
            let labels = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Today'")).allElementsBoundByIndex.map(\.label)
            let title = app.textViews["note-title"].value as? String ?? "?"
            XCTFail("rows: \(labels) title view: \(title)")
        }

        app.buttons["Clear search"].click()
        row.click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))

        app.typeKey("4", modifierFlags: .command)
        let trashed = element(app, labelStartingWith: "Weather station")
        XCTAssertTrue(trashed.waitForExistence(timeout: 5))
        trashed.click()
        app.buttons["Restore Note"].click()

        app.typeKey("1", modifierFlags: .command)
        let restored = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Weather station' AND label CONTAINS 'Projects'")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
    }

    /// VoiceOver: every button in the window, toolbar included, has a label.
    func testEveryButtonHasALabel() {
        let app = launch()
        XCTAssertTrue(app.windows["Feather Note"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textViews["note-title"].waitForExistence(timeout: 5))
        app.typeText("Labelled")
        let unlabeled = app.windows["Feather Note"].buttons.allElementsBoundByIndex
            .filter { !$0.identifier.hasPrefix("_XCUI:") }   // the window's own traffic-light buttons
            .filter { $0.label.isEmpty && $0.title.isEmpty }
        XCTAssertEqual(unlabeled.count, 0, unlabeled.map(\.debugDescription).joined(separator: "\n"))
    }

    /// Cold launch on a 10k-note library. Runs only when FEATHER_PERF_LIB names a seeded library
    /// (set TEST_RUNNER_FEATHER_PERF_LIB for xcodebuild).
    func testLaunchPerformance() throws {
        guard let lib = ProcessInfo.processInfo.environment["FEATHER_PERF_LIB"] else { throw XCTSkip("no 10k library given") }
        let app = XCUIApplication()
        app.launchArguments = ["-FeatherLibraryPath", lib]
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
            app.terminate()
        }
    }
}
