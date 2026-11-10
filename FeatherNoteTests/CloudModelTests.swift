import FeatherCore
import FeatherCrypto
import FeatherSync
import Foundation
import Testing
@testable import FeatherNote

/// Records every request any URLSession in the process makes (registered globally, and on injected sessions).
final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var urls: [URL] = []
    static let lock = NSLock()
    static var count: Int { lock.withLock { urls.count } }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { urls.append(request.url!) }
        return false   // record only; let the real loader (or nothing) handle it
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
}

/// Answers GET /server for app tests.
final class ServerInfoProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var billing = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"api_version":1,"server_version":"t","billing_enabled":\#(Self.billing),"max_blob_bytes":1,"default_quota_bytes":2}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Suite(.serialized) struct CloudModelTests {
    @Test func freeAppMakesNoRequests() async throws { // Review Focus 4
        URLProtocol.registerClass(RecordingProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingProtocol.self) }
        let before = RecordingProtocol.count
        let m = try await makeModel()
        m.cloud.environment.configuration = {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [RecordingProtocol.self] + (c.protocolClasses ?? [])
            return c
        }
        await m.cloud.restoreAtLaunch()
        await m.newNote()
        m.editTitle("Groceries")
        m.editBody("milk")
        await m.flush()
        await m.setSearch("milk")
        await m.setSearch("")
        let folder = FileManager.default.temporaryDirectory.appending(path: "FNNet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Imported\n\ntext".write(to: folder.appending(path: "Imported.md"), atomically: true, encoding: .utf8)
        _ = await m.importMarkdownFolder(folder)
        _ = await m.export(to: FileManager.default.temporaryDirectory.appending(path: "FNNetOut-\(UUID().uuidString)"), notebook: nil)
        if let id = m.selectedNoteID { await m.trash(id) }
        await m.emptyTrash()
        #expect(RecordingProtocol.count == before)
        #expect(m.cloud.state == .signedOut && !m.cloud.hasAccountService)
        // the recorder does see the app's requests: connecting to a server is one
        _ = await m.cloud.connect(serverInput: "http://127.0.0.1:9")
        #expect(RecordingProtocol.count > before)
    }

    @Test func syncNeverDropsAPendingEdit() async throws { // Review Focus 3
        let m = try await makeModel()
        await m.newNote()
        let id = try #require(m.selectedNoteID)
        m.editBody("typed")   // not saved yet
        await m.cloud.hooks.beforeSync()   // what the engine runs before each pass
        // the pass now pulls another device's version of the same note
        let remote = Note(id: id, title: "", body: "from the other Mac", notebookID: nil, tagIDs: [], pinned: false,
                          created: 1, modified: 2, trashedAt: nil)
        let applied = try await m.library.applyRemote(note: remote, version: 9, blobSHA: nil, extraMeta: nil, metaVersion: 1)
        #expect(!applied)   // the saved edit isn't collected yet: the engine must resolve, not overwrite
        await m.cloud.hooks.onPulled([id])
        #expect(m.editor?.body == "typed")
        #expect(try await m.library.note(id)?.body == "typed")
    }

    @Test func isolatedRunsUseMemoryStores() {
        let env = CloudEnvironment.live(isolated: true)
        #expect(env.secrets is InMemorySecretStore && env.keys is InMemoryMasterKeyStore)
        let real = CloudEnvironment.live(isolated: false)
        #expect(real.secrets is KeychainSecretStore && real.keys is KeychainMasterKeyStore)
    }

    @Test func connectChecksServer() async throws {
        let m = try await makeModel()
        #expect(await m.cloud.connect(serverInput: "http://notes.example.com") == "Use an https:// address. Plain http works only for this Mac (localhost).")
        #expect(await m.cloud.connect(serverInput: "") == "Enter the server's address.")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServerInfoProtocol.self]
        m.cloud.environment.configuration = { config }
        ServerInfoProtocol.billing = false
        #expect(await m.cloud.connect(serverInput: "notes.home.lan") == nil)
        #expect(m.cloud.isSelfHosted && m.cloud.server.host == "notes.home.lan")
        #expect(m.defaults.string(forKey: CloudModel.serverKey) == "notes.home.lan")
        m.cloud.useHostedServer()
        #expect(m.cloud.server == .hosted && !m.cloud.isSelfHosted && m.defaults.string(forKey: CloudModel.serverKey) == nil)
    }
}
