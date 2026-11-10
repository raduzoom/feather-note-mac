import Foundation

/// The HTTP client for sync-protocol.openapi.yaml: one method per operation, named after its operationId.
public final class APIClient: Sendable {
    public let server: CloudServer
    let session: URLSession
    let token: @Sendable () -> String?

    static let userAgent = "FeatherNote/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (Mac)"

    public init(server: CloudServer, configuration: URLSessionConfiguration = .ephemeral, token: @escaping @Sendable () -> String?) {
        self.server = server
        self.session = URLSession(configuration: configuration)
        self.token = token
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: text) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return d
    }()

    static let encoder = JSONEncoder()

    struct ErrorBody: Decodable {
        struct Inner: Decodable { var code: String }
        var error: Inner
    }

    // MARK: Transport

    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Encodable? = nil, raw: Data? = nil,
              auth: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var url = server.baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if auth, let token = token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try Self.encoder.encode(json)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else if let raw {
            request.httpBody = raw
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.network }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? Self.decoder.decode(ErrorBody.self, from: data))?.error.code ?? "server_error"
            throw APIError(status: http.statusCode, code: code, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) })
        }
        return (data, http)
    }

    func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Encodable? = nil, auth: Bool = true) async throws -> T {
        let (data, _) = try await send(method, path, query: query, json: json, auth: auth)
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw APIError(status: 200, code: "server_error", retryAfter: nil) }
    }

    // MARK: Operations

    public func getServer() async throws -> ServerInfo { try await call("GET", "server", auth: false) }

    public func prelogin(email: String) async throws -> (kdf: KDF, salt: Data) {
        struct R: Decodable { var kdf: KDF; var salt: Data }
        let r: R = try await call("POST", "auth/prelogin", json: ["email": email], auth: false)
        return (r.kdf, r.salt)
    }

    public func signup(_ body: SignupRequest) async throws { _ = try await send("POST", "auth/signup", json: body, auth: false) }

    public func verify(email: String, code: String, deviceName: String) async throws -> SessionResponse {
        try await call("POST", "auth/verify", json: ["email": email, "code": code, "device_name": deviceName], auth: false)
    }

    public func resend(email: String) async throws { _ = try await send("POST", "auth/resend", json: ["email": email], auth: false) }

    public func login(email: String, authKey: Data, deviceName: String) async throws -> SessionResponse {
        try await call("POST", "auth/login", json: ["email": email, "auth_key": authKey.base64EncodedString(), "device_name": deviceName], auth: false)
    }

    public func recover(email: String, recoveryAuthKey: Data, deviceName: String) async throws -> SessionResponse {
        try await call("POST", "auth/recover",
                       json: ["email": email, "recovery_auth_key": recoveryAuthKey.base64EncodedString(), "device_name": deviceName], auth: false)
    }

    public func logout() async throws { _ = try await send("POST", "auth/logout") }

    public func getAccount() async throws -> CloudAccount { try await call("GET", "account") }

    public func deleteAccount(authKey: Data) async throws {
        _ = try await send("DELETE", "account", json: ["auth_key": authKey.base64EncodedString()])
    }

    public func setPassword(_ body: SetPasswordRequest) async throws -> String {
        struct R: Decodable { var token: String }
        let r: R = try await call("POST", "account/password", json: body)
        return r.token
    }

    public func listDevices() async throws -> [CloudDevice] {
        struct R: Decodable { var devices: [CloudDevice] }
        let r: R = try await call("GET", "devices")
        return r.devices
    }

    public func revokeDevice(_ id: String) async throws { _ = try await send("DELETE", "devices/\(id)") }

    public func push(libraryID: String, changes: [Change]) async throws -> [PushResult] {
        struct Body: Encodable { var library_id: String; var changes: [Change] }
        struct R: Decodable { var results: [PushResult] }
        let r: R = try await call("POST", "sync/push", json: Body(library_id: libraryID, changes: changes))
        return r.results
    }

    public func pull(libraryID: String, cursor: String?, limit: Int = 500) async throws -> PullPage {
        var q = [URLQueryItem(name: "library_id", value: libraryID), URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await call("GET", "sync/pull", query: q)
    }

    public func putBlob(sha256: String, data: Data) async throws -> BlobRef {
        let (body, _) = try await send("PUT", "blobs/\(sha256)", raw: data)
        do { return try Self.decoder.decode(BlobRef.self, from: body) } catch { throw APIError(status: 200, code: "server_error", retryAfter: nil) }
    }

    public func getBlob(sha256: String) async throws -> Data {
        try await send("GET", "blobs/\(sha256)").0
    }
}
