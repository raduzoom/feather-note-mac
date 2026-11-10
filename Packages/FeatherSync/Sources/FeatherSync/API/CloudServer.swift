import Foundation

public enum ServerURLError: Error, Equatable, Sendable {
    case invalid
    /// Plain HTTP to anything but this Mac (sync-protocol.md: "TLS is required except for localhost").
    case insecure
}

/// A Feather Cloud server: the hosted service or a self-hosted one.
public struct CloudServer: Sendable, Equatable, Codable {
    /// Ends in /v1.
    public let baseURL: URL

    /// Fixed at launch in Phase 10.
    public static let hosted = try! CloudServer(userInput: "https://cloud.feathernote.app")

    /// What the user typed: a host or a URL. `https://` is added when no scheme is given, and `/v1` appended.
    public init(userInput: String) throws(ServerURLError) {
        var text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalid }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1") { text.removeLast(3) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty,
              scheme == "https" || scheme == "http" else { throw .invalid }
        if scheme == "http", host != "localhost", host != "127.0.0.1" { throw .insecure }
        baseURL = url.appending(path: "v1")
    }

    public var host: String { baseURL.host() ?? "" }
    /// What the user typed it as, for the settings field.
    public var display: String { baseURL.deletingLastPathComponent().absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
