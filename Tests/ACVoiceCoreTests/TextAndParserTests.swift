import Foundation
import Testing
@testable import ACVoiceCore

@Suite struct TextTests {
    @Test(arguments: [
        ("Öffne mir mal das we we te Projekt", "WWT"), ("W W T", "WWT"), ("weh weh te", "WWT"), ("W.W.T.", "WWT"),
        ("WW T", "WWT"), ("Wewete", "WWT"), ("S und K", "S+K"), ("es und ka", "S+K"), ("S & K", "S+K"),
        ("S&K", "S+K"), ("ku zett CRM", "QZ"), ("I B N", "IBN"), ("Öffne WWTilonch.", "WWT"),
        ("Q Z C R M", "QZCRM"), ("ku zett ce er em", "QZCRM"),
        // X+Y with a weak letter name ("es", "em", "el") next to a strong one, and two strong ones.
        ("Es Ka", "SK"), ("em und te", "M+T"), ("el und ka", "L+K"), ("ka und te", "K+T"),
    ])
    func spelling(input: String, expect: String) {
        #expect(TextNorm.tokenize(input).contains { $0.isAcronym && $0.text.uppercased() == expect }, "\(input)")
    }

    @Test(arguments: ["Kategorie", "Betreuung", "Telefonie", "Website", "Wehwehchen", "Teekanne", "Beete", "Kuhweide", "es ist", "IT e"])
    func noFalseSpelling(_ s: String) {
        #expect(!TextNorm.tokenize(s).contains { $0.isAcronym && !s.contains($0.text.uppercased()) }, "\(s)")
    }

    @Test func fixtureTitlesStayWords() {
        // No title word of the sample projects turns into a spelled acronym.
        for p in Fixture.projects {
            let tokens = TextNorm.tokenize(p.title)
            let created = tokens.filter { $0.isAcronym && !p.title.uppercased().contains($0.text.uppercased()) }
            #expect(created.isEmpty, "\(p.id)")
        }
    }

    @Test func cleaning() {
        #expect(TextNorm.tokenize("Datenbank – Export").map(\.key) == ["datenbank", "export"])
        #expect(TextNorm.tokenize("Ticket 47. 285").map(\.key) == ["ticket", "47285"])
        #expect(TextNorm.queryKey(TextNorm.tokenize("S+K Partner")) == "sk partner")
    }

    @Test func cologne() {
        #expect(Fuzzy.cologne("relaunch") == Fuzzy.cologne("relonch"))
        #expect(Fuzzy.cologne("relaunch") == Fuzzy.cologne("rilonch"))
    }
}

@Suite struct NumberTests {
    typealias P = GermanNumbers.Part
    static func parts(_ v: Int...) -> [P] { v.map { P(value: $0) } }

    @Test func compose() {
        #expect(GermanNumbers.compose(Self.parts(4, 12)) == 412)
        #expect(GermanNumbers.compose(Self.parts(400, 12)) == 412)
        #expect(GermanNumbers.compose(Self.parts(47000, 285)) == 47285)
        #expect(GermanNumbers.compose(Self.parts(4, 1, 2)) == 412)
        #expect(GermanNumbers.compose(Self.parts(1, 0, 0)) == 100)
        #expect(GermanNumbers.compose(Self.parts(20, 3)) == 23)
        #expect(GermanNumbers.compose([P(value: 4), P(value: 100, isMultiplierWord: true), P(value: 12)]) == 412)
        #expect(GermanNumbers.compose([]) == nil)
        #expect(GermanNumbers.compose(Self.parts(9999, 9999)) == nil)   // above the limit
    }

    @Test(arguments: [
        ("Öffne Ticket 47.285.", 47285), ("Öffne Ticket 47. 285", 47285), ("Ticket vierhundertzwölf", 412),
        ("Ticket vier eins zwei", 412), ("Öffne Ticket 4 12", 412), ("Öffne Ticket 400 12", 412),
        ("Ticket 47000 285", 47285), ("Ticket vier hundert zwölf", 412), ("Ticket Nummer 412", 412),
        ("Ticket sieben und vierzig tausend zwei hundert fünf und achtzig", 47285), ("öffne 47285", 47285),
        ("öffne 47000 285", 47285),
    ])
    func ticketNumbers(text: String, n: Int) {
        guard case let .openTask(q, number) = Parser.command(text) else { Issue.record("\(text)"); return }
        #expect(number == n && q.isEmpty, "\(text) -> \(number) \(q)")
    }

    @Test func overflowNeverTraps() {
        // Review: 19-digit tokens and glued "hundert" runs used to trap (pow / multiplication overflow).
        #expect(GermanNumbers.compose(Self.parts(5, 1_234_567_890_123_456_789)) == nil)
        #expect(GermanNumbers.compose(Self.parts(10, 100_000_000_000_000_000)) == nil)
        #expect(GermanNumbers.compose(Self.parts(1, Int.max)) == nil)
        #expect(GermanNumbers.compose(Array(repeating: P(value: 100, isMultiplierWord: true), count: 12)) == nil)
        #expect(GermanNumbers.compose([P(value: 999_999), P(value: 1000, isMultiplierWord: true)]) == nil)
        #expect(GermanNumbers.cardinal(String(repeating: "hundert", count: 10)) == nil)
        #expect((GermanNumbers.cardinal(String(repeating: "tausend", count: 10)) ?? 0) <= GermanNumbers.composeLimit)
        #expect(GermanNumbers.cardinal("neunhundertneunundneunzigtausendneunhundertneunundneunzig") == 999_999)
        #expect(Parser.command("Ticket 5 1234567890123456789") == .unknown)
        if case .openTask = Parser.command("Ticket 99999999999999999999999") { Issue.record("beyond Int.max is no number") }
        #expect(Fixture.run("Öffne WWT 1 1000000000000000000") == "none")
        #expect(Fixture.run("Öffne WWT 10 100000000000000000") == "none")
    }

    @Test func leftoverNumeralsStayInQuery() {
        // "und" between 412 and 5 is not the units-und-tens pattern, so 5 is a separate (leftover) numeral.
        #expect(Parser.command("Ticket 412 und 5") == .openTask(query: [Token(text: "5")], number: 412))
    }

    @Test(arguments: ["Öffne 412", "zwei", "412"])
    func smallBareNumberIsNotACommand(_ s: String) { #expect(Parser.command(s) == .unknown) }
}

@Suite struct CommandTests {
    @Test(arguments: ["Zeig meine Aufgaben", "Zeige meine Aufgaben", "Zeige meine Aufgabe", "Zeig mir meine Aufgabe",
                      "was liegt bei mir an", "meine Aufgaben bitte", "Was steht heute an"])
    func myTasks(_ s: String) { #expect(Parser.command(s) == .openMyTasks, "\(s)") }

    @Test func myTaskWithNumberIsATicket() {
        #expect(Parser.command("Öffne meine Aufgabe 412") == .openTask(query: [], number: 412))
    }

    @Test func ticketWithProject() {
        guard case let .openTask(q, n) = Parser.command("Öffne WWT Ticket 412") else { Issue.record(); return }
        #expect(n == 412 && q.map(\.key) == ["wwt"])
        guard case let .openTask(q2, n2) = Parser.command("Ticket 412 im WWT Relaunch") else { Issue.record(); return }
        #expect(n2 == 412 && q2.map(\.key) == ["wwt", "relaunch"])
        guard case let .openTask(q3, n3) = Parser.command("Öffne Ticket WWT 412") else { Issue.record(); return }
        #expect(n3 == 412 && q3.map(\.key) == ["wwt"])
    }

    @Test func implicitTicketIsLeftToTheInterpreter() {
        guard case let .openProject(q) = Parser.command("Öffne WWT 412") else { Issue.record(); return }
        #expect(q.map(\.key) == ["wwt", "412"])
        let imp = Parser.implicitTicket(q)
        #expect(imp?.number == 412 && imp?.project.map(\.key) == ["wwt"] && imp?.numeralIndices == 1..<2)
        #expect(Parser.implicitTicket(TextNorm.tokenize("412")) == nil)          // no project words
        #expect(Parser.implicitTicket(TextNorm.tokenize("WWT Relaunch")) == nil)  // no number
    }

    @Test func cancel() {
        #expect(Parser.command("abbrechen") == .cancel)
        #expect(Parser.command("Nein.") == .cancel)
    }

    @Test(arguments: ["Öffne Ticket 412, danke", "Ticket 412 bitte schön", "Ticket 412 ja", "Öffne Ticket 412 gleich",
                      "Ticket 412 please", "Öffne mal eben Ticket 412", "Öffne eben mal Ticket 412", "Ja, Ticket 412",
                      "Öffne gerade eben Ticket 412", "Ticket 412 eben schnell"])
    func softFillersAreNoProjectWords(_ s: String) {
        #expect(Parser.command(s) == .openTask(query: [], number: 412), "\(s)")
    }

    @Test func ebenAloneStaysAProjectWord() {
        // STT hears the code "IBN" as "eben" (config alias): only "mal eben" & co. are fillers.
        guard case let .openProject(q) = Parser.command("Öffne Eben Betreuung") else { Issue.record(); return }
        #expect(q.map(\.key) == ["eben", "betreuung"])
        guard case let .openProject(q2) = Parser.command("Öffne mal eben WWT gleich") else { Issue.record(); return }
        #expect(q2.map(\.key) == ["wwt"])
    }

    @Test(arguments: ["Danke.", "Danke schön", "Dankeschön", "Nein danke", "Ja danke", "abbrechen bitte"])
    func politeCancel(_ s: String) { #expect(Parser.command(s) == .cancel, "\(s)") }

    @Test func softFillersStayAnswersWhileChoosing() {
        #expect(Parser.selection("ja", count: 1) == .pick(1))
        #expect(Parser.command("ja") == .unknown)
    }

    @Test func leadingNegationCorrectsTheCommand() {
        #expect(Parser.command("Nein, Ticket 412") == .openTask(query: [], number: 412))
        #expect(Parser.command("nein, WWT") == .openProject(query: [Token(text: "wwt", isAcronym: true)]))
    }
}

@Suite struct SelectionParserTests {
    @Test(arguments: [
        ("nein", Selection.keepListening), ("Nein.", .keepListening), ("nein nein", .keepListening), ("ne", .keepListening),
        ("abbrechen", .cancel), ("nein, abbrechen", .cancel), ("ja", .keepListening), ("Genau.", .keepListening),
        ("nein, die zweite", .pick(2)), ("Ne, die Vier", .pick(4)), ("nö, die erste", .pick(1)), ("nee drei", .pick(3)),
        ("mehr", .more), ("Frei.", .byName([Token(text: "frei")])),
    ])
    func fourItems(text: String, expect: Selection) {
        #expect(Parser.selection(text, count: 4) == expect, "\(text)")
    }

    @Test func confirmNeedsExactlyOneItem() {
        #expect(Parser.selection("ja", count: 1) == .pick(1))
        #expect(Parser.selection("ja genau", count: 1) == .pick(1))
        #expect(Parser.selection("passt", count: 2) == .keepListening)
    }

    @Test func negatedCommand() {
        #expect(Parser.selection("nein, öffne TKZ", count: 4) == .command(.openProject(query: [Token(text: "tkz", isAcronym: true)])))
    }
}

/// REVIEW M1: the end-of-utterance gate waits longer while the partial cannot be complete.
@Suite struct IncompleteTranscriptTests {
    @Test(arguments: ["", "  ", "Öffne", "Öffne das", "Öffne mir mal das", "Öffne das Projekt", "Ticket", "Ticket Nummer",
                      "Öffne WWT Ticket 4", "Öffne 47000", "Öffne WWT 412", "Zeig mir", "Öffne K und", "Öffne mal eben",
                      "Öffne Ticket 412 im", "Zeig meine"])
    func incomplete(_ s: String) { #expect(Parser.looksIncomplete(s), "\(s)") }

    @Test(arguments: ["Öffne das WWT Projekt", "Öffne WWT Relaunch", "WWT", "Meine Aufgaben", "Was steht an", "abbrechen",
                      "Danke.", "Nein.", "Mach WWT auf", "Ticket 412 bitte", "Öffne Eben Betreuung"])
    func complete(_ s: String) { #expect(!Parser.looksIncomplete(s), "\(s)") }

    @Test(arguments: ["zwei", "die zweite", "Nummer drei", "Relaunch", "abbrechen", "mehr", "nein, die zweite", "Hi."])
    func completeAnswer(_ s: String) { #expect(!Parser.looksIncomplete(s, choosing: true), "\(s)") }

    @Test(arguments: ["", "nein", "Nein,", "die", "Nummer", "nein, die", "nein, öffne", "Ticket 4", "ähm"])
    func incompleteAnswer(_ s: String) { #expect(Parser.looksIncomplete(s, choosing: true), "\(s)") }
}
