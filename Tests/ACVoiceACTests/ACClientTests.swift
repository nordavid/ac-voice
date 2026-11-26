import Foundation
import Testing
@testable import ACVoiceAC

@Suite("ACClient")
struct ACClientTests {
    @Test("every request is a GET with the token and no body")
    func everyRequestIsGET() async throws {
        let server = Fixtures.server()
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast()
        await store.refreshTaskLists()
        await store.extendArchives()
        _ = await store.ensureArchive([101, 103])
        _ = try await store.probe(taskId: 47285)
        _ = try await store.probe(taskId: 99999)
        _ = await store.refreshNames()
        let requests = server.requests
        // 5 fast + 5 task lists + companies + 3 archive pages + 2 + 1 probe + 1 names; ensureArchive finds nothing missing.
        #expect(requests.count == 18)
        for r in requests {
            #expect(r.method == "GET", "\(r.path)")
            #expect(!r.hasBody, "\(r.path)")
            #expect(r.token == Fixtures.token, "\(r.path)")
            #expect(r.headers["Accept"] == "application/json")
        }
        // The probe never follows the redirect to the canonical path with the same request.
        #expect(requests.filter { $0.path == "/projects/101/tasks/47285" }.count == 1)
    }

    @Test("ETag is sent as If-None-Match and 304 gives .notModified")
    func etagAnd304() async throws {
        let server = Fixtures.server()
        let client = server.client()
        let first = try await client.projects()
        guard case .fresh(let list, let tag) = first else { Issue.record("expected fresh"); return }
        #expect(list.map(\.id) == [101, 102, 103, 104, 105, 106])   // the broken element is skipped
        #expect(tag == Fixtures.etag("projects"))
        let second = try await client.projects(etag: tag)
        guard case .notModified = second else { Issue.record("expected 304"); return }
        #expect(server.requests.last?.ifNoneMatch == Fixtures.etag("projects"))
        #expect(server.requests.first?.ifNoneMatch == nil)
        #expect(client.stats.notModified == 1)
        // A stale validator gets a fresh body.
        let third = try await client.projects(etag: "W/\"old\"")
        #expect(third.value?.count == 6)
    }

    @Test("301 probe parses the Location; 200 is the probe project; 404 is nil")
    func probe() async throws {
        let server = Fixtures.server()
        let client = server.client()
        #expect(try await client.probeProject(ofTask: 47285, via: 101) == 103)
        #expect(try await client.probeProject(ofTask: 47285, via: 103) == 103)
        #expect(try await client.probeProject(ofTask: 12345, via: 101) == nil)
        let details = try await client.task(projectId: 103, taskId: 47285)
        #expect(details == ACTask(id: 47285, projectId: 103, taskNumber: 77))
        #expect(try await client.task(projectId: 103, taskId: 4242) == nil)
    }

    @Test("Location parsing checks the task id")
    func locationParsing() {
        #expect(ACClient.projectId(fromTaskLocation: "https://h.test/api/v1/projects/2032/tasks/47285", taskId: 47285) == 2032)
        #expect(ACClient.projectId(fromTaskLocation: "/api/v1/projects/12/tasks/5?x=1", taskId: 5) == 12)
        #expect(ACClient.projectId(fromTaskLocation: "https://h.test/api/v1/projects/2032/tasks/47285", taskId: 4728) == nil)
        #expect(ACClient.projectId(fromTaskLocation: "https://h.test/api/v1/projects/2032/tasks/472850", taskId: 47285) == nil)
        #expect(ACClient.projectId(fromTaskLocation: "https://h.test/api/v1/projects/x/tasks/1", taskId: 1) == nil)
    }

    @Test("a redirect is refused by the session, never followed")
    func redirectRefused() async throws {
        let target = "https://elsewhere.test/api/v1/projects/77/tasks/42"
        let server = StubServer { r in
            r.path == "/projects/1/tasks/42" ? StubResponse(status: 301, redirect: target) : .notFound
        }
        let client = server.client()
        #expect(try await client.probeProject(ofTask: 42, via: 1) == 77)
        #expect(server.paths() == ["/projects/1/tasks/42"])
        // Any other endpoint answering with a redirect is an error, not a silent follow.
        let other = StubServer { _ in StubResponse(status: 302, redirect: "https://elsewhere.test/api/v1/projects") }
        await #expect(throws: ACError.unexpectedRedirect(path: "/projects")) { try await other.client().projects() }
        #expect(other.requests.count == 1)
    }

    @Test("401: one renewal and retry, then a typed error; asked again only after the cooldown")
    func unauthorizedRetryOnce() async throws {
        let server = StubServer { _ in .unauthorized }
        let provider = CountingTokenProvider(initial: "7-OldTokenAbcdefghij", fresh: "7-NewTokenAbcdefghij")
        let client = server.client(tokens: provider, renewalCooldown: .milliseconds(600))
        await #expect(throws: ACError.unauthorized) { try await client.favorites() }
        #expect(provider.asked == 1)
        #expect(server.requests.map(\.token) == ["7-OldTokenAbcdefghij", "7-NewTokenAbcdefghij"])
        // The renewed token is rejected too: the provider is asked once for it (and has nothing new), no retry.
        await #expect(throws: ACError.unauthorized) { try await client.favorites() }
        #expect(provider.asked == 2)
        #expect(server.requests.count == 3)
        // Within the cooldown further rejections throw at once, without asking the provider.
        await #expect(throws: ACError.unauthorized) { try await client.favorites() }
        #expect(provider.asked == 2)
        #expect(server.requests.count == 4)
        // After the cooldown the provider is asked again (it may hold a new token by now).
        try await Task.sleep(for: .milliseconds(700))
        await #expect(throws: ACError.unauthorized) { try await client.favorites() }
        #expect(provider.asked == 3)
        #expect(server.requests.count == 5)
    }

    @Test("a token that becomes valid later is picked up: after the cooldown, or at once after resetToken")
    func tokenRecoversLater() async throws {
        let good = "7-GoodTokenAbcdefghij"
        let server = StubServer { r in r.token == good ? .json("[]") : .unauthorized }

        // Review P1: the provider had nothing new at first, then the user signed in again.
        let provider = SwitchableTokenProvider(initial: "7-ExpiredTokenAbcdefgh")
        let client = server.client(tokens: provider, renewalCooldown: .zero)
        await #expect(throws: ACError.unauthorized) { try await client.favorites() }
        #expect(provider.asked == 1)
        provider.publish(good)
        #expect(try await client.favorites().value?.isEmpty == true)
        #expect(provider.asked == 2)
        #expect(try await client.favorites().value?.isEmpty == true)
        #expect(server.requests.last?.token == good)
        #expect(provider.asked == 2)

        // With the default cooldown the client waits, unless the app resets it after a sign-in or paste.
        let pasted = SwitchableTokenProvider(initial: "7-ExpiredTokenAbcdefgh")
        let app = server.client(tokens: pasted)
        await #expect(throws: ACError.unauthorized) { try await app.favorites() }
        pasted.publish(good)
        await #expect(throws: ACError.unauthorized) { try await app.favorites() }
        #expect(pasted.asked == 1)
        await app.resetToken()
        let before = server.requests.count
        #expect(try await app.favorites().value?.isEmpty == true)
        #expect(server.requests.count == before + 1)   // the reloaded token works without a 401 first
        #expect(pasted.asked == 1 && pasted.loads == 2)
    }

    @Test("concurrent first requests share one token load; a failed load is not cached")
    func tokenLoadSingleFlight() async throws {
        let server = StubServer { _ in var r = StubResponse.json("[]"); r.delay = 0.05; return r }
        let provider = SwitchableTokenProvider(initial: Fixtures.token, loadDelay: .milliseconds(30))
        let client = server.client(tokens: provider)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await client.favorites() } }
            try await group.waitForAll()
        }
        #expect(provider.loads == 1)   // review P9: was 4 of 8
        #expect(server.requests.count == 8)

        let flaky = SwitchableTokenProvider(initial: Fixtures.token, failLoads: 1)
        let second = server.client(tokens: flaky)
        await #expect(throws: ACError.noToken) { try await second.favorites() }
        #expect(try await second.favorites().value?.isEmpty == true)
        #expect(flaky.loads == 2)
    }

    @Test("AC's 500 InvalidTokenException counts as a rejected token [V]")
    func invalidTokenAs500() async throws {
        let body = #"{"type":"ActiveCollab\\Authentication\\Exception\\InvalidTokenException","message":"Authorization token is not valid","code":0}"#
        let good = "7-NewTokenAbcdefghij"
        let server = StubServer { r in r.token == good ? .json("[]") : StubResponse(status: 500, body: Data(body.utf8)) }
        let provider = CountingTokenProvider(initial: "7-OldTokenAbcdefghij", fresh: good)
        let client = server.client(tokens: provider)
        #expect(try await client.favorites().value?.isEmpty == true)
        #expect(provider.asked == 1)
        #expect(server.requests.count == 2)
        let stuck = StubServer { _ in StubResponse(status: 500, body: Data(body.utf8)) }
        await #expect(throws: ACError.unauthorized) { try await stuck.client().favorites() }
        #expect(ACClient.isTokenRejected(status: 500, body: Data(#"{"message":"Failed to match '/x' path."}"#.utf8)) == false)
    }

    @Test("401 without a different token: no retry")
    func unauthorizedNoFreshToken() async throws {
        let server = StubServer { _ in .unauthorized }
        let provider = CountingTokenProvider(initial: "7-OldTokenAbcdefghij", fresh: nil)
        await #expect(throws: ACError.unauthorized) { try await server.client(tokens: provider).favorites() }
        #expect(provider.asked == 1)
        #expect(server.requests.count == 1)
    }

    @Test("401 recovers with the renewed token; concurrent 401s share one renewal")
    func unauthorizedRecovers() async throws {
        let good = "7-NewTokenAbcdefghij"
        let server = StubServer { r in r.token == good ? .json(Fixtures.favorites) : .unauthorized }
        let provider = CountingTokenProvider(initial: "7-OldTokenAbcdefghij", fresh: good)
        let client = server.client(tokens: provider)
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await client.favorites().value?.count ?? -1 } }
            var out: [Int] = []
            for try await n in group { out.append(n) }
            return out
        }
        #expect(results == [4, 4, 4, 4, 4])
        #expect(provider.asked == 1)
        #expect(client.stats.renewals == 1)
        // Later calls use the renewed token directly.
        _ = try await client.favorites()
        #expect(server.requests.last?.token == good)
    }

    @Test("typed errors never carry the token or an ETag")
    func typedErrors() async throws {
        let server = StubServer { r in
            switch r.path {
            case "/favorites": return StubResponse(status: 500, body: Data(#"{"type":"RuntimeException","message":"Failed to match '/favorites' path."}"#.utf8))
            case "/companies": return StubResponse(status: 503)
            case "/projects": return .json(#"{"not": "a list"}"#, etag: Fixtures.etag("x"))
            default: return .notFound
            }
        }
        let client = server.client()
        await #expect(throws: ACError.endpointMissing(path: "/favorites")) { try await client.favorites() }
        await #expect(throws: ACError.http(status: 503, path: "/companies")) { try await client.companies() }
        await #expect(throws: ACError.notFound(path: "/users/7/tasks")) { try await client.myTasks() }
        do {
            _ = try await client.projects(etag: Fixtures.etag("x"))
            Issue.record("expected a decoding error")
        } catch let e as ACError {
            guard case .decoding(let path, _) = e else { Issue.record("\(e)"); return }
            #expect(path == "/projects")
            let text = "\(e) \(e.userMessage)"
            #expect(!text.contains(Fixtures.token) && !text.contains("example.com"))
        }
        #expect(ACError.unauthorized.userMessage == "AC lehnt den Token ab")
    }

    @Test("a cancelled request throws CancellationError")
    func cancellation() async throws {
        let server = StubServer { _ in var r = StubResponse.json("[]"); r.delay = 2; return r }
        let client = server.client()
        let task = Task { try await client.favorites() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("a base URL that is not https never gets the token: no token load, no request")
    func insecureBaseNeverSendsTheToken() async throws {
        let server = Fixtures.server()
        let tokens = SwitchableTokenProvider(initial: Fixtures.token)
        for raw in ["http://\(server.host)", "file:///tmp/x"] {
            let client = ACClient(base: URL(string: raw)!, userId: Fixtures.userId, tokens: tokens,
                                  configuration: server.configuration())
            await #expect(throws: ACError.insecureBaseURL) { _ = try await client.projects() }
            #expect(throws: ACError.insecureBaseURL) { try client.makeRequest("/projects", etag: nil, token: "t") }
        }
        #expect(server.requests.isEmpty && tokens.loads == 0)
        #expect(ACError.insecureBaseURL.userMessage == "Die AC-Adresse braucht https")
        // The https base of the same host works.
        _ = try await server.client().projects()
        #expect(server.requests.count >= 1)
    }

    @Test("paths are validated and built below /api/v1")
    func paths() throws {
        let client = ACClient(base: URL(string: "https://ac.example.test/")!, token: Fixtures.token, userId: 7)
        #expect(client.apiBase.absoluteString == "https://ac.example.test/api/v1")
        let r = try client.makeRequest("/projects/1/tasks/archive?page=2", etag: "e", token: Fixtures.token)
        #expect(r.httpMethod == "GET")
        #expect(r.url?.absoluteString == "https://ac.example.test/api/v1/projects/1/tasks/archive?page=2")
        #expect(r.value(forHTTPHeaderField: "If-None-Match") == "e")
        #expect(throws: ACError.self) { try client.makeRequest("https://evil.test/x", etag: nil, token: "t") }
        #expect(throws: ACError.self) { try client.makeRequest("/../x", etag: nil, token: "t") }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let to = Date(timeIntervalSince1970: 1_763_900_000)   // 2025-11-23 13:13 CET
        #expect(ACPaths.timeRecords(7, from: to.addingTimeInterval(-30 * 86_400), to: to, calendar: cal)
                == "/users/7/time-records/filtered-by-date?from=2025-10-24&to=2025-11-23")
    }

    @Test("/projects follows pagination when the total exceeds one page")
    func projectsPaging() async throws {
        let server = StubServer { r in
            let item = { (id: Int) in #"{"id": \#(id), "name": "P\#(id): Synthetic"}"# }
            switch r.path {
            case "/projects": return .json("[\(item(1)),\(item(2))]", etag: "\"e\"", headers: ["X-Angie-PaginationTotalItems": "3"])
            case "/projects?page=2": return .json("[\(item(3))]")
            default: return .notFound
            }
        }
        let list = try await server.client().projects().value
        #expect(list?.map(\.id) == [1, 2, 3])
    }

    @Test("tolerant decoding: favorites, archive pages and time records")
    func tolerantDecoding() async throws {
        let server = Fixtures.server()
        let client = server.client()
        let favs = try await client.favorites().value ?? []
        #expect(favs.map(\.parentId) == [101, 999, 5001, 101])
        let mine = try await client.myTasks().value?.tasks ?? []
        #expect(mine.map(\.id) == [5001, 5101, 5102])   // 5103 has no number and is skipped
        let records = try await client.timeRecords(from: .now.addingTimeInterval(-86_400 * 30), to: .now).value ?? []
        #expect(records.count == 5)
        let page = try await client.archivePage(101, page: 1)
        #expect(page.tasks.map(\.taskNumber) == [9, 8, 7])
        #expect(page.totalItems == 3 && page.perPage == 30)
        let object = try JSONDecoder().decode(ACFavorite.self, from: Data(#"{"parent_type": "Project", "parent_id": 5}"#.utf8))
        #expect(object == ACFavorite(parentType: "Project", parentId: 5))
        let plain = try JSONDecoder().decode(ACTimeRecords.self, from: Data(#"[{"project_id": 3}, {"x": 1}]"#.utf8))
        #expect(plain.records == [ACTimeRecord(projectId: 3)])
    }
}
