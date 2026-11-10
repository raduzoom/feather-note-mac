import Foundation
import Testing
@testable import FeatherCrypto

/// Both stores; the Keychain one uses a service name of its own per run, so the real item is never touched.
func stores() -> [any MasterKeyStore] {
    [InMemoryMasterKeyStore(), KeychainMasterKeyStore(service: "app.feathermark.FeatherCryptoTests.\(UUID().uuidString)")]
}

@Suite struct MasterKeyStoreTests {
    @Test(arguments: stores()) func saveLoadDelete(_ store: any MasterKeyStore) throws {
        let key = MasterKey.generate()
        try store.save(key, account: "acct-1")
        defer { try? store.delete(account: "acct-1") }
        #expect(try store.load(account: "acct-1") == key)
        #expect(try store.load(account: "acct-2") == nil)
        try store.delete(account: "acct-1")
        #expect(try store.load(account: "acct-1") == nil)
        try store.delete(account: "acct-1")   // deleting nothing is fine (sign-out twice)
    }

    @Test(arguments: stores()) func saveTwiceReplaces(_ store: any MasterKeyStore) throws {   // Review Focus 5
        defer { try? store.delete(account: "a") }
        try store.save(Data(repeating: 1, count: 32), account: "a")
        try store.save(Data(repeating: 2, count: 32), account: "a")
        #expect(try store.load(account: "a") == Data(repeating: 2, count: 32))
    }

    @Test func onlyMasterKeysAreSaved() {
        #expect(throws: InvalidArgument.length(name: "masterKey", expected: 32, actual: 3)) {
            try InMemoryMasterKeyStore().save(Data([1, 2, 3]), account: "a")
        }
    }
}

// Identifiers carry the app's name, FeatherMark (2026-11-10), before any release.
@Test func keychainServiceUsesTheAppIdentifier() {
    #expect(KeychainMasterKeyStore().service == "app.feathermark.FeatherMark.master-key")
}
