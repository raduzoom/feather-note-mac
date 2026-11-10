import FeatherCore
import FeatherCrypto
import FeatherSync
import Foundation
import Observation

/// The strength label on the password field (board desktop-onboarding-2): code points after NFC.
enum PasswordStrength: Equatable {
    case tooShort, fair, good, strong

    init(_ password: String) {
        let n = password.precomposedStringWithCanonicalMapping.unicodeScalars.count
        self = n < 10 ? .tooShort : n < 12 ? .fair : n < 16 ? .good : .strong
    }

    var label: String? {
        switch self {
        case .tooShort: nil
        case .fair: "Fair"
        case .good: "Good"
        case .strong: "Strong"
        }
    }
}

/// Fixed account copy (ui-copy.md "Security and recovery", the onboarding and sign-in boards).
enum AccountCopy {
    static let lostBoth = "Without your password or your recovery key, your notes can't be decrypted by anyone, including us."
    static let encryption = "Your notes are encrypted on this device before they're uploaded. Only your devices can read them."
    static let passwordNote = "We never see this password, so we can't reset it for you. In step 4 you'll get a recovery key as your backup."
    static let passwordHint = "Use 12 or more characters. A few random words work well."
    static let recoveryTitle = "Save your recovery key"
    static let recoveryBody = "This key is the only way back into your notes if you forget your password. Feather Cloud never sees your password or your notes, so we can't reset it for you. Print it or save it somewhere safe, away from this device."
    static let recoveryConfirm = "I've saved my recovery key somewhere safe"

    static func verifySent(_ email: String) -> String { "We sent a 6-digit code to \(email). It expires in 15 minutes." }

    static func message(_ e: AccountError) -> String {
        switch e {
        case .wrongPassword: "That password doesn't match. Forgot it? Sign in with your recovery key instead."
        case .recoveryKeyTypo: "That recovery key has a typo. Check each group and try again."
        case .wrongRecoveryKey: "That recovery key doesn't match this account."
        case .emailUnverified: "This account isn't verified yet. Finish creating it with the code we emailed you."
        case .codeInvalid: "That code doesn't match. Check the email and try again."
        case .codeExpired: "That code has expired. Send a new one."
        case .passwordTooShort: "Use at least 10 characters."
        case .rateLimited: "Too many attempts. Wait a minute and try again."
        case .network: "The server didn't respond."
        case .server: "Something went wrong on the server. Try again."
        }
    }

    static func message(_ error: Error) -> String {
        (error as? AccountError).map(message) ?? "Something went wrong. Try again."
    }
}

/// Feather Cloud onboarding, steps 1–5 (desktop-onboarding-* boards).
@MainActor @Observable
final class OnboardingFlow {
    let cloud: CloudModel
    var step = 1
    var email = ""
    var password = ""
    var code = ""
    var savedConfirmed = false
    /// Shown on step 4 only, then forgotten; never stored.
    private(set) var recoveryText: String?
    private(set) var working = false
    private(set) var error: String?
    private(set) var signedIn: SignedIn?

    init(cloud: CloudModel) { self.cloud = cloud }

    var strength: PasswordStrength { PasswordStrength(password) }

    var emailLooksValid: Bool {
        let parts = email.trimmingCharacters(in: .whitespaces).split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }

    var canContinue: Bool {
        guard !working else { return false }
        switch step {
        case 2: return emailLooksValid && strength != .tooShort
        case 3: return code.count == 6 && code.allSatisfy(\.isNumber)
        case 4: return savedConfirmed
        default: return true
        }
    }

    func showRecoveryKey(_ key: RecoveryKey) {
        recoveryText = key.text
        savedConfirmed = false
        step = 4
    }

    private var pendingKey: RecoveryKey?

    func next() async {
        guard canContinue else { return }
        error = nil
        switch step {
        case 1:
            step = 2
        case 2:
            working = true
            defer { working = false }
            do {
                pendingKey = try await cloud.accountService().startSignup(email: email.trimmingCharacters(in: .whitespaces),
                                                                          password: password, libraryID: cloud.library.id.description)
                step = 3
            } catch { self.error = AccountCopy.message(error) }
        case 3:
            working = true
            defer { working = false }
            do {
                signedIn = try await cloud.accountService().verify(email: email.trimmingCharacters(in: .whitespaces), code: code,
                                                                   deviceName: cloud.environment.deviceName)
                password = ""
                if let key = pendingKey { showRecoveryKey(key) }
                pendingKey = nil
            } catch { self.error = AccountCopy.message(error) }
        case 4:
            recoveryText = nil
            step = 5
            if let s = signedIn { await cloud.didSignIn(s, merge: true) }   // this Mac's notes are new to the account
        default:
            break
        }
    }

    /// Back stops at step 4: once the code is verified the account exists, and the code is spent.
    var canGoBack: Bool { step > 1 && step < 4 && !working }

    func back() {
        guard canGoBack else { return }
        error = nil
        step -= 1
    }

    func resend() async {
        do { try await cloud.accountService().resend(email: email.trimmingCharacters(in: .whitespaces)) } catch { self.error = AccountCopy.message(error) }
    }
}

/// Sign in on another Mac, or with the recovery key (desktop-signin-* boards).
@MainActor @Observable
final class SignInFlow {
    enum Mode { case password, recoveryKey, newPassword }

    let cloud: CloudModel
    var mode = Mode.password
    var email = ""
    var password = ""
    var recoveryText = ""
    var newPassword = ""
    var confirmPassword = ""
    private(set) var working = false
    private(set) var error: String?
    /// How many notes this Mac already has, when signing in would merge them into the account.
    private(set) var mergePrompt: Int?
    private(set) var done = false
    private var pending: SignedIn?
    private var recovery: RecoveryHandle?

    init(cloud: CloudModel) { self.cloud = cloud }

    var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    func signIn() async {
        working = true
        defer { working = false }
        error = nil
        do {
            let s = try await cloud.accountService().signIn(email: trimmedEmail, password: password, deviceName: cloud.environment.deviceName)
            password = ""
            await didAuthenticate(s)
        } catch { self.error = AccountCopy.message(error) }
    }

    /// Signed in: merge straight away on an empty Mac, otherwise ask first.
    func didAuthenticate(_ s: SignedIn) async {
        let local = (try? await cloud.library.counts().all) ?? 0
        if local > 0 {
            pending = s
            mergePrompt = local
        } else {
            await cloud.didSignIn(s, merge: true)
            done = true
        }
    }

    func confirmMerge() async {
        guard let s = pending else { return }
        pending = nil
        mergePrompt = nil
        await cloud.didSignIn(s, merge: true)
        done = true
    }

    /// Keeps this Mac's notes as they are and signs the new session out again.
    func cancelMerge() async {
        pending = nil
        mergePrompt = nil
        await cloud.signOut()
    }

    func useRecoveryKey() {
        error = nil
        mode = .recoveryKey
    }

    func submitRecoveryKey() async {
        working = true
        defer { working = false }
        error = nil
        do {
            recovery = try await cloud.accountService().recover(email: trimmedEmail, recoveryText: recoveryText,
                                                                deviceName: cloud.environment.deviceName)
            recoveryText = ""
            mode = .newPassword
        } catch { self.error = AccountCopy.message(error) }
    }

    var newPasswordReady: Bool {
        PasswordStrength(newPassword) != .tooShort && newPassword == confirmPassword && !working
    }

    func setNewPassword() async {
        guard let handle = recovery, newPasswordReady else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let s = try await cloud.accountService().finishRecovery(handle, newPassword: newPassword)
            newPassword = ""
            confirmPassword = ""
            recovery = nil
            await didAuthenticate(s)
        } catch { self.error = AccountCopy.message(error) }
    }
}
