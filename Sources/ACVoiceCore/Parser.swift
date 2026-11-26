import Foundation

/// Parsed command-phase utterance.
public enum Command: Sendable, Equatable {
    /// Filler-free project words. May end in a number ("WWT 412"): `Interpreter` decides whether that is a
    /// ticket or a title word ("TYPO 3", "Relaunch 2026"), see `Parser.implicitTicket`.
    case openProject(query: [Token])
    /// "Ticket <n>" with optional project words, or a bare global id ("öffne 47285").
    /// `query` keeps numerals that are not part of `number` (leftovers, or title words such as "TYPO 3").
    case openTask(query: [Token], number: Int)
    case openMyTasks
    case cancel
    case unknown
}

/// Parsed answer while a numbered list is visible.
public enum Selection: Sendable, Equatable {
    case pick(Int)            // 1-based; -1 = last
    case byName([Token])      // resolve against the visible candidates
    case cancel
    case more                 // show the next page
    /// Only a negation ("nein") or a confirm word while several items are visible: keep the mic open,
    /// no pick and no failed attempt (REVIEW m3). With one item (a confirm prompt) a bare negation is `.cancel`.
    case keepListening
    case command(Command)     // a fresh command replaces the list
    case unclear
}

public enum Parser {
    static let fillers: Set<String> = [
        "offne", "offnen", "oeffne", "offnet", "mach", "mache", "auf", "zeig", "zeige", "zeigen", "mir", "mal", "doch",
        "bitte", "das", "die", "den", "dem", "der", "des", "projekt", "projekte", "project", "geh", "gehe", "zu", "zum",
        "zur", "in", "ins", "im", "wechsel", "wechsle", "spring", "springe", "open", "kannst", "du", "hol", "hole",
        "lade", "starte", "jetzt", "schnell", "nimm", "nehme", "nehmen", "ich", "will", "mochte", "gern", "gerne",
        "hey", "jarvis", "von", "vom", "fur", "bring", "bringe", "mich", "ah", "ahm", "hm", "also", "na", "okay",
        "ok", "aufmachen", "anzeigen", "aufrufen", "konntest", "bei", "an", "einmal", "kurz", "ein", "eine",
        "einen", "einem", "einer", "mein", "meine", "meinen", "meinem", "meiner", "und", "noch", "nochmal", "so",
        "sofort", "bitteschon", "dieses", "diese", "dieser", "diesen", "hier", "da", "aus", "auch",
    ]
    static let taskWords: Set<String> = [
        "ticket", "tickets", "task", "tasks", "aufgabe", "issue", "ticker", "ticketnummer", "tasknummer", "aufgabennummer",
    ]
    static let numberWords: Set<String> = ["nummer", "nr", "no", "number"]
    static let selectWords: Set<String> = ["nummer", "nr", "option", "eintrag", "punkt", "zeile"]
    /// Everyday particles and politeness that carry no project meaning in a command ("Ticket 412, danke",
    /// "Öffne gleich WWT"). Command phase only: `selection` keeps "ja" as a confirm word.
    static let softFillers: Set<String> = [
        "danke", "dankeschon", "schon", "gleich", "gerade", "aber", "halt", "nun", "eigentlich", "ja", "okay",
        "please", "thanks",
    ]
    /// "eben" is filler only next to these words ("mal eben", "eben mal", "gerade eben", "eben schnell").
    /// Alone it stays a project word, because STT hears the code "IBN" as "eben" (alias, REVIEW m9).
    static let ebenBefore: Set<String> = ["mal", "gerade", "grad", "jetzt"]
    static let ebenAfter: Set<String> = ["mal", "schnell", "kurz"]
    static let cancelWords: Set<String> = ["abbrechen", "abbruch", "stopp", "stop", "egal", "vergiss", "schliessen", "nein", "nichts", "cancel", "danke", "dankeschon"]
    /// Words after which a German command or answer cannot end (REVIEW M1, `looksIncomplete`).
    static let danglingWords: Set<String> = [
        "das", "die", "den", "dem", "der", "des", "ein", "eine", "einen", "einem", "einer", "mein", "meine", "meinen",
        "meinem", "meiner", "dieses", "diese", "dieser", "diesen", "zu", "zum", "zur", "in", "ins", "im", "von", "vom",
        "fur", "bei", "mir", "mich", "und", "plus", "oder",
    ]
    /// Negations that lead into a real answer ("nein, die zweite", "ne, die vier", "nö, Relaunch").
    static let negations: Set<String> = ["nein", "ne", "nee", "no", "noe", "nope"]
    static let confirmWords: Set<String> = ["ja", "jawohl", "genau", "passt", "richtig", "korrekt", "yes", "jep"]
    static let moreWords: Set<String> = ["mehr", "weitere", "weiter", "andere", "nachste", "rest"]
    static let openVerbs: Set<String> = ["offne", "oeffne", "offnet", "mach", "zeig", "zeige", "geh", "gehe", "wechsel", "wechsle", "spring", "bring", "hol"]
    static let myTaskPhrases = [" meine aufgaben ", " meine aufgabe ", " meine tasks ", " meine tickets ", " meine todos ",
                                " my work ", " bei mir an ", " was steht an ", " was steht heute an ", " mir zugewiesen ",
                                " meine offenen ", " meine arbeit ", " was liegt an "]
    /// "ein"/"eine" are articles far more often than numbers.
    static let notNumerals: Set<String> = ["ein", "eine", "und"]

    // MARK: Command phase

    public static func command(_ raw: String) -> Command { command(tokens: TextNorm.tokenize(raw)) }

    static func command(tokens all: [Token]) -> Command {
        // "Nein, Ticket 412" corrects the previous attempt: the negation is not a project word. "Nein." alone cancels.
        var tokens = all
        let lead = tokens.prefix { negations.contains($0.text) }.count
        if lead > 0, tokens.dropFirst(lead).contains(where: { !fillers.contains($0.text) }) { tokens.removeFirst(lead) }
        let joined = " " + tokens.map(\.text).joined(separator: " ") + " "
        let hasNumeral = tokens.contains(where: isNumeral)
        // "Zeige meine Aufgabe" -> my tasks; "Öffne meine Aufgabe 412" -> ticket 412 below.
        if !hasNumeral, myTaskPhrases.contains(where: joined.contains) { return .openMyTasks }
        let content = tokens.filter { !fillers.contains($0.text) }
        // "Danke.", "Nein danke", "Danke schön" cancel; "Ticket 412 danke" does not.
        if content.contains(where: { cancelWords.contains($0.text) }),
           content.allSatisfy({ cancelWords.contains($0.text) || softFillers.contains($0.text) }) { return .cancel }

        // Ticket: "<project?> ticket [nummer] <number> <project?>". The first numeral run after the keyword is the
        // number, else the last one before it. Other numerals stay in the query.
        if let k = tokens.firstIndex(where: { taskWords.contains($0.text) }) {
            let runs = numeralRuns(tokens)
            if let run = runs.first(where: { $0.range.lowerBound > k }) ?? runs.last(where: { $0.range.upperBound <= k }) {
                var rest = tokens
                rest.removeSubrange(run.range)
                return .openTask(query: strip(rest), number: run.value)
            }
        }
        // Only a number: a global task id ("öffne 47285", "47000 285"). Task numbers need the word "Ticket"
        // or project words, so a stray "zwei" after a list closed is not a ticket.
        let q = strip(tokens)
        if !q.isEmpty, q.allSatisfy(isNumeral) {
            let runs = numeralRuns(tokens)
            guard runs.count == 1, runs[0].value >= TicketResolver.globalIdThreshold else { return .unknown }
            return .openTask(query: [], number: runs[0].value)
        }
        return q.isEmpty ? .unknown : .openProject(query: q)
    }

    /// "<project> <number>" without the word "Ticket" (REVIEW M6): a numeral run at the end (or start) of a
    /// project query with project words left over. The caller must check that no project title explains the
    /// numerals ("TYPO 3", "Relaunch 2026") before reading it as a ticket.
    public static func implicitTicket(_ query: [Token]) -> (project: [Token], number: Int, numeralIndices: Range<Int>)? {
        let runs = numeralRuns(query)
        guard let run = runs.last(where: { $0.range.upperBound == query.count }) ?? runs.first(where: { $0.range.lowerBound == 0 })
        else { return nil }
        var rest = query
        rest.removeSubrange(run.range)
        guard rest.contains(where: { !isNumeral($0) }) else { return nil }
        return (rest, run.value, run.range)
    }

    // MARK: Choice phase

    public static func selection(_ raw: String, count: Int) -> Selection {
        var tokens = TextNorm.tokenize(raw)
        // Leading negations only introduce the real answer: "nein, die zweite" -> 2. "nein" alone keeps listening.
        var lead = 0
        while lead < tokens.count, negations.contains(tokens[lead].text) { lead += 1 }
        let negated = lead > 0
        tokens.removeFirst(lead)
        let content = tokens.filter { !fillers.contains($0.text) && !selectWords.contains($0.text) }
        let texts = content.map(\.text)
        // A one-item list is a confirm prompt ("Sag ja oder eins"): "nein" answers it and closes it.
        let negation: Selection = count == 1 ? .cancel : .keepListening
        if texts.isEmpty { return negated ? negation : .unclear }
        if texts.allSatisfy({ cancelWords.contains($0) }) {
            // "nein nein" keeps listening; "abbrechen" cancels.
            return texts.allSatisfy(negations.contains) ? negation : .cancel
        }
        // A confirm word only picks when exactly one item is visible ("Sag ja oder eins").
        if texts.allSatisfy(confirmWords.contains) { return count == 1 ? .pick(1) : .keepListening }
        if texts.allSatisfy({ moreWords.contains($0) }) { return .more }
        // Ordinal anywhere in a short answer: "die zweite", "nimm die letzte".
        if tokens.count <= 4, let o = tokens.lazy.compactMap({ GermanNumbers.ordinal($0.text) }).first { return .pick(o) }
        // Single number: "zwei", "2", "nummer drei", "die drei".
        if texts.count == 1, let n = GermanNumbers.cardinal(texts[0]) ?? lookalikeDigit(texts[0]), (1...max(count, 1)).contains(n) {
            return .pick(n)
        }
        // A new command replaces the list ("nein, öffne TKZ", "Ticket 412").
        let first = tokens.first(where: { !cancelWords.contains($0.text) })?.text ?? ""
        if openVerbs.contains(first) || tokens.contains(where: { taskWords.contains($0.text) }) {
            let c = command(tokens: tokens)
            if c != .unknown { return .command(c) }
        }
        let names = content.filter { !cancelWords.contains($0.text) && !confirmWords.contains($0.text) }
        return names.isEmpty ? .unclear : .byName(names)
    }

    /// Frequent STT confusions for short number words. "frei" is not here: it is a real word and picked #3
    /// from ambient speech (REVIEW m3). Extend only with real recordings.
    static func lookalikeDigit(_ t: String) -> Int? {
        ["zwai": 2, "zwo": 2, "dry": 3, "fier": 4, "funf": 5, "fuenf": 5][t]
    }

    // MARK: End of utterance (REVIEW M1)

    /// True when a live partial cannot be the whole utterance yet, so the end-of-utterance gate should wait longer:
    /// empty, ending in a numeral ("Ticket 4" may become 412), a task word, "Nummer", an open verb or a dangling
    /// article/preposition, or holding only fillers so far ("Öffne mir mal das").
    /// `choosing`: the answer phase of a visible list. There a numeral, an ordinal or a name ends the answer
    /// ("zwei", "die zweite", "Relaunch"), while a bare negation may lead into one ("nein, … die zweite").
    /// The one rule for dangling words: `HangoverPolicy` uses it for the live budget, the speech layer for reopening
    /// a dangling final and for its stable-transcript fallback, the flow for hesitations in the answer phase.
    public static func looksIncomplete(_ partial: String, choosing: Bool = false) -> Bool {
        let tokens = TextNorm.tokenize(partial)
        guard let last = tokens.last else { return true }
        if choosing {
            switch selection(partial, count: 9) {
            case .pick, .cancel, .more: return false
            case .keepListening: return true
            case .command: break                  // a new command: command-phase rules below
            case .byName, .unclear:
                return danglingWords.contains(last.text) || selectWords.contains(last.text) || isDanglingVerbOrTaskWord(last)
                    || tokens.allSatisfy { fillers.contains($0.text) || selectWords.contains($0.text) }
            }
        }
        switch command(tokens: tokens) {
        case .openMyTasks, .cancel: return false
        default: break
        }
        if isNumeral(last) || danglingWords.contains(last.text) || isDanglingVerbOrTaskWord(last) { return true }
        return strip(tokens).isEmpty
    }

    /// True when the last word is a numeral: digits or a German number word, not "ein", "eine" or "und".
    /// In the command phase such a partial may still grow ("Ticket 4" -> 412, `HangoverPolicy.trailingNumber`).
    public static func endsInNumeral(_ text: String) -> Bool {
        guard let last = TextNorm.tokenize(text).last(where: { !$0.key.isEmpty }) else { return false }
        return isNumeral(last)
    }

    static func isDanglingVerbOrTaskWord(_ t: Token) -> Bool {
        openVerbs.contains(t.text) || taskWords.contains(t.text) || numberWords.contains(t.text)
    }

    // MARK: Helpers

    /// Project words of a command: drops fillers, task and number words, soft fillers and "eben" next to
    /// "mal"/"gerade"/"schnell".
    static func strip(_ tokens: [Token]) -> [Token] {
        tokens.indices.filter { i in
            let t = tokens[i].text
            if fillers.contains(t) || taskWords.contains(t) || numberWords.contains(t) || softFillers.contains(t) { return false }
            if t == "eben" {
                if i > 0, ebenBefore.contains(tokens[i - 1].text) { return false }
                if i + 1 < tokens.count, ebenAfter.contains(tokens[i + 1].text) { return false }
            }
            return true
        }.map { tokens[$0] }
    }

    static func isNumeral(_ t: Token) -> Bool {
        !notNumerals.contains(t.key) && GermanNumbers.cardinal(t.key) != nil
    }

    /// Maximal runs of adjacent numerals with their composed value ("4 12" -> 412). A standalone "und" between
    /// two numerals belongs to the run ("acht und funfzig").
    static func numeralRuns(_ tokens: [Token]) -> [(range: Range<Int>, value: Int)] {
        var runs: [(Range<Int>, Int)] = []
        var i = 0
        while i < tokens.count {
            guard isNumeral(tokens[i]) else { i += 1; continue }
            var parts: [GermanNumbers.Part] = []
            var j = i
            while j < tokens.count {
                let k = tokens[j].key
                if isNumeral(tokens[j]) {
                    parts.append(.init(value: GermanNumbers.cardinal(k)!, isMultiplierWord: k == "hundert" || k == "tausend"))
                } else if k == "und", j > i, j + 1 < tokens.count, isNumeral(tokens[j + 1]),
                          let units = GermanNumbers.cardinal(tokens[j - 1].key), (1...9).contains(units),
                          let tens = GermanNumbers.cardinal(tokens[j + 1].key), (20...90).contains(tens), tens % 10 == 0 {
                    // Only the German units-und-tens order joins: "acht und funfzig" = 58, not "412 und 5".
                    parts.append(.init(value: 0, isJoiner: true))
                } else { break }
                j += 1
            }
            if let v = GermanNumbers.compose(parts) { runs.append((i..<j, v)) }
            i = j
        }
        return runs
    }
}
