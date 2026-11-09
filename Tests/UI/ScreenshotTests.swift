import XCTest

/// Captures the screens compared with the design boards. Runs only when asked:
/// TEST_RUNNER_FEATHER_SHOT_LIB=<seeded library dir> xcodebuild test … -only-testing:FeatherNoteUITests/ScreenshotTests
/// Images land in the UI-test runner's temporary folder, under "shots/".
@MainActor
final class ScreenshotTests: XCTestCase {
    func testCaptureScreens() throws {
        guard let lib = ProcessInfo.processInfo.environment["FEATHER_SHOT_LIB"] else { throw XCTSkip("screenshots not requested") }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "shots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for scheme in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-FeatherLibraryPath", lib, "-FeatherColorScheme", scheme]
            app.launch()
            let window = app.windows["Feather Note"]
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            func shot(_ name: String) throws {
                sleep(1)
                try window.screenshot().pngRepresentation.write(to: out.appending(path: "\(name)-\(scheme).png"))
            }
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Weather station build'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.click()
            try shot("main")

            let search = app.textFields["Search notes"]
            app.typeKey("f", modifierFlags: [.command, .option])
            search.typeText("sensor")
            try shot("search")
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "zzzq")
            try shot("search-empty")
            app.buttons["Clear search"].click()

            app.typeKey("n", modifierFlags: .command)
            try shot("editor-empty")
            app.menuBars.menuBarItems["Note"].click()
            app.menuItems["Move to Trash"].click()

            app.typeKey("4", modifierFlags: .command)
            let trashed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Untitled'")).firstMatch
            if trashed.waitForExistence(timeout: 3), trashed.isHittable { trashed.click() }
            try shot("trash")
            app.terminate()
        }
    }
}
