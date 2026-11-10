import FeatherCrypto
import Foundation

/// What the account screens need to tell apart (ui-copy.md "Security and recovery").
public enum AccountError: Error, Equatable, Sendable {
    case wrongPassword, recoveryKeyTypo, wrongRecoveryKey, emailUnverified, codeInvalid, codeExpired
    case passwordTooShort
    case rateLimited(retryAfter: Int?)
    case network
    case server(String)
}

/// A signed-in account on this Mac.
public struct SignedIn: Sendable, Equatable {
    public var email: String
    public var server: CloudServer
    public var deviceID: String
    public var libraryID: String
    public var account: CloudAccount

    public init(email: String, server: CloudServer, deviceID: String, libraryID: String, account: CloudAccount) {
        self.email = email
        self.server = server
        self.deviceID = deviceID
        self.libraryID = libraryID
        self.account = account
    }
}

/// A recovery sign-in waiting for its new password (the token may only set a password).
public struct RecoveryHandle: Sendable {
    public var email: String
    public var token: String
    public var deviceID: String
    public var masterKey: Data
}

/// Signup, sign-in, recovery, password change, devices and sign-out against one server. The password, `root`
/// and keys never leave this actor except as the derived values the protocol sends.
public actor AccountService {
    public nonisolated let server: CloudServer
    let secrets: SecretStore
    let keys: MasterKeyStore
    let configuration: URLSessionConfiguration
    private var email: String?
    private var pending: (email: String, account: NewAccount, libraryID: String)?

    public init(server: CloudServer, secrets: SecretStore, keys: MasterKeyStore, configuration: URLSessionConfiguration) {
        self.server = server
        self.secrets = secrets
        self.keys = keys
        self.configuration = configuration
    }

    /// The account name both secret stores use.
    public nonisolated func storeKey(_ email: String) -> String { "\(server.host)|\(email)" }

    /// A client carrying this account's token.
    public func client() -> APIClient {
        let secrets = self.secrets, key = email.map(storeKey)
        return APIClient(server: server, configuration: configuration, token: { key.flatMap { try? secrets.token(for: $0) } ?? nil })
    }

    private func bareClient(token: String? = nil) -> APIClient {
        APIClient(server: server, configuration: configuration, token: { token })
    }

    /// Picks up a sign-in stored by an earlier launch.
    public func restore(email: String) -> Bool {
        guard (try? secrets.token(for: storeKey(email))) != nil, (try? keys.load(account: storeKey(email))) != nil else { return false }
        self.email = email
        return true
    }

    public func masterKey() throws -> Data? {
        guard let email else { return nil }
        return try keys.load(account: storeKey(email))
    }

    public var currentEmail: String? { email }

    // MARK: Signup

    /// Makes the keys and starts the signup. The recovery key is for the screen only; it's never stored.
    public func startSignup(email: String, password: String, libraryID: String) async throws -> RecoveryKey {
        let account: NewAccount
        do { account = try Account.create(password: password) } catch { throw AccountError.passwordTooShort }
        let body = SignupRequest(email: email, salt: account.salt, kdf: KDF(account.params), authKey: account.authKey,
                                 recoveryAuthKey: account.recoveryAuthKey, wrappedMasterPassword: account.wrappedByPassword,
                                 wrappedMasterRecovery: account.wrappedByRecovery, libraryID: libraryID)
        try await mapped { try await self.bareClient().signup(body) }
        pending = (email, account, libraryID)
        return account.recoveryKey
    }

    public func resend(email: String) async throws {
        try await mapped { try await self.bareClient().resend(email: email) }
    }

    public func verify(email: String, code: String, deviceName: String) async throws -> SignedIn {
        guard let pending, pending.email == email else { throw AccountError.codeExpired }
        let r = try await mapped { try await self.bareClient().verify(email: email, code: code, deviceName: deviceName) }
        try store(email: email, token: r.token, masterKey: pending.account.masterKey)
        self.pending = nil
        return try signedIn(email: email, r)
    }

    // MARK: Sign-in and recovery

    public func signIn(email: String, password: String, deviceName: String) async throws -> SignedIn {
        let keys = try await passwordKeys(email: email, password: password)
        let r: SessionResponse
        do {
            r = try await bareClient().login(email: email, authKey: keys.authKey, deviceName: deviceName)
        } catch let e as APIError where e.status == 401 {
            throw AccountError.wrongPassword
        } catch {
            throw Self.map(error)
        }
        guard let wrapped = r.wrappedMasterPassword, let master = try? MasterKey.unwrap(wrapped, kind: .password, key: keys.kek) else {
            throw AccountError.wrongPassword
        }
        try store(email: email, token: r.token, masterKey: master)
        return try signedIn(email: email, r)
    }

    /// Parses the key first (a typo never reaches the server), then signs in with recovery scope.
    public func recover(email: String, recoveryText: String, deviceName: String) async throws -> RecoveryHandle {
        let key: RecoveryKey
        do { key = try RecoveryKey(parsing: recoveryText) } catch { throw AccountError.recoveryKeyTypo }
        let r: SessionResponse
        do {
            r = try await bareClient().recover(email: email, recoveryAuthKey: key.authKey, deviceName: deviceName)
        } catch let e as APIError where e.status == 401 {
            throw AccountError.wrongRecoveryKey
        } catch {
            throw Self.map(error)
        }
        guard let wrapped = r.wrappedMasterRecovery, let master = try? MasterKey.unwrap(wrapped, kind: .recovery, key: key.kek) else {
            throw AccountError.wrongRecoveryKey
        }
        return RecoveryHandle(email: email, token: r.token, deviceID: r.deviceID, masterKey: master)
    }

    /// Sets the new password with the recovery token; every other session ends.
    public func finishRecovery(_ handle: RecoveryHandle, newPassword: String) async throws -> SignedIn {
        let change: PasswordChange
        do { change = try Account.changePassword(masterKey: handle.masterKey, newPassword: newPassword) } catch { throw AccountError.passwordTooShort }
        let body = SetPasswordRequest(currentAuthKey: nil, salt: change.salt, kdf: KDF(change.params), authKey: change.authKey,
                                      wrappedMasterPassword: change.wrappedByPassword)
        let token = try await mapped { try await self.bareClient(token: handle.token).setPassword(body) }
        try store(email: handle.email, token: token, masterKey: handle.masterKey)
        let account = try await mapped { try await self.bareClient(token: token).getAccount() }
        return SignedIn(email: handle.email, server: server, deviceID: handle.deviceID, libraryID: account.libraryID, account: account)
    }

    public func changePassword(current: String, new: String) async throws {
        guard let email, let master = try masterKey() else { throw AccountError.server("signed_out") }
        let currentKeys = try await passwordKeys(email: email, password: current)
        let change: PasswordChange
        do { change = try Account.changePassword(masterKey: master, newPassword: new) } catch { throw AccountError.passwordTooShort }
        let body = SetPasswordRequest(currentAuthKey: currentKeys.authKey, salt: change.salt, kdf: KDF(change.params),
                                      authKey: change.authKey, wrappedMasterPassword: change.wrappedByPassword)
        let token: String
        do { token = try await client().setPassword(body) } catch let e as APIError where e.status == 401 {
            throw AccountError.wrongPassword
        } catch { throw Self.map(error) }
        try secrets.setToken(token, for: storeKey(email))
    }

    // MARK: Devices, sign-out, deletion

    public func account() async throws -> CloudAccount { try await mapped { try await self.client().getAccount() } }
    public func devices() async throws -> [CloudDevice] { try await mapped { try await self.client().listDevices() } }
    public func revoke(_ deviceID: String) async throws { try await mapped { try await self.client().revokeDevice(deviceID) } }

    /// Ends the session on the server if it can, and forgets the token and master key in any case.
    public func signOut() async {
        try? await client().logout()
        forget()
    }

    /// Forgets this Mac's secrets without asking the server (after a 401).
    public func forget() {
        if let email {
            try? secrets.setToken(nil, for: storeKey(email))
            try? keys.delete(account: storeKey(email))
        }
        email = nil
    }

    public func deleteAccount(password: String) async throws {
        guard let email else { throw AccountError.server("signed_out") }
        let k = try await passwordKeys(email: email, password: password)
        do { try await client().deleteAccount(authKey: k.authKey) } catch let e as APIError where e.status == 401 {
            throw AccountError.wrongPassword
        } catch { throw Self.map(error) }
        forget()
    }

    // MARK: Helpers

    private func passwordKeys(email: String, password: String) async throws -> PasswordKeys {
        let pre = try await mapped { try await self.bareClient().prelogin(email: email) }
        do {
            return try PasswordKeys.derive(password: password, salt: pre.salt, params: Argon2Params(pre.kdf))
        } catch InvalidArgument.unsupportedParameters {
            throw AccountError.server("unsupported_kdf")
        }
    }

    private func store(email: String, token: String, masterKey: Data) throws {
        try keys.save(masterKey, account: storeKey(email))
        try secrets.setToken(token, for: storeKey(email))
        self.email = email
    }

    private func signedIn(email: String, _ r: SessionResponse) throws -> SignedIn {
        guard let account = r.account else { throw AccountError.server("no_account") }
        return SignedIn(email: email, server: server, deviceID: r.deviceID, libraryID: account.libraryID, account: account)
    }

    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw Self.map(error) }
    }

    static func map(_ error: Error) -> Error {
        guard let e = error as? APIError else { return error }
        switch (e.status, e.code) {
        case (0, _): return AccountError.network
        case (_, "email_unverified"): return AccountError.emailUnverified
        case (_, "verification_invalid"): return AccountError.codeInvalid
        case (_, "verification_expired"): return AccountError.codeExpired
        case (429, _): return AccountError.rateLimited(retryAfter: e.retryAfter)
        default: return AccountError.server(e.code)
        }
    }
}

extension KDF {
    init(_ p: Argon2Params) { self.init(alg: p.alg, t: Int(p.t), mKiB: Int(p.mKiB), p: Int(p.p)) }
}

extension Argon2Params {
    init(_ k: KDF) { self.init(alg: k.alg, t: UInt32(clamping: k.t), mKiB: UInt32(clamping: k.mKiB), p: UInt32(clamping: k.p)) }
}
