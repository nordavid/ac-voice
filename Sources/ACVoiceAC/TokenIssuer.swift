import ACVoiceCore
import Foundation
import os

/// Sign-in with e-mail and password: asks ActiveCollab to issue an API token for AC Voice in the user's account.
/// ActiveCollab 8 issues tokens through `POST {base}/api/v1/issue-token` with
/// `{"username", "password", "client_name", "client_vendor"}` and answers `{"is_ok": 1, "token": "<userId>-<key>"}`.
///
/// This is the single write AC Voice sends to ActiveCollab, and it lives apart from `ACClient`, which stays GET-only.
///
/// - Base URL: https with a host only (`Config.isValidBaseURL`), checked before any request is built, so the password
///   never travels in clear text.
/// - Redirects are refused (`RedirectRefuser`): the password is never forwarded to another URL. A 3xx answer is an
///   error.
/// - Ephemeral session without cache or cookies; about 15 s timeout.
/// - The password lives only as long as `issueToken` runs. Errors are `ACError` values that name the path only, never
///   the password, the token or the response body.
public final class ACTokenIssuer: Sendable {
    /// ACVoiceAC has no dependency on ACVoiceSystem's `Log`, so it logs under the same subsystem directly.
    static let log = Logger(subsystem: "io.github.nordavid.acvoice", category: "index")

    /// Path below {base}/api/v1.
    public static let path = "/issue-token"
    /// `client_name` and `client_vendor`: the name ActiveCollab shows for the issued token.
    public static let clientName = "AC Voice"
    public static let timeout: TimeInterval = 15

    /// Web root, e.g. https://ac.example.com.
    public let base: URL
    private let session: URLSession

    /// - Parameter configuration: nil uses `ACTokenIssuer.defaultConfiguration()`. Tests pass one with a stub protocol.
    public init(base: URL, configuration: URLSessionConfiguration? = nil) {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        self.base = URL(string: root) ?? base
        session = URLSession(configuration: configuration ?? Self.defaultConfiguration(),
                             delegate: RedirectRefuser(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Ephemeral (no disk cache, no cookies, no credential storage), 15 s timeout.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let c = ACClient.defaultConfiguration()
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        return c
    }

    /// Asks ActiveCollab for a new API token. Returns the token ("<userId>-<key>").
    ///
    /// Throws `ACError`:
    /// - `.insecureBaseURL` when the base is not https with a host (no request is sent),
    /// - `.credentialsRejected` for 401 or 403, `is_ok` false, or an empty e-mail address or password,
    /// - `.transport` when the network fails (offline, timeout),
    /// - `.unexpectedRedirect`, `.http` or `.decoding` for anything else.
    public func issueToken(username: String, password: String) async throws -> String {
        let request = try makeRequest(username: username, password: password)
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
        do {
            return try Self.token(status: http.statusCode, body: data)
        } catch {
            // Status and the shape of the answer only, never the body, the e-mail address, the password or a token.
            let status = http.statusCode, bytes = data.count
            let okFalse = Self.isOkFalse(data), credential = Self.isCredentialError(data)
            Self.log.error("token.issue.answer status=\(status, privacy: .public) bytes=\(bytes, privacy: .public) isOkFalse=\(okFalse, privacy: .public) credentialException=\(credential, privacy: .public)")
            throw error
        }
    }

    /// The answer decodes and says `is_ok` false (ActiveCollab's way to reject a sign-in with status 200).
    static func isOkFalse(_ body: Data) -> Bool {
        (try? JSONDecoder().decode(Answer.self, from: body)).map { !$0.isOk } ?? false
    }

    /// Maps an answer of `issue-token` to the token or an `ACError`. Pure, for tests.
    static func token(status: Int, body: Data) throws -> String {
        switch status {
        case 200:
            guard let answer = try? JSONDecoder().decode(Answer.self, from: body) else {
                throw ACError.decoding(path: path, detail: "root")
            }
            guard answer.isOk else { throw ACError.credentialsRejected }
            guard let token = answer.token.flatMap(ACToken.sanitize) else {
                throw ACError.decoding(path: path, detail: "token")
            }
            return token
        case 300...399:
            throw ACError.unexpectedRedirect(path: path)
        case 401, 403:
            throw ACError.credentialsRejected
        case 500 where isCredentialError(body):
            throw ACError.credentialsRejected
        default:
            throw ACError.http(status: status, path: path)
        }
    }

    /// ActiveCollab may answer unknown users and wrong passwords with a 500 that names the exception, as it does for
    /// an invalid token [A, same pattern as `ACClient.isTokenRejected`]. Reads the head of the body only.
    static func isCredentialError(_ body: Data) -> Bool {
        let head = String(decoding: body.prefix(512), as: UTF8.self)
        return head.contains("InvalidPasswordException") || head.contains("UserNotFoundException")
    }

    /// The only request builder: POST with a JSON body, never for a base that is not https.
    func makeRequest(username: String, password: String) throws -> URLRequest {
        guard Config.isValidBaseURL(base) else { throw ACError.insecureBaseURL }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else {
            Self.log.error("token.issue.emptyField email=\(user.isEmpty, privacy: .public) password=\(password.isEmpty, privacy: .public)")
            throw ACError.credentialsRejected
        }
        guard let url = URL(string: base.absoluteString + "/api/v1" + Self.path) else { throw ACError.invalidPath(Self.path) }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Body(username: user, password: password, clientName: Self.clientName, clientVendor: Self.clientName)
        r.httpBody = try JSONEncoder().encode(body)
        return r
    }

    private struct Body: Encodable {
        var username: String
        var password: String
        var clientName: String
        var clientVendor: String
        enum CodingKeys: String, CodingKey {
            case username, password, clientName = "client_name", clientVendor = "client_vendor"
        }
    }

    /// `{"is_ok": 1, "token": "…"}`. `is_ok` comes as a number or a boolean.
    struct Answer: Decodable {
        var isOk: Bool
        var token: String?

        enum CodingKeys: String, CodingKey { case isOk = "is_ok", token }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let flag = try? c.decode(Bool.self, forKey: .isOk) {
                isOk = flag
            } else if let number = try? c.decode(Int.self, forKey: .isOk) {
                isOk = number != 0
            } else {
                isOk = false
            }
            token = try? c.decodeIfPresent(String.self, forKey: .token)
        }
    }
}
