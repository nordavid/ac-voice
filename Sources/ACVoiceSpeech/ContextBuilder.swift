import ACVoiceCore
import Foundation

/// Contextual strings for the DictationTranscriber, per phase (PLAN 2.3, REVIEW m10). SpeechTranscriber ignores
/// them. Research: 19 targeted entries helped, 100 and 185 entries made results worse, so the list stays short and
/// ordered by value; `limit` cuts the tail.
public enum ContextBuilder {
    /// Default size. `Config.contextualStringLimit` overrides it in the app.
    public static let defaultLimit = 35
    /// German command phrases (`commandPhrases(_:)`).
    public static let commandPhrases = ["Ticket", "Meine Aufgaben", "Projekt"]

    /// The words every command context starts with, in the language of the voice commands.
    public static func commandPhrases(_ language: AppLanguage) -> [String] {
        language == .de ? commandPhrases : ["Ticket", "My tasks", "Project"]
    }

    /// Command phase, in this order until `limit` is reached:
    /// 1. "Ticket", "Meine Aufgaben", "Projekt" (English: "Ticket", "My tasks", "Project")
    /// 2. codes of projects with personal signals (tier > 0, highest first) as written, "S+K" also as "S und K"
    ///    ("S and K"); "<CODE>-Projekt" ("<CODE> project") for the two strongest; then their aliases
    /// 3. titles of those projects (short titles whole, long ones by their rarest words), then the single words of
    ///    the three strongest ("Relaunch" next to "Website Relaunch")
    /// 4. titles of their sibling projects (same code, at most `siblingsPerCode` each)
    /// 5. all other codes (by best tier, then project count, then name), then their aliases
    /// Codes, aliases and titles are AC names: only the command phrases and the spoken "+" follow `language`.
    public static func command(projects: [ProjectEntry], now: Date = .now, limit: Int = defaultLimit,
                               language: AppLanguage = .de) -> [String] {
        var out = Collector(limit: limit)
        out.add(commandPhrases(language))
        let docFreq = documentFrequency(projects.map(\.title))
        let tiers = Dictionary(projects.map { ($0.id, $0.signals.tier(now: now)) }, uniquingKeysWith: max)
        let byRank = { (a: ProjectEntry, b: ProjectEntry) in
            tiers[a.id]! != tiers[b.id]! ? tiers[a.id]! > tiers[b.id]! : a.id < b.id
        }
        let personal = projects.filter { tiers[$0.id, default: 0] > 0 }.sorted(by: byRank)

        for p in personal { if let c = p.code { out.add(codeVariants(c, language: language)) } }
        var seenCodes = Set<String>()
        let strongCodes = personal.compactMap(\.code).filter { $0.allSatisfy(\.isLetter) && seenCodes.insert($0).inserted }
        for c in strongCodes.prefix(2) { out.add([language == .de ? "\(c)-Projekt" : "\(c) project"]) }
        for p in personal { out.add(p.aliases) }
        for p in personal { out.add(titlePhrases(p.title, docFreq: docFreq)) }
        for p in personal.prefix(3) { out.add(words(p.title).filter { $0.count >= 4 }) }

        let personalIds = Set(personal.map(\.id))
        var siblingCount: [String: Int] = [:]
        let personalCodes = Set(personal.compactMap { $0.code.map(ProjectEntry.codeKey) })
        for p in projects.sorted(by: byRank) where !personalIds.contains(p.id) {
            guard let c = p.code.map(ProjectEntry.codeKey), personalCodes.contains(c), siblingCount[c, default: 0] < siblingsPerCode else { continue }
            siblingCount[c, default: 0] += 1
            out.add(titlePhrases(p.title, docFreq: docFreq))
        }

        // Other codes: best personal tier first, then larger groups (more ways to be misheard), then name.
        var groups: [String: (code: String, tier: Int, count: Int, aliases: [String])] = [:]
        for p in projects {
            guard let c = p.code else { continue }
            let k = ProjectEntry.codeKey(c)
            var g = groups[k] ?? (c, Int.min, 0, [])
            g.tier = max(g.tier, tiers[p.id, default: 0]); g.count += 1; g.aliases += p.aliases
            groups[k] = g
        }
        let ordered = groups.values.sorted {
            if $0.tier != $1.tier { return $0.tier > $1.tier }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.code.localizedStandardCompare($1.code) == .orderedAscending
        }
        for g in ordered { out.add(codeVariants(g.code, language: language)) }
        for g in ordered { out.add(g.aliases) }
        return out.items
    }

    /// Sibling titles per personal code in the command context.
    public static let siblingsPerCode = 3

    /// Answer phase for a visible list: number words for the visible rows ("zwo" too), ordinals, the distinctive
    /// words of the shown titles, "abbrechen", "nein" and, when more rows exist, "mehr". English: "one", "the second",
    /// "the last", "cancel", "no", "more".
    /// `titles` are the shown rows in order (project titles without code and type). Rows are numbered absolutely
    /// across "mehr" pages (PLAN 4.5): `firstNumber` is the number of the first shown row, 7 on the second page of 6.
    public static func answer(titles: [String], hasMore: Bool = false, firstNumber: Int = 1,
                              limit: Int = defaultLimit, language: AppLanguage = .de) -> [String] {
        let count = max(1, min(titles.count, maxNumberWords))
        let first = min(max(1, firstNumber), 99 - count + 1)
        let shown = first..<(first + count)
        var out = Collector(limit: limit)
        let de = language == .de
        out.add(shown.compactMap(de ? GermanNumbers.spelled : EnglishNumbers.spelled))
        if de, shown.contains(2) { out.add(["zwo"]) }
        // Words that tell the rows apart: a word in every title does not help.
        let docFreq = documentFrequency(titles)
        for t in titles {
            let ws = words(t)
            if ws.count <= 3, !ws.isEmpty, ws.joined(separator: " ").count <= 30 { out.add([ws.joined(separator: " ")]) }
            out.add(ws.filter { docFreq[TextNorm.fold($0), default: 0] < titles.count && $0.count >= 3 })
        }
        // The parser reads ordinals up to "zehnte" / "tenth" (`GermanNumbers.ordinal`, `EnglishNumbers.ordinal`).
        let ordinals = shown.filter { $0 <= ordinalStems.count }.prefix(6)
        out.add(de ? ordinals.map { "die " + ordinalStems[$0 - 1] + "e" } : ordinals.map { "the " + EnglishNumbers.ordinalWords[$0 - 1] })
        if count >= 2 { out.add([de ? "die letzte" : "the last"]) }
        out.add(de ? ["abbrechen", "nein"] : ["cancel", "no"])
        if hasMore { out.add([de ? "mehr" : "more"]) }
        return out.items
    }

    /// Answer phase for project rows; `firstNumber` as in `answer(titles:)`.
    public static func answer(choices: [ProjectEntry], hasMore: Bool = false, firstNumber: Int = 1,
                              limit: Int = defaultLimit, language: AppLanguage = .de) -> [String] {
        answer(titles: choices.map(\.title), hasMore: hasMore, firstNumber: firstNumber, limit: limit, language: language)
    }

    /// Number words per answer context at most (two pages of 6 rows).
    static let maxNumberWords = 12

    static let ordinalStems = ["erst", "zweit", "dritt", "viert", "fünft", "sechst", "siebt", "acht", "neunt", "zehnt"]

    // MARK: Helpers

    /// "S+K" -> ["S+K", "S und K"] (English "S and K"; the spoken variant only up to 3 words). Codes stay whole up to
    /// 3 words and 24 characters, longer ones are cut to two words (the documentation asks for 1-2 words per phrase).
    static func codeVariants(_ code: String, language: AppLanguage = .de) -> [String] {
        let parts = code.split(separator: " ").map(String.init)
        let short = parts.count <= 3 && code.count <= 24 ? parts.joined(separator: " ") : parts.prefix(2).joined(separator: " ")
        var out = [short]
        if short.contains("+") || short.contains("&") {
            let joiner = language == .de ? " und " : " and "
            let spoken = short.replacingOccurrences(of: "+", with: joiner).replacingOccurrences(of: "&", with: joiner)
                .split(separator: " ")
            // "S und K" yes, "S und K Partner" no: the resolver maps "+", "&" and "und" anyway.
            if spoken.count <= 3 { out.append(spoken.joined(separator: " ")) }
        }
        return out
    }

    static let stopWords: Set<String> = [
        "der", "die", "das", "und", "von", "fur", "the", "of", "for", "a", "an", "to", "im", "in", "mit", "auf", "zu",
        "nur", "bis", "zum", "zur", "am", "oder", "dem", "den", "des",
    ]

    /// Title words as written, without punctuation, numbers and stop words.
    static func words(_ title: String) -> [String] {
        let trim = CharacterSet(charactersIn: ",.;:!?()[]{}\"'„“”‚‘’»«|*").union(.whitespaces)
        return title.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "–" || $0 == "—" })
            .map { String($0).trimmingCharacters(in: trim) }
            .filter { w in
                guard !w.isEmpty, w != "-", w.contains(where: \.isLetter) else { return false }
                let letters = w.filter(\.isLetter)
                let acronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
                return (w.count >= 3 || acronym) && !stopWords.contains(TextNorm.fold(w))
            }
    }

    /// Short titles whole (up to 3 words, 30 characters), long titles by their two rarest words.
    static func titlePhrases(_ title: String, docFreq: [String: Int]) -> [String] {
        let ws = words(title)
        guard !ws.isEmpty else { return [] }
        let joined = ws.joined(separator: " ")
        if ws.count <= 3, joined.count <= 30 { return [joined] }
        let rare = ws.enumerated().sorted {
            let a = docFreq[TextNorm.fold($0.element), default: 0], b = docFreq[TextNorm.fold($1.element), default: 0]
            if a != b { return a < b }
            if $0.element.count != $1.element.count { return $0.element.count > $1.element.count }
            return $0.offset < $1.offset
        }
        return rare.prefix(2).sorted { $0.offset < $1.offset }.map(\.element)
    }

    /// Folded word -> number of titles that contain it.
    static func documentFrequency(_ titles: [String]) -> [String: Int] {
        var df: [String: Int] = [:]
        for t in titles { for w in Set(words(t).map(TextNorm.fold)) { df[w, default: 0] += 1 } }
        return df
    }

    /// Ordered, case- and diacritic-insensitive unique list with a size limit.
    struct Collector {
        let limit: Int
        private(set) var items: [String] = []
        private var seen = Set<String>()
        init(limit: Int) { self.limit = max(0, limit) }
        mutating func add(_ phrases: [String]) {
            for p in phrases {
                guard items.count < limit else { return }
                let t = p.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, seen.insert(TextNorm.fold(t)).inserted else { continue }
                items.append(t)
            }
        }
    }
}
