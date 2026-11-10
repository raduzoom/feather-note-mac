import FeatherCore
import FeatherSync
import Foundation
import Testing
@testable import FeatherNote

@Suite struct SyncStatusTextTests {
    let now = Date(timeIntervalSince1970: 1_794_234_720)
    var twoMinAgo: Date { now.addingTimeInterval(-120) }
    let signedIn = CloudState.signedIn(SignedIn(email: "a@x.io", server: .hosted, deviceID: "D", libraryID: "L",
                                                account: CloudAccount(email: "a@x.io", libraryID: "L",
                                                                      plan: CloudPlan(state: "active", reason: nil, trialEndsAt: nil, quotaBytes: 1, usedBytes: 0),
                                                                      billingEnabled: true)))
    let active = CloudPlan(state: "active", reason: nil, trialEndsAt: nil, quotaBytes: 10_737_418_240, usedBytes: 0)

    func text(_ state: CloudState, _ status: SyncStatus, plan: CloudPlan? = nil, host: String? = nil) -> SyncStatusText {
        SyncStatusText.make(state: state, status: status, plan: plan ?? active, selfHostedHost: host, now: now)
    }

    @Test func boardStates() {
        #expect(text(.signedOut, .idle(lastSynced: nil)) == SyncStatusText(title: "Sync with Feather Cloud", detail: nil, action: nil))
        #expect(text(signedIn, .idle(lastSynced: twoMinAgo)) == SyncStatusText(title: "Synced", detail: "2 min ago", action: nil))
        #expect(text(signedIn, .syncing(done: 12, total: 40)) == SyncStatusText(title: "Syncing… 12 of 40", detail: nil, action: nil))
        #expect(text(signedIn, .offline) == SyncStatusText(title: "Offline", detail: "Changes sync when you're back online.", action: nil))
        #expect(text(signedIn, .error("The server didn't respond.")) == SyncStatusText(title: "Couldn't sync", detail: "The server didn't respond.", action: "Try Again"))
        let trial = CloudPlan(state: "trial", reason: nil, trialEndsAt: now.addingTimeInterval(9 * 86_400 - 60), quotaBytes: 1_073_741_824, usedBytes: 125_829_120)
        #expect(text(signedIn, .idle(lastSynced: twoMinAgo), plan: trial) == SyncStatusText(title: "Trial: 9 days left", detail: "120 MB of 1 GB · synced 2 min ago", action: nil))
        #expect(text(signedIn, .readOnly) == SyncStatusText(title: "Read-only sync", detail: "Notes still arrive. Changes here stay on this Mac.", action: nil))
        #expect(text(signedIn, .idle(lastSynced: twoMinAgo), host: "notes.home.lan") == SyncStatusText(title: "notes.home.lan", detail: "Synced 2 min ago", action: nil))
    }

    @Test func readOnlyPlanIsReadOnlyEvenWhenIdle() {
        let lapsed = CloudPlan(state: "read_only", reason: "subscription_ended", trialEndsAt: nil, quotaBytes: 10_737_418_240, usedBytes: 0)
        #expect(text(signedIn, .idle(lastSynced: twoMinAgo), plan: lapsed).title == "Read-only sync")
    }

    @Test func banners() {
        #expect(CloudBanner.make(status: .readOnly, plan: active, selfHosted: false, now: now) == .readOnly)
        #expect(CloudBanner.readOnly.text == "Your Feather Cloud subscription has ended. Your notes are safe on this device and still arrive from your other devices, but changes made here won't upload until you subscribe. Nothing has been deleted.")
        let ending = CloudPlan(state: "trial", reason: nil, trialEndsAt: now.addingTimeInterval(3 * 86_400 - 60), quotaBytes: 1, usedBytes: 0)
        #expect(CloudBanner.make(status: .idle(lastSynced: nil), plan: ending, selfHosted: false, now: now)?.text
                == "Your Feather Cloud trial ends in 3 days. Subscribe to keep syncing; your notes stay on this Mac either way.")
        let full90 = CloudPlan(state: "active", reason: nil, trialEndsAt: nil, quotaBytes: 10_737_418_240, usedBytes: 9_663_676_416)
        #expect(CloudBanner.make(status: .idle(lastSynced: nil), plan: full90, selfHosted: false, now: now)?.text
                == "Your Feather Cloud storage is 90% full: 9 GB of 10 GB.")
        #expect(CloudBanner.make(status: .quotaFull, plan: active, selfHosted: false, now: now)?.text
                == "Your Feather Cloud storage is full. New changes stay on this device until you free up space.")
        #expect(CloudBanner.make(status: .idle(lastSynced: nil), plan: active, selfHosted: false, now: now) == nil)
        #expect(CloudBanner.make(status: .idle(lastSynced: nil), plan: ending, selfHosted: true, now: now) == nil)
    }
}
