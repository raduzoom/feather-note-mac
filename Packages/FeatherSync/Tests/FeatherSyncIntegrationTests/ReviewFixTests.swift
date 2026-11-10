import FeatherCore
import FeatherCrypto
import Foundation
import Testing
@testable import FeatherSync

/// Regression tests for the Part A review (Phase 8).
@Suite struct ReviewFixTests {
    func pair() async throws -> (TestDevice, TestDevice, ULID) {
        let a = try TestDevice("Mac A"), b = try TestDevice("Mac B")
        let email = Harness.email()
        try await a.signUp(email)
        let note = try await a.library.createNote(title: "Groceries", body: "milk")
        try await a.sync()
        try await b.signIn(email)
        try await b.sync()
        return (a, b, note.id)
    }

    // C1: B's unpushed body edit against A's metadata change makes a conflict copy, never a silent loss
    @Test func bodyEditAgainstMetadataChangeKeepsText() async throws {
        let (a, b, id) = try await pair()
        try await a.library.setPinned(id, true)
        try await b.library.updateNote(id, body: "milk, bread")
        try await a.sync()
        try await b.sync()
        try await a.sync()
        for device in [a, b] {
            let bodies = Set(try await device.notes().map(\.body))
            #expect(bodies == ["milk", "milk, bread"], "\(device.name): \(bodies)")
        }
        #expect(try await b.library.dirtyItems().isEmpty)
    }

    // C1: a permanent delete that loses to a metadata edit brings the note back with its real body
    @Test func revivedNoteHasItsBody() async throws {
        let (a, b, id) = try await pair()
        try await a.library.setPinned(id, true)
        try await b.library.deleteNotePermanently(id)
        try await a.sync()
        try await b.sync()
        #expect(try await b.library.note(id)?.body == "milk")
    }

    // C2 (and Focus 5): an edit made after a push, before the pull, is pushed next time, with no conflict copy
    @Test func editBetweenPushAndPullIsPushedLater() async throws {
        let (a, b, id) = try await pair()
        try await a.library.updateNote(id, body: "v1")
        await a.engine.setTestHook { event, _ in
            if event == "afterPush" { try? await a.library.updateNote(id, body: "v2") }
        }
        try await a.sync()
        await a.engine.setTestHook(nil)
        try await a.sync()
        try await b.sync()
        #expect(try await b.library.note(id)?.body == "v2")
        let onA = try await a.notes(), onB = try await b.notes()
        #expect(onA.count == 1 && onB.count == 1)
    }

    // C3: typing while a pull applies the other device's change is kept as a conflict copy
    @Test func typingDuringPullIsKept() async throws {
        let (a, b, id) = try await pair()
        try await b.library.updateNote(id, body: "from B")
        try await b.sync()
        await a.engine.setTestHook { event, item in
            if event == "beforeApply", item == id { try? await a.library.updateNote(id, body: "A typed during pull") }
        }
        try await a.sync()
        await a.engine.setTestHook(nil)
        try await a.sync()
        try await b.sync()
        for device in [a, b] {
            let bodies = Set(try await device.notes().map(\.body))
            #expect(bodies == ["from B", "A typed during pull"], "\(device.name): \(bodies)")
        }
    }

    // I1: notes keep their notebook and tags on a new device even when those were renamed after the note
    @Test func referencesSurviveSeqOrder() async throws {
        let a = try TestDevice("Mac A"), b = try TestDevice("Mac B")
        let email = Harness.email()
        try await a.signUp(email)
        let nb = try await a.library.createNotebook(name: "Work", parentID: nil)
        let tag = try await a.library.createTag(name: "todo")
        let note = try await a.library.createNote(title: "Plan", body: "x", notebookID: nb.id, tagIDs: [tag.id])
        try await a.sync()
        try await a.library.renameNotebook(nb.id, to: "Office")
        try await a.library.renameTag(tag.id, to: "next")
        try await a.sync()
        try await b.signIn(email)
        try await b.sync()
        let onB = try #require(try await b.library.note(note.id))
        #expect(onB.notebookID == nb.id && onB.tagIDs == [tag.id])
        #expect(try await b.library.dirtyItems().isEmpty)
    }

    // I2: a blob the server no longer has is uploaded again instead of being rejected forever
    @Test func blobMissingIsReuploaded() async throws {
        let (a, b, id) = try await pair()
        _ = try Harness.sql("DELETE FROM blobs WHERE account_id = (SELECT id FROM accounts WHERE email_norm = '\(a.signedIn.email)')")
        try await a.library.setPinned(id, true)
        let first = try await a.sync()
        #expect(first.rejected[id.description] == "blob_missing")
        let second = try await a.sync()
        #expect(second.rejected.isEmpty)
        #expect(try await a.library.dirtyItems().isEmpty)
        try await b.sync()
        let onB = try await b.library.note(id)
        #expect(onB?.pinned == true && onB?.body == "milk")
    }

    // I3: two passes started together don't push the same changes twice
    @Test func concurrentPassesAreSerial() async throws {
        let (a, b, _) = try await pair()
        for i in 1...5 { _ = try await a.library.createNote(title: "N\(i)", body: "\(i)") }
        async let r1 = a.sync()
        async let r2 = a.sync()
        let (x, y) = try await (r1, r2)
        #expect(x.pushed + y.pushed == 5 && x.conflictCopies.isEmpty && y.conflictCopies.isEmpty)
        try await b.sync()
        #expect(try await b.notes().count == 6)
    }

    // I3: after a 401 ends the schedule, starting it again works
    @Test func scheduleRestartsAfterSignOut() async throws {
        let (a, _, _) = try await pair()
        let signedOut = Flag(), synced = Flag()
        let engine = a.engine!
        await a.account.forget()
        await engine.start(beforeSync: {}, onPulled: { _ in }, onSignedOut: { signedOut.set() })
        try await signedOut.wait()
        _ = try await a.account.signIn(email: a.signedIn.email, password: "correct horse battery", deviceName: "Mac A")   // same engine
        let updates = await engine.statusUpdates()
        let watcher = Task { for await s in updates { if case .idle(let d) = s, d != nil { synced.set(); return } } }
        await engine.start(beforeSync: {}, onPulled: { _ in }, onSignedOut: {})
        try await synced.wait()
        watcher.cancel()
        await engine.stop()
    }
}

/// A one-shot signal tests can wait on (with a timeout).
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.withLock { isSet = true } }
    func wait(seconds: Double = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !lock.withLock({ isSet }) {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
