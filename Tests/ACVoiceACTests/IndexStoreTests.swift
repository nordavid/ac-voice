import ACVoiceCore
import Foundation
import Synchronization
import Testing
@testable import ACVoiceAC

/// A generated instance for paging and timing: projects 1...n, project 1 has `completed` archive rows
/// (ids 1001..., number = id - 1000, newest completion = highest id first) plus `hidden` completed ids the
/// archive never lists.
final class ArchiveLab: Sendable {
    struct State: Sendable {
        var completed = 65
        var hidden: [Int] = []
        var archiveDelay = 0.0
        var listDelay = 0.0
    }
    final class Box: Sendable {
        let mutex: Mutex<State>
        init(_ s: State) { mutex = Mutex(s) }
        func withLock<R: Sendable>(_ body: (inout State) -> R) -> R { mutex.withLock { body(&$0) } }
    }
    let state: Box
    let projects: Int
    let server: StubServer

    init(projects: Int = 1, _ initial: State = State()) {
        let state = Box(initial)
        self.state = state
        self.projects = projects
        server = StubServer { r in
            let s = state.withLock { $0 }
            let rows = (1...max(1, s.completed)).reversed().map { (id: 1000 + $0, number: $0) }.prefix(s.completed)
            switch r.path {
            case "/projects":
                let items = (1...projects).map { #"{"id": \#($0), "name": "LAB: Project \#($0) [AGIL]", "company_id": 50}"# }
                return .json("[" + items.joined(separator: ",") + "]")
            case "/users/\(Fixtures.userId)/tasks":
                return .json(#"{"tasks": []}"#)
            case "/projects/1/tasks":
                let ids = rows.map(\.id) + s.hidden
                var resp = StubResponse.json(Fixtures.projectTasks(open: [(2001, 500)], completed: ids, trashed: [], pid: 1),
                                             etag: Fixtures.etag("lab-\(s.completed)"))
                if r.ifNoneMatch == Fixtures.etag("lab-\(s.completed)") { resp = .notModified }
                resp.delay = s.listDelay
                return resp
            default:
                if r.path.hasPrefix("/projects/1/tasks/archive?page="), let page = Int(r.path.split(separator: "=").last ?? "") {
                    var resp = Fixtures.archivePage(Array(rows), pid: 1, page: page)
                    resp.delay = s.archiveDelay
                    return resp
                }
                if r.path.hasSuffix("/tasks"), r.path.hasPrefix("/projects/") {
                    var resp = StubResponse.json(Fixtures.projectTasks(open: [], completed: [], trashed: [], pid: 0))
                    resp.delay = s.listDelay
                    return resp
                }
                return .json("[]")
            }
        }
    }

    func archivePages() -> [Int] {
        server.paths().filter { $0.hasPrefix("/projects/1/tasks/archive") }.compactMap { Int($0.split(separator: "=").last ?? "") }
    }

    func store() -> IndexStore { IndexStore(client: server.client(), cacheURL: Fixtures.tempCache()) }
}

@Suite("IndexStore")
struct IndexStoreTests {
    let now = Date(timeIntervalSince1970: 1_764_000_000)

    @Test("fast refresh: projects, favorites, own tasks, time records, companies; then all 304")
    func refreshFast() async throws {
        let server = Fixtures.server()
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        let r1 = await store.refreshFast(now: now)
        #expect(r1.fresh == 5 && r1.failed == 0 && r1.notModified == 0)
        #expect(r1.persisted)
        let s = await store.snapshot
        #expect(s.projectIds == [101, 102, 103, 104, 105])
        #expect(s.projects[0] == ProjectRecord(id: 101, name: "ABC: Website Relaunch [AGIL]", companyId: 11,
                                               lastActivity: Date(timeIntervalSince1970: 1_763_900_000)))
        #expect(s.projects[2].lastActivity == nil)
        #expect(s.favorites == [101, 999])
        #expect(s.mine == [TaskRef(id: 5001, projectId: 101, number: 12), TaskRef(id: 5101, projectId: 103, number: 3)])
        #expect(s.timeRecords30d == [101: 3, 103: 1])
        #expect(s.companies.count == 4 && s.companies[1]?.isOwner == true && s.companies[14] == nil)
        #expect(s.fetchedAt == now)
        #expect(s.etags.count == 5)
        #expect(s.tasks.mine.count == 2 && s.tasks.projectOfTask[5001] == 101)

        let r2 = await store.refreshFast(now: now)
        #expect(r2.notModified == 4 && r2.fresh == 0 && r2.failed == 0)
        #expect(await store.snapshot == s)
        let conditional = server.requests.suffix(4)
        #expect(conditional.allSatisfy { $0.ifNoneMatch != nil })
    }

    @Test("task lists: open numbers, completed and trashed ids, ETag on the second pass")
    func taskLists() async throws {
        let server = Fixtures.server()
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast(now: now)
        let r = await store.refreshTaskLists(now: now)
        #expect(r.fresh == 5 && r.notModified == 1 && r.failed == 0)   // 5 lists + /companies (304)
        let s = await store.snapshot
        let t = s.tasks
        #expect(t.byProject[101]?[12] == TaskRef(id: 5001, projectId: 101, number: 12))
        #expect(t.byProject[105]?[12]?.id == 5501)
        #expect(t.projectOfTask[4002] == 101)          // completed id, number not known yet
        #expect(t.byProject[101]?[8] == nil)
        #expect(t.trashed == [4900] && t.projectOfTask[4900] == 101)
        #expect(t.archiveComplete == [102, 104])       // nothing completed there
        #expect(s.taskListsFetchedAt == now)
        #expect(s.stats.openTasks == 5 && s.stats.completedIds == 5 && s.stats.taskIds == 11)

        let r2 = await store.refreshTaskLists(now: now)
        #expect(r2.notModified == 6 && r2.fresh == 0)
        #expect(await store.snapshot.tasks == t)
    }

    @Test("task lists run with bounded parallelism")
    func taskListConcurrency() async throws {
        let lab = ArchiveLab(projects: 12, .init(listDelay: 0.05))
        let store = lab.store()
        await store.refreshFast(now: now)
        lab.server.resetMaxInFlight()
        let r = await store.refreshTaskLists(concurrency: 3, now: now)
        #expect(r.fresh == 13 && r.failed == 0)   // 12 lists + /companies
        #expect(lab.server.maxInFlight <= 3)
        #expect(lab.server.maxInFlight >= 2)
    }

    @Test("cold archive: all pages in parallel, project marked complete")
    func coldArchive() async throws {
        let lab = ArchiveLab()
        let store = lab.store()
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        let r = await store.extendArchives()
        #expect(Set(lab.archivePages()) == [1, 2, 3])   // 65 ids = 30 + 30 + 5
        #expect(r.pages == 3 && r.failed == 0)
        let t = await store.snapshot.tasks
        #expect(t.archiveComplete.contains(1))
        #expect(t.byProject[1]?[65] == TaskRef(id: 1065, projectId: 1, number: 65, isCompleted: true))
        #expect(t.byProject[1]?[1]?.id == 1001)
        #expect(t.byProject[1]?[500]?.isCompleted == false)
        // Nothing missing: a second pass fetches nothing.
        _ = await store.extendArchives()
        #expect(lab.archivePages().count == 3)
    }

    @Test("incremental archive: pages until the new completed ids are covered, then stop")
    func incrementalArchive() async throws {
        let lab = ArchiveLab()
        let store = lab.store()
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        await store.extendArchives()
        // 25 new completions: they sit on page 1 (newest first).
        lab.state.withLock { $0.completed = 90 }
        let lists = await store.refreshTaskLists(now: now)
        #expect(lists.fresh == 2)   // project 1 and /companies (the lab sends no ETag)
        #expect(await store.snapshot.projectTasks[1]?.missingArchiveIds.count == 25)
        let before = lab.archivePages().count
        await store.extendArchives()
        #expect(Array(lab.archivePages().dropFirst(before)) == [1])
        #expect(await store.snapshot.tasks.archiveComplete.contains(1))
        #expect(await store.snapshot.tasks.byProject[1]?[90]?.id == 1090)

        // 40 more: two pages, and nothing beyond.
        lab.state.withLock { $0.completed = 130 }
        await store.refreshTaskLists(now: now)
        let mark = lab.archivePages().count
        await store.extendArchives()
        #expect(Array(lab.archivePages().dropFirst(mark)).sorted() == [1, 2])
        #expect(await store.snapshot.tasks.archiveComplete.contains(1))
    }

    @Test("ids the archive never lists are marked unreachable after the last page")
    func unreachableIds() async throws {
        let lab = ArchiveLab(projects: 1, .init(completed: 31, hidden: [9999]))
        let store = lab.store()
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        await store.extendArchives()
        let st = await store.snapshot.projectTasks[1]
        #expect(st?.unreachable == [9999])
        #expect(st?.archived.count == 31)
        #expect(await store.snapshot.tasks.archiveComplete.contains(1))
        // The hidden id still maps to its project for a bare global id.
        #expect(await store.snapshot.tasks.projectOfTask[9999] == 1)
    }

    @Test("ensureArchive keeps its budget, then completes when the server is fast")
    func ensureArchiveBudget() async throws {
        let lab = ArchiveLab(projects: 1, .init(completed: 65, archiveDelay: 1.5))
        let store = lab.store()
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        let clock = ContinuousClock()
        let start = clock.now
        let ok = await store.ensureArchive([1], budget: .milliseconds(200))
        let elapsed = clock.now - start
        #expect(!ok)
        #expect(elapsed < .milliseconds(1200))
        lab.state.withLock { $0.archiveDelay = 0 }
        #expect(await store.ensureArchive([1]))
        #expect(await store.snapshot.tasks.byProject[1]?[42]?.id == 1042)
        // Complete projects cost nothing.
        let count = lab.server.requests.count
        #expect(await store.ensureArchive([1, 1]))
        #expect(lab.server.requests.count == count)
    }

    @Test("ensureArchive fetches a missing task list first")
    func ensureArchiveCold() async throws {
        let lab = ArchiveLab()
        let store = lab.store()
        await store.refreshFast(now: now)
        #expect(await store.ensureArchive([1]))
        #expect(lab.server.paths().contains("/projects/1/tasks"))
        let t = await store.snapshot.tasks
        #expect(t.byProject[1]?[7]?.id == 1007)
        #expect(t.projectOfTask[1007] == 1)
    }

    @Test("probe: 301 then details; trashed and unknown ids")
    func probe() async throws {
        let server = Fixtures.server()
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast(now: now)
        let ref = try await store.probe(taskId: 47285)
        #expect(ref == TaskRef(id: 47285, projectId: 103, number: 77))
        #expect(server.paths().contains("/projects/101/tasks/47285"))   // via the first active favorite
        let trashed = try await store.probe(taskId: 61000)
        #expect(trashed?.isTrashed == true)
        #expect(try await store.probe(taskId: 12345) == nil)
        let s = await store.snapshot
        #expect(s.tasks.projectOfTask[47285] == 103)
        #expect(s.tasks.trashed.contains(61000))
        #expect(s.probed.count == 2)
    }

    @Test("names refresh adds, renames and drops projects")
    func names() async throws {
        let server = Fixtures.server()
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast(now: now)
        #expect(await store.refreshNames())
        let s = await store.snapshot
        #expect(s.projectIds == [101, 102, 103, 104, 105, 107])
        #expect(s.projects.first { $0.id == 105 }?.name == "Muster Kampagne Neu")
        #expect(s.projects.first { $0.id == 105 }?.companyId == 13)
        #expect(s.etags[ACPaths.projects] == nil)
        #expect(await store.refreshNames() == false)
    }

    @Test("snapshot round-trip through the disk cache (0600), other instance or junk is discarded")
    func snapshotRoundTrip() async throws {
        let server = Fixtures.server()
        let cache = Fixtures.tempCache()
        let store = IndexStore(client: server.client(), cacheURL: cache)
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        await store.extendArchives()
        _ = try await store.probe(taskId: 47285)
        let original = await store.snapshot

        let data = try original.encoded()
        #expect(IndexSnapshot.decode(data) == original)
        let attrs = try FileManager.default.attributesOfItem(atPath: cache.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        let again = IndexStore(client: server.client(), cacheURL: cache)
        #expect(await again.loadFromDisk() == original)
        #expect(await again.snapshot.tasks == original.tasks)
        #expect(again.latest == original)

        let otherUser = IndexStore(client: server.client(userId: 8), cacheURL: cache)
        #expect(await otherUser.loadFromDisk() == nil)
        #expect(await otherUser.snapshot.projects.isEmpty)
        let otherHost = IndexStore(client: Fixtures.server().client(), cacheURL: cache)
        #expect(await otherHost.loadFromDisk() == nil)

        #expect(IndexSnapshot.decode(Data("junk".utf8)) == nil)
        #expect(IndexSnapshot.decode(Data(#"{"version": 99}"#.utf8)) == nil)
        let minimal = IndexSnapshot.decode(Data(#"{"version": 1}"#.utf8))
        #expect(minimal?.projects.isEmpty == true)
        #expect(String(decoding: data, as: UTF8.self).contains(Fixtures.token) == false)
    }

    @Test("updates: the current snapshot first, then every change")
    func updates() async throws {
        let server = Fixtures.server()
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        var a = store.updates.makeAsyncIterator()
        var b = store.updates.makeAsyncIterator()
        #expect(await a.next()?.projects.isEmpty == true)
        #expect(await b.next()?.projects.isEmpty == true)
        await store.refreshFast(now: now)
        #expect(await a.next()?.projects.count == 5)
        #expect(await b.next()?.projects.count == 5)
        #expect(store.latest?.projects.count == 5)
    }

    @Test("a 401 during refresh is reported, the cache stays")
    func unauthorizedRefresh() async throws {
        let server = StubServer { _ in .unauthorized }
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        let r = await store.refreshFast(now: now)
        #expect(r.unauthorized)
        #expect(r.failed == 5)   // projects, favorites, own tasks, time records, companies
        #expect(await store.snapshot.fetchedAt == nil)
    }

    @Test("ticket flow: interpreter -> fetchArchive -> ensureArchive -> open; own tasks; probe")
    func ticketFlow() async throws {
        let server = Fixtures.server()
        let store = IndexStore(client: server.client(), cacheURL: Fixtures.tempCache())
        await store.refreshFast(now: now)
        await store.refreshTaskLists(now: now)
        var snapshot = await store.snapshot
        let interp = snapshot.interpreter()

        guard case .task(let req) = interp.command([Hypothesis("Öffne ABC Ticket 8")], now: now) else {
            Issue.record("expected a ticket"); return
        }
        #expect(req.number == 8 && req.projects?.projectIds == [101, 102])
        #expect(interp.ticket(req, index: snapshot.tasks, now: now) == .fetchArchive(projectIds: [101]))
        #expect(await store.ensureArchive([101]))
        snapshot = await store.snapshot
        #expect(interp.ticket(req, index: snapshot.tasks, now: now) == .open(projectId: 101, taskId: 4002))

        guard case .task(let own) = interp.command([Hypothesis("Ticket 12")], now: now) else { Issue.record("ticket"); return }
        #expect(interp.ticket(own, index: snapshot.tasks, now: now) == .open(projectId: 101, taskId: 5001))
        #expect(interp.ticket(own, index: snapshot.tasks, activeProjectId: 105, now: now) == .open(projectId: 105, taskId: 5501))

        guard case .task(let global) = interp.command([Hypothesis("Öffne Ticket 47285")], now: now) else { Issue.record("ticket"); return }
        #expect(interp.ticket(global, index: snapshot.tasks, now: now) == .probe(taskId: 47285))
        let ref = try #require(try await store.probe(taskId: 47285))
        snapshot = await store.snapshot
        #expect(interp.ticket(global, index: snapshot.tasks, now: now) == .open(projectId: 103, taskId: 47285))
        #expect(Routes.task(server.base, projectId: ref.projectId, taskId: ref.id).path == "/projects/103/tasks/47285")
    }
}
