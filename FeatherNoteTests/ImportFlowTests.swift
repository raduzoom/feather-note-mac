import Foundation
import Testing
import FeatherCore
@testable import FeatherNote

/// An ENEX file with `count` short notes, written to a temporary folder.
func makeENEX(notes count: Int, name: String = "Trip notes", truncate: Bool = false) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "FNEnex-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<en-export>"
    for i in 1...count {
        xml += "<note><title>Note \(i)</title><created>20251109T135200Z</created><content><![CDATA[<en-note><div>Body \(i)</div>"
        xml += (i == 1 ? "<table><tr><td>a</td></tr></table>" : "") + "</en-note>]]></content></note>"
    }
    xml += "</en-export>"
    if truncate { xml = String(xml.prefix(xml.count / 2)) }
    let url = dir.appending(path: "\(name).enex")
    try Data(xml.utf8).write(to: url)
    return url
}

@MainActor func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 15) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor @Suite(.serialized) struct ImportFlowTests {
    @Test func sourceFromURL() throws {
        let dir = FileManager.default.temporaryDirectory
        #expect(ImportSource(url: dir.appending(path: "a.enex")) == .evernote(dir.appending(path: "a.enex")))
        #expect(ImportSource(url: dir.appending(path: "b.ZIP")) == .notion(dir.appending(path: "b.ZIP")))
        #expect(ImportSource(url: dir) == .markdownFolder(dir))
        #expect(ImportSource(url: dir.appending(path: "c.txt")) == nil)
    }

    @Test func enexImportFlowReachesReport() async throws {
        let m = try await makeModel()
        m.startImport(.evernote(try makeENEX(notes: 3)))
        #expect(await waitFor { if case .finished = m.importState { true } else { false } })
        guard case .finished(let report) = m.importState else { Issue.record("state \(String(describing: m.importState))"); return }
        #expect(report.notes == 3)
        #expect(report.preserved.map(\.kind) == [.table])
        #expect(Formatting.importSummary(report) == "Imported 3 notes and 0 attachments. 1 note contains content FeatherMark can't display yet (tables or HTML); it was kept as plain text.")
        await m.showImportedNotes()
        #expect(m.selection == .notebook(try #require(report.topNotebookID)))
        #expect(m.notebooks.contains { $0.name == "Trip notes" })
        m.finishImport()
        #expect(m.importState == nil)
    }

    @Test func cancelDuringImportLeavesLibraryUnchanged() async throws {
        let m = try await makeModel()
        m.importNoteDelay = 0.05
        m.startImport(.evernote(try makeENEX(notes: 60)))
        #expect(await waitFor { if case .running(let p, _, _) = m.importState { p.notesDone >= 2 } else { false } })
        m.cancelImport()
        #expect(await waitFor { m.importState == nil })
        #expect(m.noteCount == 0)
        #expect(m.notebooks.isEmpty)
    }

    @Test func failedImportShowsMessage() async throws {
        let m = try await makeModel()
        m.startImport(.evernote(try makeENEX(notes: 4, name: "Broken", truncate: true)))
        #expect(await waitFor { if case .failed = m.importState { true } else { false } })
        guard case .failed(let message) = m.importState else { return }
        #expect(message.contains("Broken.enex"))
        #expect(m.noteCount == 0)
    }

    @Test func progressLineText() {
        #expect(Formatting.importProgressLine(ImportProgress(notesDone: 798, notesTotal: 1284, attachments: 191, current: "x"))
                == "798 of \(1284.formatted()) notes · 191 attachments")   // the locale decides the separator
        #expect(Formatting.timeLeft(done: 100, total: 400, elapsed: 2) == nil)   // too early to say
        #expect(Formatting.timeLeft(done: 100, total: 400, elapsed: 40) == "About 2 min left")
        #expect(Formatting.timeLeft(done: 390, total: 400, elapsed: 40) == "Less than a minute left")
    }
}
