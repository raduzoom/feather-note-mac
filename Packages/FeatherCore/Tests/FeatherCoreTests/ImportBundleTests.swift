import Foundation
import Testing
@_spi(Testing) @testable import FeatherCore

@Suite struct ImportBundleTests {
    func scratch(_ files: [String: [UInt8]]) -> URL {
        let dir = TestLibrary.directory().appending(path: "scratch")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, bytes) in files { try! Data(bytes).write(to: dir.appending(path: name)) }
        return dir
    }

    func sample() -> ImportBundle {
        let dir = scratch(["r1": [1, 2, 3]])
        return ImportBundle(
            notebooks: [.init(key: "a", name: "A", parentKey: nil), .init(key: "b", name: "B", parentKey: "a")],
            notes: [
                .init(title: "One", body: "See ![shot](feather-import://t1)", notebookKey: "b", tags: ["Kitchen", "q3"],
                      created: 1_000, modified: 2_000,
                      attachments: [AttachmentFile(token: "t1", file: dir.appending(path: "r1"), filename: "shot.png", mime: "image/png")],
                      preserved: [.table]),
                .init(title: "Two", body: "plain", notebookKey: "a", tags: ["kitchen"], created: nil, modified: nil, attachments: [], preserved: []),
            ],
            keptAsWritten: 2, scratch: dir)
    }

    @Test func bundleImportsTreeNotesTagsAttachments() async throws {
        let lib = try TestLibrary.open()
        let existing = try await lib.createTag(name: "kitchen")
        let b = sample()
        let report = try await lib.importBundle(b, into: nil)
        #expect(report.notes == 2 && report.notebooks == 2 && report.attachments == 1 && report.keptAsWritten == 2)
        let nbs = try await lib.notebooks()
        let a = try #require(nbs.first { $0.name == "A" }), bNb = try #require(nbs.first { $0.name == "B" })
        #expect(bNb.parentID == a.id && report.topNotebookID == a.id)
        let one = try #require(try await lib.notes(in: .notebook(bNb.id)).first)
        let note = try #require(try await lib.note(one.id))
        #expect(note.body.contains("](feather://attachment/") && !note.body.contains("feather-import://"))
        #expect(note.created == 1_000 && note.modified == 2_000)
        let tagCount = try await lib.tags().count
        #expect(note.tagIDs.contains(existing.id) && tagCount == 2)   // "kitchen" reused, "q3" created
        #expect(report.preserved == [PreservedContent(noteID: note.id, title: "One", kind: .table)])
        #expect(!FileManager.default.fileExists(atPath: b.scratch!.path))
    }

    @Test func collidingTopNotebookGetsSuffix() async throws {
        let lib = try TestLibrary.open()
        _ = try await lib.createNotebook(name: "A", parentID: nil)
        let report = try await lib.importBundle(sample(), into: nil)
        let top = try #require(try await lib.notebooks().first { $0.id == report.topNotebookID })
        #expect(top.name == "A (2)")
    }

    @Test func cancelledImportLeavesNothing() async throws {
        let lib = try TestLibrary.open()
        let b = sample()
        let task = Task {
            try await lib.importBundle(b, into: nil) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await lib.notes(in: .all).isEmpty)
        #expect(try await lib.notebooks().isEmpty)
        #expect(try await lib.attachments().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: b.scratch!.path))
    }

    @Test func failingImportLeavesNothing() async throws {
        let lib = try TestLibrary.open()
        struct Boom: Error {}
        await lib.setBeforeCommitHook { throw Boom() }
        await #expect(throws: Boom.self) { try await lib.importBundle(sample(), into: nil) }
        await lib.setBeforeCommitHook(nil)
        #expect(try await lib.notes(in: .all).isEmpty)
        #expect(try await lib.notebooks().isEmpty)
    }

    @Test func progressCountsEveryNote() async throws {
        let lib = try TestLibrary.open()
        let seen = Seen()
        _ = try await lib.importBundle(sample(), into: nil) { seen.add($0) }
        let last = try #require(seen.all.last)
        #expect(last.notesDone == 2 && last.notesTotal == 2 && last.attachments == 1 && last.current == "Two")
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ImportProgress] = []
    func add(_ p: ImportProgress) { lock.withLock { items.append(p) } }
    var all: [ImportProgress] { lock.withLock { items } }
}
