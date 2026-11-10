import FeatherCore
import FeatherCrypto
import FeatherSync
import Foundation
import Testing
@testable import FeatherNote

/// Regression tests for the Phase 8 Part B review.
@MainActor @Suite struct ReviewFix8bTests {
    // I-1: typing after the pre-sync save, while the pull brings another Mac's edit of the same note: both survive
    @Test func typingAfterFlushKeepsBothVersions() async throws {
        let m = try await makeModel()
        await m.newNote()
        let id = try #require(m.selectedNoteID)
        m.editBody("shared line")
        await m.flush()
        // the note is synced and clean at version 1
        _ = try await m.library.collectChanges()
        try await m.library.markPushed(id, version: 1, blobSHA: "b1", ifDirtySeq: try #require(try await m.library.syncItem(id)?.dirtySeq))
        await m.cloud.hooks.beforeSync()
        m.editBody("shared line + typed here")   // after the flush: still only in memory
        var other = try #require(try await m.library.note(id))
        other.body = "shared line + written on the other Mac"
        #expect(try await m.library.applyRemote(note: other, version: 2, blobSHA: "b2", extraMeta: nil, metaVersion: 1))
        await m.cloud.hooks.onPulled([id])
        await m.flush()
        var bodies: [String] = []
        for s in try await m.library.notes(in: .all) { bodies.append(try #require(try await m.library.note(s.id)).body) }
        #expect(Set(bodies) == ["shared line + written on the other Mac", "shared line + typed here"])
        #expect(try await m.library.note(id)?.body == "shared line + written on the other Mac")
        #expect(m.editor?.body == "shared line + typed here")   // still in front of you, now in the copy
    }

    // I-2: signed out by the server: say so, keep the email, and never fall back to the trial pitch
    @Test func serverSignOutAsksToSignInAgain() async throws {
        let m = try await makeModel()
        let plan = CloudPlan(state: "active", reason: nil, trialEndsAt: nil, quotaBytes: 1, usedBytes: 0)
        let s = SignedIn(email: "ana@example.com", server: .hosted, deviceID: "D", libraryID: "01JC8ZN0AB1CD2EF3GH4JK5MN6",
                         account: CloudAccount(email: "ana@example.com", libraryID: "01JC8ZN0AB1CD2EF3GH4JK5MN6", plan: plan, billingEnabled: true))
        await m.cloud.didSignIn(s, merge: false)
        await m.cloud.serverSignedOut()
        #expect(m.cloud.state == .signedOut && m.cloud.reauthEmail == "ana@example.com" && !m.cloud.offersTrial)
        let text = SyncStatusText.make(state: m.cloud.state, status: m.cloud.status, plan: nil, selfHostedHost: nil,
                                       reauthEmail: m.cloud.reauthEmail, now: Date())
        #expect(text == SyncStatusText(title: "Signed out of Feather Cloud", detail: "Sign in again to keep syncing.", action: "Sign In…"))
        m.cloud.showSignIn()
        guard case .signIn(let flow)? = m.cloud.sheet else { Issue.record("no sign-in sheet"); return }
        #expect(flow.email == "ana@example.com")
        // a deliberate sign-out is different: the trial offer comes back
        await m.cloud.signOut()
        #expect(m.cloud.reauthEmail == nil && m.cloud.offersTrial)
    }
}
