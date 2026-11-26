import Foundation
import Testing
@testable import ACVoiceCore

private typealias F = Fixture

/// The hangover rule the flow applies to every live partial (one rule for the flow, the speech tools and tests).
@Suite struct HangoverPolicyTests {
    let p = HangoverPolicy.standard

    func command(_ text: String) -> Double {
        p.command(text: text, interpretation: F.interpreter.command([Hypothesis(text)], now: F.now))
    }

    func answer(_ text: String, list: [Int] = [628, 314, 315, 693]) -> Double {
        let hyps = [Hypothesis(text)]
        return p.answer(text: text, outcome: F.interpreter.selection(hyps, candidates: list, now: F.now),
                        command: { F.interpreter.command(hyps, now: F.now) })
    }

    @Test func standardValues() {
        #expect(p == HangoverPolicy(command: 0.60, fast: 0.45, answer: 0.40, incomplete: 1.10, trailingNumber: 1.10))
    }

    @Test(arguments: [
        // Complete intents are fast.
        ("Öffne WWT Relaunch", 0.45), ("Meine Aufgaben", 0.45), ("Öffne Ticket 47285 bitte", 0.45),
        ("Ticket 412 im WWT Relaunch", 0.45), ("Zeige meine Aufgabe", 0.45), ("WWT Relaunch öffnen", 0.45),
        // Lists and misreads keep the command hangover.
        ("Öffne das WWT-Projekt", 0.60), ("Öffne WWT", 0.60), ("Hallo Welt", 0.60),
        // Dangling words and fillers only.
        ("Öffne", 1.10), ("Öffne das", 1.10), ("Öffne WWT Ticket", 1.10), ("Zeige meine", 1.10), ("Hey Jarvis", 1.10),
        ("Öffne WWT Ticketnummer", 1.10), ("Ticket 412 im", 1.10),
        // A trailing number may still grow (REVIEW M1).
        ("Öffne WWT Ticket 4", 1.10), ("Ticket 47285", 1.10), ("Öffne WWT 41", 1.10), ("Ticket vierhundert", 1.10),
    ])
    func commandPhase(text: String, expect: Double) {
        #expect(command(text) == expect, "\(text)")
    }

    @Test func numbersAndDanglingWordsHaveTheirOwnValues() {
        let tuned = HangoverPolicy(command: 0.6, fast: 0.45, answer: 0.4, incomplete: 1.2, trailingNumber: 0.9)
        let i = F.interpreter.command([Hypothesis("Öffne WWT Ticket 4")], now: F.now)
        #expect(tuned.command(text: "Öffne WWT Ticket 4", interpretation: i) == 0.9)
        #expect(tuned.command(text: "Öffne WWT Ticket", interpretation: i) == 1.2)
    }

    @Test(arguments: [
        ("zwei", 0.40), ("die zweite", 0.40), ("Relaunch", 0.40), ("die", 0.40), ("nein", 0.40), ("Öffne das", 0.40),
        // A new command follows the command rules.
        ("Öffne WWT Ticket", 1.10), ("Ticket 47285", 1.10), ("Öffne WWT Relaunch", 0.45),
    ])
    func answerPhase(text: String, expect: Double) {
        #expect(answer(text) == expect, "\(text)")
    }

    @Test func completeIntents() {
        func complete(_ t: String) -> Bool { F.interpreter.command([Hypothesis(t)], now: F.now).isCompleteIntent }
        #expect(complete("Meine Aufgaben") && complete("Öffne WWT Relaunch") && complete("Ticket 47285"))
        #expect(complete("Ticket 412 im WWT Relaunch") && complete("Ticket 412"))
        #expect(!complete("Öffne das WWT-Projekt") && !complete("WWT Ticket 412") && !complete("Hallo Welt"))
        #expect(!complete("Ticket 412 und 5"))   // a leftover numeral: not confident
        #expect(!Interpretation.cancel.isCompleteIntent)
    }

    @Test func endsInNumeral() {
        #expect(Parser.endsInNumeral("Ticket vierhundertzwölf") && Parser.endsInNumeral("Ticket 47.285."))
        #expect(Parser.endsInNumeral("Öffne WWT 4 12"))
        #expect(!Parser.endsInNumeral("Öffne eine") && !Parser.endsInNumeral("WWT Relaunch") && !Parser.endsInNumeral(""))
        #expect(!Parser.endsInNumeral("Öffne K und"))
    }
}

/// A one-item list is a confirm prompt ("Sag ja oder nein").
@Suite struct ConfirmPromptTests {
    @Test func negationClosesAConfirmPrompt() {
        #expect(Parser.selection("nein", count: 1) == .cancel)
        #expect(Parser.selection("Nein, nein.", count: 1) == .cancel)
        #expect(Parser.selection("nein, die erste", count: 1) == .pick(1))
        #expect(Parser.selection("ja", count: 1) == .pick(1))
        #expect(Parser.selection("nein", count: 2) == .keepListening)
        #expect(F.interpreter.selection([Hypothesis("Nein.")], candidates: [628], now: F.now) == .cancel)
        // The speech layer's rule still waits after "nein" (it does not know the list size).
        #expect(Parser.looksIncomplete("nein", choosing: true))
    }
}

@Suite struct IntegrationTextTests {
    /// "Geh WWT Relaunch": the verb is no spelled letter in front of the code ("GWWT").
    @Test func gehBeforeACode() {
        #expect(TextNorm.tokenize("Geh WWT Relaunch").map(\.key) == ["geh", "wwt", "relaunch"])
        #expect(F.run("Geh WWT Relaunch") == "unique 628")
        #expect(F.run("Geh zu WWT Relaunch") == "unique 628")
        // Spelled codes with G still collapse.
        #expect(TextNorm.tokenize("geh we ix").contains { $0.isAcronym && $0.text == "gwx" })
        #expect(TextNorm.tokenize("G W X").contains { $0.isAcronym && $0.text == "gwx" })
        #expect(TextNorm.tokenize("geh und ha").contains { $0.isAcronym && $0.text == "g+h" })
    }

    @Test func spelledNumbersParseBack() throws {
        for n in 1...99 {
            let word = try #require(GermanNumbers.spelled(n))
            #expect(TextNorm.tokenize(word).count == 1 && GermanNumbers.cardinal(TextNorm.tokenize(word)[0].key) == n, "\(word)")
        }
        #expect(GermanNumbers.spelled(0) == nil && GermanNumbers.spelled(100) == nil)
        #expect(GermanNumbers.spelled(2) == "zwei" && GermanNumbers.spelled(21) == "einundzwanzig")
    }

    @Test func speechStamp() {
        #expect(SpeechGen(session: 3, utterance: 2).description == "3.2")
        #expect(SpeechGen(session: 3, utterance: 2) != SpeechGen(session: 3, utterance: 3))
    }
}

/// `Interpreter(projects:config:history:)`: the runtime's one call.
@Suite struct InterpreterSetupTests {
    let ibn = 2041

    @Test func configAndLearnedAliases() {
        var config = Config()
        var history = History()
        for _ in 0..<2 { history.recordPick(query: "imben betreuung", projectId: ibn) }
        let learned = Interpreter(projects: F.projectsWithoutAliases, config: config, history: history)
        #expect(learned.resolver.projects.first { $0.id == ibn }?.aliases == ["imben"])
        #expect(F.run("Öffne Imben Betreuung", using: learned) == "unique \(ibn)")
        #expect(learned.history == history)

        config.learnAliases = false
        let off = Interpreter(projects: F.projectsWithoutAliases, config: config, history: history)
        #expect(off.resolver.projects.first { $0.id == ibn }?.aliases == [])

        config.aliases = ["IBN": ["eben"]]
        let configured = Interpreter(projects: F.projectsWithoutAliases, config: config, history: History())
        #expect(F.run("Öffne Eben Betreuung", using: configured) == "unique \(ibn)")
        // Config aliases come first; a learned alias that already exists is not added twice.
        config.learnAliases = true
        var both = History()
        for _ in 0..<2 { both.recordPick(query: "eben betreuung", projectId: ibn) }
        let merged = Interpreter(projects: F.projectsWithoutAliases, config: config, history: both)
        #expect(merged.resolver.projects.first { $0.id == ibn }?.aliases == ["eben"])
    }

    @Test func historyOpensBecomeSignals() {
        var history = History()
        history.recordOpen(projectId: 628, at: F.now)
        let entries = Interpreter.entries(F.projectsWithoutAliases, config: Config(), history: history)
        #expect(entries.first { $0.id == 628 }?.signals.recentOpens == [F.now])
        // Without opens in the history an entry keeps its own.
        let own = F.projectsWithoutAliases.first { !$0.signals.recentOpens.isEmpty }
        if let own {
            #expect(Interpreter.entries([own], config: Config(), history: History())[0].signals.recentOpens == own.signals.recentOpens)
        }
    }
}
