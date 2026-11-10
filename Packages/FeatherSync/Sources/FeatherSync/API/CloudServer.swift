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

    /// Feather Cloud: the app's Info.plist key FeatherCloudURL.
    public static let hosted: CloudServer = hosted(info: Bundle.main.infoDictionary)

    /// The FeatherCloudURL in `info`, or `feather-cloud.invalid` when it is missing or not a valid https address
    /// (package tests, or a typo in project.yml). A `.invalid` host never resolves, so a bad build can never send
    /// an account to a domain someone else could own.
    static func hosted(info: [String: Any]?) -> CloudServer {
        if let text = info?["FeatherCloudURL"] as? String, let server = try? CloudServer(userInput: text),
           server.baseURL.scheme == "https" {
            return server
        }
        return try! CloudServer(userInput: "https://feather-cloud.invalid")
    }

    /// Whether Feather Cloud has billing (Info.plist FeatherCloudBilling). Known without asking the server, so
    /// the signed-out app can show the right offer while making no request. False for 1.0.0.
    public static var hostedBillingEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "FeatherCloudBilling") as? Bool ?? false
    }

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
