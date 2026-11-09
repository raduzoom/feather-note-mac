import Foundation
import Testing
@testable import FeatherNote

@Test func defaultDirectoryIsApplicationSupport() {
    let url = LibraryLocation.directory(arguments: ["app"], environment: [:])
    #expect(url.path.hasSuffix("Application Support/Feather Note"))
}

@Test func argumentOverridesDirectory() {
    #expect(LibraryLocation.directory(arguments: ["app", "-FeatherLibraryPath", "/tmp/x"]).path == "/tmp/x")
    #expect(LibraryLocation.directory(arguments: ["app", "-FeatherLibraryPath"], environment: [:]).path.hasSuffix("Feather Note"))
}

@MainActor @Test func openCreatesLibrary() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "FNApp-\(UUID().uuidString)")
    _ = try AppModel.open(at: dir)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "library.sqlite").path))
}

@Test func testHostNeverUsesTheRealLibrary() {
    let url = LibraryLocation.directory(arguments: ["app"], environment: ["XCTestConfigurationFilePath": "/x"])
    #expect(!url.path.contains("Application Support"))
    #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(LibraryLocation.directory(arguments: ["app"], environment: [:]).path.hasSuffix("Application Support/Feather Note"))
}
