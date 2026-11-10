import FeatherCore
import FeatherCrypto
import Foundation
import Testing
@testable import FeatherSync

@Suite struct TwoDeviceTests {
    /// Two devices on one account, with a synced note "Groceries".
    func pair() async throws -> (TestDevice, TestDevice, ULID) {
        let a = try TestDevice("Mac A"), b = try TestDevice("Mac B")
        let email = Harness.email()
        try await a.signUp(email)
        let note = try await a.library.createNote(title: "Groceries", body: "milk")
        try await a.sync()
        try await b.signIn(email)
        try await b.sync()
        #expect(try await b.library.note(note.id)?.body == "milk")
        return (a, b, note.id)
    }

    @Test(arguments: [true, false]) func noteConflictBothOrders(aFirst: Bool) async throws { // Review Focus 1
        let (a, b, id) = try await pair()
        try await a.library.updateNote(id, body: "milk, eggs")
        try await b.library.updateNote(id, body: "milk, bread")
        let (first, second) = aFirst ? (a, b) : (b, a)
        try await first.sync()
        let report = try await second.sync()
        #expect(report.conflictCopies.count == 1)
        try await first.sync()
        try await second.sync()
        let winner = aFirst ? "milk, eggs" : "milk, bread", loser = aFirst ? "milk, bread" : "milk, eggs"
        for device in [a, b] {
            let notes = try await device.notes()
            #expect(notes.count == 2, "\(device.name): \(notes.map(\.title))")
            #expect(notes.first { $0.id == id }?.body == winner)
            let copy = notes.first { $0.id != id }
            #expect(copy?.body == loser && copy?.title.hasPrefix("Groceries (conflict, \(second.name), ") == true)
        }
    }

    @Test func metadataOnlyConflictMerges() async throws {
        let (a, b, id) = try await pair()
        let tag = try await a.library.createTag(name: "shopping")
        try await a.library.setTags(id, [tag.id])
        try await b.library.setPinned(id, true)
        try await a.sync()
        let report = try await b.sync()
        try await a.sync()
        #expect(report.conflictCopies.isEmpty)
        for device in [a, b] {
            let notes = try await device.notes()
            #expect(notes.count == 1)
            #expect(notes.first?.tagIDs == [tag.id], "\(device.name)")
        }
    }

    @Test(arguments: [true, false]) func editVersusDelete(deleteFirst: Bool) async throws {
        let (a, b, id) = try await pair()
        try await a.library.updateNote(id, body: "milk, edited")
        try await b.library.deleteNotePermanently(id)
        if deleteFirst {
            try await b.sync()
            try await a.sync()   // the edit revives the note
            try await b.sync()
        } else {
            try await a.sync()
            try await b.sync()   // the delete loses to the edit
            try await a.sync()
        }
        for device in [a, b] {
            #expect(try await device.library.note(id)?.body == "milk, edited", "\(device.name)")
        }
    }

    @Test func notebookRenameConflict() async throws {
        let (a, b, _) = try await pair()
        let nb = try await a.library.createNotebook(name: "Trips", parentID: nil)
        try await a.sync()
        try await b.sync()
        try await a.library.renameNotebook(nb.id, to: "Travel")
        try await b.library.renameNotebook(nb.id, to: "Journeys")
        try await a.sync()
        let report = try await b.sync()
        #expect(report.nameConflicts == 1)
        #expect(try await b.library.notebooks().first { $0.id == nb.id }?.name == "Travel")
        let conflicts = try await b.library.syncConflicts()
        #expect(conflicts.count == 1 && conflicts.first?.lostName == "Journeys" && conflicts.first?.device == "Mac B")
        #expect(try await a.library.syncConflicts().isEmpty)
    }

    @Test func tagConflicts() async throws {
        let (a, b, id) = try await pair()
        let tag = try await a.library.createTag(name: "home")
        try await a.sync()
        try await b.sync()
        try await a.library.renameTag(tag.id, to: "house")
        try await b.library.renameTag(tag.id, to: "flat")
        try await a.sync()
        try await b.sync()
        #expect(try await b.library.tags().first { $0.id == tag.id }?.name == "house")
        // A deletes the tag while B tags the note with it
        try await a.library.deleteTag(tag.id)
        try await b.library.setTags(id, [tag.id])
        try await a.sync()
        try await b.sync()
        try await a.sync()
        #expect(try await b.library.tags().contains { $0.id == tag.id } == false)
        let onA = try await a.library.note(id), onB = try await b.library.note(id)
        #expect(onA != nil && onB != nil)
        #expect(onB?.tagIDs.contains(tag.id) == false)
    }

    @Test func attachmentsTravel() async throws {
        let (a, b, _) = try await pair()
        let image = Data((0..<5000).map { UInt8($0 % 251) })
        let att = try await a.library.addAttachment(data: image, filename: "plan.png")
        let note = try await a.library.createNote(title: "Plan", body: "![Plan](feather://attachment/\(att.id))")
        try await a.sync()
        try await b.sync()
        let url = try #require(try await b.library.attachmentFileURL(att.id))
        #expect(try Data(contentsOf: url) == image)
        #expect(try await b.library.note(note.id)?.body.contains(att.id.description) == true)
    }

    @Test func recoveryFlow() async throws { // Review Focus 2
        let a = try TestDevice("Mac A"), b = try TestDevice("Mac B")
        let email = Harness.email()
        let key = try await a.signUp(email)
        let note = try await a.library.createNote(title: "Keep me", body: "safe")
        try await a.sync()
        await #expect(throws: AccountError.wrongPassword) { try await b.signIn(email, password: "not the password") }
        try await b.signIn(email)
        var typo = Array(key.text)
        typo[0] = typo[0] == "0" ? "1" : "0"
        if (try? RecoveryKey(parsing: String(typo))) == nil {
            await #expect(throws: AccountError.recoveryKeyTypo) { try await b.account.recover(email: email, recoveryText: String(typo), deviceName: "B") }
        }
        await #expect(throws: AccountError.wrongRecoveryKey) {
            try await b.account.recover(email: email, recoveryText: RecoveryKey.generate().text, deviceName: "B")
        }
        let handle = try await b.account.recover(email: email, recoveryText: key.text, deviceName: "Mac B")
        b.signedIn = try await b.account.finishRecovery(handle, newPassword: "a brand new password")
        // A's session was revoked: its next sync is a 401, and its notes stay
        await #expect(throws: APIError.self) { try await a.sync() }
        #expect(try await a.library.note(note.id)?.body == "safe")
        // the old password fails, the new one works (prelogin, login and recover share 10 calls a minute per email)
        await #expect(throws: AccountError.wrongPassword) { try await a.signIn(email) }
        try await a.signIn(email, password: "a brand new password")
        try await a.sync()
        #expect(try await a.notes().count == 1)
        #expect(try await a.library.note(note.id)?.body == "safe")
    }

    @Test func signInMergesLocalNotes() async throws {
        let (a, _, _) = try await pair()
        let email = a.signedIn.email
        let d = try TestDevice("Mac D")
        for i in 1...3 { _ = try await d.library.createNote(title: "Local \(i)", body: "\(i)") }
        try await d.signIn(email)
        try await d.sync()
        try await a.sync()
        #expect(try await a.notes().count == 4)
        #expect(try await d.notes().count == 4)
    }

    @Test func readOnlyKeepsPulling() async throws {
        let (a, b, id) = try await pair()
        _ = try Harness.sql("UPDATE accounts SET plan_state = 'read_only', plan_reason = 'subscription_ended' WHERE email_norm = '\(a.signedIn.email)'")
        // B's change from before the lapse (pushed while still active is impossible now), so A's edit stays here
        try await a.library.updateNote(id, body: "offline edit")
        let report = try await a.sync()
        #expect(report.readOnly)
        #expect(try await a.library.dirtyItems().contains { $0.id == id })
        // pulls continue: re-activate briefly to let B push, lapse again, and A still receives it
        _ = try Harness.sql("UPDATE accounts SET plan_state = 'active', plan_reason = NULL WHERE email_norm = '\(a.signedIn.email)'")
        let n = try await b.library.createNote(title: "From B")
        try await b.sync()
        _ = try Harness.sql("UPDATE accounts SET plan_state = 'read_only', plan_reason = 'subscription_ended' WHERE email_norm = '\(a.signedIn.email)'")
        try await a.sync()
        #expect(try await a.library.note(n.id)?.title == "From B")
        #expect(try await a.library.note(id)?.body == "offline edit")
    }
}
