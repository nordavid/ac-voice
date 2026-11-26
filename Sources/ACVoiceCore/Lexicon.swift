import Foundation

extension AppLanguage {
    /// The language of a speech locale: German for any "de" locale, English for everything else.
    public init(locale: Locale) {
        self = locale.language.languageCode == .german ? .de : .en
    }
}

/// The words the parser reads per language (`Parser`). Every word is folded lowercase, as `TextNorm.tokenize`
/// writes it. Project codes and titles are not here: they are the AC names and stay language-neutral.
struct Lexicon: Sendable {
    let language: AppLanguage
    /// Words without project meaning in a command: verbs, articles, prepositions, politeness, hesitations.
    let fillers: Set<String>
    let taskWords: Set<String>
    let numberWords: Set<String>
    /// Words that only point at a row in a list ("Nummer", "option").
    let selectWords: Set<String>
    /// Everyday particles and politeness that carry no project meaning in a command ("Ticket 412, danke",
    /// "Öffne gleich WWT"). Command phase only: `Parser.selection` keeps "ja" / "yes" as a confirm word.
    let softFillers: Set<String>
    /// German only: "eben" is filler next to these words ("mal eben", "eben mal", "gerade eben", "eben schnell",
    /// `Parser.strip`). Alone it stays a project word, because STT hears the code "IBN" as "eben" (alias, REVIEW m9).
    let ebenBefore: Set<String>
    let ebenAfter: Set<String>
    let cancelWords: Set<String>
    /// Words a closing may carry: "None of them", "Close the list", "That's all for today".
    let closingObjects: Set<String>
    /// Cancel words that are safe to act on in a live partial ("nein" is not: "Nein, Ticket 412" goes on).
    let strongCancel: Set<String>
    /// Token runs that stand for one cancel word ("never mind" -> "nevermind"), merged before parsing. The longest
    /// phrase wins at a position (`Parser.mergePhrases`).
    let cancelPhrases: [(words: [String], merged: String)]
    /// Words without project meaning unless STT writes them as an acronym: "close it", "that's all", but "IT Support".
    let lowercaseFillers: Set<String>
    /// Answer phase only: token runs that only stall ("a second", "hang on"), merged into one `holdWords` word.
    let holdPhrases: [(words: [String], merged: String)]
    /// Answer phase only: an answer of these words (and fillers) keeps listening ("wait", "one second").
    let holdWords: Set<String>
    /// Words after which a command or answer cannot end (REVIEW M1, `Parser.looksIncomplete`).
    let danglingWords: Set<String>
    /// Negations that lead into a real answer ("nein, die zweite", "no, the second").
    let negations: Set<String>
    let confirmWords: Set<String>
    let moreWords: Set<String>
    let openVerbs: Set<String>
    /// Phrases for "my tasks", padded with one space on both sides.
    let myTaskPhrases: [String]
    /// Words that are articles or joiners far more often than numbers.
    let notNumerals: Set<String>
    /// Short answers STT writes for a number word ("zwai", "to").
    let lookalikeDigits: [String: Int]
    /// A short answer holds at most this many tokens when an ordinal in it picks a row. German reads the ordinal
    /// anywhere in it, English only at its head ("wait a second" is no pick).
    let ordinalAnswerTokens: Int

    static func of(_ language: AppLanguage) -> Lexicon { language == .de ? de : en }

    // MARK: German

    static let de = Lexicon(
        language: .de,
        fillers: [
            "offne", "offnen", "oeffne", "offnet", "mach", "mache", "auf", "zeig", "zeige", "zeigen", "mir", "mal", "doch",
            "bitte", "das", "die", "den", "dem", "der", "des", "projekt", "projekte", "project", "geh", "gehe", "zu", "zum",
            "zur", "in", "ins", "im", "wechsel", "wechsle", "spring", "springe", "open", "kannst", "du", "hol", "hole",
            "lade", "starte", "jetzt", "schnell", "nimm", "nehme", "nehmen", "ich", "will", "mochte", "gern", "gerne",
            "hey", "jarvis", "von", "vom", "fur", "bring", "bringe", "mich", "ah", "ahm", "hm", "also", "na", "okay",
            "ok", "aufmachen", "anzeigen", "aufrufen", "konntest", "bei", "an", "einmal", "kurz", "ein", "eine",
            "einen", "einem", "einer", "mein", "meine", "meinen", "meinem", "meiner", "und", "noch", "nochmal", "so",
            "sofort", "bitteschon", "dieses", "diese", "dieser", "diesen", "hier", "da", "aus", "auch",
        ],
        taskWords: [
            "ticket", "tickets", "task", "tasks", "aufgabe", "issue", "ticker", "ticketnummer", "tasknummer", "aufgabennummer",
        ],
        numberWords: ["nummer", "nr", "no", "number"],
        selectWords: ["nummer", "nr", "option", "eintrag", "punkt", "zeile"],
        softFillers: [
            "danke", "dankeschon", "schon", "gleich", "gerade", "aber", "halt", "nun", "eigentlich", "ja", "okay",
            "please", "thanks",
        ],
        ebenBefore: ["mal", "gerade", "grad", "jetzt"],
        ebenAfter: ["mal", "schnell", "kurz"],
        cancelWords: ["abbrechen", "abbruch", "stopp", "stop", "egal", "vergiss", "schliessen", "nein", "nichts", "cancel", "danke", "dankeschon"],
        closingObjects: [],
        strongCancel: ["abbrechen", "abbruch", "stopp", "stop", "cancel"],
        cancelPhrases: [],
        lowercaseFillers: [],
        holdPhrases: [],
        holdWords: [],
        danglingWords: [
            "das", "die", "den", "dem", "der", "des", "ein", "eine", "einen", "einem", "einer", "mein", "meine", "meinen",
            "meinem", "meiner", "dieses", "diese", "dieser", "diesen", "zu", "zum", "zur", "in", "ins", "im", "von", "vom",
            "fur", "bei", "mir", "mich", "und", "plus", "oder",
        ],
        negations: ["nein", "ne", "nee", "no", "noe", "nope"],
        confirmWords: ["ja", "jawohl", "genau", "passt", "richtig", "korrekt", "yes", "jep"],
        moreWords: ["mehr", "weitere", "weiter", "andere", "nachste", "rest"],
        openVerbs: ["offne", "oeffne", "offnet", "mach", "zeig", "zeige", "geh", "gehe", "wechsel", "wechsle", "spring", "bring", "hol"],
        myTaskPhrases: [" meine aufgaben ", " meine aufgabe ", " meine tasks ", " meine tickets ", " meine todos ",
                        " my work ", " bei mir an ", " was steht an ", " was steht heute an ", " mir zugewiesen ",
                        " meine offenen ", " meine arbeit ", " was liegt an "],
        notNumerals: ["ein", "eine", "und"],
        // "frei" is not here: it is a real word and picked #3 from ambient speech (REVIEW m3).
        lookalikeDigits: ["zwai": 2, "zwo": 2, "dry": 3, "fier": 4, "funf": 5, "fuenf": 5],
        ordinalAnswerTokens: 4
    )

    // MARK: English

    static let en = Lexicon(
        language: .en,
        fillers: [
            // Verbs that open or show something.
            "open", "opens", "opening", "show", "display", "go", "goto", "get", "take", "bring", "pull", "load",
            "switch", "jump", "navigate", "head", "find", "search", "look", "see", "view", "pick", "choose", "select",
            "use", "give", "gimme",
            // Pronouns, articles, prepositions.
            "me", "my", "us", "the", "a", "an", "this", "that", "these", "those", "to", "into", "in", "inside", "on", "at",
            "of", "for", "from", "with", "up", "and", "is", "what", "whats", "where", "wheres", "there",
            // Requests and wishes ("can you", "I'd like", "let's").
            "can", "could", "would", "will", "you", "i", "id", "im", "ill", "ive", "want", "wanna", "need", "like",
            "let", "lets", "please",
            "project", "projects", "page", "ones",
            // Hesitations and greetings.
            "hey", "jarvis", "um", "uh", "uhm", "umm", "er", "erm", "hmm", "hm", "ah", "oh", "so", "well", "then", "also",
        ],
        taskWords: ["ticket", "tickets", "task", "tasks", "issue", "issues", "ticker"],
        numberWords: ["number", "num", "nr", "no"],
        selectWords: ["number", "num", "nr", "option", "item", "entry", "line", "row", "choice", "page"],
        softFillers: [
            "thanks", "thank", "thankyou", "please", "yes", "yeah", "yep", "ok", "okay", "right", "alright", "actually", "just",
            "now", "again", "real", "quick", "quickly", "cheers", "sure", "though", "anyway",
        ],
        ebenBefore: [],
        ebenAfter: [],
        // "thatsit", "alright" and the rest come from `cancelPhrases`: closings that end the session ("That's all").
        cancelWords: ["cancel", "stop", "abort", "nevermind", "forget", "forgetit", "close", "nothing", "no", "nope", "quit",
                      "exit", "dismiss", "thanks", "thankyou", "thatsit", "thatsall", "alright", "allgood", "allset",
                      "alldone", "leaveit", "skipit", "dropit", "none", "neither", "done", "bye", "goodbye"],
        closingObjects: ["them", "list", "window", "listening", "today"],
        strongCancel: ["cancel", "stop", "abort", "nevermind"],
        cancelPhrases: [
            (["thank", "you", "so", "much"], "thankyou"), (["thank", "you", "very", "much"], "thankyou"),
            (["thanks", "so", "much"], "thanks"), (["thanks", "very", "much"], "thanks"), (["thanks", "a", "lot"], "thanks"),
            (["many", "thanks"], "thanks"), (["thank", "you"], "thankyou"),
            (["never", "mind"], "nevermind"), (["forget", "about", "it"], "forgetit"), (["forget", "it"], "forgetit"),
            (["forget", "that"], "forgetit"), (["thats", "it"], "thatsit"), (["thats", "all"], "thatsall"),
            (["all", "right"], "alright"), (["all", "good"], "allgood"), (["all", "set"], "allset"),
            (["all", "done"], "alldone"), (["leave", "it"], "leaveit"), (["skip", "it"], "skipit"), (["drop", "it"], "dropit"),
        ],
        // "it" is the pronoun in "close it", "IT" the code in "QZ IT Support" (`Token.isAcronym`). "all" would
        // prefix-match title words such as "Allgemein".
        lowercaseFillers: ["it", "its", "thats", "all"],
        // "wait a second" stalls; "second" alone is still the ordinal ("the second").
        holdPhrases: [
            (["a", "second"], "wait"), (["one", "second"], "wait"), (["a", "sec"], "wait"), (["one", "sec"], "wait"),
            (["a", "moment"], "wait"), (["one", "moment"], "wait"), (["a", "minute"], "wait"), (["one", "minute"], "wait"),
            (["hang", "on"], "wait"), (["hold", "on"], "wait"), (["let", "me", "think"], "wait"), (["let", "me", "see"], "wait"),
            (["lets", "see"], "wait"),
        ],
        holdWords: ["wait"],
        danglingWords: [
            "the", "a", "an", "to", "into", "in", "on", "at", "of", "for", "from", "with", "by", "my", "me", "your", "our",
            "this", "that", "and", "plus", "or",
        ],
        negations: ["no", "nope", "nah", "naw"],
        // "All right" confirms a one-row prompt; with several rows and in a command it closes (`cancelWords`).
        // "ahead" is what "Go ahead" leaves, as "go" is a filler.
        confirmWords: ["yes", "yeah", "yep", "yup", "yea", "correct", "right", "exactly", "sure", "affirmative", "alright",
                       "okay", "ok", "ahead"],
        moreWords: ["more", "next", "other", "others", "rest", "further"],
        openVerbs: ["open", "show", "display", "go", "get", "take", "bring", "pull", "load", "switch", "jump", "navigate",
                    "find", "view"],
        myTaskPhrases: [" my tasks ", " my task ", " my work ", " my todos ", " my todo ", " my to dos ", " my to do ",
                        " my tickets ", " my issues ", " my open ", " my assignments ", " my assigned tasks ",
                        " on my plate ", " assigned to me "],
        notNumerals: [],
        // Single-word answers STT writes for a number word. Only a whole answer counts ("To." -> 2), never a word in a
        // sentence.
        // After "ticket" or "number" and before a numeral they start the number ("Ticket for 12" -> 412,
        // `Parser.leadingLookalikes`).
        lookalikeDigits: ["to": 2, "too": 2, "for": 4, "fore": 4, "won": 1],
        // English reads an ordinal only at the head of the answer (`Parser.englishOrdinal`), so a longer answer is safe.
        ordinalAnswerTokens: 7
    )
}
