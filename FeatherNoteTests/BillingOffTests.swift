import FeatherCore
import FeatherSync
import Foundation
import Testing
@testable import FeatherNote

/// 1.0.0: Feather Cloud runs with billing off (roadmap, 2026-11-10).
@MainActor @Suite struct BillingOffTests {
    func model(billing: Bool) async throws -> AppModel {
        let m = try await makeModel()
        m.cloud.environment.hostedBillingEnabled = billing
        return m
    }

    @Test func billingOffHostedShowsNoTrialAnywhere() async throws { // Review Focus 1
        let m = try await model(billing: false)
        #expect(m.cloud.server == .hosted && !m.cloud.billingEnabled && !m.cloud.offersTrial)
        let bullets = OnboardingFlow(cloud: m.cloud).introBullets.joined(separator: " ")
        #expect(!bullets.contains("14 days") && !bullets.lowercased().contains("trial") && !bullets.contains("stop paying"))
        #expect(bullets.contains("Free during the first release."))
        #expect(m.cloud.signedOutActions == ["Create Free Account…", "Sign In…"])
        #expect(SyncStatusText.make(state: m.cloud.state, status: m.cloud.status, plan: nil, selfHostedHost: nil, now: Date()).title
                == "Sync with Feather Cloud")
    }

    @Test func billingOnHostedKeepsTrial() async throws {
        let m = try await model(billing: true)
        #expect(m.cloud.billingEnabled && m.cloud.offersTrial)
        #expect(OnboardingFlow(cloud: m.cloud).introBullets.contains("14 days free, no card. 1 GB during the trial."))
        #expect(m.cloud.signedOutActions == ["Start Free 14-Day Trial…", "Sign In…"])
    }

    @Test func signedInAccountDecides() async throws {
        let m = try await model(billing: true)
        let stale = CloudPlan(state: "read_only", reason: "trial_expired", trialEndsAt: nil, quotaBytes: 1_073_741_824, usedBytes: 1_020_054_733)
        let s = SignedIn(email: "a@x.io", server: .hosted, deviceID: "D", libraryID: "01JC8ZN0AB1CD2EF3GH4JK5MN6",
                         account: CloudAccount(email: "a@x.io", libraryID: "01JC8ZN0AB1CD2EF3GH4JK5MN6", plan: stale, billingEnabled: false))
        await m.cloud.didSignIn(s, merge: false)
        #expect(!m.cloud.billingEnabled)
        let banner = CloudBanner.make(status: .idle(lastSynced: nil), plan: stale, billingEnabled: m.cloud.billingEnabled,
                                      selfHosted: m.cloud.isSelfHosted, now: Date())
        #expect(banner == .storageNearlyFull(used: 1_020_054_733, quota: 1_073_741_824))
        // no read-only banner without billing, even when the status says read-only; the 95% storage banner remains
        #expect(CloudBanner.make(status: .readOnly, plan: stale, billingEnabled: false, selfHosted: false, now: Date())
                == .storageNearlyFull(used: 1_020_054_733, quota: 1_073_741_824))
        await m.cloud.signOut()
    }

    @Test func selfHostedWithBillingShowsNoFeatherCloudTrial() async throws { // review fix: trial terms are Feather Cloud's
        let m = try await model(billing: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServerInfoProtocol.self]
        m.cloud.environment.configuration = { config }
        ServerInfoProtocol.billing = true
        #expect(await m.cloud.connect(serverInput: "notes.home.lan") == nil)
        #expect(m.cloud.isSelfHosted && !m.cloud.offersTrial)
        let bullets = OnboardingFlow(cloud: m.cloud).introBullets.joined(separator: " ")
        #expect(!bullets.contains("14 days") && !bullets.lowercased().contains("trial"))
        ServerInfoProtocol.billing = false
    }

    @Test func selfHostedStillShowsNone() {
        let full = CloudPlan(state: "active", reason: nil, trialEndsAt: nil, quotaBytes: 100, usedBytes: 100)
        #expect(CloudBanner.make(status: .quotaFull, plan: full, billingEnabled: false, selfHosted: true, now: Date()) == nil)
    }
}
