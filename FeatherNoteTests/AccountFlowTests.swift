import FeatherCore
import FeatherCrypto
import FeatherSync
import Foundation
import Testing
@testable import FeatherNote

@MainActor @Suite struct AccountFlowTests {
    @Test func passwordStrengthBands() {
        #expect(PasswordStrength("123456789") == .tooShort && PasswordStrength("123456789").label == nil)
        #expect(PasswordStrength("1234567890") == .fair && PasswordStrength("1234567890").label == "Fair")
        #expect(PasswordStrength("123456789012") == .good && PasswordStrength("123456789012").label == "Good")
        #expect(PasswordStrength("1234567890123456") == .strong && PasswordStrength("1234567890123456").label == "Strong")
        #expect(PasswordStrength(String(repeating: "e\u{301}", count: 10)) == .fair)   // 20 scalars typed, 10 after NFC
    }

    @Test func onboardingSteps() async throws {
        let m = try await makeModel()
        let flow = OnboardingFlow(cloud: m.cloud)
        #expect(flow.step == 1 && flow.canContinue)
        await flow.next()
        #expect(flow.step == 2 && !flow.canContinue)
        flow.email = "ana@example.com"
        flow.password = "short"
        #expect(!flow.canContinue)
        flow.password = "correct horse battery"
        #expect(flow.canContinue)
        flow.step = 3
        flow.back()
        #expect(flow.step == 2 && flow.email == "ana@example.com" && flow.password == "correct horse battery")
        flow.step = 3
        flow.code = "12345"
        #expect(!flow.canContinue)
        flow.code = "123456"
        #expect(flow.canContinue)
        flow.showRecoveryKey(RecoveryKey.generate())
        #expect(flow.step == 4 && !flow.canContinue)
        flow.back()   // the account exists by now: there's no going back to the code
        #expect(flow.step == 4 && !flow.canGoBack)
        flow.savedConfirmed = true
        #expect(flow.canContinue)
    }

    @Test func recoveryKeyShownOnce() async throws {
        let m = try await makeModel()
        let flow = OnboardingFlow(cloud: m.cloud)
        let key = RecoveryKey.generate()
        flow.showRecoveryKey(key)
        #expect(flow.recoveryText == key.text)
        flow.savedConfirmed = true
        await flow.next()
        #expect(flow.step == 5 && flow.recoveryText == nil)
        let stored = m.defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        #expect(!stored.contains(key.text))
    }

    @Test func signInErrorsShowSpecCopy() { // Review Focus 2
        #expect(AccountCopy.message(.wrongPassword) == "That password doesn't match. Forgot it? Sign in with your recovery key instead.")
        #expect(AccountCopy.message(.recoveryKeyTypo) == "That recovery key has a typo. Check each group and try again.")
        #expect(AccountCopy.message(.wrongRecoveryKey) == "That recovery key doesn't match this account.")
        #expect(AccountCopy.message(.network) == "The server didn't respond.")
        #expect(AccountCopy.lostBoth == "Without your password or your recovery key, your notes can't be decrypted by anyone, including us.")
        #expect(AccountCopy.verifySent("ana@example.com") == "We sent a 6-digit code to ana@example.com. It expires in 15 minutes.")
    }

    @Test func mergePromptWhenLocalNotes() async throws {
        let m = try await makeModel()
        for i in 1...3 { _ = try await m.library.createNote(title: "Local \(i)") }
        let flow = SignInFlow(cloud: m.cloud)
        let plan = CloudPlan(state: "active", reason: nil, trialEndsAt: nil, quotaBytes: 1, usedBytes: 0)
        let s = SignedIn(email: "ana@example.com", server: .hosted, deviceID: "D", libraryID: "01JC8ZN0AB1CD2EF3GH4JK5MN6",
                         account: CloudAccount(email: "ana@example.com", libraryID: "01JC8ZN0AB1CD2EF3GH4JK5MN6", plan: plan, billingEnabled: true))
        await flow.didAuthenticate(s)
        #expect(flow.mergePrompt == 3 && m.cloud.state == .signedOut)
        await flow.cancelMerge()
        #expect(flow.mergePrompt == nil && m.cloud.state == .signedOut)
        #expect(try await m.library.notes(in: .all).count == 3)
    }
}
