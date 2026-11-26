import ACVoiceCore
import Foundation
import Synchronization

/// Outcome of one refresh step. Counts logical fetches; `ACClient.stats` has the raw HTTP numbers.
public struct RefreshReport: Sendable, Equatable {
    public var fresh = 0
    public var notModified = 0
    public var failed = 0
    /// Archive pages fetched.
    public var pages = 0
    public var errors: [ACError] = []
    public var duration: Duration = .zero
    public var persisted = false
    public init() {}

    public var unauthorized: Bool { errors.contains(.unauthorized) }

    mutating func record<T: Sendable>(_ f: Fetch<T>) {
        if case .notModified = f { notModified += 1 } else { fresh += 1 }
    }

    mutating func fail(_ error: any Error) {
        failed += 1
        if let e = error as? ACError, !errors.contains(e) { errors.append(e) }
    }

    mutating func add(_ other: RefreshReport) {
        fresh += other.fresh; notModified += other.notModified; failed += other.failed; pages += other.pages
        for e in other.errors where !errors.contains(e) { errors.append(e) }
    }
}

/// Outcome of a ticket-path step (`checkArchives`, `revalidateTaskLists`): whether the index now covers the
/// requested projects, and if not, why. Lets the caller show "AC-Token ungültig" or "AC nicht erreichbar"
/// instead of "nicht gefunden".
public struct IndexCheck: Sendable, Equatable {
    /// Every requested project is covered: archive complete (`checkArchives`) or task list current
    /// (`revalidateTaskLists`).
    public var complete: Bool
    /// The budget ran out first. What arrived until then is merged.
    public var timedOut: Bool
    /// Distinct errors in order of arrival (paths and status codes only).
    public var errors: [ACError]

    public init(complete: Bool = true, timedOut: Bool = false, errors: [ACError] = []) {
        self.complete = complete; self.timedOut = timedOut; self.errors = errors
    }

    /// The error to show instead of "nicht gefunden": `unauthorized` first, then a transport error, then any other,
    /// then `ACError.timedOut` when only the budget ran out. nil when `complete`.
    public var error: ACError? {
        guard !complete else { return nil }
        if errors.contains(.unauthorized) { return .unauthorized }
        if let t = errors.first(where: { if case .transport = $0 { return true } else { return false } }) { return t }
        return errors.first ?? (timedOut ? .timedOut : nil)
    }

    mutating func add(_ report: RefreshReport) {
        for e in report.errors where !errors.contains(e) { errors.append(e) }
    }
}

/// Either the value of the raced work or the deadline.
enum Raced<T: Sendable>: Sendable {
    case value(T)
    case timeout
}

/// Runs `operation` until `deadline`, then cancels it and throws `ACError.timedOut`. URLSession requests end at
/// once on cancellation, so this returns within a few milliseconds of the deadline.
func withDeadline<T: Sendable>(_ deadline: ContinuousClock.Instant,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: Raced<T>.self) { group in
        group.addTask { .value(try await operation()) }
        group.addTask {
            try await Task.sleep(until: deadline, clock: .continuous)
            return .timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        switch first {
        case .value(let v): return v
        case .timeout: throw ACError.timedOut
        }
    }
}

/// The AC index: disk cache, conditional refreshes, task lists, archives and the 301 probe (PLAN 2.2, 5).
///
/// Resolution never waits on this actor's background work: callers keep the latest `IndexSnapshot` (from `updates`
/// or `latest`). Only the ticket path awaits network work, and every such call has a time budget:
/// `revalidateTaskLists` before a ticket decision, `checkArchives` / `ensureArchive` on a ticket miss, `probe` for
/// a bare global id, `refreshNames` on a project miss. Every mutation publishes a new snapshot and is persisted to
/// `cacheURL` (mode 0600). Archive work merges page by page, so a cancelled or timed-out fetch keeps what arrived.
public actor IndexStore {
    public let client: ACClient
    public nonisolated let cacheURL: URL
    public private(set) var snapshot: IndexSnapshot
    /// Archive page size [V]; the server ignores `per_page`.
    public static let archivePageSize = 30
    private nonisolated let broadcaster = SnapshotBroadcaster()
    /// Company ids that projects name but /companies does not list (trashed, archived): already revalidated once,
    /// so `refreshFast` does not fetch /companies for them on every key press.
    private var checkedUnknownCompanies = Set<Int>()

    public init(client: ACClient, cacheURL: URL = AppPaths.indexCache, snapshot: IndexSnapshot? = nil) {
        self.client = client
        self.cacheURL = cacheURL
        var s = snapshot ?? IndexSnapshot(baseURL: client.base, userId: client.userId)
        s.rebuildTasks()
        self.snapshot = s
        broadcaster.publish(s)
    }

    /// A new stream per access: it yields the current snapshot at once, then every change (newest only when the
    /// consumer is slow).
    public nonisolated var updates: AsyncStream<IndexSnapshot> { broadcaster.subscribe() }

    /// The latest published snapshot, without awaiting the actor.
    public nonisolated var latest: IndexSnapshot? { broadcaster.latest }

    // MARK: - Disk

    /// Loads the cache when it belongs to this client's instance and user. Returns nil and keeps the current
    /// snapshot otherwise (missing file, junk, other version, other instance).
    @discardableResult
    public func loadFromDisk() -> IndexSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL), let s = IndexSnapshot.decode(data),
              s.baseURL.map(Self.normalized) == Self.normalized(client.base), s.userId == client.userId else { return nil }
        snapshot = s
        broadcaster.publish(s)
        return s
    }

    /// Atomic write, directory 0700, file 0600.
    public func persist() throws {
        let data = try snapshot.encoded()
        try AppPaths.ensureDirectory(cacheURL.deletingLastPathComponent())
        try data.write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    /// Forgets everything, ETags included (`acvoice-index refresh --full`).
    public func reset() {
        snapshot = IndexSnapshot(baseURL: client.base, userId: client.userId)
        broadcaster.publish(snapshot)
    }

    // MARK: - Fast refresh

    /// Projects, favorites, own tasks and own time records (30 days), in parallel with ETags; companies when a
    /// project names an unknown one. Run on every key press and every 5 minutes; mostly 304 in 25-60 ms [V].
    @discardableResult
    public func refreshFast(now: Date = .now) async -> RefreshReport {
        let start = ContinuousClock.now
        var report = RefreshReport()
        let client = self.client
        let me = client.userId, etags = snapshot.etags
        let trPath = ACPaths.timeRecords(me, from: now.addingTimeInterval(-30 * 86_400), to: now)
        let needCompanies = snapshot.companies.isEmpty

        async let projects = client.projects(etag: etags[ACPaths.projects])
        async let favorites = client.favorites(etag: etags[ACPaths.favorites])
        async let mine = client.myTasks(etag: etags[ACPaths.userTasks(me)])
        async let records = client.timeRecords(path: trPath, etag: etags[trPath])
        async let companies = needCompanies ? client.companies(etag: etags[ACPaths.companies]) : nil

        do {
            let f = try await projects
            report.record(f)
            if case .fresh(let list, let tag) = f {
                snapshot.projects = list.filter { !$0.isTrashed && !$0.isCompleted }
                    .map { ProjectRecord(id: $0.id, name: $0.name, companyId: $0.companyId,
                                         lastActivity: $0.lastActivityOn.map { Date(timeIntervalSince1970: TimeInterval($0)) }) }
                    .sorted { $0.id < $1.id }
                setETag(tag, for: ACPaths.projects)
            }
        } catch { report.fail(error) }
        do {
            let f = try await favorites
            report.record(f)
            if case .fresh(let list, let tag) = f {
                var seen = Set<Int>()
                snapshot.favorites = list.filter { $0.parentType == "Project" && seen.insert($0.parentId).inserted }.map(\.parentId)
                setETag(tag, for: ACPaths.favorites)
            }
        } catch { report.fail(error) }
        do {
            let f = try await mine
            report.record(f)
            if case .fresh(let list, let tag) = f {
                snapshot.mine = list.tasks.filter { !$0.isCompleted && !$0.isTrashed }
                    .map { TaskRef(id: $0.id, projectId: $0.projectId, number: $0.taskNumber) }
                    .sorted { ($0.projectId, $0.number, $0.id) < ($1.projectId, $1.number, $1.id) }
                setETag(tag, for: ACPaths.userTasks(me))
            }
        } catch { report.fail(error) }
        do {
            let f = try await records
            report.record(f)
            if case .fresh(let list, let tag) = f {
                var counts: [Int: Int] = [:]
                for r in list where !r.isTrashed { counts[r.projectId, default: 0] += 1 }
                snapshot.timeRecords30d = counts
                // The path carries the dates: keep only today's validator.
                for k in snapshot.etags.keys where k.contains(ACPaths.timeRecordsPrefix) && k != trPath { snapshot.etags[k] = nil }
                setETag(tag, for: trPath)
            }
        } catch { report.fail(error) }
        var companiesCurrent = false
        do {
            if let f = try await companies { applyCompanies(f, report: &report); companiesCurrent = true }
        } catch { report.fail(error) }

        // A project of an unknown company: revalidate the companies (conditional GET), once per new unknown id.
        if !report.unauthorized {
            var unknown = unknownCompanyIds()
            if !companiesCurrent, !unknown.isSubset(of: checkedUnknownCompanies) {
                do {
                    applyCompanies(try await client.companies(etag: snapshot.etags[ACPaths.companies]), report: &report)
                    companiesCurrent = true
                    unknown = unknownCompanyIds()
                } catch { report.fail(error) }
            }
            if companiesCurrent { checkedUnknownCompanies.formUnion(unknown) }
        }

        if report.failed == 0 { snapshot.fetchedAt = now }
        report.persisted = commit(rebuild: true)
        report.duration = ContinuousClock.now - start
        return report
    }

    /// Company ids of active projects that the company map does not hold.
    private func unknownCompanyIds() -> Set<Int> {
        Set(snapshot.projects.compactMap(\.companyId).filter { $0 > 0 && snapshot.companies[$0] == nil })
    }

    private func applyCompanies(_ f: Fetch<[ACCompany]>, report: inout RefreshReport) {
        report.record(f)
        guard case .fresh(let list, let tag) = f else { return }
        var map: [Int: CompanyRecord] = [:]
        for c in list where !c.isTrashed { map[c.id] = CompanyRecord(name: c.name, isOwner: c.isOwner) }
        snapshot.companies = map
        setETag(tag, for: ACPaths.companies)
    }

    /// GET /projects/names (a few KB): picks up new and renamed projects after a resolver miss. True when the
    /// project list changed; false when nothing changed, on an error or when `budget` ran out.
    @discardableResult
    public func refreshNames(budget: Duration = .milliseconds(2500)) async -> Bool {
        let client = self.client
        guard let names = try? await withDeadline(.now + budget, { try await client.projectNames() }),
              !names.isEmpty else { return false }
        var byId = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for (id, name) in names where byId[id]?.name != name {
            byId[id, default: ProjectRecord(id: id, name: name)].name = name
            changed = true
        }
        for id in byId.keys where names[id] == nil { byId[id] = nil; changed = true }
        guard changed else { return false }
        snapshot.projects = byId.values.sorted { $0.id < $1.id }
        // The /projects validator no longer matches what we hold.
        snapshot.etags[ACPaths.projects] = nil
        commit(rebuild: false)
        return true
    }

    // MARK: - Task lists

    /// GET /projects/{id}/tasks for every active project, `concurrency` in parallel, with ETags (a few seconds cold,
    /// several MB [V]), plus a conditional GET /companies. Keeps open tasks (id, number), completed and trashed ids.
    /// Run every 10-15 minutes.
    @discardableResult
    public func refreshTaskLists(concurrency: Int = 8, now: Date = .now) async -> RefreshReport {
        let start = ContinuousClock.now
        var report = RefreshReport()
        let client = self.client
        let ids = snapshot.projectIds, etags = snapshot.etags
        let work: @Sendable (Int) async -> (Int, Result<Fetch<ACProjectTasks>, any Error>) = { pid in
            do { return (pid, .success(try await client.projectTasks(pid, etag: etags[ACPaths.projectTasks(pid)]))) }
            catch { return (pid, .failure(error)) }
        }
        await withTaskGroup(of: (Int, Result<Fetch<ACProjectTasks>, any Error>).self) { group in
            var pending = ids[...]
            for _ in 0..<max(1, concurrency) {
                guard let pid = pending.popFirst() else { break }
                group.addTask { await work(pid) }
            }
            while let (pid, result) = await group.next() {
                switch result {
                case .success(let f):
                    report.record(f)
                    applyTaskList(pid, f, now: now)
                case .failure(let e):
                    report.fail(e)
                    if case ACError.unauthorized = e { pending.removeAll() }
                }
                if let next = pending.popFirst() { group.addTask { await work(next) } }
            }
        }
        // Companies change rarely: revalidate them on this slow cadence (picks up renames).
        if !report.unauthorized {
            do { applyCompanies(try await client.companies(etag: snapshot.etags[ACPaths.companies]), report: &report) }
            catch { report.fail(error) }
        }
        // Forget projects that left the active list (never on an empty list).
        let active = Set(ids)
        for pid in snapshot.projectTasks.keys where !active.isEmpty && !active.contains(pid) {
            snapshot.projectTasks[pid] = nil
            snapshot.etags[ACPaths.projectTasks(pid)] = nil
        }
        if report.failed == 0 { snapshot.taskListsFetchedAt = now }
        report.persisted = commit(rebuild: true)
        report.duration = ContinuousClock.now - start
        return report
    }

    /// Ticket path, before the decision: conditional GET /projects/{id}/tasks (stored ETag, mostly 304 in ~25 ms
    /// [V]) for each of `projectIds` whose list is missing or older than `olderThan`, all in parallel, within
    /// `budget`. Task lists otherwise refresh only every 10-15 minutes: a ticket created in a sibling project since
    /// then is invisible, and a single hit would open directly instead of a ranked list.
    /// `complete`: every list is current. On an error or a timeout the cached lists stay.
    @discardableResult
    public func revalidateTaskLists(_ projectIds: [Int], olderThan: Duration = .seconds(60),
                                    budget: Duration = .milliseconds(800), now: Date = .now) async -> IndexCheck {
        let maxAge = Self.seconds(olderThan)
        func isCurrent(_ pid: Int) -> Bool {
            guard let at = snapshot.projectTasks[pid]?.fetchedAt else { return false }
            return now.timeIntervalSince(at) < maxAge
        }
        var seen = Set<Int>()
        let targets = projectIds.filter { seen.insert($0).inserted && !isCurrent($0) }
        guard !targets.isEmpty else { return IndexCheck() }
        let client = self.client, etags = snapshot.etags
        let tags = Dictionary(uniqueKeysWithValues: targets.map { pid in
            (pid, snapshot.projectTasks[pid]?.fetchedAt == nil ? nil : etags[ACPaths.projectTasks(pid)])
        })
        let deadline = ContinuousClock.now + budget
        var check = IndexCheck(complete: false)
        var report = RefreshReport()
        await withTaskGroup(of: (Int, Result<Fetch<ACProjectTasks>, any Error>)?.self) { group in
            group.addTask {
                try? await Task.sleep(until: deadline, clock: .continuous)
                return nil
            }
            for pid in targets {
                group.addTask {
                    do { return (pid, .success(try await client.projectTasks(pid, etag: tags[pid] ?? nil))) }
                    catch { return (pid, .failure(error)) }
                }
            }
            var remaining = targets.count
            while let next = await group.next() {
                guard let (pid, result) = next else { check.timedOut = true; break }
                switch result {
                case .success(let f): report.record(f); applyTaskList(pid, f, now: now)
                case .failure(let e): if !(e is CancellationError) { report.fail(e) }
                }
                remaining -= 1
                if remaining == 0 { break }
            }
            group.cancelAll()
        }
        check.add(report)
        // 304s only move `fetchedAt`: no new snapshot needed. A changed list is published and persisted.
        if report.fresh > 0 { commit(rebuild: true) }
        check.complete = targets.allSatisfy(isCurrent)
        return check
    }

    /// `revalidateTaskLists` for the lists a ticket decision reads: the candidate projects of "WWT Ticket 412"; for a
    /// bare "Ticket 412" the active tab project and the active favorites. Nothing for a global id or for project
    /// words that matched no project.
    @discardableResult
    public func revalidateTaskLists(for request: TaskRequest, activeProjectId: Int? = nil,
                                    olderThan: Duration = .seconds(60), budget: Duration = .milliseconds(800),
                                    now: Date = .now) async -> IndexCheck {
        guard request.number < TicketResolver.globalIdThreshold else { return IndexCheck() }
        let pids: [Int]
        if let r = request.projects {
            pids = r.projectIds
        } else {
            let active = Set(snapshot.projectIds)
            pids = ([activeProjectId].compactMap { $0 } + snapshot.favorites).filter(active.contains)
        }
        return await revalidateTaskLists(pids, olderThan: olderThan, budget: budget, now: now)
    }

    private func applyTaskList(_ pid: Int, _ f: Fetch<ACProjectTasks>, now: Date) {
        guard case .fresh(let pt, let tag) = f else {
            // 304 without local data (should not happen): drop the validator so the next pass fetches the list.
            if snapshot.projectTasks[pid] != nil { snapshot.projectTasks[pid]?.fetchedAt = now }
            else { snapshot.etags[ACPaths.projectTasks(pid)] = nil }
            return
        }
        var st = snapshot.projectTasks[pid] ?? ProjectTaskState()
        let mine = pt.tasks.filter { $0.projectId == pid && !$0.isTrashed }
        st.open = mine.filter { !$0.isCompleted }.map { TaskRow(id: $0.id, number: $0.taskNumber) }.sorted { $0.number < $1.number }
        st.completedIds = Array(Set(pt.completedTaskIds)).sorted()
        st.trashedIds = Array(Set(pt.trashedTaskIds)).sorted()
        st.mergeArchive(mine.filter(\.isCompleted).map { TaskRow(id: $0.id, number: $0.taskNumber) })
        st.fetchedAt = now
        st.normalize()
        snapshot.projectTasks[pid] = st
        setETag(tag, for: ACPaths.projectTasks(pid))
    }

    // MARK: - Archives

    /// Background: numbers of completed tasks, `priority` first, then `IndexSnapshot.archivePriority()`.
    /// Incremental: only projects with completed ids that have no number yet. Runs `projects` archives at a time
    /// with up to `pages` requests each, started in priority order. Stops early when cancelled or on a 401.
    @discardableResult
    public func extendArchives(priority: [Int] = [], projects parallel: Int = 3, pages: Int = 4) async -> RefreshReport {
        let start = ContinuousClock.now
        var report = RefreshReport()
        var seen = Set<Int>()
        let order = (priority + snapshot.archivePriority()).filter { pid in
            guard seen.insert(pid).inserted, let st = snapshot.projectTasks[pid] else { return false }
            return st.fetchedAt != nil && !st.missingArchiveIds.isEmpty
        }
        var sinceSave = 0
        await withTaskGroup(of: (Int, RefreshReport).self) { group in
            var pending = order[...]
            for _ in 0..<max(1, parallel) {
                guard let pid = pending.popFirst() else { break }
                group.addTask { (pid, await self.fetchArchive(pid, concurrency: pages)) }
            }
            while let (pid, r) = await group.next() {
                report.add(r)
                snapshot.refreshTasks(project: pid)
                broadcaster.publish(snapshot)
                sinceSave += 1
                if sinceSave >= 10 { sinceSave = 0; try? persist() }
                if r.unauthorized || Task.isCancelled { pending.removeAll() }
                if let next = pending.popFirst() { group.addTask { (next, await self.fetchArchive(next, concurrency: pages)) } }
            }
        }
        report.persisted = commit(rebuild: false)
        report.duration = ContinuousClock.now - start
        return report
    }

    /// Miss path ("WWT Ticket 412" not in the index): `checkArchives(projectIds, budget:).complete`. The caller then
    /// resolves again, with `archivesFetched: true` when this returned false.
    public func ensureArchive(_ projectIds: [Int], budget: Duration = .milliseconds(2500)) async -> Bool {
        await checkArchives(projectIds, budget: budget).complete
    }

    /// Miss path: completes the archives of `projectIds` in parallel within `budget`. A task list that is missing or
    /// older than `listsOlderThan` is (re)validated first (conditional GET), so the pass sees current completed ids;
    /// this also holds for a project whose archive is already complete. A complete project with a current list
    /// costs nothing. `complete`: every project's archive is complete afterwards. `error`: why not (401, offline,
    /// timeout), for the overlay instead of "nicht gefunden".
    public func checkArchives(_ projectIds: [Int], budget: Duration = .milliseconds(2500),
                              listsOlderThan: Duration = .seconds(60), now: Date = .now) async -> IndexCheck {
        let maxAge = Self.seconds(listsOlderThan)
        func listCurrent(_ pid: Int) -> Bool {
            snapshot.projectTasks[pid]?.fetchedAt.map { now.timeIntervalSince($0) < maxAge } ?? false
        }
        var seen = Set<Int>()
        let targets = projectIds.filter {
            seen.insert($0).inserted && !(snapshot.tasks.archiveComplete.contains($0) && listCurrent($0))
        }
        guard !targets.isEmpty else { return IndexCheck() }
        let deadline = ContinuousClock.now + budget
        var check = IndexCheck(complete: false)
        await withTaskGroup(of: RefreshReport?.self) { group in
            group.addTask {
                try? await Task.sleep(until: deadline, clock: .continuous)
                return nil
            }
            for pid in targets { group.addTask { await self.completeArchive(pid, maxListAge: maxAge, now: now) } }
            var remaining = targets.count
            while let next = await group.next() {
                guard let report = next else { check.timedOut = true; break }
                check.add(report)
                remaining -= 1
                if remaining == 0 { break }
            }
            group.cancelAll()
        }
        // A revalidated task list can drop or move tasks: rebuild the whole task index (a few ms).
        commit(rebuild: true)
        check.complete = targets.allSatisfy { snapshot.tasks.archiveComplete.contains($0) }
        return check
    }

    private func completeArchive(_ pid: Int, maxListAge: Double, now: Date) async -> RefreshReport {
        var report = RefreshReport()
        let fetchedAt = snapshot.projectTasks[pid]?.fetchedAt
        if fetchedAt.map({ now.timeIntervalSince($0) >= maxListAge }) ?? true {
            let etag = fetchedAt == nil ? nil : snapshot.etags[ACPaths.projectTasks(pid)]
            do {
                let f = try await client.projectTasks(pid, etag: etag)
                report.record(f)
                applyTaskList(pid, f, now: now)
            } catch {
                if !(error is CancellationError) { report.fail(error) }
                return report
            }
        }
        report.add(await fetchArchive(pid, concurrency: 16))
        snapshot.refreshTasks(project: pid)
        return report
    }

    /// Pages through one archive until every completed id has a number. The archive is sorted by completion,
    /// newest first [V]: a few new completions sit on page 1. Phase 1 fetches the pages the missing count needs
    /// (all pages for a cold project), phase 2 the rest in one parallel batch. Ids that were missing at the start
    /// and are still missing after the last (short) page are marked unreachable.
    func fetchArchive(_ pid: Int, concurrency: Int) async -> RefreshReport {
        var report = RefreshReport()
        guard let st = snapshot.projectTasks[pid], st.fetchedAt != nil else { return report }
        let missing = st.missingArchiveIds
        guard !missing.isEmpty else { return report }
        let size = Self.archivePageSize
        let total = max(1, (st.completedIds.count + size - 1) / size)
        let first = st.archived.isEmpty ? total : min(total, (missing.count + size - 1) / size)

        var sawEnd = false, failed = false
        let p1 = await fetchPages(pid, Array(1...first), concurrency: concurrency, report: &report)
        sawEnd = p1.sawEnd; failed = p1.failed
        // New completions shift older tasks to later pages: one extra page covers the shift.
        if !failed, !sawEnd, !(snapshot.projectTasks[pid]?.missingArchiveIds.isEmpty ?? true), first < total + 1 {
            let p2 = await fetchPages(pid, Array((first + 1)...(total + 1)), concurrency: concurrency, report: &report)
            sawEnd = p2.sawEnd; failed = p2.failed
        }
        // Only ids that were missing when this pass started: an id completed meanwhile (a task-list refresh during
        // the pass) cannot be on the pages fetched before, and stays missing for the next pass.
        if sawEnd, !failed, var cur = snapshot.projectTasks[pid] {
            let gone = cur.missingArchiveIds.intersection(missing)
            if !gone.isEmpty {
                cur.unreachable = Array(Set(cur.unreachable).union(gone)).sorted()
                snapshot.projectTasks[pid] = cur
            }
        }
        return report
    }

    /// Fetches `pages` with at most `concurrency` in flight and merges each page as it arrives. Stops adding pages
    /// once nothing is missing. `sawEnd`: a short or empty page arrived.
    private func fetchPages(_ pid: Int, _ pages: [Int], concurrency: Int,
                            report: inout RefreshReport) async -> (sawEnd: Bool, failed: Bool) {
        let client = self.client
        let size = Self.archivePageSize
        var sawEnd = false, failed = false
        await withTaskGroup(of: Result<ACArchivePage, any Error>.self) { group in
            var pending = pages[...]
            for _ in 0..<max(1, concurrency) {
                guard let p = pending.popFirst() else { break }
                group.addTask { do { return .success(try await client.archivePage(pid, page: p)) } catch { return .failure(error) } }
            }
            while let result = await group.next() {
                switch result {
                case .success(let page):
                    report.pages += 1
                    if page.tasks.count < (page.perPage ?? size) { sawEnd = true }
                    let rows = page.tasks.filter { $0.projectId == pid }.map { TaskRow(id: $0.id, number: $0.taskNumber) }
                    if var st = snapshot.projectTasks[pid] {
                        st.mergeArchive(rows)
                        st.normalize()
                        snapshot.projectTasks[pid] = st
                    }
                case .failure(let e):
                    if !(e is CancellationError) { report.fail(e) }
                    failed = true
                }
                let done = snapshot.projectTasks[pid]?.missingArchiveIds.isEmpty ?? true
                if done || failed || sawEnd { pending.removeAll() }
                if let p = pending.popFirst(), !Task.isCancelled {
                    group.addTask { do { return .success(try await client.archivePage(pid, page: p)) } catch { return .failure(error) } }
                }
            }
        }
        return (sawEnd, failed)
    }

    // MARK: - Probe

    /// Bare global id missing from the index: 301 probe via any active project (prefers a favorite), then the
    /// task itself for its number and trash state (~85 ms in total [V]), both within `budget`.
    /// - Returns: nil when AC does not know the id. When the details do not arrive in time, the ref has number 0,
    ///   is not trashed and is not cached; otherwise it is cached (`IndexSnapshot.probed`).
    /// - Throws: `ACError.timedOut` when the probe itself runs out of budget; `unauthorized`, `transport` and other
    ///   AC errors as they come. With no project cached yet (cold start) it fetches /projects first, so an offline
    ///   start or a rejected token surfaces as that error, not as "nicht gefunden".
    public func probe(taskId: Int, budget: Duration = .milliseconds(2500)) async throws -> TaskRef? {
        let client = self.client
        let deadline = ContinuousClock.now + budget
        let active = snapshot.projectIds
        var via = snapshot.favorites.first(where: active.contains) ?? active.first
        if via == nil {
            let list = try await withDeadline(deadline) { try await client.projects().value ?? [] }
            via = list.first { !$0.isTrashed && !$0.isCompleted }?.id
        }
        guard let via else { return nil }
        guard let pid = try await withDeadline(deadline, { try await client.probeProject(ofTask: taskId, via: via) })
        else { return nil }
        let details = try? await withDeadline(deadline) { try await client.task(projectId: pid, taskId: taskId) }
        try Task.checkCancellation()
        guard let details else { return TaskRef(id: taskId, projectId: pid, number: 0) }
        let ref = TaskRef(id: taskId, projectId: pid, number: details.taskNumber,
                          isCompleted: details.isCompleted, isTrashed: details.isTrashed)
        snapshot.probed[taskId] = ref
        commit(rebuild: true)
        return ref
    }

    // MARK: - Internals

    private func setETag(_ tag: String?, for path: String) { snapshot.etags[path] = tag }

    /// Publishes and persists. Returns whether the write succeeded.
    @discardableResult
    private func commit(rebuild: Bool) -> Bool {
        if rebuild { snapshot.rebuildTasks() }
        broadcaster.publish(snapshot)
        return (try? persist()) != nil
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func normalized(_ url: URL) -> String {
        var s = url.absoluteString.lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// Fan-out of snapshots to any number of `AsyncStream` subscribers.
final class SnapshotBroadcaster: Sendable {
    private struct State {
        var latest: IndexSnapshot?
        var subscribers: [UUID: AsyncStream<IndexSnapshot>.Continuation] = [:]
    }
    private let state = Mutex(State())

    var latest: IndexSnapshot? { state.withLock { $0.latest } }

    /// Yields under the lock so every subscriber sees snapshots in publish order.
    func publish(_ s: IndexSnapshot) {
        state.withLock { st in
            st.latest = s
            for c in st.subscribers.values { c.yield(s) }
        }
    }

    func subscribe() -> AsyncStream<IndexSnapshot> {
        let (stream, cont) = AsyncStream.makeStream(of: IndexSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        cont.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) } }
        state.withLock { st in
            st.subscribers[id] = cont
            if let s = st.latest { cont.yield(s) }
        }
        return stream
    }
}
