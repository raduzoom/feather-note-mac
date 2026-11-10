import Foundation
import Testing
@testable import FeatherCrypto

@Suite struct AccountTests {
    @Test func wrongThenRightPassword() throws {   // Review Focus 2
        let a = try Account.create(password: "correct horse battery")
        #expect(throws: CryptoError.authenticationFailed) {
            try Account.unlock(password: "correct horse batterY", salt: a.salt, params: a.params, wrappedByPassword: a.wrappedByPassword)
        }
        #expect(try Account.unlock(password: "correct horse battery", salt: a.salt, params: a.params, wrappedByPassword: a.wrappedByPassword) == a.masterKey)
        #expect(try PasswordKeys.derive(password: "correct horse battery", salt: a.salt, params: a.params).authKey == a.authKey)
    }

    /// The key's text with one character changed so the checksum fails (once in 4,096 changes it wouldn't).
    func typo(of key: RecoveryKey) throws -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var chars = Array(key.text)
        for candidate in alphabet where candidate != chars[0] {
            chars[0] = candidate
            if (try? RecoveryKey(parsing: String(chars))) == nil { return String(chars) }
        }
        Issue.record("no typo found")
        return key.text
    }

    @Test func typoAndWrongRecoveryKeyStayDistinct() throws {   // Review Focus 2
        let a = try Account.create(password: "correct horse battery")
        #expect(throws: CryptoError.recoveryKeyTypo) { try Account.recover(recoveryText: try typo(of: a.recoveryKey), wrappedByRecovery: a.wrappedByRecovery) }
        #expect(throws: CryptoError.authenticationFailed) { try Account.recover(recoveryText: RecoveryKey.generate().text, wrappedByRecovery: a.wrappedByRecovery) }
        #expect(try Account.recover(recoveryText: a.recoveryKey.text.lowercased(), wrappedByRecovery: a.wrappedByRecovery) == a.masterKey)
        #expect(a.recoveryAuthKey == a.recoveryKey.authKey)
    }

    @Test func passwordChangeKeepsMasterKeyAndRecovery() throws {
        let a = try Account.create(password: "correct horse battery")
        let c = try Account.changePassword(masterKey: a.masterKey, newPassword: "a new long password")
        #expect(c.salt != a.salt && c.authKey != a.authKey && c.params == .v1)
        #expect(throws: CryptoError.authenticationFailed) {
            try Account.unlock(password: "correct horse battery", salt: c.salt, params: c.params, wrappedByPassword: c.wrappedByPassword)
        }
        #expect(try Account.unlock(password: "a new long password", salt: c.salt, params: c.params, wrappedByPassword: c.wrappedByPassword) == a.masterKey)
        #expect(try Account.recover(recoveryText: a.recoveryKey.text, wrappedByRecovery: a.wrappedByRecovery) == a.masterKey)
    }

    @Test func shortPasswordRefused() {
        #expect(throws: InvalidArgument.passwordTooShort) { try Account.create(password: "short") }
        #expect(throws: InvalidArgument.passwordTooShort) { try Account.changePassword(masterKey: Data(count: 32), newPassword: "short") }
    }
}
