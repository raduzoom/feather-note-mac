import Foundation

/// A fake server for one test: its own handler and request log, routed by a header on its session's
/// configuration, so suites running in parallel never share one.
final class Stub: @unchecked Sendable {
    typealias Response = (Int, [String: String], Data)
    struct Recorded: Sendable { var method: String; var url: URL; var headers: [String: String]; var body: Data }

    let id = UUID().uuidString
    let handler: @Sendable (Recorded) -> Response
    private let lock = NSLock()
    private var log: [Recorded] = []

    init(_ handler: @escaping @Sendable (Recorded) -> Response) {
        self.handler = handler
        StubProtocol.register(self)
    }

    var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        c.httpAdditionalHeaders = [StubProtocol.header: id]
        return c
    }

    var requests: [Recorded] { lock.withLock { log } }
    func record(_ r: Recorded) { lock.withLock { log.append(r) } }

    static func json(_ status: Int, _ s: String, headers: [String: String] = [:]) -> Response {
        (status, headers.merging(["Content-Type": "application/json"]) { a, _ in a }, Data(s.utf8))
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-Feather-Stub"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]

    static func register(_ stub: Stub) { lock.withLock { stubs[stub.id] = stub } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            stream.close()
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        let stub = Self.lock.withLock { headers[Self.header].flatMap { Self.stubs[$0] } }
        headers[Self.header] = nil
        let rec = Stub.Recorded(method: request.httpMethod ?? "GET", url: request.url!, headers: headers, body: body)
        stub?.record(rec)
        let (status, responseHeaders, data) = stub?.handler(rec) ?? (500, [:], Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: responseHeaders)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
