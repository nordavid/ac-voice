import Foundation

public enum CodeHit: Int, Sendable, Comparable {
    case none, fuzzy, partial, alias, exact
    public static func < (a: CodeHit, b: CodeHit) -> Bool { a.rawValue < b.rawValue }
}

public struct Scored: Sendable, Equatable {
    public let project: ProjectEntry
    public var text: Double
    public var codeHit: CodeHit
    /// Part of `text` that comes from title/alias/type words (not the code).
    public var titleEvidence: Double
    public var matched: Int
    public var queryCount: Int
    /// `Signals.tier`: coarse personal rank, only orders equal text matches.
    public var tier: Int
    /// Earlier picks of this project for the same normalized query (`History.picks`), set by `decide`.
    public var learned: Int = 0
    /// Indices of the caller's query tokens this project explains (code, alias, title or type).
    public var got: Set<Int> = []
    public var coverage: Double { queryCount == 0 ? 0 : Double(matched) / Double(queryCount) }

    /// Text score in steps of 0.1. Differences below that come only from the partial-title bonus and must not
    /// override learned picks or personal signals.
    public var textBand: Int { Int((text * 10 + 1e-6).rounded(.down)) }

    /// Stable order (REVIEW M5): text band, then learned picks, then the personal tier, then the project id.
    public static func ranksBefore(_ a: Scored, _ b: Scored) -> Bool {
        if a.textBand != b.textBand { return a.textBand > b.textBand }
        if a.learned != b.learned { return a.learned > b.learned }
        if a.tier != b.tier { return a.tier > b.tier }
        return a.project.id < b.project.id
    }
}

public enum Resolution: Sendable, Equatable {
    case unique(Scored)
    /// Sorted best first (`Scored.ranksBefore`). Paging is up to the caller.
    case ambiguous([Scored])
    case none(best: Scored?)

    /// The unique hit or the ranked list; empty for `.none`.
    public var candidates: [Scored] {
        switch self {
        case .unique(let s): return [s]
        case .ambiguous(let l): return l
        case .none: return []
        }
    }
    public var projectIds: [Int] { candidates.map(\.project.id) }
}

public struct ResolverConfig: Sendable {
    public var codeExact = 3.0, codeAlias = 2.5, codePartial = 3.0, codeFuzzy = 1.5
    public var wExact = 1.0, wSynonym = 0.9, wPrefix = 0.8, wPhonetic = 0.7, wEdit = 0.6
    public var wTitleBigram = 1.8, wTitleBigramFuzzy = 1.4, wType = 0.5
    /// Product decision (REVIEW M5): a query that covers a whole title wins over a longer title with the same word.
    /// "WWT Wartung" opens "WWT: Maintenance" and does not list "WWT: TYPO3 Website maintenance".
    /// Set it to `epsilon` or lower to list both instead.
    public var fullTitleBonus = 0.4
    /// Minimum text score and query coverage for any action.
    public var minScore = 0.9, minCoverage = 0.5
    /// Inside a visible list of at most a few candidates, one phonetic title hit is enough ("Relonch").
    public var minSelectScore = 0.6
    /// Candidates within this text distance of the top one are "the same" -> choices.
    public var epsilon = 0.3
    /// Title tokens of at least this length that differ by one edit are one canonical word ("TourenpPlaner").
    public var canonicalMinLength = 8
    /// Generic German words for English title words. Words for one customer's titles go to `Config.synonyms`.
    public var synonyms: [String: [String]] = [
        "wartung": ["maintenance"], "pflege": ["maintenance"], "webseite": ["website"], "homepage": ["website"],
        "internetseite": ["website"],
    ]
    public var typeSynonyms: [String: String] = ["intern": "int", "interne": "int", "internal": "int", "agile": "agil", "support": "sla"]
    /// Language of the spoken queries: picks the phonetic key (Koelner Phonetik or `Fuzzy.metaphone`) and the number
    /// words ("funfundvierzig" or "forty five" = "45"). `Interpreter` keeps it in line with its own language.
    public var language: AppLanguage = .de
    public init() {}

    /// Defaults plus `extra` (`Config.synonyms`); the words of both lists count for a shared key.
    public init(synonyms extra: [String: [String]]) {
        for (k, v) in extra {
            let key = TextNorm.fold(k)
            let words = v.map(TextNorm.fold)
            synonyms[key] = (synonyms[key] ?? []) + words.filter { !(synonyms[key] ?? []).contains($0) }
        }
    }
}

/// Deterministic fuzzy matcher over "CODE: Title [TYPE]" project names.
public struct Resolver: Sendable {
    /// Projects with canonical title keys. Build a new `Resolver` when the list or the signals change (cheap).
    public let projects: [ProjectEntry]
    public var config: ResolverConfig
    /// Title-token variant -> canonical form ("tourenpplaner" -> "tourenplaner").
    let canonical: [String: String]
    /// Prefixes for splitting glued query tokens: single code words and alias words ("qz", "eben").
    let splitPrefixes: [String]
    /// Every code, alias and title word. Known words are never split.
    let knownKeys: Set<String>
    let titleKeySet: Set<String>
    let codeWordKeys: Set<String>

    public init(projects: [ProjectEntry], config: ResolverConfig = .init()) {
        self.config = config
        let (entries, canonical) = Self.canonicalize(projects, minLength: config.canonicalMinLength)
        self.projects = entries
        self.canonical = canonical
        let titles = Set(entries.flatMap(\.titleKeys))
        let codeWords = Set(entries.flatMap { $0.codeSeqs.flatMap { $0 } })
        let aliasWords = Set(entries.flatMap { $0.aliasSeqs.flatMap { $0 } })
        titleKeySet = titles
        codeWordKeys = codeWords
        knownKeys = titles.union(codeWords).union(aliasWords)
        splitPrefixes = codeWords.filter { $0.count >= 2 }.union(aliasWords.filter { $0.count >= 3 })
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    // MARK: - Index-time canonicalization (REVIEW M5)

    /// 1. Glue: a title word pair that another title spells as one word becomes that word ("Touren Planer" -> "tourenplaner").
    /// 2. Typos: words of at least `minLength` characters within one edit form one cluster ("tourenpplaner" ~ "tourenplaner").
    ///    The representative is the most frequent form, then the shortest, then the alphabetically first.
    static func canonicalize(_ projects: [ProjectEntry], minLength: Int) -> ([ProjectEntry], [String: String]) {
        var entries = projects
        let singles = Set(projects.flatMap(\.titleKeys))
        for e in entries.indices {
            var keys = entries[e].titleKeys, i = 0
            while i + 1 < keys.count {
                let glued = keys[i] + keys[i + 1]
                if glued.count >= 6, singles.contains(glued) { keys.replaceSubrange(i...(i + 1), with: [glued]) }
                i += 1
            }
            entries[e].titleKeys = keys
        }

        var freq: [String: Int] = [:]
        for e in entries { for k in e.titleKeys { freq[k, default: 0] += 1 } }
        let long = freq.keys.filter { $0.count >= minLength && !$0.allSatisfy(\.isNumber) }.sorted()
        var parent = Dictionary(uniqueKeysWithValues: long.map { ($0, $0) })
        func root(_ k: String) -> String { var k = k; while parent[k]! != k { k = parent[k]! }; return k }
        for (i, a) in long.enumerated() {
            for b in long[(i + 1)...] where abs(a.count - b.count) <= 1 && Fuzzy.osa(a, b, cap: 1) <= 1 {
                let ra = root(a), rb = root(b)
                if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
            }
        }
        var clusters: [String: [String]] = [:]
        for k in long { clusters[root(k), default: []].append(k) }
        var map: [String: String] = [:]
        for members in clusters.values where members.count > 1 {
            let rep = members.min { a, b in
                let fa = freq[a]!, fb = freq[b]!
                if fa != fb { return fa > fb }
                if a.count != b.count { return a.count < b.count }
                return a < b
            }!
            for m in members where m != rep { map[m] = rep }
        }
        if !map.isEmpty {
            for e in entries.indices {
                entries[e].titleKeys = entries[e].titleKeys.map { map[$0] ?? $0 }
                entries[e].titleCologne = entries[e].titleKeys.map(Fuzzy.cologne)
                entries[e].titleMetaphone = entries[e].titleKeys.map(Fuzzy.metaphone)
            }
        }
        return (entries, map)
    }

    // MARK: - Query preparation

    /// Canonical title spellings and glued tokens split at a known code or alias prefix (REVIEW m8):
    /// "qzcrm" (from "Q Z C R M") -> "qz crm", "ebenbetreuung" with alias "eben" -> "eben betreuung".
    /// Splits only unknown tokens whose remainder is an exact title or code word.
    /// English: a number of several words is one word ("forty five" -> "45"), as German glues it ("funfundvierzig").
    /// `origin[i]` are the indices of the caller's tokens that prepared token `i` came from.
    func prepare(_ q: [Token]) -> (tokens: [Token], origin: [[Int]]) {
        var out: [Token] = [], origin: [[Int]] = []
        var numbers: [Int: (end: Int, value: Int)] = [:]
        if config.language == .en {
            for run in Parser.numeralRuns(q, .en) where run.range.count > 1 {
                numbers[run.range.lowerBound] = (run.range.upperBound, run.value)
            }
        }
        var i = 0
        while i < q.count {
            defer { i += 1 }
            if let n = numbers[i] {
                out.append(Token(text: String(n.value))); origin.append(Array(i..<n.end))
                i = n.end - 1
                continue
            }
            let t = q[i], k = t.key
            if let c = canonical[k] { out.append(Token(text: c)); origin.append([i]); continue }
            if k.count >= 4, !knownKeys.contains(k), !k.allSatisfy(\.isNumber),
               let p = splitPrefixes.first(where: { k.hasPrefix($0) && k.count - $0.count >= 2
                   && (titleKeySet.contains(String(k.dropFirst($0.count))) || codeWordKeys.contains(String(k.dropFirst($0.count)))) }) {
                let rest = String(k.dropFirst(p.count))
                out.append(Token(text: p, isAcronym: t.isAcronym)); origin.append([i])
                out.append(Token(text: canonical[rest] ?? rest, isAcronym: t.isAcronym && rest.count <= 4)); origin.append([i])
                continue
            }
            out.append(t); origin.append([i])
        }
        return (out, origin)
    }

    // MARK: - Scoring

    /// Scores every project (optionally only `within`) for filler-free query tokens. `got` refers to `q`'s indices.
    public func score(_ q: [Token], within: Set<Int>? = nil, now: Date = .now) -> [Scored] {
        guard !q.isEmpty else { return [] }
        let (pq, origin) = prepare(q)
        let prepared = Prepared(pq, language: config.language)
        var all = projects.filter { within?.contains($0.id) ?? true }.map { score(prepared, $0, now: now) }.filter { $0.text > 0 }
        // An exact code anywhere outranks lookalike codes: drop fuzzy code credit ("WKT" when "WWT" was said exactly).
        if all.contains(where: { $0.codeHit == .exact }) {
            let exactEvidence = all.filter { $0.codeHit == .exact }.map(\.titleEvidence).max() ?? 0
            all = all.compactMap { s in
                // A lookalike that explains title words the exact-code projects miss ("WKT Relaunch" -> WWT Relaunch)
                // gets near-exact code credit, so it lands in the same list instead of vanishing.
                if s.codeHit == .fuzzy, s.titleEvidence > exactEvidence { var t = s; t.text += 0.5; return t }
                guard s.codeHit == .fuzzy else { return s }
                // Rescore without code credit; the lookalike token may still match a title word.
                let rescored = score(prepared, s.project, now: now, skipCode: true)
                return rescored.text > 0 ? rescored : nil
            }
        }
        // Report coverage and explained tokens in the caller's token space.
        return all.map { s in
            var t = s
            t.got = Set(s.got.flatMap { origin[$0] })
            t.queryCount = q.count
            t.matched = t.got.count
            return t
        }
    }

    /// Merges scores from several STT hypotheses: per project, keep the best weighted result.
    public static func merge(_ lists: [(weight: Double, scored: [Scored])]) -> [Scored] {
        var best: [Int: Scored] = [:]
        for (w, list) in lists {
            for var s in list {
                s.text *= w
                if let cur = best[s.project.id], cur.text >= s.text { continue }
                best[s.project.id] = s
            }
        }
        return best.values.sorted(by: Scored.ranksBefore)
    }

    /// `inList`: the answer phase of a visible list uses the lower `config.minSelectScore` and may narrow on
    /// partial matches. `learned` maps project id -> earlier picks for this query (`History.picks(for:)`); it only
    /// orders the list.
    public func decide(_ scored: [Scored], inList: Bool = false, learned: [Int: Int] = [:]) -> Resolution {
        let sorted = scored.map { s -> Scored in var t = s; t.learned = learned[s.project.id] ?? 0; return t }
            .sorted(by: Scored.ranksBefore)
        guard let top = sorted.max(by: { $0.text != $1.text ? $0.text < $1.text : $0.project.id > $1.project.id })
        else { return .none(best: nil) }
        guard top.text >= (inList ? config.minSelectScore : config.minScore), top.coverage >= config.minCoverage
        else { return .none(best: top) }
        let near = sorted.filter { $0.text >= top.text - config.epsilon }
        // Without a code, a partial match must point at one project: "Braun Navigation" opens, while "App TV" (a
        // common title word plus noise) is not understood instead of listing every "App" project.
        if !inList, near.count > 1, top.codeHit == .none, top.coverage < 1 { return .none(best: top) }
        // Never auto-open on a lookalike code without supporting title words.
        if near.count == 1, !(top.codeHit == .fuzzy && top.titleEvidence < 1.0) { return .unique(top) }
        return .ambiguous(near)
    }

    public func resolve(_ q: [Token], within: Set<Int>? = nil, now: Date = .now, learned: [Int: Int] = [:]) -> Resolution {
        decide(score(q, within: within, now: now), learned: learned)
    }

    // MARK: - Per-project scoring

    /// Per-token values computed once per query instead of once per project.
    struct Prepared {
        let tokens: [Token], keys: [String], phonetic: [String], numbers: [Int?]
        let language: AppLanguage
        init(_ q: [Token], language: AppLanguage) {
            tokens = q; keys = q.map(\.key); self.language = language
            phonetic = keys.map { Fuzzy.phonetic($0, language: language) }
            numbers = keys.map(language == .de ? GermanNumbers.cardinal : EnglishNumbers.cardinal)
        }
    }

    private func score(_ prepared: Prepared, _ p: ProjectEntry, now: Date, skipCode: Bool = false) -> Scored {
        let q = prepared.tokens, keys = prepared.keys
        var used = [Bool](repeating: false, count: q.count)
        var text = 0.0, hit = CodeHit.none, matched = 0
        var got = Set<Int>()

        func take(_ seq: [String]) -> Bool {
            guard !seq.isEmpty, seq.count <= keys.count else { return false }
            for at in 0...(keys.count - seq.count) where (at..<(at + seq.count)).allSatisfy({ !used[$0] }) {
                if Array(keys[at..<(at + seq.count)]) == seq {
                    for k in at..<(at + seq.count) { used[k] = true; got.insert(k) }
                    matched += seq.count
                    return true
                }
            }
            return false
        }

        if let seq = p.codeSeqs.first(where: take) { text += config.codeExact + 1.0 * Double(seq.count - 1); hit = .exact }
        if hit == .none, p.spokenAliasSeqs(config.language).contains(where: take) { text += config.codeAlias; hit = .alias }
        if hit == .none, let seq = p.codeSeqs.last, seq.count > 1 {
            // Multi-word code ("Hollenstein TS"): credit the words present.
            var n = 0
            for word in seq where word.count >= 2 {
                if let i = keys.indices.first(where: { !used[$0] && keys[$0] == word }) { used[i] = true; got.insert(i); n += 1 }
            }
            if n > 0 { text += 1.5 + 1.0 * Double(n - 1); hit = .partial; matched += n }
        }
        if hit == .none, !skipCode, let c = p.singleCodeKey, c.count >= 3 {
            if let i = keys.indices.first(where: { !used[$0] && (q[$0].isAcronym || keys[$0].count <= 4)
                && keys[$0].count >= 3 && Fuzzy.osa(keys[$0], c, cap: 1) == 1 }) {
                used[i] = true; got.insert(i); text += config.codeFuzzy; hit = .fuzzy; matched += 1
            }
        }

        var titleUsed = [Bool](repeating: false, count: p.titleKeys.count)
        var evidence = 0.0
        for i in q.indices where !used[i] {
            let k = keys[i]
            guard !k.isEmpty else { continue }
            // Query bigram vs one title word: "typo 3" / "typo drei" -> "typo3".
            if i + 1 < q.count, !used[i + 1] {
                let next = keys[i + 1]
                let digits = prepared.numbers[i + 1].map(String.init)
                if let j = p.titleKeys.indices.first(where: { !titleUsed[$0]
                    && (p.titleKeys[$0] == k + next || (digits != nil && p.titleKeys[$0] == k + digits!)) }) {
                    used[i] = true; used[i + 1] = true; titleUsed[j] = true; got.formUnion([i, i + 1])
                    evidence += config.wExact; matched += 2; continue
                }
            }
            var best = 0.0, bestJ: [Int] = []
            let kc = prepared.phonetic[i]
            let titlePhonetic = p.titlePhonetic(prepared.language)
            let kNumber = prepared.numbers[i]
            for j in p.titleKeys.indices where !titleUsed[j] {
                let t = p.titleKeys[j]
                var s = 0.0
                if t == k || (kNumber != nil && Int(t) == kNumber) { s = config.wExact }   // "funfundvierzig" = "45"
                else if config.synonyms[k]?.contains(t) == true { s = config.wSynonym }
                else if k.count >= 3, t.count >= 4, t.hasPrefix(k) || (k.hasPrefix(t)) { s = config.wPrefix }
                else if k.count >= 4, kc == titlePhonetic[j], !kc.isEmpty { s = config.wPhonetic }
                else if t.count >= 6, k.count > t.count, k.hasSuffix(t) { s = config.wPhonetic }   // compound: "ebenbetreuung"
                else if (k.count >= 4 && Fuzzy.osa(k, t, cap: 1) <= 1) || (k.count >= 7 && Fuzzy.osa(k, t, cap: 2) <= 2) { s = config.wEdit }
                if s > best { best = s; bestJ = [j] }
                // One query word for two title words: "grantnavigation" -> "grand navigation".
                if j + 1 < p.titleKeys.count, !titleUsed[j + 1], k.count >= 8 {
                    let cat = t + p.titleKeys[j + 1]
                    let b = cat == k ? config.wTitleBigram : (Fuzzy.osa(k, cat, cap: 2) <= 2 ? config.wTitleBigramFuzzy : 0)
                    if b > best { best = b; bestJ = [j, j + 1] }
                }
            }
            if best == 0, let tk = p.typeKey, tk == k || config.typeSynonyms[k] == tk { best = config.wType }
            if best > 0 {
                used[i] = true; got.insert(i); matched += 1; evidence += best
                for j in bestJ { titleUsed[j] = true }
            }
        }
        if !p.titleKeys.isEmpty {
            let usedTitle = titleUsed.filter { $0 }.count
            if usedTitle == p.titleKeys.count { evidence += config.fullTitleBonus }
            else if usedTitle > 0 { evidence += 0.1 * Double(usedTitle) / Double(p.titleKeys.count) }
        }
        text += evidence
        return Scored(project: p, text: text, codeHit: hit, titleEvidence: evidence, matched: matched,
                      queryCount: q.count, tier: p.signals.tier(now: now), got: got)
    }
}
