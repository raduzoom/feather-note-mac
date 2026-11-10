import FeatherCore
import FeatherCrypto
import Foundation
import Testing
@testable import FeatherSync

/// The local Feather Cloud server from ../server, started with forwarded addresses trusted (each test account
/// gets its own, so signup's per-IP limit doesn't trip) and billing on (so plans can be read-only).
enum Harness {
    static let setup = "Start the server: FEATHER_TRUST_PROXY=true FEATHER_BILLING=on docker compose -f ../server/deploy/docker-compose.yml up -d --build --wait, then set FEATHER_SYNC_SERVER=http://127.0.0.1:8420"
    static let compose: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }   // Harness.swift … mac
        return url.appending(path: "server/deploy/docker-compose.yml")
    }()

    static func server() throws -> CloudServer {
        guard let text = ProcessInfo.processInfo.environment["FEATHER_SYNC_SERVER"] else {
            Issue.record(Comment(rawValue: setup))
            throw CancellationError()
        }
        return try CloudServer(userInput: text)
    }

    nonisolated(unsafe) static var ip = Int.random(in: 0..<60_000)
    static let lock = NSLock()

    /// A session configuration with its own client address.
    static func configuration() -> URLSessionConfiguration {
        let n = lock.withLock { ip += 1; return ip }
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["X-Forwarded-For": "10.\(n / 65536 % 256).\(n / 256 % 256).\(n % 256)"]
        return c
    }

    static func docker(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        p.arguments = ["compose", "-f", compose.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The newest verification code the server's log mailer wrote for `email`.
    static func code(for email: String) async throws -> String {
        for _ in 0..<20 {
            let log = try docker(["logs", "--since", "5m", "server"])
            let pattern = "mail to \(email): Your Feather Cloud code is "
            if let line = log.split(separator: "\n").last(where: { $0.contains(pattern) }),
               let range = line.range(of: pattern) {
                return String(line[range.upperBound...].prefix(6))
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CancellationError()
    }

    static func sql(_ statement: String) throws -> String {
        try docker(["exec", "-T", "postgres", "psql", "-U", "feather", "-d", "feather", "-tAc", statement])
    }

    static func email() -> String { "sync-\(UUID().uuidString.prefix(8).lowercased())@example.com" }
}

/// One simulated Mac: a library, an account service and, once signed in, a sync engine.
final class TestDevice: @unchecked Sendable {
    let name: String
    let library: Library
    let account: AccountService
    var engine: SyncEngine!
    var signedIn: SignedIn!

    init(_ name: String) throws {
        self.name = name
        let dir = FileManager.default.temporaryDirectory.appending(path: "FeatherSyncIT-\(UUID().uuidString)")
        library = try Library.open(at: dir)
        account = AccountService(server: try Harness.server(), secrets: InMemorySecretStore(), keys: InMemoryMasterKeyStore(),
                                 configuration: Harness.configuration())
    }

    /// Signs up a new account and verifies it; returns its recovery key.
    @discardableResult
    func signUp(_ email: String, password: String = "correct horse battery") async throws -> RecoveryKey {
        let key = try await account.startSignup(email: email, password: password, libraryID: library.id.description)
        signedIn = try await account.verify(email: email, code: try await Harness.code(for: email), deviceName: name)
        try await library.resetSync(markAllDirty: true)
        engine = SyncEngine(library: library, account: account, libraryID: signedIn.libraryID, deviceName: name)
        return key
    }

    func signIn(_ email: String, password: String = "correct horse battery") async throws {
        signedIn = try await account.signIn(email: email, password: password, deviceName: name)
        try await library.resetSync(markAllDirty: true)
        engine = SyncEngine(library: library, account: account, libraryID: signedIn.libraryID, deviceName: name)
    }

    @discardableResult
    func sync() async throws -> SyncReport { try await engine.syncOnce().report }

    func notes() async throws -> [Note] {
        var out: [Note] = []
        for s in try await library.notes(in: .all) { if let n = try await library.note(s.id) { out.append(n) } }
        return out.sorted { $0.title < $1.title }
    }
}
