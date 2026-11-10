import Foundation
import Testing
@testable import FeatherCore

@Suite struct SyncSupportTests {
    let t0 = TestLibrary.t0

    @Test func collectMarksLocalEditsDirty() async throws {
        let lib = try TestLibrary.open()
        let note = try await lib.createNote(title: "A", body: "a")
        let gone = try await lib.createNote(title: "B")
        let tag = try await lib.createTag(name: "x")
        _ = try await lib.collectChanges()
        try await lib.renameTag(tag.id, to: "y")
        try await lib.deleteNotePermanently(gone.id)
        try await lib.updateNote(note.id, body: "a2")
        #expect(try await lib.collectChanges() == 3)
        let dirty = Dictionary(uniqueKeysWithValues: try await lib.dirtyItems().map { ($0.id, $0) })
        #expect(dirty[note.id]?.bodyDirty == true && dirty[note.id]?.type == .note)
        #expect(dirty[gone.id]?.deleted == true)
        #expect(dirty[tag.id]?.type == .tag && dirty[tag.id]?.bodyDirty == false)
        #expect(try await lib.collectChanges() == 0)
    }

    @Test func remoteApplyIsNotALocalChange() async throws {
        let lib = try TestLibrary.open()
        let id = ULID.generate(at: t0)
        let note = Note(id: id, title: "Remote", body: "from B", notebookID: nil, tagIDs: [], pinned: true, created: t0, modified: t0, trashedAt: nil)
        try await lib.applyRemote(note: note, version: 4, blobSHA: "b1", extraMeta: nil, metaVersion: 1)
        #expect(try await lib.collectChanges() == 0)
        #expect(try await lib.note(id) == note)
        #expect(try await lib.syncItem(id)?.serverVersion == 4)
        #expect(try await lib.syncItem(id)?.dirtySeq == nil)
        // an update to the same note, and a remote delete
        var changed = note
        changed.title = "Remote 2"
        try await lib.applyRemote(note: changed, version: 5, blobSHA: "b2", extraMeta: nil, metaVersion: 1)
        #expect(try await lib.note(id)?.title == "Remote 2")
        try await lib.applyRemoteDelete(id, type: .note, version: 6)
        #expect(try await lib.note(id) == nil)
        #expect(try await lib.collectChanges() == 0)
    }

    @Test func markPushedKeepsLaterEdits() async throws { // Review Focus 5
        let lib = try TestLibrary.open()
        let note = try await lib.createNote(title: "A")
        _ = try await lib.collectChanges()
        let s1 = try #require(try await lib.syncItem(note.id)?.dirtySeq)
        try await lib.updateNote(note.id, body: "later")
        _ = try await lib.collectChanges()
        let s2 = try #require(try await lib.syncItem(note.id)?.dirtySeq)
        try await lib.markPushed(note.id, version: 5, blobSHA: "x", ifDirtySeq: s1)
        #expect(try await lib.syncItem(note.id)?.dirtySeq == s2)
        #expect(try await lib.syncItem(note.id)?.serverVersion == 5)
        try await lib.markPushed(note.id, version: 6, blobSHA: "y", ifDirtySeq: s2)
        let item = try #require(try await lib.syncItem(note.id))
        #expect(item.dirtySeq == nil && !item.bodyDirty && item.blobSHA == "y")
        #expect(try await lib.dirtyItems().isEmpty)
    }

    @Test func extraMetaRoundTrips() async throws {
        let lib = try TestLibrary.open()
        let id = ULID.generate(at: t0)
        let note = Note(id: id, title: "R", body: "", notebookID: nil, tagIDs: [], pinned: false, created: t0, modified: t0, trashedAt: nil)
        try await lib.applyRemote(note: note, version: 1, blobSHA: nil, extraMeta: #"{"color":"red"}"#, metaVersion: 1)
        try await lib.updateNote(id, title: "R2")
        _ = try await lib.collectChanges()
        #expect(try await lib.syncItem(id)?.extraMeta == #"{"color":"red"}"#)
        #expect(try await lib.syncItem(id)?.dirtySeq != nil)
    }

    @Test func resetForMerge() async throws {
        let lib = try TestLibrary.open()
        let nb = try await lib.createNotebook(name: "N", parentID: nil)
        let tag = try await lib.createTag(name: "t")
        let note = try await lib.createNote(title: "x", notebookID: nb.id)
        try await lib.setSyncValue("pull_cursor", "c_000000000009")
        try await lib.resetSync(markAllDirty: true)
        let dirty = try await lib.dirtyItems()
        #expect(Set(dirty.map(\.id)) == [nb.id, tag.id, note.id])
        #expect(dirty.allSatisfy { $0.serverVersion == 0 })
        #expect(dirty.first { $0.id == note.id }?.bodyDirty == true)
        #expect(try await lib.syncValue("pull_cursor") == nil)
        try await lib.resetSync(markAllDirty: false)
        #expect(try await lib.dirtyItems().isEmpty)
    }

    @Test func conflictCopyIsALocalCreate() async throws {
        let lib = try TestLibrary.open()
        let nb = try await lib.createNotebook(name: "N", parentID: nil)
        let tag = try await lib.createTag(name: "t")
        var note = try await lib.createNote(title: "Groceries", body: "milk", notebookID: nb.id, tagIDs: [tag.id])
        try await lib.setPinned(note.id, true)
        note = try #require(try await lib.note(note.id))
        _ = try await lib.collectChanges()
        let copy = try await lib.createConflictCopy(of: note, title: "Groceries (conflict, Mac, 9 Nov 14:32)")
        #expect(copy.id != note.id && copy.body == "milk" && copy.tagIDs == [tag.id] && copy.notebookID == nb.id && copy.pinned)
        #expect(copy.title == "Groceries (conflict, Mac, 9 Nov 14:32)")
        #expect(try await lib.collectChanges() >= 1)
        #expect(try await lib.dirtyItems().contains { $0.id == copy.id && $0.bodyDirty })
    }

    @Test func remoteNotesTolerateMissingReferences() async throws {
        let lib = try TestLibrary.open()
        let note = Note(id: ULID.generate(at: t0), title: "R", body: "", notebookID: ULID.generate(at: t0), tagIDs: [ULID.generate(at: t0)],
                        pinned: false, created: t0, modified: t0, trashedAt: nil)
        try await lib.applyRemote(note: note, version: 1, blobSHA: nil, extraMeta: nil, metaVersion: 1)
        let stored = try #require(try await lib.note(note.id))
        #expect(stored.notebookID == nil && stored.tagIDs.isEmpty)
    }

    @Test func remoteTagWithATakenNameIsKept() async throws {
        let lib = try TestLibrary.open()
        _ = try await lib.createTag(name: "Travel")
        let remote = Tag(id: ULID.generate(at: t0), name: "travel", created: t0, modified: t0)
        try await lib.applyRemote(tag: remote, version: 1, extraMeta: nil, metaVersion: 1)
        #expect(try await lib.tags().count == 2)
    }

    @Test func remoteAttachmentStoresContent() async throws {
        let lib = try TestLibrary.open()
        let data = Data("hello".utf8)
        let a = Attachment(id: ULID.generate(at: t0), filename: "h.txt", mime: "text/plain", size: 5,
                           sha256: AttachmentStore.sha256(data), created: t0)
        try await lib.applyRemote(attachment: a, content: data, version: 1, blobSHA: "e1", extraMeta: nil, metaVersion: 1)
        #expect(try await lib.attachment(a.id) == a)
        #expect(try Data(contentsOf: #require(try await lib.attachmentFileURL(a.id))) == data)
        #expect(try await lib.collectChanges() == 0)
    }

    @Test func nameConflictsListNewestFirst() async throws {
        let clock = TestClock()
        let lib = try TestLibrary.open(clock: clock)
        let id = ULID.generate(at: t0)
        try await lib.recordSyncConflict(itemID: id, type: .notebook, lostName: "Old", device: "Mac")
        clock.advance(1000)
        try await lib.recordSyncConflict(itemID: id, type: .tag, lostName: "Newer", device: "Mac")
        let list = try await lib.syncConflicts()
        #expect(list.map(\.lostName) == ["Newer", "Old"])
    }

    @Test func migratesFromV2() async throws {
        let dir = TestLibrary.directory()
        let note: Note
        do {
            let lib = try Library.open(at: dir)
            note = try await lib.createNote(title: "Kept")
        }
        do {
            let db = try Connection(path: dir.appending(path: "library.sqlite").path)
            try db.execute("DROP TABLE sync_items; DROP TABLE sync_state; DROP TABLE sync_conflicts; PRAGMA user_version = 2")
        }
        let lib = try Library.open(at: dir)
        #expect(try await lib.note(note.id)?.title == "Kept")
        #expect(try await lib.dirtyItems().isEmpty)
        #expect(try await lib.collectChanges() == 1) // the create from before the migration is still in the change log
    }

    @Test func rebaseKeepsItDirty() async throws {
        let lib = try TestLibrary.open()
        let note = try await lib.createNote(title: "A")
        _ = try await lib.collectChanges()
        try await lib.rebase(note.id, version: 7)
        let item = try #require(try await lib.syncItem(note.id))
        #expect(item.serverVersion == 7 && item.dirtySeq != nil && item.bodyDirty)
    }

    // review C3: an edit made after the engine looked is never overwritten by a remote write
    @Test func applyRemoteRefusesUnseenLocalEdits() async throws {
        let lib = try TestLibrary.open()
        let id = ULID.generate(at: t0)
        let remote = Note(id: id, title: "R", body: "server", notebookID: nil, tagIDs: [], pinned: false, created: t0, modified: t0, trashedAt: nil)
        #expect(try await lib.applyRemote(note: remote, version: 1, blobSHA: nil, extraMeta: nil, metaVersion: 1))
        try await lib.updateNote(id, body: "typed")   // not collected yet
        #expect(try await !lib.applyRemote(note: remote, version: 2, blobSHA: nil, extraMeta: nil, metaVersion: 1))
        #expect(try await lib.note(id)?.body == "typed")
        _ = try await lib.collectChanges()
        let seq = try #require(try await lib.syncItem(id)?.dirtySeq)
        #expect(try await !lib.applyRemote(note: remote, version: 2, blobSHA: nil, extraMeta: nil, metaVersion: 1))   // dirty, not expected
        #expect(try await lib.applyRemote(note: remote, version: 2, blobSHA: nil, extraMeta: nil, metaVersion: 1, ifDirtySeq: seq))
        #expect(try await lib.note(id)?.body == "server")
        #expect(try await !lib.applyRemoteDelete(id, type: .note, version: 3, ifDirtySeq: seq))   // clean now: seq no longer matches
        #expect(try await lib.applyRemoteDelete(id, type: .note, version: 3))
    }

    @Test func markBodyDirty() async throws {
        let lib = try TestLibrary.open()
        let note = try await lib.createNote(title: "A")
        _ = try await lib.collectChanges()
        try await lib.markPushed(note.id, version: 1, blobSHA: "x", ifDirtySeq: try #require(try await lib.syncItem(note.id)?.dirtySeq))
        try await lib.markBodyDirty(note.id)
        let item = try #require(try await lib.syncItem(note.id))
        #expect(item.bodyDirty && item.dirtySeq != nil)
    }

    @Test func referencesResolve() async throws {
        let lib = try TestLibrary.open()
        let nb = try await lib.createNotebook(name: "N", parentID: nil)
        let tag = try await lib.createTag(name: "t")
        #expect(try await lib.referencesResolve(notebookID: nb.id, tagIDs: [tag.id]))
        #expect(try await !lib.referencesResolve(notebookID: ULID.generate(at: t0), tagIDs: []))
        #expect(try await !lib.referencesResolve(notebookID: nil, tagIDs: [ULID.generate(at: t0)]))
    }
}
