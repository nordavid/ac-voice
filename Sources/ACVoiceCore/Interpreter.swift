import Foundation

/// One STT text. Best results of both transcribers weigh 1.0, alternatives 0.9.
public struct Hypothesis: Sendable, Equatable, Codable {
    public var text: String
    public var weight: Double
    public init(_ text: String, weight: Double = 1.0) { self.text = text; self.weight = weight }
}

/// A ticket command, ready for `TicketResolver` (or `Interpreter.ticket`).
public struct TaskRequest: Sendable, Equatable {
    /// Task number inside a project, or a global task id when >= `TicketResolver.globalIdThreshold`.
    public var number: Int
    /// nil: no project words were spoken. `.none`: project words were spoken but matched nothing; the resolver
    /// then answers `.projectNotRecognized` and never widens the search (REVIEW M6).
    public var projects: Resolution?
    /// Normalized project words ("wwt relaunch"), empty when none were spoken.
    public var query: String
    /// False when numerals were heard that are neither part of `number` nor explained by a project title
    /// ("Ticket 412 und 5"). The resolver then lists a single hit for confirmation instead of opening it.
    public var confident: Bool
    /// True for "<project> <number>" without the word "Ticket" ("Öffne WWT 412").
    public var implicit: Bool
    public init(number: Int, projects: Resolution? = nil, query: String = "", confident: Bool = true, implicit: Bool = false) {
        self.number = number; self.projects = projects; self.query = query; self.confident = confident; self.implicit = implicit
    }
}

public enum Interpretation: Sendable, Equatable {
    case myTasks
    /// `.unique` -> open, `.ambiguous` -> numbered list (never auto-open). `query` is the normalized query for
    /// `History.recordPick(query:projectId:)` when the user picks from the list.
    case project(Resolution, query: String)
    case task(TaskRequest)
    case cancel
    case notUnderstood(heard: String)
}

extension Interpretation {
    /// A complete intent: my tasks, a unique project, or a confident ticket with no project words or one project.
    /// A live partial with such a preview ends after the short hangover (`HangoverPolicy.fast`).
    public var isCompleteIntent: Bool {
        switch self {
        case .myTasks, .project(.unique, _):
            return true
        case .task(let r):
            guard r.confident else { return false }
            if r.projects == nil { return true }
            if case .unique? = r.projects { return true }
            return false
        default:
            return false
        }
    }
}

public enum SelectionOutcome: Sendable, Equatable {
    case pick(Int)            // 0-based index into the full candidate list
    case narrow([Int])        // 0-based indices that still match
    case cancel, more
    /// "nein" alone, or "ja" while several items are visible: keep the mic open, show nothing new and do not count
    /// a failed attempt (REVIEW m3).
    case keepListening
    /// Not understood: hint "Sag eine Zahl"; counts as a failed attempt.
    case unclear
    case command(Command)
}

public struct Interpreter: Sendable {
    public var resolver: Resolver
    /// Learned picks order equal matches. Replace it after `History.recordPick`.
    public var history: History
    public init(resolver: Resolver, history: History = .init()) { self.resolver = resolver; self.history = history }

    /// The app's interpreter in one call: `Interpreter.entries(projects, config:, history:)`, `config.synonyms` and the
    /// history's learned picks. Rebuild it whenever the index snapshot, the config or the history changes.
    public init(projects: [ProjectEntry], config: Config, history: History) {
        self.init(resolver: Resolver(projects: Self.entries(projects, config: config, history: history),
                                     config: ResolverConfig(synonyms: config.synonyms)), history: history)
    }

    /// Index entries (AC signals, company aliases) plus what ac-voice knows locally: `config.aliases` per code,
    /// `History.learnedAliases` when `config.learnAliases` is on (REVIEW m9), and the history's opens as
    /// `Signals.recentOpens` (an entry keeps its own opens when the history has none for it).
    public static func entries(_ projects: [ProjectEntry], config: Config, history: History) -> [ProjectEntry] {
        var base = projects.map { p -> ProjectEntry in
            var e = p.addingAliases(byCode: config.aliases)
            let opens = history.recentOpens(p.id)
            if !opens.isEmpty { e.signals.recentOpens = opens }
            return e
        }
        if config.learnAliases {
            let learned = history.learnedAliases(projects: base)
            if !learned.isEmpty { base = base.map { $0.addingAliases(byCode: learned) } }
        }
        return base
    }

    // MARK: Command phase

    public func command(_ hyps: [Hypothesis], now: Date = .now) -> Interpretation {
        let parsed = hyps.filter { !$0.text.isEmpty }.map { (h: $0, c: Parser.command($0.text)) }
        let heard = parsed.first?.h.text ?? ""
        if parsed.contains(where: { $0.c == .openMyTasks }) { return .myTasks }
        if let firstBest = parsed.first(where: { $0.h.weight >= 1 }), firstBest.c == .cancel { return .cancel }

        // Explicit tickets ("Ticket 412", "öffne 47285"): any hypothesis with a ticket wins.
        let tasks = parsed.compactMap { p -> (w: Double, q: [Token], n: Int)? in
            if case let .openTask(q, n) = p.c { return (p.h.weight, q, n) }
            return nil
        }
        if let first = tasks.first(where: { $0.w >= 1 }) ?? tasks.first {
            let same = tasks.filter { $0.n == first.n }.map { (w: $0.w, q: $0.q) }
            return .task(taskRequest(number: first.n, queries: same, implicit: false, now: now))
        }

        var lists: [(Double, [Scored])] = []
        var union: [Token] = [], seen = Set<String>(), bestCount = 0
        var queries: [(w: Double, q: [Token])] = []
        for (h, c) in parsed {
            guard case let .openProject(q) = c else { continue }
            queries.append((h.weight, q))
            lists.append((h.weight, resolver.score(q, now: now)))
            // Union of the best texts: DT hears codes, ST hears title words ("TKZ Tauben" + "CKZ Touren").
            if h.weight >= 1 { bestCount += 1; for t in q where seen.insert(t.key).inserted { union.append(t) } }
        }
        guard let best = queries.first(where: { $0.w >= 1 }) ?? queries.first else { return .notUnderstood(heard: heard) }
        if bestCount > 1 { lists.append((1.0, resolver.score(union, now: now))) }
        let key = TextNorm.queryKey(best.q)
        let r = resolver.decide(Resolver.merge(lists), learned: history.picks(for: key))

        // "<project> <number>" is a ticket unless a matching title contains that number ("TYPO 3", "Relaunch 2026").
        if let imp = Parser.implicitTicket(best.q), !explains(best.q, Set(imp.numeralIndices), among: r, now: now) {
            let same = queries.compactMap { e -> (w: Double, q: [Token])? in
                guard let i = Parser.implicitTicket(e.q), i.number == imp.number else { return nil }
                return (e.w, i.project)
            }
            return .task(taskRequest(number: imp.number, queries: same, implicit: true, now: now))
        }
        if case .none = r { return .notUnderstood(heard: heard) }
        return .project(r, query: key)
    }

    /// Resolves the project words of a ticket command. Numerals in the query that no candidate title explains are
    /// leftovers and lower the confidence.
    /// Only best-weight hypotheses (>= 1) supply project words; alternatives count only when no best hypothesis
    /// exists, so a noisy alternative never narrows a bare ticket. When a best hypothesis heard no project words and
    /// the words of the others match nothing, the scope stays open (`projects: nil`) with low confidence: a single hit
    /// then asks for confirmation instead of failing with "Projekt nicht erkannt".
    func taskRequest(number: Int, queries: [(w: Double, q: [Token])], implicit: Bool, now: Date) -> TaskRequest {
        let tier = queries.contains { $0.w >= 1 } ? queries.filter { $0.w >= 1 } : queries
        // The first hypothesis with project words names the query key and decides about leftover numerals.
        guard let best = tier.first(where: { $0.q.contains { !Parser.isNumeral($0) } }) ?? tier.first else {
            return TaskRequest(number: number, implicit: implicit)
        }
        let numerals = Set(best.q.indices.filter { Parser.isNumeral(best.q[$0]) })
        let worded = tier.filter { $0.q.contains { !Parser.isNumeral($0) } }
        guard !worded.isEmpty else {
            return TaskRequest(number: number, projects: nil, query: "", confident: numerals.isEmpty, implicit: implicit)
        }
        let key = TextNorm.queryKey(best.q)
        let learned = history.picks(for: key)
        var r = resolver.decide(Resolver.merge(worded.map { ($0.w, resolver.score($0.q, now: now)) }), learned: learned)
        if case .none = r, !numerals.isEmpty {
            // Stray numerals can push coverage below the threshold: retry with the words alone.
            let words = worded.map { e in (e.w, resolver.score(e.q.filter { !Parser.isNumeral($0) }, now: now)) }
            r = resolver.decide(Resolver.merge(words), learned: learned)
        }
        if case .none = r, worded.count < tier.count {
            // Another best hypothesis heard a bare ticket: do not trust words that match nothing.
            return TaskRequest(number: number, projects: nil, query: key, confident: false, implicit: implicit)
        }
        let confident = numerals.isEmpty || explains(best.q, numerals, among: r, now: now)
        return TaskRequest(number: number, projects: r, query: key, confident: confident, implicit: implicit)
    }

    /// Normalized project words of the best hypothesis ("eben betreuung"), the same key `.project(_, query:)` carries.
    /// After `.notUnderstood`, the Flow records a correction pick with it once the user opens a project in the same
    /// session (`History.recordPick(query: key, projectId:)`), so `History.learnedAliases` can learn what STT heard
    /// (REVIEW m9). nil when no hypothesis holds project words. For tickets use `TaskRequest.query`.
    public func correctionKey(_ hyps: [Hypothesis]) -> String? {
        let queries = hyps.filter { !$0.text.isEmpty }.compactMap { h -> (w: Double, q: [Token])? in
            if case let .openProject(q) = Parser.command(h.text) { return (h.weight, q) }
            return nil
        }
        guard let best = queries.first(where: { $0.w >= 1 }) ?? queries.first else { return nil }
        let key = TextNorm.queryKey(best.q)
        return key.isEmpty ? nil : key
    }

    /// True when a candidate of `r` explains every token at `indices` of `q`.
    func explains(_ q: [Token], _ indices: Set<Int>, among r: Resolution, now: Date) -> Bool {
        guard !indices.isEmpty else { return true }
        let ids = Set(r.projectIds)
        guard !ids.isEmpty else { return false }
        return resolver.score(q, within: ids, now: now).contains { $0.got.isSuperset(of: indices) }
    }

    // MARK: Choice phase

    /// `candidates` are the project ids of the list in displayed order. For ticket choices pass the tasks' project
    /// ids (each project has at most one task with a given number).
    /// Best-weight hypotheses decide first: their number, control word or unique name wins. A number from an
    /// alternative (weight < 1) counts only when no best hypothesis gave a number, a unique name, a command or a
    /// keep-listening answer, and only when it lies inside a list the best hypotheses narrowed to.
    public func selection(_ hyps: [Hypothesis], candidates: [Int], now: Date = .now) -> SelectionOutcome {
        var names: [(Double, [Scored])] = [], bestNames: [(Double, [Scored])] = []
        var fallback: SelectionOutcome = .unclear
        var altPick: Int? = nil, bestAnswered = false
        for h in hyps where !h.text.isEmpty {
            let isBest = h.weight >= 1
            switch Parser.selection(h.text, count: candidates.count) {
            case .pick(let n):
                let i = n == -1 ? candidates.count - 1 : n - 1
                guard candidates.indices.contains(i) else { break }
                if isBest { return .pick(i) }
                if altPick == nil { altPick = i }
            case .cancel where isBest: return .cancel
            case .more where isBest: return .more
            case .command(let c):
                if isBest { bestAnswered = true }
                if fallback == .unclear || fallback == .keepListening { fallback = .command(c) }
            case .keepListening where isBest:
                bestAnswered = true
                if fallback == .unclear { fallback = .keepListening }
            case .byName(let q):
                let scored = resolver.score(q, within: Set(candidates), now: now)
                names.append((h.weight, scored))
                if isBest { bestNames.append((h.weight, scored)) }
            default: break
            }
        }
        let fromBest = resolver.decide(Resolver.merge(bestNames), inList: true)
        if case .unique(let s) = fromBest, let i = candidates.firstIndex(of: s.project.id) { return .pick(i) }
        if let i = altPick, !bestAnswered {
            // An alternative's number outside the names the best hypotheses heard contradicts them: narrow below.
            var contradicts = false
            if case .ambiguous(let list) = fromBest { contradicts = !list.contains { $0.project.id == candidates[i] } }
            if !contradicts { return .pick(i) }
        }
        switch resolver.decide(Resolver.merge(names), inList: true) {
        case .unique(let s): return candidates.firstIndex(of: s.project.id).map(SelectionOutcome.pick) ?? fallback
        case .ambiguous(let list) where list.count < candidates.count:
            return .narrow(list.compactMap { s in candidates.firstIndex(of: s.project.id) }.sorted())
        default: return fallback
        }
    }

    // MARK: Tickets

    /// `TicketResolver.resolve` with favorites and the project order taken from the resolver's signals
    /// (tier, then id). Pass every project id whose archive fetch was attempted in `attemptedArchives`
    /// (see `TicketResolver.resolve` for the termination rule).
    public func ticket(_ request: TaskRequest, index: TaskIndex, activeProjectId: Int? = nil,
                       archivesFetched: Bool = false, attemptedArchives: Set<Int> = [], now: Date = .now) -> TicketOutcome {
        let ranked = resolver.projects
            .map { (p: $0, tier: $0.signals.tier(now: now)) }
            .sorted { $0.tier != $1.tier ? $0.tier > $1.tier : $0.p.id < $1.p.id }
            .map(\.p)
        return TicketResolver.resolve(request, index: index, favorites: ranked.filter(\.signals.favorite).map(\.id),
                                      allProjects: ranked.map(\.id), activeProjectId: activeProjectId,
                                      archivesFetched: archivesFetched, attemptedArchives: attemptedArchives)
    }
}
