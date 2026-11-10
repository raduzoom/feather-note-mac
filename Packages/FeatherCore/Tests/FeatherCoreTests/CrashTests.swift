import Foundation
import Testing
@testable import FeatherCore

/// The fncore binary SwiftPM or Xcode built next to the test bundle.
func fncoreURL() throws -> URL {
    var info = Dl_info()
    try #require(dladdr(#dsohandle, &info) != 0 && info.dli_fname != nil)   // this test binary's own path
    var url = URL(fileURLWithPath: String(cString: info.dli_fname))
    while url.pathComponents.count > 1 && url.pathExtension != "xctest" { url.deleteLastPathComponent() }
    let binary = url.deletingLastPathComponent().appending(path: "fncore")
    try #require(FileManager.default.isExecutableFile(atPath: binary.path), "fncore not built at \(binary.path)")
    return binary
}

struct RunResult {
    var status: Int32
    var reason: Process.TerminationReason
    var stdout: String
    var stderr: String
}

@discardableResult
func runFncore(_ args: [String], stdin: String = "") throws -> RunResult {
    let p = Process()
    p.executableURL = try fncoreURL()
    p.arguments = args
    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = errPipe
    try p.run()
    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
    try inPipe.fileHandleForWriting.close()
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return RunResult(status: p.terminationStatus, reason: p.terminationReason,
                     stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
}

@Test func harnessCreatesSearchesExports() throws {
    let dir = TestLibrary.directory().appending(path: "lib")
    let initRun = try runFncore(["init", dir.path])
    #expect(initRun.status == 0 && ULID(string: initRun.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    let add = try runFncore(["add", dir.path, "--title", "Station", "--notebook", "Home", "--tag", "iot"], stdin: "hello weather")
    #expect(add.status == 0, "\(add.stderr)")
    let noteID = add.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(ULID(string: noteID) != nil)
    let search = try runFncore(["search", dir.path, "weather"])
    #expect(search.status == 0 && search.stdout.hasPrefix(noteID + "\tStation\t"))
    let list = try runFncore(["list", dir.path])
    #expect(list.stdout == "\(noteID)\tStation\n")
    let dest = TestLibrary.directory()
    let export = try runFncore(["export", dir.path, dest.path])
    #expect(export.status == 0, "\(export.stderr)")
    let files = try FileManager.default.subpathsOfDirectory(atPath: dest.path).filter { $0.hasSuffix(".md") }
    #expect(files == ["FeatherMark Export/Home/Station.md"])
    let src = TestLibrary.directory()
    try Data("imported".utf8).write(to: src.appending(path: "x.md"))
    let imp = try runFncore(["import", dir.path, src.path])
    #expect(imp.status == 0 && imp.stdout.contains("notes: 1"))
}

@Test func harnessReportsBadUsage() throws {
    #expect(try runFncore([]).status == 2)
    #expect(try runFncore(["frobnicate"]).status == 2)
    let missing = try runFncore(["add", TestLibrary.directory().path, "--title"])
    #expect(missing.status == 2)
}

@Test func killMidSaveKeepsLastCommittedNote() async throws {
    let dir = TestLibrary.directory()
    let noteID: ULID
    let changesBefore: Int
    do {
        let lib = try Library.open(at: dir)
        let a = try await lib.addAttachment(data: Data(repeating: 7, count: 2 << 20), filename: "big.bin")
        noteID = try await lib.createNote(title: "x", body: "before ![](feather://attachment/\(a.id))").id
        changesBefore = try await lib.changes(after: 0).count
    }
    let run = try runFncore(["_crash-during-save", dir.path, noteID.description, "after"])
    #expect(run.reason == .uncaughtSignal && run.status == SIGKILL)

    let lib = try Library.open(at: dir)
    #expect(try await lib.note(noteID)?.body.hasPrefix("before ") == true)
    #expect(try await lib.scalar("PRAGMA integrity_check") == "ok")
    try await lib.execute("INSERT INTO notes_fts(notes_fts) VALUES('integrity-check')")
    #expect(try await lib.search("after").isEmpty)
    #expect(try await lib.search("before").map(\.note.id) == [noteID])
    #expect(try await lib.changes(after: 0).count == changesBefore)
}

@Test func killDuringImportLeavesNoPartialImport() async throws {
    let dir = TestLibrary.directory()
    do { _ = try Library.open(at: dir) }
    let src = TestLibrary.directory()
    for i in 0..<20 {
        let folder = src.appending(path: "Folder \(i % 4)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("note \(i)".utf8).write(to: folder.appending(path: "n\(i).md"))
    }
    let run = try runFncore(["_crash-during-import", dir.path, src.path])
    #expect(run.reason == .uncaughtSignal && run.status == SIGKILL)
    let lib = try Library.open(at: dir)
    #expect(try await lib.notes(in: .all).isEmpty)
    #expect(try await lib.notebooks().isEmpty)
    #expect(try await lib.scalar("PRAGMA integrity_check") == "ok")
}
