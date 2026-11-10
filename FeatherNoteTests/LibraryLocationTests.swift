import Foundation
import Testing
@testable import FeatherNote

@Test func defaultDirectoryIsApplicationSupport() {
    let url = LibraryLocation.directory(arguments: ["app"], environment: [:])
    #expect(url.path.hasSuffix("Application Support/FeatherMark"))
}

@Test func argumentOverridesDirectory() {
    #expect(LibraryLocation.directory(arguments: ["app", "-FeatherLibraryPath", "/tmp/x"]).path == "/tmp/x")
    #expect(LibraryLocation.directory(arguments: ["app", "-FeatherLibraryPath"], environment: [:]).path.hasSuffix("FeatherMark"))
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
    #expect(LibraryLocation.directory(arguments: ["app"], environment: [:]).path.hasSuffix("Application Support/FeatherMark"))
}

// Renamed from Feather Note (2026-11-10): an existing library moves to the new folder once, and is never overwritten.
@Test func oldLibraryMovesToTheNewName() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "FNSupport-\(UUID().uuidString)")
    let old = support.appending(path: LibraryLocation.formerName)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try Data("db".utf8).write(to: old.appending(path: "library.sqlite"))
    let url = LibraryLocation.directory(arguments: ["app"], environment: [:], supportDirectory: support)
    #expect(url.lastPathComponent == "FeatherMark")
    #expect(FileManager.default.fileExists(atPath: url.appending(path: "library.sqlite").path))
    #expect(!FileManager.default.fileExists(atPath: old.path))
}

@Test func newLibraryIsNeverReplacedByTheOldOne() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "FNSupport-\(UUID().uuidString)")
    for (name, body) in [(LibraryLocation.formerName, "old"), (LibraryLocation.name, "new")] {
        try FileManager.default.createDirectory(at: support.appending(path: name), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: support.appending(path: name).appending(path: "library.sqlite"))
    }
    let url = LibraryLocation.directory(arguments: ["app"], environment: [:], supportDirectory: support)
    #expect(try String(contentsOf: url.appending(path: "library.sqlite"), encoding: .utf8) == "new")
    #expect(FileManager.default.fileExists(atPath: support.appending(path: LibraryLocation.formerName).path))
}
