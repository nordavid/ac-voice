import Foundation

/// Resolver regression lists, shared by `acvoice-resolve --cases` and the private real-name test suite.
/// Outcomes are printed as ids only, so results can be shared without project names.
///
/// File format (UTF-8, one case per line, TAB separated):
/// ```
/// <utterance> TAB <more hypotheses, " | " separated, may be empty> TAB <expected> [TAB <note>]
/// ```
/// Expected outcomes (`describe`): `my`, `cancel`, `none`, `unique <id>`, `choices <id,id,…>` (exact order),
/// `task <n> <projects>[ lowconf][ implicit]` with `<projects>` = `-` (no project words), `notRecognized`,
/// `unique <id>` or `choices <ids>`. A trailing `~` after `choices` (`choices~ 1,2`) compares as a set.
/// Lines starting with `#` are comments. Directives apply to all following cases:
/// - `@aliases IBN=eben|imben; WWT=hollenstein navigation` sets config aliases (`@aliases` alone clears them).
/// - `@signals 628 favorite timeRecords30d=8 ownOpenTasks=2 lastActivityDaysAgo=1` sets one project's signals
///   relative to the run's `now` (`@signals reset` clears all).
/// - `@picks wwt=693x3` adds learned picks (`@picks reset` clears them).
/// - `@language en` reads the following utterances as English commands (`@language de`, the default, as German).
public enum Regression {
    public struct Case: Sendable {
        public var line: Int
        public var hypotheses: [Hypothesis]
        public var expected: String
        public var aliases: [String: [String]]
        public var signals: [Int: Signals]
        public var history: History
        /// Language of the utterances (`@language`).
        public var language: AppLanguage = .de
    }

    public struct Result: Sendable {
        public var testCase: Case
        public var actual: String
        public var micros: Double
        public var passed: Bool
    }

    /// Compact id-only description of an interpretation.
    public static func describe(_ i: Interpretation) -> String {
        func ids(_ r: Resolution) -> String {
            switch r {
            case .unique(let s): return "unique \(s.project.id)"
            case .ambiguous(let l): return "choices " + l.map { String($0.project.id) }.joined(separator: ",")
            case .none: return "notRecognized"
            }
        }
        switch i {
        case .myTasks: return "my"
        case .cancel: return "cancel"
        case .notUnderstood: return "none"
        case .project(let r, _): return ids(r)
        case .task(let t):
            var s = "task \(t.number) " + (t.projects.map(ids) ?? "-")
            if !t.confident { s += " lowconf" }
            if t.implicit { s += " implicit" }
            return s
        }
    }

    public static func matches(actual: String, expected: String) -> Bool {
        let e = expected.trimmingCharacters(in: .whitespaces)
        guard let tilde = e.range(of: "choices~ ") else { return actual == e }
        // "task 412 choices~ 1,2" or "choices~ 1,2": compare the id lists as sets.
        let prefix = String(e[..<tilde.lowerBound]) + "choices "
        guard actual.hasPrefix(prefix) else { return false }
        let set = { (s: Substring) in Set(s.split(separator: " ").first?.split(separator: ",").map(String.init) ?? []) }
        let restA = actual.dropFirst(prefix.count), restE = e[tilde.upperBound...]
        let tailA = restA.split(separator: " ").dropFirst().joined(separator: " ")
        let tailE = restE.split(separator: " ").dropFirst().joined(separator: " ")
        return set(restA) == set(restE) && tailA == tailE
    }

    /// `language`: the language of the cases before the first `@language` directive.
    public static func parse(_ text: String, now: Date, language start: AppLanguage = .de) -> [Case] {
        var aliases: [String: [String]] = [:], signals: [Int: Signals] = [:], history = History()
        var language = start
        var cases: [Case] = []
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("@") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                switch parts[0] {
                case "@aliases":
                    aliases = [:]
                    for entry in arg.split(separator: ";") {
                        let kv = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        if kv.count == 2 { aliases[kv[0]] = kv[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
                    }
                case "@signals":
                    if arg == "reset" { signals = [:]; continue }
                    let f = arg.split(separator: " ")
                    guard let id = f.first.flatMap({ Int($0) }) else { continue }
                    var s = Signals()
                    for kv in f.dropFirst() {
                        let p = kv.split(separator: "=", maxSplits: 1)
                        let v = p.count > 1 ? Double(p[1]) ?? 0 : 1
                        switch p[0] {
                        case "favorite": s.favorite = v != 0
                        case "timeRecords30d": s.timeRecords30d = Int(v)
                        case "ownOpenTasks": s.ownOpenTasks = Int(v)
                        case "lastActivityDaysAgo": s.lastActivity = now.addingTimeInterval(-v * 86_400)
                        default: break
                        }
                    }
                    signals[id] = s
                case "@language":
                    language = arg.lowercased().hasPrefix("en") ? .en : .de
                case "@picks":
                    if arg == "reset" { history = History(); continue }
                    for entry in arg.split(separator: ";") {
                        let kv = entry.split(separator: "=", maxSplits: 1)
                        guard kv.count == 2 else { continue }
                        let q = TextNorm.queryKey(TextNorm.tokenize(String(kv[0]), language: language))
                        let pc = kv[1].split(separator: "x")
                        guard let id = Int(pc[0].trimmingCharacters(in: .whitespaces)) else { continue }
                        let count = pc.count > 1 ? Int(pc[1]) ?? 1 : 1
                        for _ in 0..<count { history.recordPick(query: q, projectId: id) }
                    }
                default: break
                }
                continue
            }
            let cols = raw.components(separatedBy: "\t")
            guard cols.count >= 3 else { continue }
            var hyps = [Hypothesis(cols[0].trimmingCharacters(in: .whitespaces))]
            hyps += cols[1].components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.map { Hypothesis($0) }
            cases.append(Case(line: n + 1, hypotheses: hyps, expected: cols[2].trimmingCharacters(in: .whitespaces),
                              aliases: aliases, signals: signals, history: history, language: language))
        }
        return cases
    }

    /// Runs every case against `projects` (signals and aliases of the case applied on top).
    public static func run(_ cases: [Case], projects: [ProjectEntry], now: Date) -> [Result] {
        var cache: [String: Resolver] = [:]
        return cases.map { c in
            let setup = "\(c.aliases.sorted { $0.key < $1.key })|\(c.signals.sorted { $0.key < $1.key })"
            let resolver = cache[setup] ?? {
                let entries = projects.map { p -> ProjectEntry in
                    var e = p.addingAliases(byCode: c.aliases)
                    if let s = c.signals[p.id] { e.signals = s }
                    return e
                }
                let r = Resolver(projects: entries)
                cache[setup] = r
                return r
            }()
            let interpreter = Interpreter(resolver: resolver, history: c.history, language: c.language)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let actual = describe(interpreter.command(c.hypotheses, now: now))
            let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
            return Result(testCase: c, actual: actual, micros: us, passed: matches(actual: actual, expected: c.expected))
        }
    }
}
