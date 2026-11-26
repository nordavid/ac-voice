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
    /// German everyday particles (`Lexicon.de.softFillers`); `History.particles` builds on them.
    static let softFillers = Lexicon.de.softFillers

    // MARK: Command phase

    public static func command(_ raw: String, language: AppLanguage = .de) -> Command {
        command(tokens: TextNorm.tokenize(raw, language: language), .of(language))
    }

    /// `titleNumber: false` reads the English "the <digits> one" as a numeral ("the maintenance 58 one" -> 581):
    /// `Interpreter.command` decides with the project titles (`isPronounOne`).
    static func command(_ raw: String, language: AppLanguage, titleNumber: Bool) -> Command {
        command(tokens: TextNorm.tokenize(raw, language: language), .of(language), titleNumber: titleNumber)
    }

    static func command(tokens all: [Token], _ lx: Lexicon, titleNumber: Bool = true) -> Command {
        // "Nein, Ticket 412" corrects the previous attempt: the negation is not a project word. "Nein." alone cancels.
        var tokens = mergePhrases(all, lx.cancelPhrases + lx.holdPhrases)
        if lx.language == .en { tokens = pronounOne(leadingLookalikes(tokens, lx), lx, titleNumber: titleNumber) }
        let lead = tokens.prefix { lx.negations.contains($0.text) }.count
        if lead > 0, tokens.dropFirst(lead).contains(where: { !isFiller($0, lx) }) { tokens.removeFirst(lead) }
        // English: "wait", "hold on", "forget that" and "never mind" before the first content word only lead into the
        // command ("Hold on, ticket 412"). After it they keep their meaning: "Ticket 412, never mind" opens nothing.
        if lx.language == .en {
            let leadIns = lx.negations.union(lx.holdWords).union(["forgetit", "nevermind"])
            if let first = tokens.firstIndex(where: { !leadIns.contains($0.text) && !englishClosings.contains($0.text)
                                                      && !isFiller($0, lx) && !lx.softFillers.contains($0.text) }) {
                tokens = tokens[..<first].filter { !leadIns.contains($0.text) } + tokens[first...]
            }
        }
        let joined = " " + tokens.map(\.text).joined(separator: " ") + " "
        let hasNumeral = tokens.contains { isNumeral($0, lx) }
        // "Zeige meine Aufgabe" -> my tasks; "Öffne meine Aufgabe 412" -> ticket 412 below.
        if !hasNumeral, lx.myTaskPhrases.contains(where: joined.contains) { return .openMyTasks }
        let content = tokens.filter { !isFiller($0, lx) }
        // "Danke.", "Nein danke", "Danke schön" cancel; "Ticket 412 danke" does not.
        if content.contains(where: { lx.cancelWords.contains($0.text) }),
           content.allSatisfy({ lx.cancelWords.contains($0.text) || lx.softFillers.contains($0.text)
               || lx.closingObjects.contains($0.text) }) { return .cancel }

        // Ticket: "<project?> ticket [nummer] <number> <project?>". The first numeral run after the keyword is the
        // number, else the last one before it. Other numerals stay in the query.
        if let k = tokens.firstIndex(where: { lx.taskWords.contains($0.text) }) {
            let runs = numeralRuns(tokens, lx)
            if let run = runs.first(where: { $0.range.lowerBound > k }) ?? runs.last(where: { $0.range.upperBound <= k }) {
                var rest = tokens
                rest.removeSubrange(run.range)
                return .openTask(query: strip(rest, lx), number: run.value)
            }
        }
        // Only a number: a global task id ("öffne 47285", "47000 285"). Task numbers need the word "Ticket"
        // or project words, so a stray "zwei" after a list closed is not a ticket.
        let q = strip(tokens, lx)
        if !q.isEmpty, q.allSatisfy({ isNumeral($0, lx) || isRunWord($0, lx) }) {
            let runs = numeralRuns(tokens, lx)
            guard runs.count == 1, runs[0].value >= TicketResolver.globalIdThreshold else { return .unknown }
            return .openTask(query: [], number: runs[0].value)
        }
        return q.isEmpty ? .unknown : .openProject(query: q)
    }

    /// "<project> <number>" without the word "Ticket" (REVIEW M6): a numeral run at the end (or start) of a
    /// project query with project words left over. The caller must check that no project title explains the
    /// numerals ("TYPO 3", "Relaunch 2026") before reading it as a ticket.
    public static func implicitTicket(_ query: [Token], language: AppLanguage = .de)
        -> (project: [Token], number: Int, numeralIndices: Range<Int>)? {
        let lx = Lexicon.of(language)
        let runs = numeralRuns(query, lx)
        guard let run = runs.last(where: { $0.range.upperBound == query.count }) ?? runs.first(where: { $0.range.lowerBound == 0 })
        else { return nil }
        var rest = query
        rest.removeSubrange(run.range)
        guard rest.contains(where: { !isNumeral($0, lx) }) else { return nil }
        return (rest, run.value, run.range)
    }

    // MARK: Choice phase

    public static func selection(_ raw: String, count: Int, language: AppLanguage = .de) -> Selection {
        let lx = Lexicon.of(language)
        var tokens = mergePhrases(TextNorm.tokenize(raw, language: language), lx.cancelPhrases + lx.holdPhrases)
        // Leading negations only introduce the real answer: "nein, die zweite" -> 2. "nein" alone keeps listening.
        var lead = 0
        while lead < tokens.count, lx.negations.contains(tokens[lead].text) { lead += 1 }
        let negated = lead > 0
        tokens.removeFirst(lead)
        let holds = tokens.contains { lx.holdWords.contains($0.text) }
        let content = tokens.filter { !isFiller($0, lx) && !lx.selectWords.contains($0.text) && !lx.holdWords.contains($0.text) }
        let texts = content.map(\.text)
        // A one-item list is a confirm prompt ("Sag ja oder eins"): "nein" answers it and closes it.
        let negation: Selection = count == 1 ? .cancel : .keepListening
        // "wait a second", "just a sec", "hang on": the user still thinks. No pick and no failed attempt.
        if holds, texts.allSatisfy(lx.softFillers.contains) { return .keepListening }
        if texts.isEmpty {
            // A whole answer "To." is "two" (English lookalikes are fillers in a sentence).
            if tokens.count == 1, let n = lx.lookalikeDigits[tokens[0].text], (1...max(count, 1)).contains(n) { return .pick(n) }
            return negated ? negation : .unclear
        }
        // A confirm word only picks when exactly one item is visible ("Sag ja oder eins"). "All right" confirms there,
        // and closes a list of several like a cancel word.
        if count == 1, texts.allSatisfy(lx.confirmWords.contains) { return .pick(1) }
        // English one-row prompt: a yes with a closing or the pronoun "one" confirms ("Yes, that's it", "Yep, that's the
        // one", "Yes, thanks"). A closing alone still closes ("That's it", "Thanks").
        if count == 1, lx.language == .en, texts.contains(where: lx.confirmWords.contains),
           texts.allSatisfy({ lx.confirmWords.contains($0) || ["thatsit", "allgood", "allset", "thanks", "thankyou", "one"].contains($0) }) {
            return .pick(1)
        }
        // English one-row prompt: "Okay" often only leads into the answer ("Okay, cancel", "OK, never mind", "Okay, no").
        let closing = count == 1 && lx.language == .en ? Array(texts.drop(while: softConfirms.contains)) : texts
        if !closing.isEmpty, closing.allSatisfy({ lx.cancelWords.contains($0) || lx.closingObjects.contains($0) }),
           closing.contains(where: lx.cancelWords.contains) {
            // "nein nein" keeps listening; "abbrechen" cancels.
            return closing.allSatisfy(lx.negations.contains) ? negation : .cancel
        }
        if texts.allSatisfy(lx.confirmWords.contains) { return .keepListening }
        if texts.allSatisfy({ lx.moreWords.contains($0) }) { return .more }
        // Ordinal in a short answer: German anywhere ("die zweite", "nimm die letzte"), English at the head only
        // ("the second one", not "wait a second" or "first of all").
        if tokens.count <= lx.ordinalAnswerTokens {
            if lx.language == .en {
                switch englishOrdinal(tokens, count: count, lx) {
                case .pick(let o): return .pick(o)
                case .notARow: return .unclear
                case .none: break
                }
            } else if let o = tokens.lazy.compactMap({ ordinal($0.text, lx) }).first {
                return .pick(o)
            }
        }
        // English: politeness and particles around a number do not hide it ("Two, thanks", "just two").
        let numberContent = lx.language == .en ? content.filter { !lx.softFillers.contains($0.text) } : content
        let numberTexts = numberContent.map(\.text)
        // Single number: "zwei", "2", "nummer drei", "die drei", "number two".
        if numberTexts.count == 1, let n = cardinal(numberTexts[0], lx) ?? lx.lookalikeDigits[numberTexts[0]],
           (1...max(count, 1)).contains(n) {
            return .pick(n)
        }
        // English writes a number in several words ("twenty one"): one run that is the whole answer.
        if lx.language == .en, numberTexts.count > 1, let run = numeralRuns(numberContent, lx).first,
           run.range == numberContent.indices,
           (1...max(count, 1)).contains(run.value) {
            return .pick(run.value)
        }
        // A new command replaces the list ("nein, öffne TKZ", "Ticket 412", "wait, open TKZ").
        let spoken = tokens.filter { !lx.holdWords.contains($0.text) }
        let first = spoken.first(where: { !lx.cancelWords.contains($0.text) })?.text ?? ""
        if lx.openVerbs.contains(first) || spoken.contains(where: { lx.taskWords.contains($0.text) }) {
            let c = command(tokens: spoken, lx)
            if c != .unknown { return .command(c) }
        }
        let names = content.filter { !lx.cancelWords.contains($0.text) && !lx.confirmWords.contains($0.text) }
        return names.isEmpty ? .unclear : .byName(names)
    }

    /// Frequent STT confusions for short German number words. "frei" is not here: it is a real word and picked #3
    /// from ambient speech (REVIEW m3). Extend only with real recordings.
    static func lookalikeDigit(_ t: String) -> Int? { Lexicon.de.lookalikeDigits[t] }

    // MARK: End of utterance (REVIEW M1)

    /// True when a live partial cannot be the whole utterance yet, so the end-of-utterance gate should wait longer:
    /// empty, ending in a numeral ("Ticket 4" may become 412), a task word, "Nummer", an open verb or a dangling
    /// article/preposition, or holding only fillers so far ("Öffne mir mal das").
    /// `choosing`: the answer phase of a visible list. There a numeral, an ordinal or a name ends the answer
    /// ("zwei", "die zweite", "Relaunch"), while a bare negation may lead into one ("nein, … die zweite").
    /// The one rule for dangling words: `HangoverPolicy` uses it for the live budget, the speech layer for reopening
    /// a dangling final and for its stable-transcript fallback, the flow for hesitations in the answer phase.
    public static func looksIncomplete(_ partial: String, choosing: Bool = false, language: AppLanguage = .de) -> Bool {
        let lx = Lexicon.of(language)
        let tokens = TextNorm.tokenize(partial, language: language)
        guard let last = tokens.last else { return true }
        if choosing {
            switch selection(partial, count: 9, language: language) {
            case .pick, .cancel, .more: return false
            case .keepListening: return true
            case .command: break                  // a new command: command-phase rules below
            case .byName, .unclear:
                return lx.danglingWords.contains(last.text) || lx.selectWords.contains(last.text) || isDanglingVerbOrTaskWord(last, lx)
                    || tokens.allSatisfy { isFiller($0, lx) || lx.selectWords.contains($0.text) }
            }
        }
        switch command(tokens: tokens, lx) {
        case .openMyTasks, .cancel: return false
        default: break
        }
        if isNumeral(last, lx) || lx.danglingWords.contains(last.text) || isDanglingVerbOrTaskWord(last, lx) { return true }
        return strip(tokens, lx).isEmpty
    }

    /// English answer phase: the last word of a live partial may still turn its pick into another answer. "one"
    /// becomes "one second" (a stall) unless an ordinal or "number" came before it ("the first one", "number one");
    /// "second" becomes "second to last" or "second last"; "Okay" becomes "Okay, cancel". A live pick from such a
    /// partial does not commit (`VoiceFlow` fastSelect); the final decides. German: always false.
    public static func pickMayChange(_ partial: String, language: AppLanguage = .de) -> Bool {
        guard language == .en else { return false }
        let lx = Lexicon.en
        let tokens = mergePhrases(TextNorm.tokenize(partial, language: language), lx.cancelPhrases)
        guard let last = tokens.last else { return false }
        // "Okay" may lead into "Okay, cancel" in a one-row prompt.
        if softConfirms.contains(last.text) || ordinal(last.text, lx) == 2 { return true }
        guard cardinal(last.key, lx) == 1 else { return false }
        return !tokens.dropLast().contains { t in
            ordinal(t.text, lx) != nil || lx.selectWords.contains(t.text) || lx.numberWords.contains(t.text)
        }
    }

    /// True when the last word is a numeral: digits or a number word, not "ein", "eine" or "und".
    /// In the command phase such a partial may still grow ("Ticket 4" -> 412, `HangoverPolicy.trailingNumber`).
    public static func endsInNumeral(_ text: String, language: AppLanguage = .de) -> Bool {
        guard let last = TextNorm.tokenize(text, language: language).last(where: { !$0.key.isEmpty }) else { return false }
        return isNumeral(last, .of(language))
    }

    /// A cancel word that is safe to act on in a live partial ("abbrechen", "cancel", "never mind"). "nein" and
    /// "egal" are not: "Nein, Ticket 412" goes on.
    public static func isStrongCancel(_ text: String, language: AppLanguage = .de) -> Bool {
        let lx = Lexicon.of(language)
        return mergePhrases(TextNorm.tokenize(text, language: language), lx.cancelPhrases).contains { lx.strongCancel.contains($0.key) }
    }

    static func isDanglingVerbOrTaskWord(_ t: Token, _ lx: Lexicon = .de) -> Bool {
        lx.openVerbs.contains(t.text) || lx.taskWords.contains(t.text) || lx.numberWords.contains(t.text)
    }

    // MARK: Helpers

    /// Project words of a command: drops fillers, task and number words, soft fillers and "eben" next to
    /// "mal"/"gerade"/"schnell". English keeps the joiners of a numeral run ("four oh two", "a hundred").
    static func strip(_ tokens: [Token], _ lx: Lexicon = .de) -> [Token] {
        let keep = lx.language == .en ? Set(numeralRuns(tokens, lx).flatMap { $0.range }) : []
        return tokens.indices.filter { i in
            if keep.contains(i) { return true }
            let t = tokens[i].text
            if isFiller(tokens[i], lx) || lx.taskWords.contains(t) || lx.numberWords.contains(t) || lx.softFillers.contains(t) { return false }
            if lx.language == .en, englishClosings.contains(t) { return false }
            if t == "eben" {
                if i > 0, lx.ebenBefore.contains(tokens[i - 1].text) { return false }
                if i + 1 < tokens.count, lx.ebenAfter.contains(tokens[i + 1].text) { return false }
            }
            return true
        }.map { tokens[$0] }
    }

    /// Merges phrases into one token each ("never mind" -> "nevermind"). At a position the longest phrase wins
    /// ("thank you so much" before "thank you"), the earlier one on a tie.
    static func mergePhrases(_ tokens: [Token], _ phrases: [(words: [String], merged: String)]) -> [Token] {
        guard !phrases.isEmpty else { return tokens }
        let ordered = phrases.enumerated()
            .sorted { $0.element.words.count != $1.element.words.count ? $0.element.words.count > $1.element.words.count
                : $0.offset < $1.offset }
            .map(\.element)
        var out: [Token] = [], i = 0
        outer: while i < tokens.count {
            for p in ordered where i + p.words.count <= tokens.count
                && zip(tokens[i..<(i + p.words.count)], p.words).allSatisfy({ $0.text == $1 }) {
                out.append(Token(text: p.merged)); i += p.words.count
                continue outer
            }
            out.append(tokens[i]); i += 1
        }
        return out
    }

    /// A word without project meaning: a filler, or an English pronoun such as "it" unless STT wrote it as an acronym
    /// ("IT Support").
    static func isFiller(_ t: Token, _ lx: Lexicon) -> Bool {
        lx.fillers.contains(t.text) || (!t.isAcronym && lx.lowercaseFillers.contains(t.text))
    }

    /// English closings that end a request like "thank you" ("Ticket 412, that's all"). Alone they cancel (`cancelWords`).
    static let englishClosings: Set<String> = ["thatsit", "thatsall", "allgood", "allset", "alldone"]

    /// English: STT writes "ticket four twelve" as "Ticket for 12" and "two twelve" as "to 12". A lookalike digit
    /// right before a numeral below 1000 starts the number right after a task word or "number" ("Ticket for 12" -> 412)
    /// and continues it after a first group below 100 ("Ticket 47 to 85" -> 47285, not after "tickets": "tickets 10 to
    /// 20" is a range). Elsewhere "for" and "to" stay fillers ("Go to 47285", "Relaunch for 2027", "Ticket 412 to 5").
    static func leadingLookalikes(_ tokens: [Token], _ lx: Lexicon) -> [Token] {
        func keyword(_ t: Token) -> Bool { lx.taskWords.contains(t.text) || lx.numberWords.contains(t.text) }
        var out = tokens
        for i in tokens.indices.dropFirst() where i + 1 < tokens.count {
            let inside = i >= 2 && keyword(out[i - 2]) && !["tickets", "tasks", "issues"].contains(out[i - 2].text)
                && isNumeral(out[i - 1], lx) && (cardinal(out[i - 1].key, lx) ?? 100) < 100
            guard let digit = lx.lookalikeDigits[tokens[i].text], !tokens[i].isAcronym, keyword(tokens[i - 1]) || inside,
                  isNumeral(tokens[i + 1], lx), let next = cardinal(tokens[i + 1].key, lx), next < 1000 else { continue }
            out[i] = Token(text: String(digit))
        }
        return out
    }

    /// English: "the maintenance one" names a project, not ticket 1 (`isPronounOne`). "ticket one", "number one",
    /// "twenty one" and the digit "1" stay numerals.
    static func pronounOne(_ tokens: [Token], _ lx: Lexicon, titleNumber: Bool) -> [Token] {
        tokens.indices.filter { !(tokens[$0].text == "one" && isPronounOne(tokens, $0, lx, titleNumber: titleNumber)) }
            .map { tokens[$0] }
    }

    /// A spoken "one" at `i` is a pronoun, never when a numeral or "oh"/"and" follows ("WWT one two"):
    /// - right after a project word, unless a task word before it still lacks its number ("ticket WWT one" is ticket 1;
    ///   "ticket 412 in the navigation one" and "ticket for the relaunch one" name a project),
    /// - without a task word: before "of" ("one of the WWT projects") or after "the" before a preposition ("the one
    ///   with maintenance"), and with `titleNumber` at the end after a number in digits that "the" introduces
    ///   ("the 2027 one", "the Sensor 45 one"). Only a project title tells that number from a ticket number that
    ///   ends in 1 ("the maintenance 58 one" -> 581): `Interpreter.command` decides (`pronounOneRun`).
    static func isPronounOne(_ tokens: [Token], _ i: Int, _ lx: Lexicon, titleNumber: Bool) -> Bool {
        let articles: Set<String> = ["the", "that", "this"]
        if i + 1 < tokens.count, isNumeral(tokens[i + 1], lx) || ["oh", "o", "and"].contains(tokens[i + 1].key) { return false }
        let before = tokens[..<i]
        let task = before.lastIndex { lx.taskWords.contains($0.text) }
        let prev = i > 0 ? tokens[i - 1] : nil
        if let p = prev, isProjectWord(p, lx),
           task.map({ k in tokens[(k + 1)..<i].contains { isNumeral($0, lx) || articles.contains($0.text) } }) ?? true {
            return true
        }
        guard task == nil else { return false }
        if prev.map({ !isNumeral($0, lx) && !lx.numberWords.contains($0.text) }) ?? true, i + 1 < tokens.count,
           tokens[i + 1].text == "of" || (prev.map { articles.contains($0.text) } == true
               && ["with", "for", "from", "in", "called", "named", "about", "on", "at"].contains(tokens[i + 1].text)) {
            return true
        }
        return titleNumber && prev.map { !$0.key.isEmpty && $0.key.allSatisfy(\.isNumber) } == true
            && tokens[(i + 1)...].allSatisfy { isFiller($0, lx) || lx.softFillers.contains($0.text) }
            && before.contains { articles.contains($0.text) } && !before.contains { lx.numberWords.contains($0.text) }
    }

    /// English: the number a final "one" follows when it may be a title number ("Open the 2027 one" -> 2027), nil when
    /// there is none. `Interpreter.command` checks it against the project titles and then drops the other
    /// transcriber's glued "20271".
    static func pronounOneRun(_ raw: String, language: AppLanguage) -> Int? {
        let lx = Lexicon.of(language)
        guard lx.language == .en else { return nil }
        let tokens = mergePhrases(TextNorm.tokenize(raw, language: language), lx.cancelPhrases + lx.holdPhrases)
        guard let i = tokens.lastIndex(where: { $0.text == "one" }), i > 0, isNumeral(tokens[i - 1], lx),
              isPronounOne(tokens, i, lx, titleNumber: true) else { return nil }
        return numeralRuns(Array(tokens[..<i]), lx).last { $0.range.upperBound == i }?.value
    }

    /// A word that can name a project: no filler, numeral, task, number, cancel or run word.
    static func isProjectWord(_ t: Token, _ lx: Lexicon) -> Bool {
        !isFiller(t, lx) && !isNumeral(t, lx) && !isRunWord(t, lx) && !lx.taskWords.contains(t.text)
            && !lx.numberWords.contains(t.text) && !lx.softFillers.contains(t.text) && !lx.cancelWords.contains(t.text)
    }

    enum OrdinalAnswer: Equatable { case pick(Int), notARow }

    /// English ordinal answer. The ordinal must head the answer: only negations, fillers, soft fillers, "number" or a
    /// hold word come before it ("no, the second", "I'll take the second"), and only "one", select words, task words
    /// or soft fillers after it ("the second one please"). "first of all", "the second WWT" and "one second" are no
    /// pick. "twenty second" is 22. "second to last", "second last" and "next to last" name the row before the last
    /// (`count - 1`); with fewer than two rows they are `.notARow`. nil: no ordinal answer.
    static func englishOrdinal(_ tokens: [Token], count: Int, _ lx: Lexicon) -> OrdinalAnswer? {
        let words = tokens.map(\.text)
        func lead(_ upTo: Int) -> Bool {
            tokens[..<upTo].allSatisfy { t in
                (isFiller(t, lx) && !["a", "an"].contains(t.text)) || lx.negations.contains(t.text) || lx.softFillers.contains(t.text)
                    || lx.selectWords.contains(t.text) || lx.holdWords.contains(t.text) || ordinalLeadIns.contains(t.text)
            }
        }
        func tail(_ from: Int) -> Bool {
            tokens[min(from, tokens.count)...].allSatisfy { t in
                t.text == "one" || lx.selectWords.contains(t.text) || lx.taskWords.contains(t.text)
                    || lx.softFillers.contains(t.text) || ["project", "please", "i", "think"].contains(t.text)
            }
        }
        // The row before the last.
        for (i, w) in words.enumerated() where ["second", "next"].contains(w) {
            let rest = Array(words[(i + 1)...])
            let length = rest.starts(with: ["to", "last"]) ? 3 : (w == "second" && rest.first == "last" ? 2 : 0)
            guard length > 0 else { continue }
            guard lead(i), tail(i + length) else { return nil }
            return count >= 2 ? .pick(count - 1) : .notARow
        }
        for (i, t) in tokens.enumerated() {
            guard var o = ordinal(t.text, lx) else { continue }
            var start = i
            // "twenty second" -> 22 ("twenty-second" arrives as two words).
            if i > 0, let tens = EnglishNumbers.tens[tokens[i - 1].key], (1...9).contains(o) { o += tens; start = i - 1 }
            return lead(start) && tail(i + 1) ? .pick(o) : nil
        }
        return nil
    }

    public static func isNumeral(_ t: Token, language: AppLanguage = .de) -> Bool { isNumeral(t, .of(language)) }

    /// Words that only lead into an English ordinal answer ("I think the second", "how about the third one").
    /// Not "a", "an" or "one": "wait a second" and "one second" stay no pick.
    static let ordinalLeadIns: Set<String> = ["think", "guess", "say", "maybe", "probably", "perhaps", "definitely", "how",
                                               "about", "do", "try", "make", "mm", "mmm"]

    /// English confirm words that often only lead into the answer ("Okay, cancel"). Alone they confirm a one-row prompt.
    static let softConfirms: Set<String> = ["okay", "ok", "alright"]

    static func isNumeral(_ t: Token, _ lx: Lexicon) -> Bool {
        !lx.notNumerals.contains(t.key) && cardinal(t.key, lx) != nil
    }

    /// English words that only join a numeral run ("four oh two", "a hundred", "hundred and twelve").
    static func isRunWord(_ t: Token, _ lx: Lexicon) -> Bool {
        lx.language == .en && ["oh", "o", "a", "and"].contains(t.key)
    }

    static func cardinal(_ s: String, _ lx: Lexicon) -> Int? {
        lx.language == .de ? GermanNumbers.cardinal(s) : EnglishNumbers.cardinal(s)
    }

    static func ordinal(_ s: String, _ lx: Lexicon) -> Int? {
        lx.language == .de ? GermanNumbers.ordinal(s) : EnglishNumbers.ordinal(s)
    }

    /// Maximal runs of adjacent numerals with their composed value ("4 12" -> 412).
    /// German: a standalone "und" between two numerals belongs to the run ("acht und funfzig").
    /// English: "and" after "hundred"/"thousand" ("four hundred and twelve"), "oh" as zero between numerals
    /// ("four oh two") and "a" before "hundred"/"thousand" ("a hundred twelve") belong to the run.
    static func numeralRuns(_ tokens: [Token], _ lx: Lexicon = .de) -> [(range: Range<Int>, value: Int)] {
        lx.language == .de ? germanRuns(tokens, lx) : englishRuns(tokens, lx)
    }

    private static func germanRuns(_ tokens: [Token], _ lx: Lexicon) -> [(range: Range<Int>, value: Int)] {
        var runs: [(Range<Int>, Int)] = []
        var i = 0
        while i < tokens.count {
            guard isNumeral(tokens[i], lx) else { i += 1; continue }
            var parts: [GermanNumbers.Part] = []
            var j = i
            while j < tokens.count {
                let k = tokens[j].key
                if isNumeral(tokens[j], lx) {
                    parts.append(.init(value: GermanNumbers.cardinal(k)!, isMultiplierWord: k == "hundert" || k == "tausend"))
                } else if k == "und", j > i, j + 1 < tokens.count, isNumeral(tokens[j + 1], lx),
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

    private static func englishRuns(_ tokens: [Token], _ lx: Lexicon) -> [(range: Range<Int>, value: Int)] {
        let multipliers: Set<String> = ["hundred", "thousand"]
        let zeros: Set<String> = ["oh", "o"]
        func key(_ i: Int) -> String? { tokens.indices.contains(i) ? tokens[i].key : nil }
        func numeral(_ i: Int) -> Bool { tokens.indices.contains(i) && isNumeral(tokens[i], lx) }
        var runs: [(Range<Int>, Int)] = []
        var i = 0
        while i < tokens.count {
            let article = key(i) == "a" && key(i + 1).map(multipliers.contains) == true
            guard numeral(i) || article else { i += 1; continue }
            var parts: [GermanNumbers.Part] = []
            var j = i
            while j < tokens.count {
                let k = tokens[j].key
                if numeral(j) {
                    parts.append(.init(value: EnglishNumbers.cardinal(k)!, isMultiplierWord: multipliers.contains(k)))
                } else if j == i, article {
                    parts.append(.init(value: 1))                                         // "a hundred"
                } else if k == "and", j > i, multipliers.contains(tokens[j - 1].key), numeral(j + 1) {
                    // "four hundred and twelve": the "and" adds nothing.
                } else if zeros.contains(k), j > i,
                          numeral(j + 1) || key(j + 1).map(zeros.contains) == true || zeros.contains(tokens[j - 1].key) {
                    parts.append(.init(value: 0))                                         // "four oh two"
                } else { break }
                j += 1
            }
            if let v = englishValue(parts) { runs.append((i..<j, v)) }
            i = j
        }
        return runs
    }

    /// A run with a zero digit ("four oh two", "four zero two") is read digit by digit: 402, not 42. Otherwise
    /// place values compose (`GermanNumbers.compose`).
    private static func englishValue(_ parts: [GermanNumbers.Part]) -> Int? {
        guard parts.contains(where: { $0.value == 0 }), !parts.contains(where: \.isMultiplierWord) else {
            return GermanNumbers.compose(parts)
        }
        let digits = parts.map { String($0.value) }.joined()
        guard digits.count <= String(GermanNumbers.composeLimit).count, let n = Int(digits), n <= GermanNumbers.composeLimit
        else { return nil }
        return n
    }
}
