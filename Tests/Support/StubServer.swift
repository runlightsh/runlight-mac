import Foundation
@testable import Runlight

/// Loads a captured API response from `Tests/Fixtures`.
enum Fixture {
    private final class Anchor {}

    static func data(_ name: String) -> Data {
        let bundle = Bundle(for: Anchor.self)
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            fatalError("No fixture named \(name)")
        }
        return data
    }

    /// What the fixture's request answered with, from the manifest.
    static func status(_ name: String) -> Int {
        let manifest = try! JSONSerialization.jsonObject(with: data("manifest")) as! [String: Any]
        let fixtures = manifest["fixtures"] as! [String: [String: Any]]
        return fixtures[name]!["status"] as! Int
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try RunlightClient.decoder.decode(type, from: data(name))
    }
}

/// A pretend Runlight install for one test. Each gets its own host, so tests running in parallel
/// never see each other's routes, and every request it receives is kept for checking.
final class StubServer: @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var contentType = "application/json"
    }

    typealias Route = @Sendable (URLRequest) -> Response?

    let host = "\(UUID().uuidString.lowercased()).test"
    var baseURL: URL { URL(string: "https://\(host)")! }
    let session: URLSession

    private let lock = NSLock()
    private var routes: [Route] = []
    private var received: [URLRequest] = []
    private var bodies: [Data] = []

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        StubProtocol.register(self)
    }

    deinit { StubProtocol.unregister(host) }

    func client(token: String = "rl_test", at path: String = "") -> RunlightClient {
        RunlightClient(baseURL: path.isEmpty ? baseURL : baseURL.appending(path: path), token: token, session: session)
    }

    /// Answers `method path` (the path without its query) with a fixture and its recorded status.
    func on(_ method: String, _ path: String, fixture: String, status: Int? = nil) {
        let body = Fixture.data(fixture)
        let code = status ?? Fixture.status(fixture)
        on(method, path) { _ in Response(status: code, body: body) }
    }

    func on(_ method: String, _ path: String, respond: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock {
            routes.append { request in
                request.httpMethod == method && request.url?.path == path ? respond(request) : nil
            }
        }
    }

    var requests: [URLRequest] { lock.withLock { received } }
    var requestBodies: [Data] { lock.withLock { bodies } }

    fileprivate func handle(_ request: URLRequest, body: Data) -> Response {
        lock.withLock {
            received.append(request)
            bodies.append(body)
            for route in routes.reversed() {
                if let response = route(request) { return response }
            }
            return Response(status: 404, body: Data(#"{"error":"Not found","code":"not_found"}"#.utf8))
        }
    }
}

/// Routes requests for `*.test` hosts to their StubServer.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: StubServer) { lock.withLock { servers[server.host] = server } }
    static func unregister(_ host: String) { lock.withLock { _ = servers.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host, let server = Self.lock.withLock({ Self.servers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = server.handle(request, body: Self.body(of: request))
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": response.contentType])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves a request's body into a stream before a protocol sees it.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A protocol that fails every request, to stand in for a Mac with no network.
final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        return URLSession(configuration: configuration)
    }
}
