import ACVoiceCore
import Foundation

/// An active project as cached (the parsed `ProjectEntry` is rebuilt from it, see `IndexSnapshot.entries`).
public struct ProjectRecord: Sendable, Codable, Equatable {
    public var id: Int
    public var name: String
    public var companyId: Int?
    /// Team activity (`last_activity_on`).
    public var lastActivity: Date?
    public init(id: Int, name: String, companyId: Int? = nil, lastActivity: Date? = nil) {
        self.id = id; self.name = name; self.companyId = companyId; self.lastActivity = lastActivity
    }
}

public struct CompanyRecord: Sendable, Codable, Equatable {
    public var name: String
    /// The agency's own company: never used as an alias.
    public var isOwner: Bool
    public init(name: String, isOwner: Bool = false) { self.name = name; self.isOwner = isOwner }
}

/// Task id and number; the project is implied by the containing `ProjectTaskState`.
public struct TaskRow: Sendable, Codable, Hashable {
    public var id: Int
    public var number: Int
    public init(id: Int, number: Int) { self.id = id; self.number = number }
}

/// What ac-voice keeps of one project's task list (PLAN 5): open tasks with numbers, completed and trashed ids,
/// and completed tasks with numbers from the archive pages.
public struct ProjectTaskState: Sendable, Codable, Equatable {
    public var open: [TaskRow] = []
    /// `completed_task_ids`, sorted.
    public var completedIds: [Int] = []
    /// `trashed_task_ids`, sorted.
    public var trashedIds: [Int] = []
    /// Completed tasks with numbers from /tasks/archive, sorted by number.
    public var archived: [TaskRow] = []
    /// Completed ids that a full pass through the archive did not list. They count as indexed.
    public var unreachable: [Int] = []
    /// Last 200 of /projects/{id}/tasks; nil when only archive pages are known.
    public var fetchedAt: Date?
    public init() {}

    /// Completed ids without a number yet.
    public var missingArchiveIds: Set<Int> {
        Set(completedIds).subtracting(archived.map(\.id)).subtracting(unreachable)
    }

    /// Every completed id has a number (or the archive does not list it).
    public var isArchiveComplete: Bool { fetchedAt != nil && missingArchiveIds.isEmpty }

    /// Drops archive rows and unreachable ids that are no longer completed (reopened, trashed, deleted, moved).
    mutating func normalize() {
        let done = Set(completedIds), open = Set(self.open.map(\.id))
        archived.removeAll { !done.contains($0.id) || open.contains($0.id) }
        unreachable.removeAll { !done.contains($0) }
    }

    /// Adds archive rows by id; keeps the list sorted by number.
    mutating func mergeArchive(_ rows: [TaskRow]) {
        guard !rows.isEmpty else { return }
        var byId = Dictionary(archived.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in rows { byId[r.id] = r }
        archived = byId.values.sorted { $0.number != $1.number ? $0.number < $1.number : $0.id < $1.id }
    }
}

/// Everything ac-voice knows about AC, persisted as JSON (`AppPaths.indexCache`). Holds names, ids and ETags:
/// the file is written with mode 0600, and nothing in it is ever logged.
public struct IndexSnapshot: Sendable, Codable, Equatable {
    public static let currentVersion = 1

    public var version = IndexSnapshot.currentVersion
    /// Instance and user the cache belongs to; a cache for another instance or user is discarded on load.
    public var baseURL: URL?
    public var userId: Int?
    /// Active projects (GET /projects), sorted by id.
    public var projects: [ProjectRecord] = []
    public var companies: [Int: CompanyRecord] = [:]
    /// Favorite project ids in AC order, including completed projects.
    public var favorites: [Int] = []
    /// Own time records per project in the 30 days before `fetchedAt`.
    public var timeRecords30d: [Int: Int] = [:]
    /// Own open tasks (GET /users/{me}/tasks).
    public var mine: [TaskRef] = []
    public var projectTasks: [Int: ProjectTaskState] = [:]
    /// Results of the 301 probe (tasks of archived projects, tasks newer than the task lists).
    public var probed: [Int: TaskRef] = [:]
    /// API path -> ETag. Contains the user's e-mail address: never log.
    public var etags: [String: String] = [:]
    /// Last fast refresh (projects, favorites, own tasks, time records).
    public var fetchedAt: Date?
    /// Last complete pass over all task lists.
    public var taskListsFetchedAt: Date?

    /// Derived from `projectTasks`, `mine` and `probed`; not persisted.
    public private(set) var tasks = TaskIndex()

    public init(baseURL: URL? = nil, userId: Int? = nil) { self.baseURL = baseURL; self.userId = userId }

    // MARK: Core mapping

    /// Index entries: signals from AC (favorite, own time records, own open tasks, team activity) and aliases from
    /// the company name (per project). Nothing local: `Interpreter(projects:config:history:)` adds the config aliases,
    /// the learned aliases and the history's opens.
    public func indexEntries(companyAliases: Bool = true) -> [ProjectEntry] {
        let favs = Set(favorites)
        let own = Dictionary(grouping: mine, by: \.projectId).mapValues(\.count)
        let byCompany = companyAliases ? companyAliasMap() : [:]
        return projects.map { p -> ProjectEntry in
            let s = Signals(favorite: favs.contains(p.id), timeRecords30d: timeRecords30d[p.id] ?? 0,
                            ownOpenTasks: own[p.id] ?? 0, lastActivity: p.lastActivity)
            let aliases = p.companyId.flatMap { byCompany[$0] } ?? []
            return ProjectEntry(id: p.id, name: p.name, signals: s, aliases: aliases)
        }
    }

    /// Core project entries: `indexEntries` plus `config.aliases` (per code), `History.learnedAliases` when
    /// `config.learnAliases` is on, and the history's opens (`Interpreter.entries(_:config:history:)`).
    public func entries(config: Config = Config(), history: History = History(), companyAliases: Bool = true) -> [ProjectEntry] {
        Interpreter.entries(indexEntries(companyAliases: companyAliases), config: config, history: history)
    }

    /// The app's interpreter in one call (`Interpreter(projects:config:history:)` over `indexEntries`). Rebuild it
    /// whenever the snapshot, the config or the history changes.
    public func interpreter(config: Config = Config(), history: History = History()) -> Interpreter {
        Interpreter(projects: indexEntries(), config: config, history: history)
    }

    /// Spoken company aliases per company id (owner company and conflicting aliases left out, see `CompanyAliases`).
    public func companyAliasMap() -> [Int: [String]] {
        let used = Set(projects.compactMap(\.companyId))
        var codeKeys = Set<String>(), codeWords = Set<String>()
        var titleWordCompanies: [String: Set<Int>] = [:]
        for p in projects {
            let e = ProjectEntry(id: p.id, name: p.name)
            if let code = e.code {
                codeKeys.insert(ProjectEntry.codeKey(code))
                for t in TextNorm.tokenize(code) where !t.key.isEmpty { codeWords.insert(t.key) }
            }
            for t in TextNorm.tokenize(e.title) where !t.key.isEmpty {
                titleWordCompanies[t.key, default: []].insert(p.companyId ?? -1)
            }
        }
        var out: [Int: [String]] = [:]
        for (id, c) in companies where !c.isOwner && used.contains(id) {
            let aliases = CompanyAliases.make(c.name).filter { alias in
                let keys = TextNorm.tokenize(alias).map(\.key).filter { !$0.isEmpty }
                guard !keys.isEmpty, !codeKeys.contains(keys.joined(separator: " ")) else { return false }
                if keys.count == 1 {
                    // A single word must not collide with a code word or another company's title word.
                    if codeWords.contains(keys[0]) { return false }
                    if let owners = titleWordCompanies[keys[0]], !owners.subtracting([id]).isEmpty { return false }
                }
                return true
            }
            if !aliases.isEmpty { out[id] = aliases }
        }
        return out
    }

    // MARK: Derived task index

    /// Rebuilds `tasks` (TaskIndex) from the per-project states, the own tasks and the probe results.
    public mutating func rebuildTasks() {
        var idx = TaskIndex()
        for (pid, st) in projectTasks {
            idx.byProject[pid] = Self.byNumber(pid, st)
            for id in st.completedIds { idx.projectOfTask[id] = pid }
            for r in st.open { idx.projectOfTask[r.id] = pid }
            for r in st.archived { idx.projectOfTask[r.id] = pid }
            for id in st.trashedIds { idx.projectOfTask[id] = pid; idx.trashed.insert(id) }
            if st.isArchiveComplete { idx.archiveComplete.insert(pid) }
        }
        for r in probed.values {
            if idx.projectOfTask[r.id] == nil { idx.projectOfTask[r.id] = r.projectId }
            if r.isTrashed { idx.trashed.insert(r.id) }
        }
        for r in mine where idx.projectOfTask[r.id] == nil { idx.projectOfTask[r.id] = r.projectId }
        idx.mine = mine
        tasks = idx
    }

    /// Updates one project in `tasks` after its archive grew (cheaper than `rebuildTasks`).
    mutating func refreshTasks(project pid: Int) {
        guard let st = projectTasks[pid] else { return }
        tasks.byProject[pid] = Self.byNumber(pid, st)
        for id in st.completedIds { tasks.projectOfTask[id] = pid }
        for r in st.open { tasks.projectOfTask[r.id] = pid }
        for r in st.archived { tasks.projectOfTask[r.id] = pid }
        for id in st.trashedIds { tasks.projectOfTask[id] = pid; tasks.trashed.insert(id) }
        if st.isArchiveComplete { tasks.archiveComplete.insert(pid) } else { tasks.archiveComplete.remove(pid) }
    }

    /// Number -> task; open tasks win over archive rows.
    static func byNumber(_ pid: Int, _ st: ProjectTaskState) -> [Int: TaskRef] {
        var m: [Int: TaskRef] = [:]
        for r in st.archived { m[r.number] = TaskRef(id: r.id, projectId: pid, number: r.number, isCompleted: true) }
        for r in st.open { m[r.number] = TaskRef(id: r.id, projectId: pid, number: r.number) }
        return m
    }

    // MARK: Helpers

    public var projectIds: [Int] { projects.map(\.id) }

    /// Archive order for `IndexStore.extendArchives`: active favorites, then by own time records, then projects
    /// with own tasks, then the rest by id.
    public func archivePriority() -> [Int] {
        let favs = favorites.enumerated().reduce(into: [Int: Int]()) { m, e in if m[e.element] == nil { m[e.element] = e.offset } }
        let own = Set(mine.map(\.projectId))
        return projects.map(\.id).sorted { a, b in
            let ka = (favs[a] ?? Int.max, -(timeRecords30d[a] ?? 0), own.contains(a) ? 0 : 1, a)
            let kb = (favs[b] ?? Int.max, -(timeRecords30d[b] ?? 0), own.contains(b) ? 0 : 1, b)
            return ka < kb
        }
    }

    /// Counts only (no names), for `acvoice-index --stats`.
    public struct Stats: Sendable, Equatable {
        public var projects = 0, companies = 0, favorites = 0, activeFavorites = 0
        public var ownOpenTasks = 0, ownTaskProjects = 0, timeRecords = 0, timeRecordProjects = 0
        public var taskLists = 0, openTasks = 0, completedIds = 0, trashedIds = 0, taskIds = 0
        public var archivedTasks = 0, unreachable = 0, archiveComplete = 0, probed = 0
    }

    public var stats: Stats {
        var s = Stats()
        let active = Set(projectIds)
        s.projects = projects.count; s.companies = companies.count
        s.favorites = favorites.count; s.activeFavorites = favorites.filter(active.contains).count
        s.ownOpenTasks = mine.count; s.ownTaskProjects = Set(mine.map(\.projectId)).count
        s.timeRecords = timeRecords30d.values.reduce(0, +); s.timeRecordProjects = timeRecords30d.count
        s.taskLists = projectTasks.values.filter { $0.fetchedAt != nil }.count
        for st in projectTasks.values {
            s.openTasks += st.open.count; s.completedIds += st.completedIds.count; s.trashedIds += st.trashedIds.count
            s.archivedTasks += st.archived.count; s.unreachable += st.unreachable.count
        }
        s.taskIds = tasks.projectOfTask.count
        s.archiveComplete = tasks.archiveComplete.count
        s.probed = probed.count
        return s
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case version, baseURL, userId, projects, companies, favorites, timeRecords30d, mine, projectTasks, probed
        case etags, fetchedAt, taskListsFetchedAt
    }

    /// Tolerant: missing keys decode as empty. A different `version` fails (the store then starts fresh).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "unsupported cache version")
        }
        baseURL = try c.decodeIfPresent(URL.self, forKey: .baseURL)
        userId = try c.decodeIfPresent(Int.self, forKey: .userId)
        projects = try c.decodeIfPresent([ProjectRecord].self, forKey: .projects) ?? []
        companies = try c.decodeIfPresent([Int: CompanyRecord].self, forKey: .companies) ?? [:]
        favorites = try c.decodeIfPresent([Int].self, forKey: .favorites) ?? []
        timeRecords30d = try c.decodeIfPresent([Int: Int].self, forKey: .timeRecords30d) ?? [:]
        mine = try c.decodeIfPresent([TaskRef].self, forKey: .mine) ?? []
        projectTasks = try c.decodeIfPresent([Int: ProjectTaskState].self, forKey: .projectTasks) ?? [:]
        probed = try c.decodeIfPresent([Int: TaskRef].self, forKey: .probed) ?? [:]
        etags = try c.decodeIfPresent([String: String].self, forKey: .etags) ?? [:]
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
        taskListsFetchedAt = try c.decodeIfPresent(Date.self, forKey: .taskListsFetchedAt)
        rebuildTasks()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(baseURL, forKey: .baseURL)
        try c.encodeIfPresent(userId, forKey: .userId)
        try c.encode(projects, forKey: .projects)
        try c.encode(companies, forKey: .companies)
        try c.encode(favorites, forKey: .favorites)
        try c.encode(timeRecords30d, forKey: .timeRecords30d)
        try c.encode(mine, forKey: .mine)
        try c.encode(projectTasks, forKey: .projectTasks)
        try c.encode(probed, forKey: .probed)
        try c.encode(etags, forKey: .etags)
        try c.encodeIfPresent(fetchedAt, forKey: .fetchedAt)
        try c.encodeIfPresent(taskListsFetchedAt, forKey: .taskListsFetchedAt)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        return try enc.encode(self)
    }

    /// nil for junk, an empty file or another cache version.
    public static func decode(_ data: Data) -> IndexSnapshot? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(IndexSnapshot.self, from: data)
    }
}

/// Spoken aliases from company names (REVIEW M5: "Hollenstein Navigation" needs the company name).
public enum CompanyAliases {
    /// Legal-form words; the name is cut at the first one ("Alpha Beta GmbH & Co. KG" -> "Alpha Beta").
    static let legalForms: Set<String> = [
        "gmbh", "mbh", "ag", "se", "kg", "kgaa", "ohg", "gbr", "ug", "ev", "eg", "gesmbh", "co", "inc", "llc", "ltd",
        "limited", "plc", "corp", "corporation", "sa", "sas", "sarl", "bv", "nv", "spa", "srl", "oy", "ab", "aps",
    ]

    /// The name without legal form and parentheses (1-4 words, at least 3 letters), plus its first two words when
    /// it has three or more ("Alpha Beta Chemie" -> also "Alpha Beta").
    public static func make(_ name: String) -> [String] {
        let plain = name.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        var words: [String] = []
        for raw in plain.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            let w = String(raw)
            let bare = TextNorm.fold(w).filter { $0.isLetter || $0.isNumber }
            if legalForms.contains(bare) { break }
            if w == "&" || w == "+" || bare == "und" { words.append(w); continue }
            if bare.isEmpty { continue }
            words.append(w)
        }
        while let last = words.last, ["&", "+", "und"].contains(last.lowercased()) { words.removeLast() }
        guard !words.isEmpty, words.count <= 4 else { return [] }
        let letters = { (ws: [String]) in ws.joined().filter(\.isLetter).count }
        guard letters(words) >= 3 else { return [] }
        var out = [words.joined(separator: " ")]
        if words.count >= 3 {
            let two = Array(words.prefix(2))
            if !["&", "+", "und"].contains(two[1].lowercased()), letters(two) >= 3 { out.append(two.joined(separator: " ")) }
        }
        return out
    }
}
