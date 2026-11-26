import ACVoiceCore
import Foundation
import Synchronization
import Testing
@testable import ACVoiceAC

/// The ticket path under failure and staleness: budgets, surfaced errors, stale task lists, archive races and the
/// company refetch (review of the AC module, findings 1-7 with probes P2, P3, P4, P7, P10).
@Suite("Ticket path")
struct TicketPathTests {
    let now = Date(timeIntervalSince1970: 1_764_000_000)

    /// The synthetic instance, with a hook that may replace any response.
    func makeServer(_ override: @escaping @Sendable (RecordedRequest, StubResponse) -> StubResponse) -> StubServer {
        let box = HostBox()
        let router = Fixtures.router(host: { box.value })
        let server = StubServer { r in override(r, router(r)) }
        box.set(server.host)
        return server
    }

    func ticket(_ text: String, _ snapshot: IndexSnapshot) throws -> (Interpreter, TaskRequest) {
        let interp = snapshot.interpreter()
        guard case .task(let req) = interp.command([Hypothesis(text)], now: now) else {
            throw ACError.invalidPath("not a ticket: \(text)")
        }
        return (interp, req)
    }

    @Test("stale task lists: revalidation turns a wrong auto-open into the ranked list (P10)")
    func staleListRevalidation() async throws {
        let created = Mutex(false)
        let server = makeServer { r, routed in
            guard r.path == "/projects/102/tasks", created.withLock({ $0 }) else { return routed }
            // A colleague created ABC#8 in project 102 after the last task-list pass (101 has a completed #8).
            let tag = Fixtures.etag("tasks-102-new")
            return r.ifNoneMatch == tag ? .notModified
                : .json(Fixtures.projectTasks(open: [(5201, 1), (5299, 8)], completed: [], trashed: [], pid: 102), etag: tag)
        }
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        created.withLock { $0 = true }
        await store.refreshFast(now: now)
        let (interp, req) = try ticket("Öffne ABC Ticket 8", await store.snapshot)
        #expect(req.projects?.projectIds == [101, 102])

        let later = now.addingTimeInterval(120)
        let mark = server.requests.count
        let check = await store.revalidateTaskLists(for: req, now: later)
        #expect(check == IndexCheck())
        let lists = server.requests.dropFirst(mark)
        #expect(lists.map(\.path).sorted() == ["/projects/101/tasks", "/projects/102/tasks"])
        #expect(lists.allSatisfy { $0.ifNoneMatch != nil })   // conditional: 304 when nothing changed

        var outcome = interp.ticket(req, index: await store.snapshot.tasks, now: later)
        #expect(outcome == .fetchArchive(projectIds: [101]))
        let archives = await store.checkArchives([101], now: later)
        #expect(archives.complete && archives.error == nil)
        outcome = interp.ticket(req, index: await store.snapshot.tasks, now: later)
        #expect(outcome == .choices([TaskRef(id: 5299, projectId: 102, number: 8),
                                     TaskRef(id: 4002, projectId: 101, number: 8, isCompleted: true)]))

        // Current lists cost nothing.
        let count = server.requests.count
        #expect(await store.revalidateTaskLists(for: req, now: later.addingTimeInterval(10)).complete)
        #expect(server.requests.count == count)
        // A global id needs no task list.
        #expect(await store.revalidateTaskLists(for: TaskRequest(number: 47285), now: later.addingTimeInterval(600)).complete)
        #expect(server.requests.count == count)
    }

    @Test("bare ticket numbers revalidate the active tab project and the active favorites")
    func revalidateBareNumber() async throws {
        let server = Fixtures.server()
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        let mark = server.requests.count
        let check = await store.revalidateTaskLists(for: TaskRequest(number: 12), activeProjectId: 105,
                                                    now: now.addingTimeInterval(120))
        #expect(check.complete)
        // Favorites are [101, 999]; 999 is not active.
        #expect(server.requests.dropFirst(mark).map(\.path).sorted() == ["/projects/101/tasks", "/projects/105/tasks"])
    }

    @Test("revalidation keeps its budget and the cached lists")
    func revalidateBudget() async throws {
        let lab = ArchiveLab(projects: 3)
        let store = lab.store()
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        lab.state.withLock { $0.listDelay = 1.5 }
        let clock = ContinuousClock(), t0 = clock.now
        let check = await store.revalidateTaskLists([1, 2, 3], budget: .milliseconds(200), now: now.addingTimeInterval(120))
        #expect(clock.now - t0 < .milliseconds(1000))
        #expect(!check.complete && check.timedOut)
        #expect(check.error == ACError.timedOut)
        #expect(await store.snapshot.projectTasks[1]?.open.count == 1)
    }

    @Test("checkArchives revalidates a stale task list before paging, and skips a current one")
    func checkArchivesRevalidatesList() async throws {
        let lab = ArchiveLab()
        let store = lab.store()
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        // Task #66 completed after the last task-list pass.
        lab.state.withLock { $0.completed = 66 }
        let mark = lab.server.requests.count
        let check = await store.checkArchives([1], now: now.addingTimeInterval(120))
        #expect(check.complete && check.errors.isEmpty)
        let list = lab.server.requests.dropFirst(mark).filter { $0.path == "/projects/1/tasks" }
        #expect(list.count == 1 && list.first?.ifNoneMatch != nil)
        #expect(await store.snapshot.tasks.byProject[1]?[66]?.id == 1066)

        // A complete archive with a stale list: one conditional GET (304), no archive page.
        let complete = lab.server.requests.count
        #expect(await store.checkArchives([1], now: now.addingTimeInterval(200)).complete)
        #expect(lab.server.paths().dropFirst(complete) == ["/projects/1/tasks"])

        // A current list is not fetched again.
        lab.state.withLock { $0.completed = 67 }
        await store.refreshTaskLists(now: now.addingTimeInterval(130))
        let again = lab.server.requests.count
        #expect(await store.checkArchives([1], now: now.addingTimeInterval(140)).complete)
        #expect(!lab.server.requests.dropFirst(again).contains { $0.path == "/projects/1/tasks" })
    }

    @Test("checkArchives reports 401 and timeouts instead of a silent miss (P3)")
    func checkArchivesSurfacesErrors() async throws {
        let broken = Mutex(false)
        let server = makeServer { _, routed in broken.withLock { $0 } ? .unauthorized : routed }
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        broken.withLock { $0 = true }
        let check = await store.checkArchives([101])
        #expect(!check.complete)
        #expect(check.error == .unauthorized)
        #expect(await store.ensureArchive([101]) == false)

        let lab = ArchiveLab(projects: 1, .init(completed: 65, archiveDelay: 1.5))
        let slow = lab.store()
        await slow.refreshFast(now: now)
        await slow.refreshTaskLists(now: now)
        let timed = await slow.checkArchives([1], budget: .milliseconds(200))
        #expect(timed.timedOut && !timed.complete)
        #expect(timed.error == ACError.timedOut)
    }

    @Test("IndexCheck.error: unauthorized, then transport, then any other, then the timeout")
    func indexCheckError() {
        let http = ACError.http(status: 503, path: "/x"), net = ACError.transport(code: -1009)
        #expect(IndexCheck(complete: false, errors: [http, net, .unauthorized]).error == .unauthorized)
        #expect(IndexCheck(complete: false, errors: [http, net]).error == net)
        #expect(IndexCheck(complete: false, errors: [http]).error == http)
        #expect(IndexCheck(complete: false, timedOut: true).error == .timedOut)
        #expect(IndexCheck(complete: true, errors: [http]).error == nil)
        #expect(ACError.timedOut.userMessage == "AC antwortet nicht")
    }

    @Test("a completion during an archive pass is not marked unreachable (P2)")
    func unreachableRace() async throws {
        let lab = ArchiveLab(projects: 1, .init(completed: 65, archiveDelay: 0.3))
        let store = lab.store()
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        let pass = Task { await store.extendArchives() }
        try await Task.sleep(for: .milliseconds(100))   // pages 1-3 requested, answers in flight
        lab.state.withLock { $0.completed = 66 }        // #66 (id 1066) completed meanwhile
        await store.refreshTaskLists(now: now)
        _ = await pass.value
        var st = try #require(await store.snapshot.projectTasks[1])
        #expect(st.unreachable.isEmpty)
        #expect(st.missingArchiveIds == [1066])
        #expect(!(await store.snapshot.tasks.archiveComplete.contains(1)))

        lab.state.withLock { $0.archiveDelay = 0 }
        await store.extendArchives()
        st = try #require(await store.snapshot.projectTasks[1])
        #expect(st.unreachable.isEmpty && st.missingArchiveIds.isEmpty)
        let snapshot = await store.snapshot
        #expect(snapshot.tasks.byProject[1]?[66]?.id == 1066)
        let (interp, req) = try ticket("Öffne LAB Ticket 66", snapshot)
        #expect(interp.ticket(req, index: snapshot.tasks, now: now) == .open(projectId: 1, taskId: 1066))
    }

    @Test("probe keeps its budget (P4); late details give number 0 and no cache entry")
    func probeBudget() async throws {
        let slowPaths = Mutex<Set<String>>([])
        let server = makeServer { r, routed in
            var resp = routed
            if slowPaths.withLock({ $0.contains(r.path) }) { resp.delay = 3 }
            return resp
        }
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast(now: now)
        let clock = ContinuousClock()

        // The 301 probe itself hangs: a timeout error, quickly.
        slowPaths.withLock { $0 = ["/projects/101/tasks/47285"] }
        var t0 = clock.now
        await #expect(throws: ACError.timedOut) { try await store.probe(taskId: 47285, budget: .milliseconds(300)) }
        #expect(clock.now - t0 < .milliseconds(1000))

        // Only the details hang: the project is known, the number is not.
        slowPaths.withLock { $0 = ["/projects/103/tasks/47285"] }
        t0 = clock.now
        let ref = try await store.probe(taskId: 47285, budget: .milliseconds(300))
        #expect(clock.now - t0 < .milliseconds(1000))
        #expect(ref == TaskRef(id: 47285, projectId: 103, number: 0))
        #expect(await store.snapshot.probed.isEmpty)

        slowPaths.withLock { $0 = [] }
        #expect(try await store.probe(taskId: 47285)?.number == 77)
        #expect(await store.snapshot.probed.count == 1)
    }

    @Test("probe on a cold start finds a project itself; a rejected token surfaces as unauthorized")
    func probeColdStart() async throws {
        let server = Fixtures.server()
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        #expect(try await store.probe(taskId: 47285) == TaskRef(id: 47285, projectId: 103, number: 77))
        #expect(server.paths() == ["/projects", "/projects/101/tasks/47285", "/projects/103/tasks/47285"])

        let rejected = IndexStore(client: StubServer { _ in .unauthorized }.client(), cacheURL: Fixtures.tempCache())
        await #expect(throws: ACError.unauthorized) { try await rejected.probe(taskId: 47285) }
    }

    @Test("refreshNames keeps its budget")
    func refreshNamesBudget() async throws {
        let server = makeServer { r, routed in
            var resp = routed
            if r.path == "/projects/names" { resp.delay = 3 }
            return resp
        }
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast(now: now)
        let clock = ContinuousClock(), t0 = clock.now
        #expect(await store.refreshNames(budget: .milliseconds(200)) == false)
        #expect(clock.now - t0 < .milliseconds(1000))
        #expect(await store.snapshot.projectIds == [101, 102, 103, 104, 105])
    }

    @Test("an unknown company is revalidated once (conditional), not on every key press (P7)")
    func companyRefetch() async throws {
        let moved = Mutex(13)
        let server = makeServer { r, routed in
            guard r.path == "/projects" else { return routed }
            let company = moved.withLock { $0 }
            let body = Fixtures.projects.replacingOccurrences(of: #""company_id": 13"#, with: #""company_id": \#(company)"#)
            let tag = Fixtures.etag("projects-\(company)")
            return r.ifNoneMatch == tag ? .notModified : .json(body, etag: tag)
        }
        let companies = { server.requests.filter { $0.path == "/companies" } }
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        // Project 105 belongs to company 14, which is trashed and therefore not in the map.
        moved.withLock { $0 = 14 }
        await store.refreshFast(now: now)
        #expect(companies().count == 1)
        for _ in 0..<3 { await store.refreshFast(now: now) }
        #expect(companies().count == 1)   // review P7: was 3 more, all without If-None-Match

        // A new unknown id: one conditional revalidation.
        moved.withLock { $0 = 15 }
        await store.refreshFast(now: now)
        #expect(companies().count == 2)
        #expect(companies().last?.ifNoneMatch == Fixtures.etag("companies"))
        await store.refreshFast(now: now)
        #expect(companies().count == 2)
    }
}
