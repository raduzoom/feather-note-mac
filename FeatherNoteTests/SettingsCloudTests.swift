import FeatherCore
import FeatherCrypto
import FeatherSync
import Foundation
import Testing
@testable import FeatherNote

/// A signed-in server for settings tests: devices, revoke, account, and empty sync answers.
final class SettingsServerProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var revoked: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = 200
        var body = "{}"
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/v1/devices"):
            body = #"{"devices":[{"id":"D1","name":"MacBook Air","created_at":"2026-11-01T10:00:00.000Z","last_seen_at":"2026-11-10T09:12:00.000Z","current":true},{"id":"D2","name":"iPhone 16","created_at":"2026-11-02T10:00:00.000Z","last_seen_at":"2026-11-10T09:12:00.000Z","current":false}]}"#
        case ("DELETE", let p) where p.hasPrefix("/v1/devices/"):
            Self.lock.withLock { Self.revoked.append(String(p.dropFirst("/v1/devices/".count))) }
            status = 204; body = ""
        case ("GET", "/v1/account"):
            body = #"{"email":"ana@example.com","library_id":"01JC8ZN0AB1CD2EF3GH4JK5MN6","plan":{"state":"active","reason":null,"trial_ends_at":null,"quota_bytes":10737418240,"used_bytes":2576980378},"billing_enabled":true}"#
        case ("GET", "/v1/sync/pull"):
            body = #"{"items":[],"cursor":"c_000000000000","has_more":false}"#
        case ("POST", "/v1/sync/push"):
            body = #"{"results":[]}"#
        case ("POST", "/v1/auth/logout"):
            status = 204; body = ""
        default:
            status = 404; body = #"{"error":{"code":"not_found","message":"x"}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                              headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Suite(.serialized) struct SettingsCloudTests {
    /// A model signed in to the stub server, as if from an earlier launch.
    func signedIn() async throws -> AppModel {
        let m = try await makeModel()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsServerProtocol.self]
        m.cloud.environment.configuration = { config }
        let key = "\(CloudServer.hosted.host)|ana@example.com"
        try m.cloud.environment.secrets.setToken("fn1_" + String(repeating: "A", count: 43), for: key)
        try m.cloud.environment.keys.save(MasterKey.generate(), account: key)
        m.defaults.set("ana@example.com", forKey: CloudModel.accountKey)
        m.defaults.set("01JC8ZN0AB1CD2EF3GH4JK5MN6", forKey: CloudModel.libraryKey)
        await m.cloud.restoreAtLaunch()
        await m.cloud.refreshAccount()
        return m
    }

    @Test func signedOutShowsTrialOffer() async throws {
        let m = try await makeModel()
        m.cloud.environment.hostedBillingEnabled = true   // a Feather Cloud with billing (after 1.0.0)
        #expect(m.cloud.offersTrial)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServerInfoProtocol.self]
        m.cloud.environment.configuration = { config }
        _ = await m.cloud.connect(serverInput: "notes.home.lan")
        #expect(!m.cloud.offersTrial && m.cloud.isSelfHosted)
    }

    @Test func devicesAndRevoke() async throws {
        let m = try await signedIn()
        #expect(m.cloud.devices.map(\.name) == ["MacBook Air", "iPhone 16"])
        #expect(m.cloud.devices.first { $0.current }?.id == "D1")
        await m.cloud.revoke("D2")
        #expect(SettingsServerProtocol.lock.withLock { SettingsServerProtocol.revoked }.contains("D2"))
        await m.cloud.signOut()
    }

    @Test func conflictsListed() async throws {
        let m = try await makeModel()
        let nb = try #require(await m.createNotebook(name: "Travel", parent: nil))
        try await m.library.recordSyncConflict(itemID: nb.id, type: .notebook, lostName: "Trips", device: "Mac")
        try await Task.sleep(for: .milliseconds(5))
        try await m.library.recordSyncConflict(itemID: nb.id, type: .notebook, lostName: "Journeys", device: "Mac")
        await m.cloud.refreshAccount()
        let conflicts = try await m.library.syncConflicts()
        #expect(conflicts.count == 2)
        await m.showConflict(conflicts[0])
        #expect(m.selection == .notebook(nb.id))
    }

    @Test func signOutKeepsNotes() async throws {
        let m = try await signedIn()
        _ = try await m.library.createNote(title: "Kept")
        #expect(m.cloud.state != .signedOut)
        await m.cloud.signOut()
        let key = "\(CloudServer.hosted.host)|ana@example.com"
        #expect(m.cloud.state == .signedOut)
        #expect(try m.cloud.environment.secrets.token(for: key) == nil && m.cloud.environment.keys.load(account: key) == nil)
        #expect(try await m.library.notes(in: .all).map(\.title) == ["Kept"])
        let dirty = try await m.library.dirtyItems(), cursor = try await m.library.syncValue("pull_cursor")
        #expect(dirty.isEmpty && cursor == nil)
        #expect(m.defaults.string(forKey: CloudModel.accountKey) == nil)
    }

    @Test func usageLine() {
        #expect(CloudFormat.usage(used: 2_576_980_378, quota: 10_737_418_240) == "2.4 GB of 10 GB used")
        #expect(CloudFormat.size(125_829_120) + " of " + CloudFormat.size(1_073_741_824) == "120 MB of 1 GB")
        #expect(CloudFormat.size(1_073_741_824) == "1 GB" && CloudFormat.size(9_663_676_416) == "9 GB")
        #expect(CloudFormat.size(5_242_880) == "5 MB" && CloudFormat.size(3_565_158) == "3.4 MB")
    }
}
