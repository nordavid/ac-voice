import ACVoiceCore
import Foundation
import Synchronization

/// Result of a conditional GET.
public enum Fetch<T: Sendable>: Sendable {
    /// 200 with a body. `etag` is the new validator (nil when the server sent none).
    case fresh(T, etag: String?)
    /// 304: the cached value is still current.
    case notModified

    public var value: T? {
        if case .fresh(let v, _) = self { return v }
        return nil
    }
}

/// Typed AC errors. Descriptions name paths (ids only), never the token or an ETag.
public enum ACError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No token in the Keychain or in ac-mcp.
    case noToken
    /// Token rejected (401, or 500 `InvalidTokenException` [V]), also after one renewal.
    case unauthorized
    case notFound(path: String)
    /// AC answers an unknown API path with 500 "Failed to match '<path>' path." [V].
    case endpointMissing(path: String)
    case http(status: Int, path: String)
    /// A redirect where none is expected (redirects are never followed).
    case unexpectedRedirect(path: String)
    /// `detail` holds the coding path only, never values.
    case decoding(path: String, detail: String)
    /// URLError code (`URLError.Code.rawValue`).
    case transport(code: Int)
    case invalidPath(String)
    case keychain(status: Int32)
    /// The base URL is not https with a host (`Config.isValidBaseURL`): the token header is never sent there.
    case insecureBaseURL

    /// A miss-path step ran out of its time budget (same text as a URLSession timeout: "AC nicht erreichbar").
    public static let timedOut = ACError.transport(code: URLError.Code.timedOut.rawValue)

    public var description: String {
        switch self {
        case .noToken: return "no AC token"
        case .unauthorized: return "401 unauthorized"
        case .notFound(let p): return "404 \(p)"
        case .endpointMissing(let p): return "endpoint missing: \(p)"
        case .http(let s, let p): return "HTTP \(s) \(p)"
        case .unexpectedRedirect(let p): return "unexpected redirect: \(p)"
        case .decoding(let p, let d): return "cannot decode \(p) at \(d)"
        case .transport(let c): return "transport error \(c)"
        case .invalidPath(let p): return "invalid path \(p)"
        case .keychain(let s): return "keychain status \(s)"
        case .insecureBaseURL: return "base URL is not https"
        }
    }

    /// Short German text for the overlay and the menu.
    public var userMessage: String {
        switch self {
        case .noToken: return "AC-Token fehlt"
        case .unauthorized: return "AC lehnt den Token ab"
        case .notFound: return "AC kennt diese Seite nicht"
        // Same text as `FlowText.acUnreachable`: the overlay adds "Prüfe die Internetverbindung" to it.
        case .transport: return "AC antwortet nicht"
        case .decoding: return "Ich verstehe die Antwort von AC nicht"
        case .keychain: return "Der Schlüsselbund antwortet nicht"
        case .insecureBaseURL: return "Die AC-Adresse braucht https"
        case .endpointMissing, .http, .unexpectedRedirect, .invalidPath: return "AC meldet einen Fehler"
        }
    }
}

/// API paths below {base}/api/v1. One place, so tests and the ETag map use the same strings.
public enum ACPaths {
    public static let projects = "/projects"
    public static let projectNames = "/projects/names"
    public static let favorites = "/favorites"
    public static let companies = "/companies"
    public static func userTasks(_ userId: Int) -> String { "/users/\(userId)/tasks" }
    public static func projectTasks(_ projectId: Int) -> String { "/projects/\(projectId)/tasks" }
    public static func archive(_ projectId: Int, page: Int) -> String { "/projects/\(projectId)/tasks/archive?page=\(page)" }
    public static func task(_ projectId: Int, _ taskId: Int) -> String { "/projects/\(projectId)/tasks/\(taskId)" }
    public static let timeRecordsPrefix = "/time-records/filtered-by-date"

    /// /users/{me}/time-records/filtered-by-date?from=YYYY-MM-DD&to=YYYY-MM-DD (dates in `calendar`'s time zone).
    public static func timeRecords(_ userId: Int, from: Date, to: Date, calendar: Calendar = .current) -> String {
        func day(_ d: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        return "/users/\(userId)\(timeRecordsPrefix)?from=\(day(from))&to=\(day(to))"
    }
}

/// Raw HTTP counters of one client (for `acvoice-index --stats`).
public struct ClientStats: Sendable, Equatable {
    public var requests = 0
    public var notModified = 0
    public var bytes = 0
    /// Token renewals after a 401.
    public var renewals = 0
    public init() {}
}

/// Read-only ActiveCollab client. **GET only by construction**: `makeRequest` is the single place that builds a
/// `URLRequest`, it always sets "GET", and no API takes a method or a body.
///
/// - Base URL: https with a host only (`Config.isValidBaseURL`). Otherwise every request throws
///   `ACError.insecureBaseURL` before the token is loaded: the token never travels in clear text or to a bare path.
/// - Auth: `X-Angie-AuthApiToken`. When AC rejects the token the client asks its `TokenProvider` for a fresh token
///   (re-import from ac-mcp), retries once, and then throws `ACError.unauthorized`. AC v8 answers an invalid token
///   with **500** `ActiveCollab\Authentication\Exception\InvalidTokenException`; only a missing header gives 401 [V].
///   A renewal that found nothing is not permanent: after `renewalCooldown` the next rejection asks the provider
///   again, and `resetToken()` (token re-imported or pasted) clears the state at once.
/// - ETags: pass the stored validator, get `.notModified` on 304. Never log ETags (they contain an e-mail address).
/// - Redirects are never followed (session delegate). The task probe reads the 301 `Location` itself.
/// - Network work and JSON decoding run off the actor (`@concurrent`); only the token state is isolated.
public actor ACClient {
    /// Web root, e.g. https://ac.example.com.
    public nonisolated let base: URL
    /// {base}/api/v1
    public nonisolated let apiBase: URL
    public nonisolated let userId: Int
    private nonisolated let session: URLSession
    /// After a renewal that found no new token (or failed), further rejections of the same token throw at once for
    /// this long instead of asking the provider again.
    public nonisolated let renewalCooldown: Duration
    private let tokens: any TokenProvider
    private var token: String?
    /// The first token load in flight: concurrent first requests share it.
    private var tokenLoad: Task<String, any Error>?
    /// The renewal in flight: concurrent rejections of the same token share it. Cleared when it finishes.
    private var renewal: (rejected: String, task: Task<String?, any Error>)?
    /// Last renewal that brought no new token, for `renewalCooldown`.
    private var failedRenewal: (rejected: String, at: ContinuousClock.Instant)?
    /// Bumped by `resetToken()`: results of loads and renewals started before a reset are dropped.
    private var generation = 0
    private nonisolated let counters = Mutex(ClientStats())

    /// - Parameters:
    ///   - configuration: nil uses `ACClient.defaultConfiguration()`. Tests pass one with a stub protocol.
    ///   - renewalCooldown: see `renewalCooldown`.
    public init(base: URL, userId: Int, tokens: any TokenProvider, configuration: URLSessionConfiguration? = nil,
                renewalCooldown: Duration = .seconds(10)) {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        self.base = URL(string: root) ?? base
        self.apiBase = URL(string: root + "/api/v1") ?? base.appendingPathComponent("api/v1")
        self.userId = userId
        self.tokens = tokens
        self.renewalCooldown = renewalCooldown
        self.session = URLSession(configuration: configuration ?? Self.defaultConfiguration(),
                                  delegate: RedirectRefuser(), delegateQueue: nil)
    }

    public init(base: URL, token: String, userId: Int, configuration: URLSessionConfiguration? = nil) {
        self.init(base: base, userId: userId, tokens: StaticTokenProvider(token), configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    /// Ephemeral (no disk cache, no cookies), cache bypassed so `If-None-Match` is under our control.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 16
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": "ac-voice/1"]
        return c
    }

    public nonisolated var stats: ClientStats { counters.withLock { $0 } }

    // MARK: - Endpoints

    /// GET /projects (about 60 active projects came in one response [V]). Follows pagination when the total
    /// exceeds one page.
    @concurrent public nonisolated func projects(etag: String? = nil) async throws -> Fetch<[ACProject]> {
        let first: Response<LossyList<ACProject>> = try await fetch(ACPaths.projects, etag: etag)
        guard case .fresh(let list, let tag) = first.fetch else { return .notModified }
        var all = list.items
        if let total = first.totalItems, all.count < total, !all.isEmpty {
            var page = 2
            while all.count < total, page <= 50 {
                let next: Response<LossyList<ACProject>> = try await fetch(ACPaths.projects + "?page=\(page)")
                guard let items = next.fetch.value?.items, !items.isEmpty else { break }
                all += items
                page += 1
            }
        }
        return .fresh(all, etag: tag)
    }

    /// GET /projects/names: `{"628": "WWT: …"}` for the active projects (a few KB [V]).
    @concurrent public nonisolated func projectNames() async throws -> [Int: String] {
        let r: Response<[String: String]> = try await fetch(ACPaths.projectNames)
        var out: [Int: String] = [:]
        for (k, v) in r.fetch.value ?? [:] { if let id = Int(k) { out[id] = v } }
        return out
    }

    /// GET /favorites: `[["Project", 628, false], …]` [V].
    @concurrent public nonisolated func favorites(etag: String? = nil) async throws -> Fetch<[ACFavorite]> {
        let r: Response<LossyList<ACFavorite>> = try await fetch(ACPaths.favorites, etag: etag)
        return r.fetch.map(\.items)
    }

    /// GET /users/{me}/tasks: own open tasks with `task_number` and `project_id` [V].
    @concurrent public nonisolated func myTasks(etag: String? = nil) async throws -> Fetch<ACUserTasks> {
        let r: Response<ACUserTasks> = try await fetch(ACPaths.userTasks(userId), etag: etag)
        return r.fetch
    }

    /// GET /users/{me}/time-records/filtered-by-date [V].
    @concurrent public nonisolated func timeRecords(from: Date, to: Date, etag: String? = nil) async throws -> Fetch<[ACTimeRecord]> {
        try await timeRecords(path: ACPaths.timeRecords(userId, from: from, to: to), etag: etag)
    }

    @concurrent nonisolated func timeRecords(path: String, etag: String?) async throws -> Fetch<[ACTimeRecord]> {
        let r: Response<ACTimeRecords> = try await fetch(path, etag: etag)
        return r.fetch.map(\.records)
    }

    /// GET /companies [V]. Names feed the company aliases.
    @concurrent public nonisolated func companies(etag: String? = nil) async throws -> Fetch<[ACCompany]> {
        let r: Response<LossyList<ACCompany>> = try await fetch(ACPaths.companies, etag: etag)
        return r.fetch.map(\.items)
    }

    /// GET /projects/{id}/tasks: open tasks plus completed and trashed ids (over 100 KB for a large project [V]).
    @concurrent public nonisolated func projectTasks(_ projectId: Int, etag: String? = nil) async throws -> Fetch<ACProjectTasks> {
        let r: Response<ACProjectTasks> = try await fetch(ACPaths.projectTasks(projectId), etag: etag)
        return r.fetch
    }

    /// GET /projects/{id}/tasks/archive?page=N: 30 completed tasks per page, newest completion first;
    /// a page past the end is `[]` [V].
    @concurrent public nonisolated func archivePage(_ projectId: Int, page: Int) async throws -> ACArchivePage {
        let r: Response<LossyList<ACTask>> = try await fetch(ACPaths.archive(projectId, page: page))
        return ACArchivePage(tasks: r.fetch.value?.items ?? [], totalItems: r.totalItems, perPage: r.perPage)
    }

    /// Project of a global task id without knowing it: GET /projects/{any accessible project}/tasks/{id} answers
    /// 301 with `Location: …/projects/{pid}/tasks/{id}` (25 ms warm [V]). 200 means `via` itself, 404 gives nil.
    @concurrent public nonisolated func probeProject(ofTask taskId: Int, via projectId: Int) async throws -> Int? {
        let path = ACPaths.task(projectId, taskId)
        let (_, http) = try await send(path)
        switch http.statusCode {
        case 200: return projectId
        case 301, 302, 303, 307, 308:
            guard let location = http.value(forHTTPHeaderField: "Location") else { return nil }
            return Self.projectId(fromTaskLocation: location, taskId: taskId)
        case 404: return nil
        default: throw ACError.http(status: http.statusCode, path: path)
        }
    }

    /// GET /projects/{pid}/tasks/{id} (canonical path): number, completion and trash state. nil on 404.
    @concurrent public nonisolated func task(projectId: Int, taskId: Int) async throws -> ACTask? {
        do {
            let r: Response<ACTaskDetails> = try await fetch(ACPaths.task(projectId, taskId))
            return r.fetch.value?.single
        } catch ACError.notFound {
            return nil
        }
    }

    /// "https://host/api/v1/projects/2032/tasks/47285" -> 2032 when the task id matches.
    static func projectId(fromTaskLocation location: String, taskId: Int) -> Int? {
        guard let m = location.firstMatch(of: /\/projects\/(\d+)\/tasks\/(\d+)(?:[\/?#]|$)/),
              Int(m.output.2) == taskId else { return nil }
        return Int(m.output.1)
    }

    // MARK: - Transport

    struct Response<T: Sendable>: Sendable {
        var fetch: Fetch<T>
        var totalItems: Int?
        var perPage: Int?
    }

    /// Conditional GET + decode. 304 is only valid when a validator was sent.
    @concurrent nonisolated func fetch<T: Decodable & Sendable>(_ path: String, etag: String? = nil) async throws -> Response<T> {
        let (data, http) = try await send(path, etag: etag)
        let total = http.value(forHTTPHeaderField: "X-Angie-PaginationTotalItems").flatMap { Int($0) }
        let perPage = http.value(forHTTPHeaderField: "X-Angie-PaginationItemsPerPage").flatMap { Int($0) }
        switch http.statusCode {
        case 200:
            do {
                let value = try JSONDecoder().decode(T.self, from: data)
                let tag = http.value(forHTTPHeaderField: "ETag").flatMap { $0.isEmpty ? nil : $0 }
                return Response(fetch: .fresh(value, etag: tag), totalItems: total, perPage: perPage)
            } catch let e as DecodingError {
                throw ACError.decoding(path: path, detail: Self.codingPath(e))
            }
        case 304 where etag != nil:
            return Response(fetch: .notModified, totalItems: total, perPage: perPage)
        case 300...399:
            throw ACError.unexpectedRedirect(path: path)
        case 404:
            throw ACError.notFound(path: path)
        case 500 where String(decoding: data.prefix(512), as: UTF8.self).contains("Failed to match"):
            throw ACError.endpointMissing(path: path)
        default:
            throw ACError.http(status: http.statusCode, path: path)
        }
    }

    /// One GET with the 401 renewal. Returns any status; callers map it.
    @concurrent nonisolated func send(_ path: String, etag: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard Config.isValidBaseURL(base) else { throw ACError.insecureBaseURL }
        var token = try await currentToken()
        var renewed = false
        while true {
            let request = try makeRequest(path, etag: etag, token: token)
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                throw ACError.transport(code: e.code.rawValue)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ACError.transport(code: URLError.Code.unknown.rawValue)
            }
            guard let http = response as? HTTPURLResponse else {
                throw ACError.transport(code: URLError.Code.badServerResponse.rawValue)
            }
            counters.withLock {
                $0.requests += 1; $0.bytes += data.count
                if http.statusCode == 304 { $0.notModified += 1 }
            }
            if Self.isTokenRejected(status: http.statusCode, body: data) {
                if !renewed, let fresh = try await renewToken(rejected: token) {
                    token = fresh; renewed = true
                    continue
                }
                throw ACError.unauthorized
            }
            return (data, http)
        }
    }

    /// 401, or the 500 that AC v8 sends for an invalid or expired token [V].
    static func isTokenRejected(status: Int, body: Data) -> Bool {
        if status == 401 { return true }
        guard status == 500 || status == 403 else { return false }
        let head = String(decoding: body.prefix(512), as: UTF8.self)
        return head.contains("InvalidTokenException") || head.contains("Authorization token is not valid")
    }

    /// The only request builder. Always GET, never a body, and never a token for a base that is not https.
    nonisolated func makeRequest(_ path: String, etag: String?, token: String) throws -> URLRequest {
        guard Config.isValidBaseURL(base) else { throw ACError.insecureBaseURL }
        guard path.hasPrefix("/"), !path.contains("://"), !path.contains(".."),
              let url = URL(string: apiBase.absoluteString + path) else { throw ACError.invalidPath(path) }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpMethod = "GET"
        r.setValue(token, forHTTPHeaderField: "X-Angie-AuthApiToken")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return r
    }

    // MARK: - Token state (isolated)

    /// Forgets the token and every renewal result: the next request loads the token from the provider again.
    /// Call it after the token was re-imported from ac-mcp or pasted (`KeychainTokenStore.save`).
    public func resetToken() {
        generation += 1
        token = nil
        tokenLoad = nil
        renewal = nil
        failedRenewal = nil
    }

    /// The cached token, else one shared load from the provider. A failed load is not cached.
    func currentToken() async throws -> String {
        if let token { return token }
        if let load = tokenLoad { return try await load.value }
        let provider = tokens, gen = generation
        let load = Task<String, any Error> { try await provider.token() }
        tokenLoad = load
        let result = await load.result
        if tokenLoad == load { tokenLoad = nil }
        let fresh = try result.get()
        if gen == generation, token == nil { token = fresh }
        return fresh
    }

    /// Asks the provider for a token other than `rejected`. Concurrent rejections share one renewal; after a renewal
    /// without a new token the same token is not renewed again for `renewalCooldown`.
    func renewToken(rejected: String) async throws -> String? {
        if let token, token != rejected { return token }
        // After `resetToken()` the provider may already hold a different token (re-import, paste).
        if token == nil, let current = try? await currentToken(), current != rejected { return current }
        if let r = renewal, r.rejected == rejected { return try await r.task.value }
        if let f = failedRenewal, f.rejected == rejected, ContinuousClock.now - f.at < renewalCooldown { return nil }
        let provider = tokens, gen = generation
        let task = Task<String?, any Error> {
            guard let fresh = try await provider.refreshedToken(rejected: rejected), fresh != rejected else { return nil }
            return fresh
        }
        renewal = (rejected, task)
        counters.withLock { $0.renewals += 1 }
        let result = await task.result
        if renewal?.task == task { renewal = nil }
        guard gen == generation else { return try result.get() }
        switch result {
        case .success(let fresh?):
            token = fresh
            failedRenewal = nil
            return fresh
        case .success(nil):
            failedRenewal = (rejected, .now)
            return nil
        case .failure(let error):
            failedRenewal = (rejected, .now)
            throw error
        }
    }

    static func codingPath(_ e: DecodingError) -> String {
        let path: [any CodingKey]
        switch e {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): path = c.codingPath
        case .keyNotFound(let k, let c): path = c.codingPath + [k]
        @unknown default: path = []
        }
        let s = path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return s.isEmpty ? "root" : s
    }
}

extension Fetch: Equatable where T: Equatable {}

extension Fetch {
    func map<U: Sendable>(_ f: (T) -> U) -> Fetch<U> {
        switch self {
        case .fresh(let v, let tag): return .fresh(f(v), etag: tag)
        case .notModified: return .notModified
        }
    }
}

/// Refuses every redirect: the probe reads the 301 itself, and the token header never follows to another URL.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
