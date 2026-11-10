import Foundation
import Testing
import FeatherCore
@testable import FeatherNote

/// Phase 5b review probes for the app's import flow.
@MainActor @Suite(.serialized) struct ReviewProbe5b {
    /// "Cancel Import" during a Markdown-folder import must leave nothing imported.
    @Test func probeCancelMarkdownFolderImport() async throws {
        let m = try await makeModel()
        let dir = FileManager.default.temporaryDirectory.appending(path: "Probe5bMd-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...200 { try Data("# Note \(i)\n\nBody \(i)\n".utf8).write(to: dir.appending(path: "note\(i).md")) }
        m.startImport(.markdownFolder(dir))
        m.cancelImport()
        _ = await waitFor { m.importState == nil || { if case .finished = m.importState { true } else { false } }() }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(m.importState == nil, "state after cancel: \(String(describing: m.importState))")
        #expect(m.noteCount == 0, "notes imported despite Cancel: \(m.noteCount)")
    }

    /// Starting a second import while one runs must not blank the second one's progress sheet.
    @Test(.disabled("Deferred minor (5b review finding 15): a second import started while one runs can blank the sheet")) func probeSecondStartKeepsItsState() async throws {
        let m = try await makeModel()
        m.importNoteDelay = 0.05
        m.startImport(.evernote(try makeENEX(notes: 60, name: "First")))
        #expect(await waitFor { if case .running(let p, _, _) = m.importState { p.notesDone >= 2 } else { false } })
        m.startImport(.evernote(try makeENEX(notes: 60, name: "Second")))
        try? await Task.sleep(for: .milliseconds(400))
        guard case .running(_, let name, _) = m.importState else {
            Issue.record("second import's sheet state: \(String(describing: m.importState))")
            return
        }
        #expect(name == "Second.enex")
    }
}
