import AppKit
import FeatherCore
import FeatherCrypto
import FeatherSync
import Foundation
import Observation

/// Where account secrets live and how the app talks to a server. Nothing here touches the network.
struct CloudEnvironment {
    var secrets: SecretStore
    var keys: MasterKeyStore
    /// Built only when the app first needs the network.
    var configuration: () -> URLSessionConfiguration
    var deviceName: String

    /// The Keychain normally; memory for test hosts and other isolated runs, which must never touch real secrets.
    static func live(isolated: Bool) -> CloudEnvironment {
        CloudEnvironment(secrets: isolated ? InMemorySecretStore() : KeychainSecretStore(),
                         keys: isolated ? InMemoryMasterKeyStore() : KeychainMasterKeyStore(),
                         configuration: { .ephemeral }, deviceName: Host.current().localizedName ?? "Mac")
    }

    static var memory: CloudEnvironment { live(isolated: true) }
}

enum CloudState: Equatable {
    case signedOut
    case signedIn(SignedIn)

    var signedIn: SignedIn? {
        if case .signedIn(let s) = self { return s }
        return nil
    }
}

/// What the app does around a sync pass: save pending edits first, refresh after a pull.
struct CloudHooks {
    var beforeSync: @MainActor () async -> Void
    var onPulled: @MainActor (Set<ULID>) async -> Void
}

/// Feather Cloud account and sync state. Views read it; it builds no client and makes no request until the user
/// starts the trial, signs in or connects a server, or a sign-in is stored from an earlier launch.
@MainActor @Observable
final class CloudModel {
    static let serverKey = "cloudServer"
    static let accountKey = "cloudAccount"
    static let libraryKey = "cloudLibrary"

    let library: Library
    let defaults: UserDefaults
    var environment: CloudEnvironment
    var hooks: CloudHooks

    private(set) var state: CloudState = .signedOut
    private(set) var status: SyncStatus = .idle(lastSynced: nil)
    private(set) var server: CloudServer
    private(set) var serverInfo: ServerInfo?
    private(set) var conflicts: [SyncConflict] = []
    private(set) var devices: [CloudDevice] = []
    private(set) var plan: CloudPlan?

    /// The account sheet on the main window, if any.
    enum Sheet: Identifiable {
        case onboarding(OnboardingFlow)
        case signIn(SignInFlow)
        var id: String { switch self { case .onboarding: "onboarding"; case .signIn: "signIn" } }
    }
    var sheet: Sheet?

    func startTrial() { sheet = .onboarding(OnboardingFlow(cloud: self)) }
    func showSignIn() {
        let flow = SignInFlow(cloud: self)
        flow.email = reauthEmail ?? ""
        sheet = .signIn(flow)
    }

    /// Set when the server ended the session (401): the email to sign in again with.
    private(set) var reauthEmail: String?

    /// The server ended this Mac's session (revoked, or the password changed elsewhere): keep the email so the
    /// app asks to sign in again instead of offering a trial.
    func serverSignedOut() async {
        let email = state.signedIn?.email ?? defaults.string(forKey: Self.accountKey)
        await forgetLocally()
        reauthEmail = email
    }

    private var account: AccountService?
    private var engine: SyncEngine?
    private var statusTask: Task<Void, Never>?

    var hasAccountService: Bool { account != nil }
    /// Signed out on Feather Cloud: Settings and the footer offer the free trial.
    var offersTrial: Bool { state == .signedOut && !isSelfHosted && reauthEmail == nil }
    /// A server other than Feather Cloud: trial and plan details don't apply.
    var isSelfHosted: Bool { server != .hosted }

    init(library: Library, defaults: UserDefaults, environment: CloudEnvironment, hooks: CloudHooks) {
        self.library = library
        self.defaults = defaults
        self.environment = environment
        self.hooks = hooks
        server = defaults.string(forKey: Self.serverKey).flatMap { try? CloudServer(userInput: $0) } ?? .hosted
    }

    // MARK: Server

    static func message(_ e: ServerURLError) -> String {
        switch e {
        case .invalid: "Enter the server's address."
        case .insecure: "Use an https:// address. Plain http works only for this Mac (localhost)."
        }
    }

    /// Checks a server (GET /server) and uses it. Returns a message to show, or nil.
    func connect(serverInput: String) async -> String? {
        let candidate: CloudServer
        do { candidate = try CloudServer(userInput: serverInput) } catch { return Self.message(error) }
        do {
            let info = try await APIClient(server: candidate, configuration: environment.configuration(), token: { nil }).getServer()
            server = candidate
            serverInfo = info
            defaults.set(serverInput.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.serverKey)
            account = nil
            return nil
        } catch {
            return "Couldn't reach that server. Check the address and try again."
        }
    }

    func useHostedServer() {
        server = .hosted
        serverInfo = nil
        defaults.removeObject(forKey: Self.serverKey)
        account = nil
    }

    func accountService() -> AccountService {
        if let account, account.server == server { return account }
        let a = AccountService(server: server, secrets: environment.secrets, keys: environment.keys, configuration: environment.configuration())
        account = a
        return a
    }

    // MARK: Sign-in state

    /// At launch: picks up a sign-in stored by an earlier launch and starts syncing. Without one, does nothing.
    func restoreAtLaunch() async {
        guard let email = defaults.string(forKey: Self.accountKey), let libraryID = defaults.string(forKey: Self.libraryKey) else { return }
        let a = accountService()
        guard await a.restore(email: email) else { return }
        let placeholder = CloudAccount(email: email, libraryID: libraryID,
                                       plan: CloudPlan(state: "active", reason: nil, trialEndsAt: nil, quotaBytes: 0, usedBytes: 0),
                                       billingEnabled: !isSelfHosted)
        state = .signedIn(SignedIn(email: email, server: server, deviceID: "", libraryID: libraryID, account: placeholder))
        startSync(libraryID: libraryID)
        Task { await refreshAccount() }
    }

    /// After signup, sign-in or recovery: remember the account and start syncing. `merge` marks every local item
    /// as new to the server (signing in with notes already on this Mac).
    func didSignIn(_ s: SignedIn, merge: Bool) async {
        try? await library.resetSync(markAllDirty: merge)
        defaults.set(s.email, forKey: Self.accountKey)
        defaults.set(s.libraryID, forKey: Self.libraryKey)
        state = .signedIn(s)
        reauthEmail = nil
        plan = s.account.plan
        startSync(libraryID: s.libraryID)
    }

    /// Signs out: ends the session if the server answers, forgets the secrets either way, keeps every note.
    func signOut() async {
        await engine?.stop()
        engine = nil
        statusTask?.cancel()
        await account?.signOut()
        await forgetLocally()
        reauthEmail = nil
    }

    private func forgetLocally() async {
        await engine?.stop()
        engine = nil
        statusTask?.cancel()
        statusTask = nil
        try? await library.resetSync(markAllDirty: false)
        defaults.removeObject(forKey: Self.accountKey)
        defaults.removeObject(forKey: Self.libraryKey)
        state = .signedOut
        status = .idle(lastSynced: nil)
        plan = nil
        devices = []
        conflicts = []
    }

    func refreshAccount() async {
        guard let a = account else { return }
        if let acct = try? await a.account() {
            plan = acct.plan
            if case .signedIn(var s) = state { s.account = acct; state = .signedIn(s) }
        }
        devices = (try? await a.devices()) ?? devices
        conflicts = (try? await library.syncConflicts()) ?? conflicts
    }

    func revoke(_ id: String) async {
        try? await account?.revoke(id)
        devices = (try? await account?.devices()) ?? devices
    }

    // MARK: Sync

    private func startSync(libraryID: String) {
        let e = SyncEngine(library: library, account: accountService(), libraryID: libraryID, deviceName: environment.deviceName)
        engine = e
        let hooks = self.hooks
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await s in await e.statusUpdates() { self?.status = s }
        }
        Task {
            await e.start(beforeSync: { await hooks.beforeSync() },
                          onPulled: { ids in await hooks.onPulled(ids) },
                          onSignedOut: { [weak self] in await self?.serverSignedOut() })
        }
    }

    func syncNow() { Task { await engine?.syncNow() } }
    func localChanged() { Task { await engine?.localChanged() } }
}
