import Foundation

/// Personal relevance signals, refreshed from AC and the local open history.
public struct Signals: Sendable, Codable, Hashable {
    public var favorite = false
    /// Own time records in the last 30 days.
    public var timeRecords30d = 0
    /// Own open tasks in the project.
    public var ownOpenTasks = 0
    /// Team activity (`last_activity_on`). Only used coarsely: a project idle for `staleAfterDays` ranks lower.
    public var lastActivity: Date? = nil
    /// Opens triggered by ac-voice, newest last (see `History.opens`).
    public var recentOpens: [Date] = []
    public init(favorite: Bool = false, timeRecords30d: Int = 0, ownOpenTasks: Int = 0,
                lastActivity: Date? = nil, recentOpens: [Date] = []) {
        self.favorite = favorite; self.timeRecords30d = timeRecords30d; self.ownOpenTasks = ownOpenTasks
        self.lastActivity = lastActivity; self.recentOpens = recentOpens
    }

    public static let staleAfterDays = 180.0
    public static let recentOpenDays = 30.0

    /// Coarse personal rank, higher first (REVIEW M5). Integer buckets so the order of equal text matches does not
    /// drift from day to day; team activity only counts once a project has been idle for half a year.
    /// favorite +3; own time records (30 d) >= 10: +3, >= 3: +2, >= 1: +1; own open tasks +1;
    /// ac-voice opens (30 d) >= 3: +2, >= 1: +1; idle >= 180 d: -1.
    /// Only orders candidates; never turns a list into an open.
    public func tier(now: Date) -> Int {
        var t = favorite ? 3 : 0
        switch timeRecords30d {
        case 10...: t += 3
        case 3...: t += 2
        case 1...: t += 1
        default: break
        }
        if ownOpenTasks > 0 { t += 1 }
        let opens = recentOpens.filter { now.timeIntervalSince($0) <= Self.recentOpenDays * 86_400 }.count
        t += opens >= 3 ? 2 : (opens >= 1 ? 1 : 0)
        if let la = lastActivity, now.timeIntervalSince(la) >= Self.staleAfterDays * 86_400 { t -= 1 }
        return t
    }
}

/// One AC project, parsed from "CODE: Title [TYPE]" and precompiled for matching.
public struct ProjectEntry: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    /// "WWT", "S+K", "Hollenstein TS"; nil when the name has no code.
    public let code: String?
    public let title: String
    /// "AGIL", "SLA", "INT", "FIX", "CR".
    public let type: String?
    public var signals: Signals
    /// Spoken aliases for this project: config aliases of its code, learned aliases and the company name.
    public var aliases: [String] { didSet { aliasSeqs = Self.aliasSequences(aliases) } }

    let codeSeqs: [[String]]
    /// Title keys. `Resolver.init` rewrites them to canonical forms shared across projects.
    var titleKeys: [String]
    var titleCologne: [String]
    let typeKey: String?
    private(set) var aliasSeqs: [[String]]

    static let titleStop: Set<String> = ["der", "die", "das", "und", "of", "the", "for", "fur", "von", "a", "an", "to"]

    public init(id: Int, name: String, signals: Signals = .init(), aliases: [String] = []) {
        self.id = id; self.name = name; self.signals = signals; self.aliases = aliases
        var rest = name.trimmingCharacters(in: .whitespaces)
        var type: String? = nil
        if let m = rest.firstMatch(of: /\s*\[([A-Za-z]+)\]\s*$/) {
            type = String(m.1).uppercased(); rest.removeSubrange(m.range)
        }
        var code: String? = nil
        if let colon = rest.firstIndex(of: ":") {
            code = rest[..<colon].trimmingCharacters(in: .whitespaces)
            rest = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else if let first = rest.split(separator: " ").first, first.count >= 2, first.count <= 5,
                  first.allSatisfy({ $0.isUppercase || $0 == "+" || $0 == "&" }) {
            // "QZ Dashboard": a leading acronym acts as the code.
            code = String(first); rest = String(rest.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
        }
        self.code = code; self.title = rest; self.type = type
        typeKey = type?.lowercased()

        if let code {
            let keys = TextNorm.tokenize(code).map(\.key).filter { !$0.isEmpty }
            // "Hollenstein & Co" is also said "Hollenstein und Co".
            let withUnd = TextNorm.tokenize(code.replacingOccurrences(of: "&", with: " und ")).map(\.key).filter { !$0.isEmpty }
            codeSeqs = Array(Set([keys, withUnd])).filter { !$0.isEmpty }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1) }
        } else { codeSeqs = [] }
        titleKeys = TextNorm.tokenize(Self.dropVersionFractions(rest)).map(\.key).filter { !$0.isEmpty && !Self.titleStop.contains($0) }
        titleCologne = titleKeys.map(Fuzzy.cologne)
        aliasSeqs = Self.aliasSequences(aliases)
    }

    /// Comparison key of a code as written in config ("S+K" -> "sk", "Hollenstein TS" -> "hollenstein ts").
    public static func codeKey(_ code: String) -> String {
        TextNorm.queryKey(TextNorm.tokenize(code))
    }

    /// Adds the aliases configured for this project's code (`Config.aliases`, `History.learnedAliases`).
    /// Keys are codes as written ("IBN", "S+K"); matching ignores case and punctuation.
    public func addingAliases(byCode map: [String: [String]]) -> ProjectEntry {
        guard let code else { return self }
        let mine = Self.codeKey(code)
        let extra = map.filter { Self.codeKey($0.key) == mine }.flatMap(\.value)
        guard !extra.isEmpty else { return self }
        var copy = self
        var seen = Set(aliases)
        copy.aliases = aliases + extra.filter { seen.insert($0).inserted }
        return copy
    }

    /// "Release 2024.3" -> "Release 2024", "Shop 2.0" -> "Shop 2", "v12.4" -> "v12". Otherwise the minor part becomes
    /// a title word of its own and explains a spoken ticket number ("Öffne RBZ 3" opened the project).
    /// Thousands groups ("47.285") and dates ("21.09.2026") stay intact.
    static func dropVersionFractions(_ title: String) -> String {
        title.replacingOccurrences(of: #"(?<![\d.,])(\d+)[.,]\d{1,2}(?![\d]|[.,]\d)"#, with: "$1", options: .regularExpression)
    }

    static func aliasSequences(_ aliases: [String]) -> [[String]] {
        aliases.map { TextNorm.tokenize($0).map(\.key).filter { !$0.isEmpty } }.filter { !$0.isEmpty }
    }

    /// Key of a single-token code, used for fuzzy code matching ("WWD" -> WWT).
    var singleCodeKey: String? { codeSeqs.first(where: { $0.count == 1 })?.first }
}

/// A project list as JSON, used by test fixtures and `acvoice-resolve --json`.
///
/// The committed sample is `Tests/Fixtures/projects.sample.json`: fantasy codes and titles that mirror the collision
/// structure of a real list of about 60 projects (see its "comment"). Any test target can load it relative to its
/// own source file:
/// ```swift
/// let url = URL(fileURLWithPath: #filePath)          // Tests/<Target>/<File>.swift
///     .deletingLastPathComponent().deletingLastPathComponent()
///     .appendingPathComponent("Fixtures/projects.sample.json")
/// let catalog = try ProjectCatalog.load(url)
/// let projects = catalog.entries(now: catalog.referenceDate)
/// ```
public struct ProjectCatalog: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var id: Int
        public var name: String
        public var favorite: Bool?
        public var timeRecords30d: Int?
        public var ownOpenTasks: Int?
        /// Team activity age in days relative to the `now` passed to `entries(now:)`.
        public var lastActivityDaysAgo: Double?
        /// Ages in days of earlier ac-voice opens.
        public var recentOpenDaysAgo: [Double]?
        public init(id: Int, name: String) { self.id = id; self.name = name }
    }

    public var comment: String?
    /// Fixed "now" for deterministic tests (ISO 8601 in JSON).
    public var referenceDate: Date
    /// Spoken aliases per code, same shape as `Config.aliases`.
    public var aliases: [String: [String]]
    public var projects: [Item]

    public static func load(_ url: URL) throws -> ProjectCatalog {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(ProjectCatalog.self, from: Data(contentsOf: url))
    }

    /// Entries with signals relative to `now`. `aliases` overrides the catalog's aliases (pass [:] for none).
    public func entries(now: Date, aliases: [String: [String]]? = nil) -> [ProjectEntry] {
        let map = aliases ?? self.aliases
        return projects.map { item in
            let days = { (d: Double) in now.addingTimeInterval(-d * 86_400) }
            let s = Signals(favorite: item.favorite ?? false, timeRecords30d: item.timeRecords30d ?? 0,
                            ownOpenTasks: item.ownOpenTasks ?? 0, lastActivity: item.lastActivityDaysAgo.map(days),
                            recentOpens: (item.recentOpenDaysAgo ?? []).map(days).sorted())
            return ProjectEntry(id: item.id, name: item.name, signals: s).addingAliases(byCode: map)
        }
    }

    /// Plain "id<TAB>name" lines (the private real-name list). Lines without a numeric id are skipped.
    public static func entries(tsv: String) -> [ProjectEntry] {
        tsv.split(whereSeparator: \.isNewline).compactMap { line -> ProjectEntry? in
            let f = line.split(separator: "\t", maxSplits: 1)
            guard f.count == 2, let id = Int(f[0].trimmingCharacters(in: .whitespaces)) else { return nil }
            return ProjectEntry(id: id, name: String(f[1]))
        }
    }
}
