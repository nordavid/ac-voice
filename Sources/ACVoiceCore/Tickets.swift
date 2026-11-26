import Foundation

public struct TaskRef: Sendable, Codable, Hashable {
    public var id: Int, projectId: Int, number: Int
    public var isCompleted = false, isTrashed = false
    public init(id: Int, projectId: Int, number: Int, isCompleted: Bool = false, isTrashed: Bool = false) {
        self.id = id; self.projectId = projectId; self.number = number; self.isCompleted = isCompleted; self.isTrashed = isTrashed
    }
}

public struct TaskIndex: Sendable, Codable, Equatable {
    /// project id -> task number -> task (open tasks plus archive pages fetched so far).
    public var byProject: [Int: [Int: TaskRef]] = [:]
    /// task id -> project id, for open, completed and trashed ids of all active projects.
    public var projectOfTask: [Int: Int] = [:]
    /// Projects whose archive (completed tasks with numbers) is fully indexed.
    public var archiveComplete: Set<Int> = []
    /// GET /users/{me}/tasks: own open tasks.
    public var mine: [TaskRef] = []
    /// `trashed_task_ids` of all projects.
    public var trashed: Set<Int> = []
    public init() {}

    public mutating func add(_ t: TaskRef) {
        byProject[t.projectId, default: [:]][t.number] = t
        projectOfTask[t.id] = t.projectId
        if t.isTrashed { trashed.insert(t.id) }
    }

    /// The task with `number` in `project`, from the project lists or the own tasks.
    public func task(project: Int, number: Int) -> TaskRef? {
        byProject[project]?[number] ?? mine.first { $0.projectId == project && $0.number == number }
    }

    enum CodingKeys: String, CodingKey { case byProject, projectOfTask, archiveComplete, mine, trashed }
    /// Tolerant: missing keys (older cache files) decode as empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        byProject = try c.decodeIfPresent([Int: [Int: TaskRef]].self, forKey: .byProject) ?? [:]
        projectOfTask = try c.decodeIfPresent([Int: Int].self, forKey: .projectOfTask) ?? [:]
        archiveComplete = try c.decodeIfPresent(Set<Int>.self, forKey: .archiveComplete) ?? []
        mine = try c.decodeIfPresent([TaskRef].self, forKey: .mine) ?? []
        trashed = try c.decodeIfPresent(Set<Int>.self, forKey: .trashed) ?? []
    }
}

public enum TicketOutcome: Sendable, Equatable {
    case open(projectId: Int, taskId: Int)
    /// Ranked best first: active tab project, own tasks, open before completed, project order, id.
    /// A single item means "confirm" (low-confidence number): "Sag ja oder eins".
    case choices([TaskRef])
    /// Fetch these archives (ordered), then call again with these ids added to `attemptedArchives`, whether the
    /// fetch completed or not. The list never repeats an attempted id, so the loop ends (see `TicketResolver.resolve`).
    case fetchArchive(projectIds: [Int])
    /// GET /projects/{any}/tasks/{id} without following redirects; the 301 Location names the project.
    case probe(taskId: Int)
    case trashed(taskId: Int)
    /// Project words were spoken but matched no project: retry, never search globally (REVIEW M6).
    case projectNotRecognized
    case notFound
}

public enum TicketResolver {
    /// Task numbers stay below this; anything at or above is a global task id. VERIFIED: open task numbers have
    /// four digits.
    public static let globalIdThreshold = 10_000
    /// Global task ids start well above 0 on a used instance. Below this a number without hits is no id worth a probe.
    public static let minGlobalId = 500

    /// - Parameters:
    ///   - favorites: favorite project ids, best first.
    ///   - allProjects: all project ids, best first (the order breaks ties in `choices`).
    ///   - activeProjectId: project of the active Chrome AC tab; ranks first and is searched first for bare numbers.
    ///   - archivesFetched: true: treat every archive as attempted and decide with what is indexed.
    ///   - attemptedArchives: projects whose archive fetch was already attempted in this resolution (completed,
    ///     empty or failed). They are never requested again.
    ///
    /// Termination rule for callers: add the ids of every `.fetchArchive` to `attemptedArchives` before the next
    /// call. Each round then names only new ids, so the loop ends after at most 3 rounds (active tab project,
    /// favorites or the spoken scope, all projects) and never after more rounds than there are projects.
    public static func resolve(_ req: TaskRequest, index: TaskIndex, favorites: [Int], allProjects: [Int],
                               activeProjectId: Int? = nil, archivesFetched: Bool = false,
                               attemptedArchives: Set<Int> = []) -> TicketOutcome {
        let n = req.number
        let mineIds = Set(index.mine.map(\.id))

        func isTrashed(_ ref: TaskRef) -> Bool { ref.isTrashed || index.trashed.contains(ref.id) }
        func finish(_ ref: TaskRef) -> TicketOutcome {
            if isTrashed(ref) { return .trashed(taskId: ref.id) }
            return req.confident ? .open(projectId: ref.projectId, taskId: ref.id) : .choices([ref])
        }
        func rank(_ refs: [TaskRef], order: [Int]) -> [TaskRef] {
            var pos: [Int: Int] = [:]
            for (i, p) in order.enumerated() where pos[p] == nil { pos[p] = i }
            return refs.sorted { a, b in
                (a.projectId == activeProjectId ? 0 : 1, mineIds.contains(a.id) ? 0 : 1, a.isCompleted ? 1 : 0,
                 pos[a.projectId] ?? Int.max, a.projectId, a.id)
                    < (b.projectId == activeProjectId ? 0 : 1, mineIds.contains(b.id) ? 0 : 1, b.isCompleted ? 1 : 0,
                       pos[b.projectId] ?? Int.max, b.projectId, b.id)
            }
        }
        func hits(_ scope: [Int]) -> [TaskRef] {
            scope.compactMap { index.task(project: $0, number: n) }.filter { !isTrashed($0) }
        }
        func unresolved(_ scope: [Int]) -> [Int] {
            guard !archivesFetched else { return [] }
            var seen = Set<Int>()
            return scope.filter {
                seen.insert($0).inserted && index.task(project: $0, number: n) == nil
                    && !index.archiveComplete.contains($0) && !attemptedArchives.contains($0)
            }
        }

        // A global id is unambiguous, with or without project words.
        if n >= globalIdThreshold {
            if index.trashed.contains(n) { return .trashed(taskId: n) }
            guard let pid = index.projectOfTask[n] else { return .probe(taskId: n) }
            if req.confident { return .open(projectId: pid, taskId: n) }
            // number 0: the task number is unknown for a bare global id.
            return .choices([index.byProject[pid]?.values.first { $0.id == n } ?? TaskRef(id: n, projectId: pid, number: 0)])
        }

        switch req.projects {
        case .none?:
            return .projectNotRecognized
        case let r?:
            let pids = r.projectIds
            let found = hits(pids), open = unresolved(pids)
            // One hit opens only when no sibling archive can still hide the same number, unless the hit is in the
            // active tab project or one of the own tasks (REVIEW M6).
            if found.count == 1, open.isEmpty || found[0].projectId == activeProjectId || mineIds.contains(found[0].id) {
                return finish(found[0])
            }
            if !open.isEmpty { return .fetchArchive(projectIds: open) }
            return found.isEmpty ? .notFound : .choices(rank(found, order: pids))
        case nil:
            break
        }

        // Bare "Ticket N" (N < 10000): active tab project, own open tasks, favorites, all projects.
        if let a = activeProjectId {
            if let hit = index.task(project: a, number: n), !isTrashed(hit) { return finish(hit) }
            if !unresolved([a]).isEmpty { return .fetchArchive(projectIds: [a]) }
        }
        let own = index.mine.filter { $0.number == n && !isTrashed($0) }
        if own.count == 1 { return finish(own[0]) }
        if own.count > 1 { return .choices(rank(own, order: allProjects)) }
        for (scope, isAll) in [(favorites, false), (allProjects, true)] {
            let found = hits(scope), open = unresolved(scope)
            if found.isEmpty {
                if isAll, !open.isEmpty { return .fetchArchive(projectIds: open) }
                continue
            }
            if !open.isEmpty { return .fetchArchive(projectIds: open) }
            return found.count == 1 ? finish(found[0]) : .choices(rank(found, order: scope))
        }
        return n >= minGlobalId ? .probe(taskId: n) : .notFound
    }
}
