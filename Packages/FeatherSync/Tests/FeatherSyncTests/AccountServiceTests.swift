import FeatherCore
import FeatherCrypto
import Foundation
import Testing
@testable import FeatherSync

/// Plays the server's part of signup, verify, prelogin and login with real crypto, in memory.
final class FakeAuthServer: @unchecked Sendable {
    let lock = NSLock()
    var signup: [String: Any]?
    var loginStatus = 200
    var recoverStatus = 200
    var stub: Stub?

    func handle(_ r: Stub.Recorded) -> Stub.Response {
        lock.lock(); defer { lock.unlock() }
        let body = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
        let account = #"{"email":"ana@example.com","library_id":"01JC8ZN0AB1CD2EF3GH4JK5MN6","plan":{"state":"trial","reason":null,"trial_ends_at":"2026-11-23T14:32:00.123Z","quota_bytes":1073741824,"used_bytes":0},"billing_enabled":true}"#
        switch r.url.path {
        case "/v1/auth/signup":
            signup = body
            return (202, [:], Data())
        case "/v1/auth/verify":
            return Stub.json(200, #"{"token":"fn1_\#(String(repeating: "A", count: 43))","device_id":"01JC8ZN0AB1CD2EF3GH4JK5MN7","account":\#(account)}"#)
        case "/v1/auth/prelogin":
            let salt = (signup?["salt"] as? String) ?? Data(count: 16).base64EncodedString()
            return Stub.json(200, #"{"kdf":{"alg":"argon2id13","t":3,"m_kib":262144,"p":1},"salt":"\#(salt)"}"#)
        case "/v1/auth/login":
            guard loginStatus == 200, body["auth_key"] as? String == signup?["auth_key"] as? String else {
                return Stub.json(loginStatus == 200 ? 401 : loginStatus, #"{"error":{"code":"\#(loginStatus == 403 ? "email_unverified" : "unauthorized")","message":"x"}}"#)
            }
            return Stub.json(200, #"{"token":"fn1_\#(String(repeating: "B", count: 43))","device_id":"01JC8ZN0AB1CD2EF3GH4JK5MN8","account":\#(account),"wrapped_master_password":"\#(signup!["wrapped_master_password"] as! String)"}"#)
        case "/v1/auth/recover":
            guard recoverStatus == 200, body["recovery_auth_key"] as? String == signup?["recovery_auth_key"] as? String else {
                return Stub.json(401, #"{"error":{"code":"unauthorized","message":"x"}}"#)
            }
            return Stub.json(200, #"{"token":"fn1_\#(String(repeating: "C", count: 43))","device_id":"01JC8ZN0AB1CD2EF3GH4JK5MN9","wrapped_master_recovery":"\#(signup!["wrapped_master_recovery"] as! String)"}"#)
        case "/v1/auth/logout":
            return (0, [:], Data()) // status 0: the stub answers nonsense, which reads as a network failure
        default:
            return Stub.json(404, #"{"error":{"code":"not_found","message":"x"}}"#)
        }
    }
}

@Suite struct AccountServiceTests {
    let server = try! CloudServer(userInput: "http://localhost:8420")
    let library = "01JC8ZN0AB1CD2EF3GH4JK5MN6"

    func service(_ fake: FakeAuthServer, secrets: InMemorySecretStore = InMemorySecretStore(), keys: InMemoryMasterKeyStore = InMemoryMasterKeyStore()) -> AccountService {
        fake.stub = Stub { fake.handle($0) }
        return AccountService(server: server, secrets: secrets, keys: keys, configuration: fake.stub!.configuration)
    }

    @Test func signupSendsOnlyDerivedValues() async throws {
        let fake = FakeAuthServer()
        let s = service(fake)
        _ = try await s.startSignup(email: "ana@example.com", password: "correct horse battery", libraryID: library)
        let body = try #require(fake.signup)
        let decoded = { (k: String) in Data(base64Encoded: body[k] as! String)! }
        #expect(decoded("salt").count == 16 && decoded("auth_key").count == 32 && decoded("recovery_auth_key").count == 32)
        #expect(decoded("wrapped_master_password").count == 74 && decoded("wrapped_master_recovery").count == 74)
        #expect(body["library_id"] as? String == library)
        let raw = fake.stub!.requests.map { String(decoding: $0.body, as: UTF8.self) }.joined()
        #expect(!raw.contains("correct horse battery") && !raw.contains(Data("correct horse battery".utf8).base64EncodedString()))
    }

    @Test func verifyStoresSecrets() async throws {
        let fake = FakeAuthServer()
        let secrets = InMemorySecretStore(), keys = InMemoryMasterKeyStore()
        let s = service(fake, secrets: secrets, keys: keys)
        _ = try await s.startSignup(email: "ana@example.com", password: "correct horse battery", libraryID: library)
        let signedIn = try await s.verify(email: "ana@example.com", code: "123456", deviceName: "Mac")
        #expect(signedIn.libraryID == library && signedIn.email == "ana@example.com")
        #expect(try secrets.token(for: "localhost|ana@example.com")?.hasPrefix("fn1_A") == true)
        #expect(try keys.load(account: "localhost|ana@example.com")?.count == 32)
        #expect(try await s.masterKey()?.count == 32)
    }

    @Test func signInUnwrapsTheSameMasterKey() async throws {
        let fake = FakeAuthServer()
        let a = service(fake)
        _ = try await a.startSignup(email: "ana@example.com", password: "correct horse battery", libraryID: library)
        _ = try await a.verify(email: "ana@example.com", code: "123456", deviceName: "Mac")
        let original = try await a.masterKey()
        let keys = InMemoryMasterKeyStore()
        let b = service(fake, keys: keys)
        _ = try await b.signIn(email: "ana@example.com", password: "correct horse battery", deviceName: "Air")
        #expect(try await b.masterKey() == original)
    }

    @Test func errorMapping() async throws {
        let fake = FakeAuthServer()
        let s = service(fake)
        _ = try await s.startSignup(email: "ana@example.com", password: "correct horse battery", libraryID: library)
        await #expect(throws: AccountError.wrongPassword) { try await s.signIn(email: "ana@example.com", password: "wrong password!!", deviceName: "Mac") }
        let before = fake.stub!.requests.count
        var typo = Array("DT1H-530K-CKSM-H797-JXHZ-0F5C-8F9P")
        typo[0] = "E"
        await #expect(throws: AccountError.recoveryKeyTypo) { try await s.recover(email: "ana@example.com", recoveryText: String(typo), deviceName: "Mac") }
        #expect(fake.stub!.requests.count == before)
        await #expect(throws: AccountError.wrongRecoveryKey) {
            try await s.recover(email: "ana@example.com", recoveryText: RecoveryKey.generate().text, deviceName: "Mac")
        }
        fake.lock.withLock { fake.loginStatus = 403 }
        await #expect(throws: AccountError.emailUnverified) { try await s.signIn(email: "ana@example.com", password: "correct horse battery", deviceName: "Mac") }
    }

    @Test func recoveryThenNewPassword() async throws {
        let fake = FakeAuthServer()
        let s = service(fake)
        let key = try await s.startSignup(email: "ana@example.com", password: "correct horse battery", libraryID: library)
        let handle = try await s.recover(email: "ana@example.com", recoveryText: key.text.lowercased(), deviceName: "Mac")
        #expect(handle.masterKey.count == 32)
    }

    @Test func signOutClearsEvenOffline() async throws {
        let fake = FakeAuthServer()
        let secrets = InMemorySecretStore(), keys = InMemoryMasterKeyStore()
        let s = service(fake, secrets: secrets, keys: keys)
        _ = try await s.startSignup(email: "ana@example.com", password: "correct horse battery", libraryID: library)
        _ = try await s.verify(email: "ana@example.com", code: "123456", deviceName: "Mac")
        await s.signOut()
        #expect(try secrets.token(for: "localhost|ana@example.com") == nil)
        #expect(try keys.load(account: "localhost|ana@example.com") == nil)
        #expect(try await s.masterKey() == nil)
    }
}
