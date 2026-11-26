import Foundation
import Testing
@testable import ACVoiceAC

/// The sign-in against the in-process stub server. No request leaves the process; the credentials are test values.
@Suite("Token issuer")
struct TokenIssuerTests {
    static let user = "someone@example.com"
    static let password = "Not-A-Real-Password-123"
    static let issued = "538-IssuedTokenAbcdefghij"

    func issuer(_ server: StubServer, base: URL? = nil) -> ACTokenIssuer {
        ACTokenIssuer(base: base ?? server.base, configuration: server.configuration())
    }

    /// An AC that answers every request with `response`.
    func stub(_ response: StubResponse) -> StubServer { StubServer { _ in response } }

    @Test("POST /api/v1/issue-token with the JSON body and Accept header returns the token")
    func issuesAToken() async throws {
        let server = StubServer { r in
            r.method == "POST" && r.path == ACTokenIssuer.path ? .json(#"{"is_ok":1,"token":"\#(Self.issued)"}"#) : .notFound
        }
        let token = try await issuer(server).issueToken(username: " \(Self.user)\n", password: Self.password)
        #expect(token == Self.issued)
        #expect(server.requests.count == 1)
        let r = try #require(server.requests.first)
        #expect(r.method == "POST" && r.path == "/issue-token")
        #expect(r.headers["Accept"] == "application/json" && r.headers["Content-Type"] == "application/json")
        #expect(r.token == nil)   // no API token header on the sign-in
        let body = try #require(r.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["username": Self.user, "password": Self.password, "client_name": "AC Voice", "client_vendor": "AC Voice"])

        // `is_ok` as a boolean works too.
        let bool = stub(.json(#"{"is_ok":true,"token":"\#(Self.issued)"}"#))
        #expect(try await issuer(bool).issueToken(username: Self.user, password: Self.password) == Self.issued)
    }

    @Test("401, 403 and is_ok false mean wrong e-mail or password", arguments: [
        StubResponse.unauthorized,
        StubResponse(status: 403),
        StubResponse.json(#"{"is_ok":0,"message":"Invalid password"}"#),
        StubResponse.json(#"{"is_ok":false}"#),
        StubResponse(status: 500, body: Data(#"{"type":"ActiveCollab\\Authentication\\Exception\\InvalidPasswordException"}"#.utf8)),
    ])
    func rejected(_ response: StubResponse) async {
        let server = stub(response)
        await #expect(throws: ACError.credentialsRejected) {
            try await issuer(server).issueToken(username: Self.user, password: Self.password)
        }
        #expect(server.requests.count == 1)
        #expect(ACError.credentialsRejected.userMessage == "AC lehnt E-Mail oder Passwort ab")
    }

    @Test("an empty e-mail address or password sends nothing")
    func emptyCredentials() async {
        let server = stub(.json(#"{"is_ok":1,"token":"\#(Self.issued)"}"#))
        await #expect(throws: ACError.credentialsRejected) { try await issuer(server).issueToken(username: " ", password: Self.password) }
        await #expect(throws: ACError.credentialsRejected) { try await issuer(server).issueToken(username: Self.user, password: "") }
        #expect(server.requests.isEmpty)
    }

    @Test("a redirect is refused and never followed: the password stays with the first host")
    func redirectRefused() async {
        let elsewhere = stub(.json(#"{"is_ok":1,"token":"\#(Self.issued)"}"#))
        let server = stub(StubResponse(status: 307, redirect: elsewhere.base.absoluteString + "/api/v1/issue-token"))
        await #expect(throws: ACError.unexpectedRedirect(path: ACTokenIssuer.path)) {
            try await issuer(server).issueToken(username: Self.user, password: Self.password)
        }
        #expect(server.requests.count == 1)
        #expect(elsewhere.requests.isEmpty)
    }

    @Test("http or a missing host is refused before any request", arguments: ["http://", "ftp://", "https://"])
    func needsHTTPS(_ scheme: String) async {
        let server = stub(.json(#"{"is_ok":1,"token":"\#(Self.issued)"}"#))
        let base = URL(string: scheme == "https://" ? "https:///nohost" : scheme + server.host)!
        await #expect(throws: ACError.insecureBaseURL) {
            try await issuer(server, base: base).issueToken(username: Self.user, password: Self.password)
        }
        #expect(server.requests.isEmpty)
    }

    @Test("network errors map to the transport error, other statuses to a generic one")
    func otherFailures() async {
        // A host the stub does not know fails like an offline network.
        let any = stub(.notFound)
        let offline = ACTokenIssuer(base: URL(string: "https://offline-\(UUID().uuidString.lowercased()).test")!,
                                    configuration: any.configuration())
        await #expect(throws: ACError.transport(code: URLError.Code.cannotFindHost.rawValue)) {
            try await offline.issueToken(username: Self.user, password: Self.password)
        }
        let broken = stub(StubResponse(status: 502))
        await #expect(throws: ACError.http(status: 502, path: ACTokenIssuer.path)) {
            try await issuer(broken).issueToken(username: Self.user, password: Self.password)
        }
        let garbage = stub(.json(#"{"is_ok":1}"#))
        await #expect(throws: ACError.decoding(path: ACTokenIssuer.path, detail: "token")) {
            try await issuer(garbage).issueToken(username: Self.user, password: Self.password)
        }
    }

    @Test("no error shows the password, the token or the response body")
    func errorsHoldNoSecret() async {
        let echo = Data(#"{"is_ok":0,"message":"\#(Self.password) \#(Self.issued)"}"#.utf8)
        let responses = [
            StubResponse(status: 200, body: echo),
            StubResponse(status: 401, body: echo),
            StubResponse(status: 500, body: echo),
            StubResponse(status: 200, body: Data(#"{"is_ok":1,"token":"bad token \#(Self.password)"}"#.utf8)),
            StubResponse(status: 200, body: Data("<html>\(Self.password)</html>".utf8)),
        ]
        for response in responses {
            let server = stub(response)
            do {
                _ = try await issuer(server).issueToken(username: Self.user, password: Self.password)
                Issue.record("expected an error")
            } catch {
                let texts = [String(describing: error), "\(error)", (error as? ACError)?.userMessage ?? "",
                             (error as NSError).localizedDescription]
                for t in texts {
                    #expect(!t.contains(Self.password) && !t.contains(Self.issued) && !t.contains("IssuedToken"), "\(t)")
                    #expect(!t.contains(Self.user), "\(t)")
                }
            }
        }
    }

    @Test("ephemeral session without cookies or credential storage, 15 s timeout")
    func sessionSettings() throws {
        let c = ACTokenIssuer.defaultConfiguration()
        #expect(c.urlCache == nil && c.urlCredentialStorage == nil && !c.httpShouldSetCookies)
        #expect(c.timeoutIntervalForRequest == 15)
        let request = try ACTokenIssuer(base: URL(string: "https://ac.example.test/")!)
            .makeRequest(username: Self.user, password: Self.password)
        #expect(request.url?.absoluteString == "https://ac.example.test/api/v1/issue-token")
        #expect(request.httpMethod == "POST" && request.timeoutInterval == 15)
    }
}
