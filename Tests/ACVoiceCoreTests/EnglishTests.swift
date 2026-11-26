import Foundation
import Testing
@testable import ACVoiceCore

/// English voice commands: the German suites (TextAndParserTests, TicketAndSelectionTests, IntegrationTests) mirrored
/// for `AppLanguage.en`. Project codes and titles stay the AC names of Tests/Fixtures/projects.sample.json.
enum EnglishFixture {
    static let interpreter = Interpreter(resolver: Resolver(projects: Fixture.projects), language: .en)

    /// Id-only outcome of an English command ("unique 628", "choices 628,314,315,693", "task 412 -").
    static func run(_ texts: String..., weights: [Double]? = nil) -> String {
        let hyps = texts.enumerated().map { Hypothesis($0.element, weight: weights?[$0.offset] ?? 1) }
        return Regression.describe(interpreter.command(hyps, now: Fixture.now))
    }

    static func request(_ text: String) -> TaskRequest? {
        if case let .task(t) = interpreter.command([Hypothesis(text)], now: Fixture.now) { return t }
        return nil
    }

    static func command(_ s: String) -> Command { Parser.command(s, language: .en) }
}

@Suite struct EnglishTextTests {
    @Test(arguments: [
        ("double-u double-u tee", "WWT"), ("Double U double U T", "WWT"), ("double you double you tee", "WWT"),
        ("W W T", "WWT"), ("W.W.T.", "WWT"), ("WW T", "WWT"), ("Open WWTilonch.", "WWT"), ("Open WWT's Relaunch", "WWT"),
        ("es and kay", "S+K"), ("S and K", "S+K"), ("S & K", "S+K"), ("S&K", "S+K"), ("ess plus kay", "S+K"),
        ("I B N", "IBN"), ("eye bee en", "IBN"), ("tee kay zed", "TKZ"), ("tea kay zee", "TKZ"), ("are bee zed", "RBZ"),
        ("cue zee CRM", "QZ"), ("bee dee gee", "BDG"), ("Q Z C R M", "QZCRM"), ("zed em ef", "ZMF"),
    ])
    func spelling(input: String, expect: String) {
        #expect(TextNorm.tokenize(input, language: .en).contains { $0.isAcronym && $0.text.uppercased() == expect }, "\(input)")
    }

    /// Weak letter names are common English words: they never turn a sentence into a code.
    @Test(arguments: ["can you see", "are you there", "I see why", "you are", "oh I see", "be there", "what's on my plate",
                      "I'll take the second one", "it's IBN", "can you see WWT", "you and I", "a bee", "Open a WWT",
                      "Maintenance", "Website", "Leasing Cockpit", "Navigation", "teepee", "double check"])
    func noFalseSpelling(_ s: String) {
        #expect(!TextNorm.tokenize(s, language: .en).contains { $0.isAcronym && !s.contains($0.text.uppercased()) }, "\(s)")
    }

    @Test func fixtureTitlesStayWords() {
        for p in Fixture.projects {
            let created = TextNorm.tokenize(p.title, language: .en)
                .filter { $0.isAcronym && !p.title.uppercased().contains($0.text.uppercased()) }
            #expect(created.isEmpty, "\(p.id)")
        }
    }

    @Test func germanLetterNamesStayGerman() {
        // "we we te" is German speech; English speech spells W as "double u".
        #expect(!TextNorm.tokenize("we we te", language: .en).contains { $0.isAcronym })
        #expect(TextNorm.tokenize("we we te").contains { $0.isAcronym && $0.text == "wwt" })
        #expect(!TextNorm.tokenize("double u double u tee").contains { $0.isAcronym && $0.text == "wwt" })
    }

    @Test func cleaning() {
        #expect(TextNorm.tokenize("Ticket 47,285", language: .en).map(\.key) == ["ticket", "47285"])
        #expect(TextNorm.tokenize("Ticket 47.285", language: .en).map(\.key) == ["ticket", "47285"])
        #expect(TextNorm.tokenize("what's on my plate", language: .en).map(\.key) == ["whats", "on", "my", "plate"])
        #expect(TextNorm.tokenize("I'll take WWT's", language: .en).map(\.key) == ["ill", "take", "wwt"])
        // German keeps "47,285" as two numbers (a decimal comma).
        #expect(TextNorm.tokenize("Ticket 47,285").map(\.key) == ["ticket", "47", "285"])
    }

    @Test func folding() {
        #expect(TextNorm.fold("Äpfel Straße", language: .en) == "apfel strasse")
        #expect(TextNorm.fold("Äpfel") == TextNorm.fold("Äpfel", language: .de))
        #expect(TextNorm.tokenize("Händlerportal", language: .en).map(\.key) == ["handlerportal"])
    }

    @Test func metaphone() {
        #expect(Fuzzy.metaphone("relaunch") == "RLNX")
        #expect(Fuzzy.metaphone("relonch") == "RLNX" && Fuzzy.metaphone("rilonch") == "RLNX")
        #expect(Fuzzy.metaphone("maintenance") == Fuzzy.metaphone("maintainance"))
        #expect(Fuzzy.metaphone("navigation") == Fuzzy.metaphone("navigashun"))
        #expect(Fuzzy.metaphone("cockpit") == Fuzzy.metaphone("kokpit"))
        #expect(Fuzzy.metaphone("knowledge") == Fuzzy.metaphone("nowledge"))
        #expect(Fuzzy.metaphone("phone") == Fuzzy.metaphone("fone"))
        #expect(Fuzzy.metaphone("website") != Fuzzy.metaphone("relaunch"))
        #expect(Fuzzy.metaphone("") == "" && Fuzzy.metaphone("123") == "")
        // German keeps Koelner Phonetik.
        #expect(Fuzzy.phonetic("relaunch", language: .de) == Fuzzy.cologne("relaunch"))
        #expect(Fuzzy.phonetic("relaunch", language: .en) == Fuzzy.metaphone("relaunch"))
    }

    @Test func localeMapsToLanguage() {
        #expect(AppLanguage(locale: Locale(identifier: "de_DE")) == .de)
        #expect(AppLanguage(locale: Locale(identifier: "de_AT")) == .de)
        #expect(AppLanguage(locale: Locale(identifier: "en_US")) == .en)
        #expect(AppLanguage(locale: AppLanguage.en.speechLocale) == .en && AppLanguage(locale: AppLanguage.de.speechLocale) == .de)
    }
}

@Suite struct EnglishNumberTests {
    @Test func words() {
        #expect(EnglishNumbers.cardinal("twelve") == 12 && EnglishNumbers.cardinal("fortyseven") == 47)
        #expect(EnglishNumbers.cardinal("hundred") == 100 && EnglishNumbers.cardinal("zero") == 0)
        #expect(EnglishNumbers.cardinal("412") == 412)
        for w in ["a", "and", "oh", "often", "tent", "seventh", "ones", "forty seven"] { #expect(EnglishNumbers.cardinal(w) == nil, "\(w)") }
        #expect(EnglishNumbers.ordinal("second") == 2 && EnglishNumbers.ordinal("2nd") == 2 && EnglishNumbers.ordinal("12th") == 12)
        #expect(EnglishNumbers.ordinal("last") == -1 && EnglishNumbers.ordinal("twelfth") == 12)
        #expect(EnglishNumbers.ordinal("secondly") == nil && EnglishNumbers.ordinal("2") == nil)
    }

    @Test func spelledReadsBack() {
        for n in 1...99 {
            let s = try! #require(EnglishNumbers.spelled(n))
            #expect(Parser.command("Ticket \(s)", language: .en) == .openTask(query: [], number: n), "\(n): \(s)")
        }
        #expect(EnglishNumbers.spelled(0) == nil && EnglishNumbers.spelled(100) == nil)
    }

    @Test(arguments: [
        ("Open ticket 47,285.", 47285), ("Open ticket 47285", 47285), ("Ticket four hundred twelve", 412),
        ("Ticket four hundred and twelve", 412), ("Ticket four twelve", 412), ("Ticket four one two", 412),
        ("Open ticket 4 12", 412), ("Open ticket 400 12", 412), ("Ticket four-twelve", 412), ("Ticket 47000 285", 47285),
        ("Ticket forty-seven thousand two hundred eighty-five", 47285),
        ("Ticket forty seven thousand two hundred and eighty five", 47285), ("Ticket forty seven two eighty five", 47285),
        ("Ticket four seven two eight five", 47285), ("Ticket four oh two", 402), ("Ticket four oh oh", 400),
        ("Ticket a hundred twelve", 112), ("Ticket number 412", 412), ("Ticket No. 412", 412), ("Ticket #412", 412),
        ("open 47285", 47285), ("open 47 285", 47285), ("open forty seven two eighty five", 47285),
    ])
    func ticketNumbers(text: String, n: Int) {
        guard case let .openTask(q, number) = EnglishFixture.command(text) else { Issue.record("\(text)"); return }
        #expect(number == n && q.isEmpty, "\(text) -> \(number) \(q)")
    }

    @Test func overflowNeverTraps() {
        #expect(EnglishFixture.command("Ticket 5 1234567890123456789") == .unknown)
        if case .openTask = EnglishFixture.command("Ticket 99999999999999999999999") { Issue.record("beyond Int.max is no number") }
        #expect(EnglishFixture.command("Ticket thousand thousand thousand") == .unknown)
        #expect(EnglishFixture.run("Open WWT 1 1000000000000000000") == "none")
    }

    @Test func leftoverNumeralsStayInQuery() {
        // "and" joins a run only after "hundred" / "thousand": 5 is a separate (leftover) numeral.
        #expect(EnglishFixture.command("Ticket 412 and 5") == .openTask(query: [Token(text: "5")], number: 412))
    }

    @Test(arguments: ["Open 412", "two", "412", "Open a", "oh"])
    func smallBareNumberIsNotACommand(_ s: String) { #expect(EnglishFixture.command(s) == .unknown, "\(s)") }
}

@Suite struct EnglishCommandParserTests {
    typealias E = EnglishFixture

    @Test(arguments: ["My tasks", "Show my tasks", "Open my tasks", "Show me my work", "What's on my plate",
                      "my to-dos please", "What's assigned to me", "Show my open tasks", "my task"])
    func myTasks(_ s: String) { #expect(E.command(s) == .openMyTasks, "\(s)") }

    @Test func myTaskWithNumberIsATicket() {
        #expect(E.command("Open my task 412") == .openTask(query: [], number: 412))
    }

    @Test func ticketWithProject() {
        guard case let .openTask(q, n) = E.command("Open WWT ticket 412") else { Issue.record(); return }
        #expect(n == 412 && q.map(\.key) == ["wwt"])
        guard case let .openTask(q2, n2) = E.command("Ticket 412 in WWT Relaunch") else { Issue.record(); return }
        #expect(n2 == 412 && q2.map(\.key) == ["wwt", "relaunch"])
        guard case let .openTask(q3, n3) = E.command("Open ticket WWT 412") else { Issue.record(); return }
        #expect(n3 == 412 && q3.map(\.key) == ["wwt"])
        guard case let .openTask(q4, n4) = E.command("Show me task four twelve of the S and K Leasing Cockpit")
        else { Issue.record(); return }
        #expect(n4 == 412 && q4.map(\.key) == ["sk", "leasing", "cockpit"])
    }

    @Test func implicitTicketIsLeftToTheInterpreter() {
        guard case let .openProject(q) = E.command("Open WWT 412") else { Issue.record(); return }
        #expect(q.map(\.key) == ["wwt", "412"])
        let imp = Parser.implicitTicket(q, language: .en)
        #expect(imp?.number == 412 && imp?.project.map(\.key) == ["wwt"] && imp?.numeralIndices == 1..<2)
        // "oh" stays inside the run instead of falling out as a filler.
        guard case let .openProject(q2) = E.command("Open WWT four oh two") else { Issue.record(); return }
        #expect(Parser.implicitTicket(q2, language: .en)?.number == 402)
        #expect(Parser.implicitTicket(TextNorm.tokenize("412", language: .en), language: .en) == nil)
        #expect(Parser.implicitTicket(TextNorm.tokenize("WWT Relaunch", language: .en), language: .en) == nil)
    }

    @Test(arguments: ["cancel", "Cancel.", "stop", "never mind", "Nevermind.", "forget it", "Forget about it", "No.",
                      "nope", "Thanks.", "Thank you", "No thanks", "cancel please", "abort"])
    func cancel(_ s: String) { #expect(E.command(s) == .cancel, "\(s)") }

    @Test(arguments: ["Open ticket 412, thanks", "Ticket 412 please", "Can you open ticket 412", "Yes, ticket 412",
                      "Just open ticket 412 now", "Ticket 412 okay", "Could you please show me ticket 412",
                      "No, ticket 412", "I'd like to see ticket 412"])
    func softFillersAreNoProjectWords(_ s: String) {
        #expect(E.command(s) == .openTask(query: [], number: 412), "\(s)")
    }

    @Test(arguments: [
        ("Open the WWT project", ["wwt"]), ("Can you please open the WWT project", ["wwt"]), ("Go to WWT Relaunch", ["wwt", "relaunch"]),
        ("Show me the S and K Leasing Cockpit", ["sk", "leasing", "cockpit"]), ("I'd like to see IBN", ["ibn"]),
        ("Pull up eye bee en Betreuung", ["ibn", "betreuung"]), ("no, WWT", ["wwt"]), ("Hey Jarvis, open QZ IT Support", ["qz", "it", "support"]),
        ("Switch to the double-u double-u tee project", ["wwt"]), ("Open Hollenstein and Co", ["hollenstein", "co"]),
    ])
    func fillers(text: String, keys: [String]) {
        guard case let .openProject(q) = E.command(text) else { Issue.record("\(text)"); return }
        #expect(q.map(\.key) == keys, "\(text) -> \(q)")
    }

    @Test func strongCancel() {
        #expect(Parser.isStrongCancel("cancel", language: .en) && Parser.isStrongCancel("never mind", language: .en))
        #expect(Parser.isStrongCancel("stop", language: .en))
        #expect(!Parser.isStrongCancel("No, ticket 412", language: .en) && !Parser.isStrongCancel("thanks", language: .en))
        #expect(Parser.isStrongCancel("abbrechen") && !Parser.isStrongCancel("abbrechen", language: .en))
    }

    @Test func languagesDoNotMix() {
        // The German parser does not know English fillers, and the other way round.
        #expect(Parser.command("Zeig meine Aufgaben", language: .en) != .openMyTasks)
        #expect(Parser.command("show my tasks") != .openMyTasks)
        #expect(Parser.command("Ticket vierhundertzwölf", language: .en) != .openTask(query: [], number: 412))
    }
}

@Suite struct EnglishSelectionParserTests {
    @Test(arguments: [
        ("no", Selection.keepListening), ("No.", .keepListening), ("no no", .keepListening), ("nope", .keepListening),
        ("cancel", .cancel), ("no, cancel", .cancel), ("never mind", .cancel), ("yes", .keepListening), ("Exactly.", .keepListening),
        ("no, the second", .pick(2)), ("Nope, the fourth", .pick(4)), ("nah, three", .pick(3)), ("number two", .pick(2)),
        ("the second one", .pick(2)), ("second one", .pick(2)), ("2", .pick(2)), ("2nd", .pick(2)), ("two", .pick(2)),
        ("Two please", .pick(2)), ("To.", .pick(2)), ("for", .pick(4)), ("option three", .pick(3)), ("the last one", .pick(-1)),
        ("I'll take the second one", .pick(2)), ("one", .pick(1)), ("more", .more), ("next", .more), ("Show more", .more),
        ("Next page", .more), ("Free.", .byName([Token(text: "free")])), ("Relaunch", .byName([Token(text: "relaunch")])),
        ("twenty one", .byName([Token(text: "twenty"), Token(text: "one")])),   // beyond the list: no pick
    ])
    func fourItems(text: String, expect: Selection) {
        #expect(Parser.selection(text, count: 4, language: .en) == expect, "\(text)")
    }

    @Test func confirmNeedsExactlyOneItem() {
        #expect(Parser.selection("yes", count: 1, language: .en) == .pick(1))
        #expect(Parser.selection("yeah sure", count: 1, language: .en) == .pick(1))
        #expect(Parser.selection("correct", count: 2, language: .en) == .keepListening)
        #expect(Parser.selection("no", count: 1, language: .en) == .cancel)
        #expect(Parser.selection("No, no.", count: 1, language: .en) == .cancel)
        #expect(Parser.selection("no, the first", count: 1, language: .en) == .pick(1))
        // A number outside the list is no pick: the interpreter matches it as a name and finds nothing.
        #expect(Parser.selection("seven", count: 4, language: .en) == .byName([Token(text: "seven")]))
    }

    @Test func numbersInSeveralWords() {
        #expect(Parser.selection("twenty one", count: 24, language: .en) == .pick(21))
        #expect(Parser.selection("number twenty-two", count: 24, language: .en) == .pick(22))
        #expect(Parser.selection("two three", count: 24, language: .en) == .pick(23))
        #expect(Parser.selection("twenty one Relaunch", count: 24, language: .en) == .byName(
            [Token(text: "twenty"), Token(text: "one"), Token(text: "relaunch")]))
    }

    @Test func newCommandReplacesTheList() {
        #expect(Parser.selection("no, open TKZ", count: 4, language: .en)
            == .command(.openProject(query: [Token(text: "tkz", isAcronym: true)])))
        #expect(Parser.selection("ticket 47285", count: 4, language: .en) == .command(.openTask(query: [], number: 47285)))
    }
}

/// REVIEW M1 for English: the end-of-utterance gate waits longer while the partial cannot be complete.
@Suite struct EnglishIncompleteTranscriptTests {
    @Test(arguments: ["", "  ", "Open", "Open the", "Can you", "Show me", "Open the project", "Ticket", "Ticket number",
                      "Open WWT ticket 4", "Open 47000", "Open WWT 412", "Open S and", "Open ticket 412 in", "Show my",
                      "Hey Jarvis", "Go to", "Open ticket four hundred"])
    func incomplete(_ s: String) { #expect(Parser.looksIncomplete(s, language: .en), "\(s)") }

    @Test(arguments: ["Open the WWT project", "Open WWT Relaunch", "WWT", "My tasks", "What's on my plate", "Cancel",
                      "Never mind", "Thanks.", "No.", "Ticket 412 please", "Show WWT", "Open S and K", "IBN Betreuung"])
    func complete(_ s: String) { #expect(!Parser.looksIncomplete(s, language: .en), "\(s)") }

    @Test(arguments: ["two", "the second", "number three", "Relaunch", "cancel", "more", "no, the second", "Hi.", "To."])
    func completeAnswer(_ s: String) { #expect(!Parser.looksIncomplete(s, choosing: true, language: .en), "\(s)") }

    @Test(arguments: ["", "no", "No,", "the", "number", "no, the", "no, open", "ticket 4", "um"])
    func incompleteAnswer(_ s: String) { #expect(Parser.looksIncomplete(s, choosing: true, language: .en), "\(s)") }

    /// fastSelect: a live pick waits for the final while its last word may still change it.
    @Test(arguments: ["One", "1", "Hold on, one", "Give me one", "Second", "the second", "The 2nd", "one second", "Okay",
                      "OK.", "All right"])
    func pickMayChange(_ s: String) { #expect(Parser.pickMayChange(s, language: .en), "\(s)") }

    @Test(arguments: ["Two", "the second one", "the first one", "number one", "option one", "the third", "the last",
                      "One, please", "the second please", "the second to last", "Okay, two", "Yes", ""])
    func pickStays(_ s: String) { #expect(!Parser.pickMayChange(s, language: .en), "\(s)") }

    @Test func pickMayChangeIsEnglishOnly() {
        for s in ["eins", "one", "second", "die zweite", "zwei"] { #expect(!Parser.pickMayChange(s, language: .de), "\(s)") }
    }

    @Test func endsInNumeral() {
        #expect(Parser.endsInNumeral("Ticket four hundred twelve", language: .en) && Parser.endsInNumeral("Ticket 47,285.", language: .en))
        #expect(Parser.endsInNumeral("Open WWT 4 12", language: .en))
        #expect(!Parser.endsInNumeral("Open a", language: .en) && !Parser.endsInNumeral("WWT Relaunch", language: .en))
        #expect(!Parser.endsInNumeral("Open S and", language: .en) && !Parser.endsInNumeral("", language: .en))
    }
}

/// The same request in German and in English ends in the same outcome on the same projects.
@Suite struct EnglishInterpreterTests {
    typealias E = EnglishFixture

    @Test(arguments: [
        ("Öffne das WWT-Projekt", "Open the WWT project"), ("Öffne WWT Relaunch", "Open WWT Relaunch"),
        ("Öffne das S und K Leasing Cockpit", "Open the S and K Leasing Cockpit"), ("Öffne WWT Ticket 412", "Open WWT ticket 412"),
        ("Ticket 412 im WWT Relaunch", "Ticket 412 in WWT Relaunch"), ("Öffne Ticket 47285", "Open ticket 47285"),
        ("Zeig meine Aufgaben", "Show my tasks"), ("abbrechen", "Cancel"), ("Öffne WWT 412", "Open WWT 412"),
        ("Grand Navigation", "Grand Navigation"), ("IBN Betreuung", "IBN Betreuung"), ("I B N Betreuung", "eye bee en Betreuung"),
        ("Öffne we we te Relaunch", "Open double-u double-u tee Relaunch"), ("Ticket vierhundertzwölf", "Ticket four hundred twelve"),
        ("Hallo Welt", "Hello world"), ("Öffne WWT Wartung", "Open WWT maintenance"), ("Nein, Ticket 412", "No, ticket 412"),
        ("Öffne WWT Relonch", "Open WWT relonch"), ("Ticket 412 und 5", "Ticket 412 and 5"), ("Öffne TYPO 3 von WWT", "Open TYPO 3 of WWT"),
        ("Öffne QZ 2027", "Open QZ 2027"), ("Öffne Eben Betreuung", "Open eben Betreuung"), ("Öffne Disney Ticket 58", "Open Disney ticket 58"),
    ])
    func sameOutcomeAsGerman(german: String, english: String) {
        #expect(E.run(english) == Fixture.run(german), "\(english) vs \(german)")
    }

    @Test func outcomes() {
        #expect(E.run("Open WWT Relaunch") == "unique 628")
        #expect(E.run("Open the WWT project").hasPrefix("choices ") && E.run("Open the WWT project").contains("628"))
        #expect(E.run("What's on my plate") == "my")
        #expect(E.run("Never mind") == "cancel")
        #expect(E.run("Ticket 412 in WWT Relaunch") == "task 412 unique 628")
        #expect(E.run("Open WWT relonch") == "unique 628")   // metaphone: "relonch" ~ "relaunch"
        // A number of several words is one title word ("forty five" = "45"), not a ticket.
        #expect(E.run("Open the forty five sensor app") == "unique 2091" && E.run("Open the 45 sensor app") == "unique 2091")
        #expect(E.run("Open ZMF app sensor forty five") == "unique 2091")
        #expect(E.run("Open ZMF ticket forty five") == "task 45 unique 2091" || E.run("Open ZMF ticket forty five").hasPrefix("task 45 "))
    }

    @Test func numbersExplainedByTitles() {
        // "TYPO three" -> "typo3": the title explains the number, so it is no ticket.
        #expect(E.run("Open WWT TYPO three") == Fixture.run("Öffne WWT TYPO drei"))
        #expect(!E.run("Open WWT TYPO three").hasPrefix("task"))
    }

    @Test func alternativesAndWeights() {
        // DT hears the code, ST the title words: the union decides (as in German).
        #expect(E.run("Open TKZ", "Open CKZ TourenPlaner Schulung") == Fixture.run("Öffne TKZ", "Öffne CKZ TourenPlaner Schulung"))
        #expect(E.run("", "Show my tasks") == "my")
    }

    @Test func languageFollowsTheResolver() {
        var i = Interpreter(resolver: Fixture.resolver)
        #expect(i.language == .de && i.resolver.config.language == .de)
        i.language = .en
        #expect(i.resolver.config.language == .en)
        let built = Interpreter(projects: Fixture.projects, config: Config(), history: History(), language: .en)
        #expect(built.language == .en && built.resolver.config.language == .en)
    }

    @Test func tickets() {
        let wwt412 = try! #require(E.request("Open WWT ticket 412"))
        #expect(wwt412.number == 412 && wwt412.projects?.projectIds.count == 4 && wwt412.confident && !wwt412.implicit)
        let implicit = try! #require(E.request("Open WWT 412"))
        #expect(implicit.implicit && implicit.number == 412)
        #expect(E.request("Ticket 412 and 5")?.confident == false)
        if case .none? = E.request("Open Disney ticket 58")?.projects {} else { Issue.record("project words that match nothing") }
    }

    @Test func correctionKey() {
        #expect(E.interpreter.correctionKey([Hypothesis("Open the eben Betreuung please")]) == "eben betreuung")
        #expect(E.interpreter.correctionKey([Hypothesis("Ticket 412")]) == nil)
    }
}

@Suite struct EnglishSelectionTests {
    let list = [628, 315, 314, 693]
    func sel(_ s: String..., list: [Int]? = nil) -> SelectionOutcome {
        EnglishFixture.interpreter.selection(s.map { Hypothesis($0) }, candidates: list ?? self.list, now: Fixture.now)
    }

    @Test func numbers() {
        #expect(sel("Two.") == .pick(1)); #expect(sel("2.") == .pick(1)); #expect(sel("To.") == .pick(1))
        #expect(sel("the second") == .pick(1)); #expect(sel("Number three") == .pick(2)); #expect(sel("the last one") == .pick(3))
        #expect(sel("one") == .pick(0)); #expect(sel("no, the second") == .pick(1)); #expect(sel("Nope, the fourth") == .pick(3))
        #expect(sel("", "One.") == .pick(0))
    }

    @Test func confirmWordsOnlyForOneItem() {
        #expect(sel("Yes.") == .keepListening); #expect(sel("Exactly") == .keepListening)
        #expect(sel("yes", list: [628]) == .pick(0)); #expect(sel("Correct.", list: [628]) == .pick(0))
    }

    @Test func negationKeepsListening() {
        #expect(sel("No.") == .keepListening); #expect(sel("nope") == .keepListening)
        #expect(sel("No.", "No, the second") == .pick(1))
        #expect(sel("no, cancel") == .cancel)
        #expect(sel("No.", list: [628]) == .cancel)
    }

    @Test func names() {
        #expect(sel("Relaunch") == .pick(0)); #expect(sel("Relonch.") == .pick(0)); #expect(sel("nope, Relaunch") == .pick(0))
        #expect(sel("Grand Navigation") == .pick(3)); #expect(sel("Maintenance") == .pick(2))
        #expect(sel("the maintenance one") == .pick(2))
        #expect(sel("Website") == .narrow([0, 1]))
    }

    @Test func control() {
        #expect(sel("cancel") == .cancel); #expect(sel("never mind") == .cancel); #expect(sel("Hi.") == .unclear)
        #expect(sel("seven") == .unclear)
        #expect(sel("more") == .more); #expect(sel("next") == .more)
        if case .command = sel("no, open TKZ") {} else { Issue.record("expected new command") }
        if case .command = sel("Ticket 47285") {} else { Issue.record("expected new command") }
    }
}

@Suite struct EnglishHangoverPolicyTests {
    let p = HangoverPolicy.standard
    typealias E = EnglishFixture

    func command(_ text: String) -> Double {
        p.command(text: text, interpretation: E.interpreter.command([Hypothesis(text)], now: Fixture.now), language: .en)
    }

    func answer(_ text: String, list: [Int] = [628, 314, 315, 693]) -> Double {
        let hyps = [Hypothesis(text)]
        return p.answer(text: text, outcome: E.interpreter.selection(hyps, candidates: list, now: Fixture.now), language: .en,
                        command: { E.interpreter.command(hyps, now: Fixture.now) })
    }

    @Test(arguments: [
        ("Open WWT Relaunch", 0.45), ("My tasks", 0.45), ("Open ticket 47285 please", 0.45), ("Ticket 412 in WWT Relaunch", 0.45),
        ("What's on my plate", 0.45),
        ("Open the WWT project", 0.60), ("Open WWT", 0.60), ("Hello world", 0.60),
        ("Open", 1.10), ("Open the", 1.10), ("Open WWT ticket", 1.10), ("Show my", 1.10), ("Hey Jarvis", 1.10),
        ("Ticket 412 in", 1.10), ("Can you", 1.10),
        ("Open WWT ticket 4", 1.10), ("Ticket 47285", 1.10), ("Open WWT 41", 1.10), ("Ticket four hundred", 1.10),
    ])
    func commandPhase(text: String, expect: Double) { #expect(command(text) == expect, "\(text)") }

    @Test(arguments: [
        ("two", 0.40), ("the second", 0.40), ("Relaunch", 0.40), ("the", 0.40), ("no", 0.40), ("Open the", 0.40),
        ("Open WWT ticket", 1.10), ("Ticket 47285", 1.10), ("Open WWT Relaunch", 0.45),
    ])
    func answerPhase(text: String, expect: Double) { #expect(answer(text) == expect, "\(text)") }

    @Test func languageDecidesTheDanglingWords() {
        // German reads "the" as a project word; English as a dangling article.
        let i = E.interpreter.command([Hypothesis("Open the")], now: Fixture.now)
        #expect(p.command(text: "Open the", interpretation: i) == 0.60)
        #expect(p.command(text: "Open the", interpretation: i, language: .en) == 1.10)
        let de = Fixture.interpreter.command([Hypothesis("Öffne das")], now: Fixture.now)
        #expect(p.command(text: "Öffne das", interpretation: de) == 1.10)
    }
}

@Suite struct EnglishRegressionFormatTests {
    @Test func languageDirective() {
        let text = """
        # German first, then English
        Öffne das WWT-Projekt\t\tchoices~ 628,314,315,693
        @language en
        Open the WWT project\t\tchoices~ 628,314,315,693
        What's on my plate\t\tmy
        Ticket 412 in WWT Relaunch\t\ttask 412 unique 628
        Open WWT relonch\tOpen WWT Relaunch\tunique 628
        @picks wwt=693x3
        Open the WWT project\t\tchoices 693,628,314,315
        @language de
        Zeig meine Aufgaben\t\tmy
        """
        let cases = Regression.parse(text, now: Fixture.now)
        #expect(cases.map(\.language) == [.de, .en, .en, .en, .en, .en, .de])
        let results = Regression.run(cases, projects: Fixture.projects, now: Fixture.now)
        for r in results where !r.passed {
            Issue.record("line \(r.testCase.line): got '\(r.actual)', expected '\(r.testCase.expected)'")
        }
    }
}

/// Review findings on English speech: closings, pronouns, digit lookalikes and stalling phrases.
@Suite struct EnglishPhraseTests {
    typealias E = EnglishFixture

    /// Closings never open a project: "it" is a pronoun unless STT writes the code "IT", "all" no title prefix.
    @Test(arguments: ["Stop it", "Close it", "Quit it", "Leave it", "Skip it", "Drop it", "That's it", "That's all",
                      "That's all for now", "All right", "Alright.", "All good", "All set", "All done", "Cancel it",
                      "Forget that", "Thank you so much", "Thanks a lot", "Many thanks", "Thank you very much",
                      "Thanks so much", "None of them", "Neither", "Close the list", "Close the window", "Stop listening",
                      "I'm done", "Done.", "Bye", "Goodbye", "That's all for today", "Thanks, that's all for today"])
    func closingsCancel(_ s: String) {
        #expect(E.command(s) == .cancel, "\(s)")
        #expect(E.run(s) == "cancel", "\(s)")
    }

    @Test func pronounsAndAllAreNoProjectWords() {
        #expect(E.command("Open it") == .unknown && E.command("Show all projects") == .unknown)
        #expect(E.command("Show it all") == .unknown)
        // The code "IT" stays a project word.
        #expect(E.run("Open QZ IT Support") == "unique 2077" && E.run("Open the IT project") == "unique 2077")
        #expect(E.run("Open QZ Allgemein") == "unique 2073")
        // A closing word in front of a command is a lead-in, a polite closing after a ticket no project word.
        #expect(E.command("Alright, open WWT Relaunch") == .openProject(query: [Token(text: "wwt", isAcronym: true), Token(text: "relaunch")]))
        #expect(E.run("Open ticket 412 thank you") == "task 412 -")
        #expect(E.run("Ticket 412 in WWT Relaunch, thanks a lot") == "task 412 unique 628")
    }

    @Test(arguments: ["Show my open tickets", "Show my open issues", "Show me my open tickets", "my open tasks"])
    func myOpenTickets(_ s: String) { #expect(E.command(s) == .openMyTasks, "\(s)") }

    @Test func longestPhraseWins() {
        let lx = Lexicon.en
        let merged = Parser.mergePhrases(TextNorm.tokenize("thank you so much", language: .en), lx.cancelPhrases)
        #expect(merged.map(\.text) == ["thankyou"])
        #expect(Parser.mergePhrases(TextNorm.tokenize("thank you", language: .en), lx.cancelPhrases).map(\.text) == ["thankyou"])
        #expect(Parser.isStrongCancel("Stop it", language: .en) && !Parser.isStrongCancel("That's all", language: .en))
    }

    /// STT writes "ticket four twelve" as "Ticket for 12" and "two twelve" as "to 12".
    @Test(arguments: [
        ("Open Ticket for 12", "task 412 -"), ("Open Ticket to 12", "task 212 -"), ("Open ticket too 12", "task 212 -"),
        ("Ticket for 12 in WWT Relaunch", "task 412 unique 628"), ("Open WWT Ticket for 12", "task 412 choices~ 628,314,315,693"),
        ("Open ticket number for 12", "task 412 -"), ("Open ticket for twelve", "task 412 -"), ("Open ticket four 12", "task 412 -"),
    ])
    func digitLookalikesAfterTheTaskWord(text: String, expect: String) {
        #expect(Regression.matches(actual: E.run(text), expected: expect), "\(text) -> \(E.run(text))")
    }

    @Test func lookalikesElsewhereStayWords() {
        // DT and ST agree now: no hypothesis gives ticket 12.
        #expect(E.run("Open Ticket for 12", "Open Ticket 412.") == "task 412 -")
        #expect(E.command("Go to 47285") == .openTask(query: [], number: 47285))
        #expect(E.command("Open ticket for WWT") == .openProject(query: [Token(text: "wwt", isAcronym: true)]))
        // "for 2027" after a title word is no ticket number.
        #expect(!E.run("Open the website relaunch for 2027").hasPrefix("task"))
        #expect(E.command("Show tickets for 2027") != .openTask(query: [], number: 42027))
    }

    /// "the maintenance one" is the pronoun, not ticket 1.
    @Test func pronounOne() {
        #expect(E.run("Open the maintenance one") == E.run("Open the maintenance"))
        #expect(E.run("Open the navigation one") == "unique 693")
        #expect(E.run("Open the WWT one") == E.run("Open the WWT project"))
        #expect(!E.run("Show me the Betreuung one").hasPrefix("task"))
        #expect(!E.run("Open WWT one").hasPrefix("task"))
        // A numeral "one" stays: after a task word or "number", inside a run, and the digit.
        #expect(E.run("Open ticket one") == "task 1 -")
        #expect(E.run("Open WWT ticket one").hasPrefix("task 1 "))
        #expect(E.run("Open ticket WWT one").hasPrefix("task 1 "))
        #expect(E.command("Ticket number one") == .openTask(query: [], number: 1))
        #expect(E.command("Ticket twenty one") == .openTask(query: [], number: 21))
        #expect(E.run("Open WWT one hundred twelve") == E.run("Open WWT 112") && E.run("Open WWT 112").hasPrefix("task 112 "))
        #expect(Parser.implicitTicket(TextNorm.tokenize("WWT 1", language: .en), language: .en)?.number == 1)
    }

    /// "second" is a time word far more often than a row in English.
    @Test(arguments: ["wait a second", "one second", "just a second", "Hang on a second.", "give me a second",
                      "No, wait a second", "hold on", "let me think", "Wait.", "One moment please", "a sec"])
    func stallingKeepsListening(_ s: String) {
        #expect(Parser.selection(s, count: 4, language: .en) == .keepListening, "\(s)")
        #expect(Parser.selection(s, count: 1, language: .en) == .keepListening, "\(s)")
        #expect(Parser.looksIncomplete(s, choosing: true, language: .en), "\(s)")
    }

    @Test(arguments: [
        ("the second one please", Selection.pick(2)), ("Can you open the second one please", .pick(2)),
        ("wait, the third one", .pick(3)), ("okay the first", .pick(1)), ("the second to last", .pick(3)),
        ("second last", .pick(3)), ("next to last", .pick(3)), ("the last one", .pick(-1)),
        ("close it", .cancel), ("stop it", .cancel), ("that's it", .cancel), ("That's all.", .cancel), ("all right", .cancel),
        // Lead-ins before the ordinal, "I think" after it.
        ("I think the second one", .pick(2)), ("I think the 2nd one.", .pick(2)), ("How about the second one", .pick(2)),
        ("Let's do the 1st one.", .pick(1)), ("Maybe the third one", .pick(3)), ("Probably the third", .pick(3)),
        ("I'd say the second", .pick(2)), ("Make it the second one", .pick(2)), ("I guess the first", .pick(1)),
        ("Try the third one", .pick(3)), ("Mm, the second one", .pick(2)), ("The second one, I think", .pick(2)),
        ("I think the second to last", .pick(3)),
        // Closings that name no row.
        ("None of them", .cancel), ("No, none of them", .cancel), ("Neither", .cancel), ("Close the list", .cancel),
    ])
    func ordinalsAtTheHead(text: String, expect: Selection) {
        #expect(Parser.selection(text, count: 4, language: .en) == expect, "\(text)")
    }

    @Test(arguments: ["first of all", "First, let me think", "the second WWT", "twenty second", "Maybe in a second",
                      "Do you have a second", "Second guess", "Maybe not the first", "Try the second time"])
    func ordinalsInsideAPhraseAreNoPick(_ s: String) {
        let out = Parser.selection(s, count: 4, language: .en)
        #expect(![.pick(1), .pick(2)].contains(out), "\(s) -> \(out)")
    }

    @Test func compoundOrdinalsAndShortLists() {
        #expect(Parser.selection("twenty second", count: 24, language: .en) == .pick(22))
        #expect(Parser.selection("the twenty-second", count: 24, language: .en) == .pick(22))
        #expect(Parser.selection("the second to last", count: 1, language: .en) == .unclear)
        // "All right" confirms a one-row prompt.
        #expect(Parser.selection("all right", count: 1, language: .en) == .pick(1))
        // German keeps reading an ordinal anywhere in a short answer.
        #expect(Parser.selection("ja die zweite", count: 4) == .pick(2))
    }

    /// The one-row prompt says "Say yes or no": a yes with a closing confirms, a closing alone closes.
    @Test func oneRowPromptAnswers() {
        for s in ["Yes, that's it", "Yep, that's the one", "Yes, thanks", "Go ahead", "Yes, go ahead", "Okay", "OK", "Yes, one"] {
            #expect(Parser.selection(s, count: 1, language: .en) == .pick(1), "\(s)")
        }
        for s in ["That's it", "Thanks", "No", "No, thanks", "Yes, close it"] {
            #expect(Parser.selection(s, count: 1, language: .en) != .pick(1), "\(s)")
        }
        // "Okay" only leads into a cancel or a no.
        for s in ["Okay, cancel", "OK, no", "OK, never mind", "Okay, forget it", "All right, cancel"] {
            #expect(Parser.selection(s, count: 1, language: .en) == .cancel, "\(s)")
        }
        // Several rows: a bare yes keeps listening, "Go ahead and open TKZ" is a new command.
        for s in ["Okay", "Go ahead", "Yes, go ahead"] {
            #expect(Parser.selection(s, count: 4, language: .en) == .keepListening, "\(s)")
        }
        if case .command = Parser.selection("Go ahead and open TKZ", count: 4, language: .en) {} else { Issue.record("expected a command") }
    }

    /// A polite word or particle around a number does not hide it.
    @Test(arguments: [("Two, thanks", 2), ("2 thanks.", 2), ("Three, thank you", 3), ("Number two, thank you", 2),
                      ("Just two", 2), ("Yes, two", 2)])
    func numbersWithPoliteness(text: String, row: Int) {
        #expect(Parser.selection(text, count: 4, language: .en) == .pick(row), "\(text)")
    }

    @Test func interpreterOutcomesInAList() {
        let list = [628, 315, 314, 693]
        func sel(_ s: String) -> SelectionOutcome {
            E.interpreter.selection([Hypothesis(s)], candidates: list, now: Fixture.now)
        }
        #expect(sel("wait a second") == .keepListening && sel("one second") == .keepListening)
        #expect(sel("close it") == .cancel && sel("that's all") == .cancel && sel("all right") == .cancel)
        #expect(sel("the second to last") == .pick(2))
        #expect(sel("twenty second") == .unclear)   // row 22 does not exist
        #expect(sel("the maintenance one") == .pick(2))
        if case .command(.openProject(let q)) = sel("Show me the maintenance one") {
            #expect(q.map(\.key) == ["maintenance"])
        } else { Issue.record("expected a project command") }
    }
}

/// Aliases in English commands: the words an English query drops, and what the history may learn.
@Suite struct EnglishAliasTests {
    func run(_ i: Interpreter, _ text: String) -> String {
        Regression.describe(i.command([Hypothesis(text)], now: Fixture.now))
    }

    @Test func aliasSequencesDropWhatTheQueryDrops() {
        #expect(ProjectEntry.englishAliasSequences(["Bank of Avalon", "Miller and Stone"]) == [["bank", "avalon"], ["miller", "stone"]])
        // Shrunk to one word or to nothing: left out. A one-word alias stays.
        #expect(ProjectEntry.englishAliasSequences(["Bank of", "The Paper", "of the", "Avalon"]) == [["avalon"]])
        // "IT" is an acronym in the alias and in the query, so it stays.
        #expect(ProjectEntry.englishAliasSequences(["Acme IT Services"]) == [["acme", "it", "services"]])
        let entry = ProjectEntry(id: 1, name: "XYZ: Shop Rollout", aliases: ["The Paper Shop"])
        #expect(entry.spokenAliasSeqs(.de) == [["the", "paper", "shop"]] && entry.spokenAliasSeqs(.en) == [["paper", "shop"]])
        var changed = entry
        changed.aliases = ["Bank of Avalon"]
        #expect(changed.spokenAliasSeqs(.en) == [["bank", "avalon"]])
    }

    @Test func configAliasWithJoinerWords() {
        var config = Config()
        config.aliases = ["WWT": ["Miller and Stone"]]
        let de = Interpreter(projects: Fixture.projectsWithoutAliases, config: config, history: History())
        let en = Interpreter(projects: Fixture.projectsWithoutAliases, config: config, history: History(), language: .en)
        #expect(run(de, "Miller and Stone") == "choices 628,314,315,693")
        #expect(run(en, "Miller and Stone") == "choices 628,314,315,693")
        #expect(run(en, "open Miller and Stone Relaunch") == "unique 628")
    }

    func learned(_ query: String, _ language: AppLanguage = .en) -> [String: [String]] {
        var h = History()
        for _ in 0..<2 { h.recordPick(query: query, projectId: 628) }
        return h.learnedAliases(projects: Fixture.projectsWithoutAliases, language: language)
    }

    /// Review: "Hello, website relaunch" corrected twice taught WWT the alias "hello", and every later English command
    /// with the greeting hit WWT.
    @Test func greetingsAndParticlesNeverBecomeAliases() {
        for word in ["hello", "only", "still", "very", "really", "maybe", "sorry", "oops", "wait", "thanks", "just"] {
            #expect(learned("\(word) website relaunch").isEmpty, "\(word)")
        }
        // The history holds the queries of both languages: German particles stay blocked in English.
        #expect(learned("hallo website relaunch").isEmpty && learned("schon website relaunch").isEmpty)
        // Real leftovers still teach an alias.
        #expect(learned("double website relaunch") == ["WWT": ["double"]])
        #expect(learned("wobble tea website relaunch") == ["WWT": ["wobble tea"]])
        // German keeps its own set.
        #expect(learned("hallo website relaunch", .de).isEmpty)
        #expect(learned("eben website relaunch", .de) == ["WWT": ["eben"]])
    }

    @Test func greetingKeepsTheCommand() {
        var h = History()
        for _ in 0..<2 { h.recordPick(query: "hello website relaunch", projectId: 628) }
        let en = Interpreter(projects: Fixture.projectsWithoutAliases, config: Config(), history: h, language: .en)
        #expect(en.resolver.projects.allSatisfy { $0.aliases.isEmpty })
        #expect(run(en, "Hello, open the IT support") == "unique 2077")
        #expect(run(en, "hello, crm") == "unique 2071")
    }
}

/// Command phase: lead-ins, closings, the pronoun "one" and digit lookalikes inside a number.
@Suite struct EnglishCommandWordTests {
    typealias E = EnglishFixture

    /// Stalling and correction words lead into a command, closings end it.
    @Test(arguments: ["Hold on, ticket 412", "Wait, ticket 412", "No wait, ticket 412", "Just a second, ticket 412",
                      "One moment, ticket 412", "Um, let me think, ticket 412", "Forget that, ticket 412",
                      "No, forget that, ticket 412", "Never mind, ticket 412", "Ticket 412, that's all",
                      "Ticket 412, that's it", "Ticket 412, all good", "That's it, ticket 412", "Open ticket 412 and that's it"])
    func leadInsAndClosingsAroundATicket(_ s: String) { #expect(E.run(s) == "task 412 -", "\(s)") }

    @Test func leadInsAndClosingsKeepTheirMeaning() {
        // Real STT pairs (Samantha clips).
        #expect(E.run("Open Ticket for 12 that's all", "Open Ticket 412. That's all.") == "task 412 -")
        #expect(E.run("hold on ticket for 12", "Hold on. Ticket 412.") == "task 412 -")
        // After the ticket a cancel or stall word takes it back: nothing opens.
        #expect(E.run("Open Ticket for 12 never mind", "Open Ticket 412. Never mind.") == "task 412 notRecognized")
        #expect(E.run("Ticket 412, forget it") == "task 412 notRecognized" && E.run("Ticket 412, wait") == "task 412 notRecognized")
        #expect(E.run("That's all for now") == "cancel" && E.run("Never mind, thanks") == "cancel" && E.run("Wait, cancel") == "cancel")
        #expect(E.run("Wait, show my tasks") == "my" && E.run("Hold on, ticket 412 in WWT Relaunch") == "task 412 unique 628")
        // The answer phase is unchanged.
        #expect(Parser.selection("wait, that's all", count: 4, language: .en) == .cancel)
    }

    /// "one of the WWT projects", "the one with maintenance": projects, not ticket 1.
    @Test func pronounOneBeforeTheProject() {
        #expect(E.run("Open one of the WWT projects") == E.run("Open the WWT projects"))
        #expect(E.run("Open one of the WWT project", "Open one of the WWT projects.") == E.run("Open the WWT projects"))
        #expect(E.run("Show me one of the maintenance projects") == E.run("Show me the maintenance projects"))
        #expect(E.run("Open the one with maintenance") == E.run("Open the maintenance"))
        #expect(E.run("Show me one of my tasks") == "my")
        // Still ticket 1 after a task word or "number".
        #expect(E.run("Open ticket one of WWT").hasPrefix("task 1 ") && E.run("Open number one of WWT").hasPrefix("task 1 "))
    }

    /// "the Sensor 45 one", "the 2027 one": a title number, not ticket 451 or the global id 20271.
    @Test func pronounOneAfterATitleNumber() {
        #expect(E.run("Open the sensor 4 5 one", "Open the Sensor 451.") == "unique 2091")
        #expect(E.run("Open the sensor 45 one") == "unique 2091")
        #expect(!E.run("Open the 202 7 one", "Open the 20271.").hasPrefix("task"))
        #expect(E.run("Open the TYPO 3 one") == E.run("Open the TYPO 3"))
        // Still numbers: after a task word, without "the", "twenty one", and a glued id heard alone.
        #expect(E.run("Open ticket 2027 one") == "task 20271 -" && E.run("Open 4728 one") == "task 47281 -")
        #expect(E.run("Open WWT twenty one").hasPrefix("task 21 ") && E.run("Open the 20271.") == "task 20271 -")
        // Digits no candidate title holds keep their "one": ticket 581, ticket 21, the global id 47281.
        #expect(E.run("Open the maintenance 58 one") == "task 581 unique 314 implicit")
        #expect(E.run("Open the WWT 2 one", "Open the WWT 21.") == "task 21 choices 628,314,315,693 implicit")
        #expect(E.run("Open the 4728 one", "Open the 47281.") == "task 47281 -")
    }

    /// "four two twelve" -> "Ticket 4 to 12", "forty seven two eighty five" -> "Ticket 47 to 85".
    @Test(arguments: [
        ("Open Ticket 4 to 12", "task 4212 -"), ("Ticket four to twelve", "task 4212 -"), ("Open Ticket 47 to 85", "task 47285 -"),
        ("Open WWT ticket 4 to 12", "task 4212 choices~ 628,314,315,693"), ("Ticket 412 to 5", "task 412 - lowconf"),
        ("Open ticket 12 for 2027", "task 12 - lowconf"), ("Open ticket 4 to the WWT Relaunch", "task 4 unique 628"),
        ("Show tickets 10 to 20", "task 10 - lowconf"),
    ])
    func lookalikeInsideTheNumber(text: String, expect: String) {
        #expect(Regression.matches(actual: E.run(text), expected: expect), "\(text) -> \(E.run(text))")
    }

    @Test func lookalikeInsideTheNumberWithST() {
        #expect(E.run("Open Ticket 4 to 12", "Open Ticket 4212.") == "task 4212 -")
        #expect(E.run("Open Ticket 47 to 85", "Open Ticket 47285.") == "task 47285 -")
    }

    /// With its number the ticket names its project by pronoun.
    @Test func pronounOneAfterANumberedTicket() {
        #expect(E.run("Open ticket 412 in the navigation one") == "task 412 unique 693")
        #expect(E.run("Open ticket 412, the maintenance one") == E.run("Open ticket 412 in the maintenance"))
        #expect(E.run("Open Ticket for the Relaunch one", "Open Ticket 412, the relaunch one.").hasPrefix("task 412 "))
        #expect(E.run("Open ticket WWT one").hasPrefix("task 1 ") && E.run("Open ticket in WWT one").hasPrefix("task 1 "))
    }
}
