import Foundation

/// An error from the server (sync-protocol.md "Errors"), or `network` (status 0) when it couldn't be reached.
public struct APIError: Error, Equatable, Sendable {
    public var status: Int
    public var code: String
    public var retryAfter: Int?

    public init(status: Int, code: String, retryAfter: Int?) {
        self.status = status
        self.code = code
        self.retryAfter = retryAfter
    }

    public static let network = APIError(status: 0, code: "network", retryAfter: nil)
}
