import Foundation

/// Local usage history in `AppPaths.history` (history.json). Feeds `Signals.recentOpens`, the learned order of
/// equal matches (`Interpreter.history`) and learned aliases. Decoding is tolerant: junk gives an empty history.
public struct History: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// Opens kept per project.
    public static let maxOpensPerProject = 20
    /// Distinct queries kept; beyond that, the least recently picked queries are dropped first.
    public static let maxQueries = 500

    public var version = History.currentVersion
    /// Project id -> times ac-voice opened it, oldest first.
    public var opens: [Int: [Date]] = [:]
    /// Normalized query (`TextNorm.queryKey`, see `Interpretation.project(_, query:)`) -> project id -> picks
    /// from a choice list.
    public var picks: [String: [Int: Int]] = [:]
    /// Normalized query -> value of `pickClock` at its last pick (LRU order for eviction). Queries from older files
    /// have no entry and count as least recent.
    public var lastPicked: [String: Int] = [:]
    /// Monotonic pick counter.
    public var pickClock = 0

    public init() {}

    public mutating func recordOpen(projectId: Int, at date: Date) {
        var list = opens[projectId, default: []]
        list.append(date)
        list.sort()
        if list.count > Self.maxOpensPerProject { list.removeFirst(list.count - Self.maxOpensPerProject) }
        opens[projectId] = list
    }

    /// Call when the user picks `projectId` from a list shown for `query`, or opens it right after `query` was not
    /// understood (`Interpreter.correctionKey`). Empty queries are ignored.
    /// Beyond `maxQueries`, the least recently picked queries are dropped (fewer picks first on equal age, then
    /// alphabetically), never the query just recorded.
    public mutating func recordPick(query: String, projectId: Int) {
        guard !query.isEmpty else { return }
        picks[query, default: [:]][projectId, default: 0] += 1
        pickClock += 1
        lastPicked[query] = pickClock
        guard picks.count > Self.maxQueries else { return }
        let order = picks.keys.filter { $0 != query }.map { k in
            (k: k, age: lastPicked[k] ?? 0, total: picks[k]!.values.reduce(0, +))
        }.sorted { a, b in
            if a.age != b.age { return a.age < b.age }
            if a.total != b.total { return a.total < b.total }
            return a.k < b.k
        }
        for e in order.prefix(picks.count - Self.maxQueries) { picks[e.k] = nil; lastPicked[e.k] = nil }
    }

    public func recentOpens(_ projectId: Int) -> [Date] { opens[projectId] ?? [] }

    /// Project id -> picks for this normalized query; pass to `Resolver.decide(learned:)`.
    public func picks(for query: String) -> [Int: Int] { picks[query] ?? [:] }

    /// Self-healing aliases (REVIEW m9). For each heard query whose most picked project was picked at least
    /// `minPicks` times (and more often than any project with another code), the query words that this project's
    /// code and title do not explain become an alias for its code:
    /// "eben betreuung" picked twice for "IBN: Betreuung …" -> ["IBN": ["eben"]]. A glued word explained by a
    /// title suffix contributes its prefix ("ebenbetreuung" -> "eben").
    /// No alias is produced when nothing is left over, when the leftover is longer than 3 words or shorter than
    /// 3 characters, when it is a code (or an alias of another code) already, or when it holds only everyday
    /// particles ("schon", "gleich", "aber", see `particles`).
    /// The query must not contain the project's code or an existing alias: an alias stands in for a code STT
    /// missed, so when the code was heard ("wwt schon"), the leftover is noise.
    /// Output keys are codes as written in AC, values sorted; merge it into `Config.aliases`.
    public func learnedAliases(projects: [ProjectEntry], minPicks: Int = 2) -> [String: [String]] {
        let byId = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let resolver = Resolver(projects: projects)
        let codeKeys = Set(projects.compactMap { $0.code.map(ProjectEntry.codeKey) })
        var aliasOwner: [String: String] = [:]   // existing alias text -> code key
        for p in projects { if let c = p.code { for a in p.aliases { aliasOwner[TextNorm.queryKey(TextNorm.tokenize(a))] = ProjectEntry.codeKey(c) } } }

        var out: [String: Set<String>] = [:]
        for query in picks.keys.sorted() {
            let counts = picks[query]!
            guard let (pid, n) = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
                  n >= minPicks, let p = byId[pid], let code = p.code else { continue }
            let codeKey = ProjectEntry.codeKey(code)
            // Another code picked as often makes the query ambiguous.
            let rival = counts.contains { $0.key != pid && $0.value >= n && byId[$0.key].flatMap(\.code).map(ProjectEntry.codeKey) != codeKey }
            if rival { continue }

            let tokens = TextNorm.tokenize(query)
            // No score at all ("imben" alone): nothing is explained, the whole query is the residue.
            let scored = resolver.score(tokens, within: [pid]).first
            if let hit = scored?.codeHit, hit == .exact || hit == .alias { continue }
            let indexed = resolver.projects.first { $0.id == pid } ?? p   // canonical title keys
            guard let alias = Self.residue(tokens, explained: scored?.got ?? [], project: indexed),
                  !codeKeys.contains(alias), aliasOwner[alias] == nil,
                  !alias.split(separator: " ").allSatisfy({ Self.particles.contains(String($0)) }) else { continue }
            out[code, default: []].insert(alias)
        }
        return out.mapValues { $0.sorted() }
    }

    /// Everyday words that never become an alias. "eben" is missing on purpose: STT hears "IBN" as "eben".
    static let particles: Set<String> = Parser.softFillers.union([
        "doch", "mal", "denn", "wohl", "nur", "noch", "bitte", "jetzt", "dann", "also", "so", "sehr", "hallo", "hey",
    ])

    /// Unexplained query words; a glued word whose suffix is a title word contributes its prefix.
    static func residue(_ tokens: [Token], explained: Set<Int>, project p: ProjectEntry) -> String? {
        var words: [String] = []
        for (i, t) in tokens.enumerated() {
            let k = t.key
            if !explained.contains(i) { words.append(k); continue }
            if !p.titleKeys.contains(k), !p.codeSeqs.contains(where: { $0.contains(k) }),
               let suffix = p.titleKeys.filter({ $0.count >= 6 && k.count > $0.count && k.hasSuffix($0) }).max(by: { $0.count < $1.count }) {
                words.append(String(k.dropLast(suffix.count)))
            }
        }
        let alias = words.filter { !$0.isEmpty }.joined(separator: " ")
        guard !alias.isEmpty, words.count <= 3, alias.count >= 3 else { return nil }
        return alias
    }

    enum CodingKeys: String, CodingKey { case version, opens, picks, lastPicked, pickClock }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        opens = (try? c.decodeIfPresent([Int: [Date]].self, forKey: .opens)) ?? [:]
        picks = (try? c.decodeIfPresent([String: [Int: Int]].self, forKey: .picks)) ?? [:]
        // Files without these keys (first version) decode with every query as least recent.
        lastPicked = ((try? c.decodeIfPresent([String: Int].self, forKey: .lastPicked)) ?? [:]).filter { picks[$0.key] != nil }
        pickClock = max((try? c.decodeIfPresent(Int.self, forKey: .pickClock)) ?? 0, lastPicked.values.max() ?? 0)
    }

    static func coder() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder(), dec = JSONDecoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601; dec.dateDecodingStrategy = .iso8601
        return (enc, dec)
    }

    public static func decode(_ data: Data) -> History { (try? coder().1.decode(History.self, from: data)) ?? History() }
    public func encoded() -> Data { (try? Self.coder().0.encode(self)) ?? Data("{}".utf8) }
    public static func load(from url: URL = AppPaths.history) -> History { (try? Data(contentsOf: url)).map(decode) ?? History() }
    public func save(to url: URL = AppPaths.history) throws {
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        try encoded().write(to: url, options: .atomic)
    }
}
