import Foundation
import Synchronization
@testable import ACVoiceAC

/// One request as the stub saw it.
struct RecordedRequest: Sendable {
    var method: String
    /// Path below /api/v1, with the query ("/projects/7/tasks/archive?page=2").
    var path: String
    var headers: [String: String]
    var hasBody: Bool
    var token: String? { headers.first { $0.key.lowercased() == "x-angie-authapitoken" }?.value }
    var ifNoneMatch: String? { headers.first { $0.key.lowercased() == "if-none-match" }?.value }
}

struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// Delivery delay in seconds.
    var delay: Double = 0
    /// Deliver as a redirect through `URLProtocolClient.wasRedirectedTo` (the session must refuse it).
    var redirect: String?

    static func json(_ text: String, etag: String? = nil, headers: [String: String] = [:]) -> StubResponse {
        var h = headers
        h["Content-Type"] = "application/json"
        if let etag { h["ETag"] = etag }
        return StubResponse(status: 200, headers: h, body: Data(text.utf8))
    }
    static let notModified = StubResponse(status: 304)
    static let notFound = StubResponse(status: 404)
    static let unauthorized = StubResponse(status: 401)
}

/// An in-process AC: every test gets its own host, so parallel tests never share state.
final class StubServer: Sendable {
    typealias Handler = @Sendable (RecordedRequest) -> StubResponse

    let host: String
    private let handler: Handler
    private let state = Mutex<(requests: [RecordedRequest], inFlight: Int, maxInFlight: Int)>(([], 0, 0))

    private static let registry = Mutex<[String: StubServer]>([:])

    init(_ handler: @escaping Handler) {
        host = "stub-\(UUID().uuidString.lowercased()).test"
        self.handler = handler
        Self.registry.withLock { $0[host] = self }
    }

    static func lookup(_ host: String) -> StubServer? { registry.withLock { $0[host] } }

    var base: URL { URL(string: "https://\(host)")! }
    var requests: [RecordedRequest] { state.withLock { $0.requests } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    func paths() -> [String] { requests.map(\.path) }

    func configuration() -> URLSessionConfiguration {
        let c = ACClient.defaultConfiguration()
        c.protocolClasses = [StubURLProtocol.self]
        return c
    }

    func client(token: String = Fixtures.token, userId: Int = Fixtures.userId, tokens: (any TokenProvider)? = nil,
                renewalCooldown: Duration = .seconds(10)) -> ACClient {
        ACClient(base: base, userId: userId, tokens: tokens ?? StaticTokenProvider(token), configuration: configuration(),
                 renewalCooldown: renewalCooldown)
    }

    func handle(_ r: RecordedRequest) -> StubResponse {
        state.withLock {
            $0.requests.append(r)
            $0.inFlight += 1
            $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
        }
        return handler(r)
    }

    func finished() { state.withLock { $0.inFlight -= 1 } }
    func resetMaxInFlight() { state.withLock { $0.maxInFlight = $0.inFlight } }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let server = StubServer.lookup(host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var path = url.path
        if path.hasPrefix("/api/v1") { path.removeFirst("/api/v1".count) }
        if let q = url.query { path += "?" + q }
        let recorded = RecordedRequest(method: request.httpMethod ?? "GET", path: path,
                                       headers: request.allHTTPHeaderFields ?? [:],
                                       hasBody: request.httpBody != nil || request.httpBodyStream != nil)
        let response = server.handle(recorded)
        let deliver: @Sendable () -> Void = { [self] in
            defer { server.finished() }
            if stopped.withLock({ $0 }) { return }
            var headers = response.headers
            if let target = response.redirect { headers["Location"] = target }
            let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            if let target = response.redirect, let targetURL = URL(string: target) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: targetURL), redirectResponse: http)
            }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }
}

/// Counts renewals; hands out `fresh` once (or never when nil).
final class CountingTokenProvider: TokenProvider {
    private let state = Mutex<(asked: Int, token: String)>((0, ""))
    private let fresh: String?
    init(initial: String, fresh: String?) {
        self.fresh = fresh
        state.withLock { $0.token = initial }
    }
    var asked: Int { state.withLock { $0.asked } }
    func token() async throws -> String { state.withLock { $0.token } }
    func refreshedToken(rejected: String) async throws -> String? {
        try await Task.sleep(for: .milliseconds(20))   // widen the window for concurrent 401s
        return state.withLock { s -> String? in
            s.asked += 1
            guard let fresh, fresh != rejected else { return nil }
            s.token = fresh
            return fresh
        }
    }
}

/// A token source that changes from outside: ac-mcp re-issues a token, or the user pastes one. `token()` returns the
/// current token; `refreshedToken` offers it when it differs from the rejected one. `failLoads` makes the first
/// `token()` calls throw `noToken`.
final class SwitchableTokenProvider: TokenProvider {
    private struct State { var current: String; var asked = 0; var loads = 0; var failLoads = 0 }
    private let state: Mutex<State>
    private let loadDelay: Duration
    init(initial: String, failLoads: Int = 0, loadDelay: Duration = .zero) {
        state = Mutex(State(current: initial, failLoads: failLoads))
        self.loadDelay = loadDelay
    }
    var asked: Int { state.withLock { $0.asked } }
    var loads: Int { state.withLock { $0.loads } }
    func publish(_ token: String) { state.withLock { $0.current = token } }
    func token() async throws -> String {
        if loadDelay > .zero { try await Task.sleep(for: loadDelay) }
        return try state.withLock { s in
            s.loads += 1
            if s.failLoads > 0 { s.failLoads -= 1; throw ACError.noToken }
            return s.current
        }
    }
    func refreshedToken(rejected: String) async throws -> String? {
        state.withLock { s in
            s.asked += 1
            return s.current == rejected ? nil : s.current
        }
    }
}
