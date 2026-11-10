import Foundation
import Testing
@testable import FeatherSync

@Suite struct APIClientTests {
    let server = try! CloudServer(userInput: "http://localhost:8420")

    @Test func serverURLRules() throws {
        #expect(try CloudServer(userInput: "notes.example.com").baseURL.absoluteString == "https://notes.example.com/v1")
        #expect(try CloudServer(userInput: " https://notes.example.com/ ").baseURL.absoluteString == "https://notes.example.com/v1")
        #expect(try CloudServer(userInput: "http://localhost:8420").baseURL.absoluteString == "http://localhost:8420/v1")
        #expect(try CloudServer(userInput: "http://127.0.0.1:8420").host == "127.0.0.1")
        #expect(throws: ServerURLError.insecure) { try CloudServer(userInput: "http://notes.example.com") }
        #expect(throws: ServerURLError.invalid) { try CloudServer(userInput: "") }
        #expect(throws: ServerURLError.invalid) { try CloudServer(userInput: "ftp://x.y") }
        #expect(CloudServer.hosted.baseURL.absoluteString == "https://feather-cloud.invalid/v1")
    }

    @Test func hostedComesFromInfoPlist() {
        // the package test bundle has no FeatherCloudURL key: the fallback is used, and billing defaults to off
        #expect(CloudServer.hosted.host.hasSuffix(".invalid"))
        #expect(!CloudServer.hostedBillingEnabled)
    }

    @Test func hostedNeverFallsBackToARealDomain() { // review fix: a typo must not send accounts to someone else's domain
        #expect(CloudServer.hosted(info: nil).host == "feather-cloud.invalid")
        #expect(CloudServer.hosted(info: ["FeatherCloudURL": "https://bad host"]).host == "feather-cloud.invalid")
        #expect(CloudServer.hosted(info: ["FeatherCloudURL": "http://cloud.example.app"]).host == "feather-cloud.invalid")
        #expect(CloudServer.hosted(info: ["FeatherCloudURL": "https://cloud.example.app"]).host == "cloud.example.app")
    }

    @Test func errorsDecode() async throws {
        let stub = Stub { r in
            r.url.path.hasSuffix("/server")
                ? Stub.json(429, #"{"error":{"code":"rate_limited","message":"x"}}"#, headers: ["Retry-After": "7"])
                : Stub.json(403, #"{"error":{"code":"read_only","message":"x"}}"#)
        }
        let c = APIClient(server: server, configuration: stub.configuration, token: { "fn1_x" })
        await #expect(throws: APIError(status: 403, code: "read_only", retryAfter: nil)) { try await c.getAccount() }
        await #expect(throws: APIError(status: 429, code: "rate_limited", retryAfter: 7)) { try await c.getServer() }
    }

    @Test func pushResultsDecode() async throws {
        let item = #"{"id":"01JC8ZQ6V4N1XG2H3K5M7P9R0T","type":"note","version":5,"seq":9,"deleted":false,"meta":"AAEC","blob":{"sha256":"aa","size":3},"updated_at":"2026-11-09T14:32:00.123Z"}"#
        let stub = Stub { _ in
            Stub.json(200, #"{"results":[{"id":"A","status":"accepted","version":4,"seq":1287},{"id":"B","status":"conflict","current":\#(item)},{"id":"C","status":"rejected","error":{"code":"blob_missing"}}]}"#)
        }
        let c = APIClient(server: server, configuration: stub.configuration, token: { "fn1_x" })
        let results = try await c.push(libraryID: "L", changes: [])
        guard case .accepted(let id, let v, let seq) = results[0], case .conflict(_, let current) = results[1], case .rejected(_, let code) = results[2] else {
            Issue.record("\(results)"); return
        }
        #expect(id == "A" && v == 4 && seq == 1287 && current.version == 5 && current.meta == Data([0, 1, 2]) && current.blob?.size == 3 && code == "blob_missing")
    }

    @Test func bearerOnlyWhenSignedIn() async throws {
        let stub = Stub { r in
            r.url.path.hasSuffix("/server")
                ? Stub.json(200, #"{"api_version":1,"server_version":"1","billing_enabled":false,"max_blob_bytes":10,"default_quota_bytes":20}"#)
                : Stub.json(200, #"{"devices":[]}"#)
        }
        let c = APIClient(server: server, configuration: stub.configuration, token: { "fn1_token" })
        let info = try await c.getServer()
        _ = try await c.listDevices()
        let reqs = stub.requests
        #expect(!info.billingEnabled && info.defaultQuotaBytes == 20)
        #expect(reqs[0].headers["Authorization"] == nil)
        #expect(reqs[1].headers["Authorization"] == "Bearer fn1_token")
        #expect(reqs.allSatisfy { $0.headers["User-Agent"]?.hasPrefix("FeatherNote/") == true })
    }

    @Test func blobBodiesAreRaw() async throws {
        let stub = Stub { _ in Stub.json(200, #"{"sha256":"ab","size":3}"#) }
        let c = APIClient(server: server, configuration: stub.configuration, token: { "fn1_x" })
        _ = try await c.putBlob(sha256: "ab", data: Data([9, 8, 7]))
        let r = stub.requests[0]
        #expect(r.method == "PUT" && r.url.path == "/v1/blobs/ab" && r.body == Data([9, 8, 7]) && r.headers["Content-Type"] == "application/octet-stream")
    }

    @Test func datesParse() throws {
        let d = try APIClient.decoder.decode([String: Date].self, from: Data(#"{"t":"2026-11-09T14:32:00.123Z"}"#.utf8))["t"]!
        #expect(abs(d.timeIntervalSince1970 - 1_794_234_720.123) < 0.0005)
    }

    @Test func networkFailureIsNetworkCode() async {
        let c = APIClient(server: try! CloudServer(userInput: "http://127.0.0.1:1"), configuration: .ephemeral, token: { nil })
        await #expect(throws: APIError(status: 0, code: "network", retryAfter: nil)) { try await c.getServer() }
    }
}
