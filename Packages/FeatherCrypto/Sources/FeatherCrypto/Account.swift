import Foundation

/// Everything account creation produces (crypto.md "Account creation" steps 1–3). The server gets `salt`,
/// `params`, `authKey`, `recoveryAuthKey` and both wrapped keys; the recovery key is shown once and never stored.
public struct NewAccount: Sendable {
    public let salt: Data
    public let params: Argon2Params
    public let authKey: Data
    public let recoveryAuthKey: Data
    public let wrappedByPassword: Data
    public let wrappedByRecovery: Data
    public let masterKey: Data
    public let recoveryKey: RecoveryKey
}

/// What a password change sends (crypto.md "Password change" steps 1–2). The master key is the same one,
/// re-wrapped; the recovery-wrapped key and recovery auth key don't change.
public struct PasswordChange: Sendable {
    public let salt: Data
    public let params: Argon2Params
    public let authKey: Data
    public let wrappedByPassword: Data
}

public enum Account {
    public static func create(password: String) throws -> NewAccount {
        guard Password.meetsMinimum(password) else { throw InvalidArgument.passwordTooShort }
        let masterKey = MasterKey.generate()
        let recoveryKey = RecoveryKey.generate()
        let salt = Sodium.random(16)
        let keys = try PasswordKeys.derive(password: password, salt: salt, params: .v1)
        return NewAccount(salt: salt, params: .v1, authKey: keys.authKey, recoveryAuthKey: recoveryKey.authKey,
                          wrappedByPassword: try MasterKey.wrap(masterKey, kind: .password, key: keys.kek),
                          wrappedByRecovery: try MasterKey.wrap(masterKey, kind: .recovery, key: recoveryKey.kek),
                          masterKey: masterKey, recoveryKey: recoveryKey)
    }

    /// The master key; `authenticationFailed` for a wrong password.
    public static func unlock(password: String, salt: Data, params: Argon2Params, wrappedByPassword: Data) throws -> Data {
        let keys = try PasswordKeys.derive(password: password, salt: salt, params: params)
        return try MasterKey.unwrap(wrappedByPassword, kind: .password, key: keys.kek)
    }

    /// The master key; `recoveryKeyTypo` for text that doesn't parse, `authenticationFailed` for a key that
    /// parses but belongs to another account. Clients show these differently.
    public static func recover(recoveryText: String, wrappedByRecovery: Data) throws -> Data {
        let key = try RecoveryKey(parsing: recoveryText)
        return try MasterKey.unwrap(wrappedByRecovery, kind: .recovery, key: key.kek)
    }

    /// A new random salt and the current parameters; the same master key wrapped with the new `kek`.
    public static func changePassword(masterKey: Data, newPassword: String) throws -> PasswordChange {
        guard Password.meetsMinimum(newPassword) else { throw InvalidArgument.passwordTooShort }
        try InvalidArgument.check(masterKey, "masterKey", 32)
        let salt = Sodium.random(16)
        let keys = try PasswordKeys.derive(password: newPassword, salt: salt, params: .v1)
        return PasswordChange(salt: salt, params: .v1, authKey: keys.authKey,
                              wrappedByPassword: try MasterKey.wrap(masterKey, kind: .password, key: keys.kek))
    }
}
