import ACVoiceCore
@testable import ACVoiceSpeech
import Foundation
import Testing

/// The speech layer in English: contextual strings, the gate's dangling-word rule, the reopen rule and the
/// self-check texts follow the language of the voice commands. German stays the default.
@Suite struct EnglishContextBuilderTests {
    let projects = Fixture.projects
    let now = Fixture.now

    @Test func commandContext() throws {
        let ctx = ContextBuilder.command(projects: projects, now: now, language: .en)
        #expect(ctx.count == ContextBuilder.defaultLimit)
        #expect(Array(ctx.prefix(3)) == ContextBuilder.commandPhrases(.en))
        #expect(ContextBuilder.commandPhrases(.en) == ["Ticket", "My tasks", "Project"])
        for phrase in ["WWT", "S+K", "S and K", "WWT project", "eben", "Website Relaunch", "QZ", "WKT", "IBN"] {
            #expect(ctx.contains(phrase), "missing \(phrase)")
        }
        for phrase in ["S und K", "WWT-Projekt", "Meine Aufgaben", "Projekt"] { #expect(!ctx.contains(phrase), "\(phrase)") }
        let wwt = try #require(ctx.firstIndex(of: "WWT")), wkt = try #require(ctx.firstIndex(of: "WKT"))
        #expect(wwt < wkt)
        // Codes and titles are AC names: apart from the phrases, the order is the German one.
        let de = ContextBuilder.command(projects: projects, now: now, limit: 500)
        let en = ContextBuilder.command(projects: projects, now: now, limit: 500, language: .en)
        #expect(en.count == de.count)
        #expect(ContextBuilder.command(projects: projects, now: now) == ContextBuilder.command(projects: projects, now: now, language: .de))
    }

    @Test(arguments: [0, 19, 35, 50, 100])
    func limitCutsTheSameOrder(_ limit: Int) {
        let full = ContextBuilder.command(projects: projects, now: now, limit: 500, language: .en)
        #expect(ContextBuilder.command(projects: projects, now: now, limit: limit, language: .en) == Array(full.prefix(limit)))
    }

    @Test func codeVariants() {
        #expect(ContextBuilder.codeVariants("S+K", language: .en) == ["S+K", "S and K"])
        #expect(ContextBuilder.codeVariants("Hollenstein & Co", language: .en) == ["Hollenstein & Co", "Hollenstein and Co"])
        #expect(ContextBuilder.codeVariants("S+K Partner", language: .en) == ["S+K Partner"])
        #expect(ContextBuilder.codeVariants("S+K") == ["S+K", "S und K"])
    }

    @Test func answerContextForTheWWTList() {
        let choices = Fixture.wwtList.map(Fixture.project)
        let ctx = ContextBuilder.answer(choices: choices, language: .en)
        #expect(Array(ctx.prefix(4)) == ["one", "two", "three", "four"])
        for phrase in ["Website Relaunch", "Maintenance", "Grand Navigation", "TYPO3", "the second", "the last", "cancel", "no"] {
            #expect(ctx.contains(phrase), "missing \(phrase)")
        }
        for phrase in ["zwo", "five", "more", "abbrechen", "die zweite"] { #expect(!ctx.contains(phrase), "\(phrase)") }
        #expect(ContextBuilder.answer(choices: choices, hasMore: true, language: .en).contains("more"))
        #expect(ContextBuilder.answer(choices: choices, limit: 6, language: .en).count == 6)
    }

    @Test func answerContextNumbersRowsAbsolutely() {
        let titles = ["Website Relaunch", "Maintenance", "Grand Navigation", "Intranet", "Shop", "Newsletter"]
        let page2 = ContextBuilder.answer(titles: titles, hasMore: true, firstNumber: 7, language: .en)
        #expect(Array(page2.prefix(6)) == ["seven", "eight", "nine", "ten", "eleven", "twelve"])
        for phrase in ["the seventh", "the eighth", "the ninth", "the tenth", "the last", "more", "Relaunch"] {
            #expect(page2.contains(phrase), "missing \(phrase)")
        }
        for phrase in ["one", "two", "six", "the first", "the second"] { #expect(!page2.contains(phrase), "\(phrase) is not on page 2") }
        let page3 = ContextBuilder.answer(titles: Array(titles.prefix(2)), firstNumber: 21, language: .en)
        #expect(Array(page3.prefix(2)) == ["twenty-one", "twenty-two"])
        #expect(!page3.contains { $0.hasPrefix("the ") && $0 != "the last" })   // ordinals stop at "tenth"
    }

    /// Every phrase of the English answer context is an answer the English parser reads.
    @Test func answerPhrasesParseBack() {
        let ctx = ContextBuilder.answer(titles: ["Website Relaunch", "Maintenance", "Grand Navigation", "Shop"], hasMore: true,
                                        language: .en)
        let expected: [String: Selection] = [
            "one": .pick(1), "two": .pick(2), "three": .pick(3), "four": .pick(4), "the first": .pick(1), "the second": .pick(2),
            "the fourth": .pick(4), "the last": .pick(-1), "cancel": .cancel, "no": .keepListening, "more": .more,
        ]
        for (phrase, selection) in expected {
            #expect(ctx.contains(phrase), "missing \(phrase)")
            #expect(Parser.selection(phrase, count: 4, language: .en) == selection, "\(phrase)")
        }
        for n in 1...24 {
            let s = EnglishNumbers.spelled(n)!
            #expect(Parser.selection(s, count: 24, language: .en) == .pick(n), "\(s)")
        }
    }

    @Test func singleChoiceAsksForYesOrOne() {
        let ctx = ContextBuilder.answer(titles: ["Website Relaunch"], language: .en)
        #expect(ctx.first == "one")
        #expect(!ctx.contains("the last"))
    }
}

/// The gate's text rule is Core's (`Parser.looksIncomplete`) in the gate's language.
@Suite struct EnglishGateTextRuleTests {
    @Test(arguments: [
        ("Open", true), ("Open the", true), ("Open WWT", false), ("Open WWT ticket", true), ("Open WWT ticket 412", true),
        ("Open ticket 47,285", true), ("Show my tasks", false), ("Open the WWT project", false), ("Open the project", true),
        ("Can you please open the project", true), ("My tasks", false), ("Open S and", true), ("TYPO 3", true),
        ("Open WWT please", false), ("Hey Jarvis", true), ("Never mind", false),
    ])
    func command(_ text: String, _ incomplete: Bool) {
        var g = EndpointGate(language: .en)
        g.arm(.command, at: 0)
        g.partial(text, at: 0.1)
        #expect(g.transcriptIncomplete == incomplete, "\(text)")
    }

    @Test(arguments: [
        ("two", false), ("the", true), ("no", true), ("no, the second", false), ("number", true), ("Relaunch", false),
        ("2.", false), ("the second one", false),
    ])
    func answer(_ text: String, _ incomplete: Bool) {
        var g = EndpointGate(language: .en)
        g.arm(.answer, at: 0)
        g.partial(text, at: 0.1)
        #expect(g.transcriptIncomplete == incomplete, "\(text)")
    }

    @Test func languageDecides() {
        // "Open the" dangles in English; the German gate reads "the" as a word.
        var en = EndpointGate(language: .en), de = EndpointGate()
        en.arm(.command, at: 0); de.arm(.command, at: 0)
        en.partial("Open the", at: 0.1); de.partial("Open the", at: 0.1)
        #expect(en.transcriptIncomplete && !de.transcriptIncomplete)
        #expect(EndpointGate().language == .de)
    }
}

@Suite struct EnglishFinishPolicyTests {
    func job(_ mode: UtteranceMode = .command, hangover: Double) -> Run.FinalizeJob {
        Run.FinalizeJob(epoch: Epoch(id: 1), utterance: 1, mode: mode, from: 0, through: 0, reason: .pause, speechStart: 0.3,
                        speechEnd: 1.3, lastVoicedWall: 0, decidedWall: 0, hangover: hangover, kill: false, reopens: 0)
    }

    let config = EndpointGate.Config()

    func reopens(_ mode: UtteranceMode = .command, hangover: Double, _ text: String) -> Bool {
        Run.shouldReopen(after: job(mode, hangover: hangover), killed: false, finalText: text, config: config, language: .en)
    }

    @Test func danglingFinalAfterAShortHangoverReopens() {
        #expect(reopens(hangover: 0.60, "Open WWT ticket"))
        #expect(reopens(hangover: 0.45, "Open ticket 47285"))
        #expect(reopens(hangover: 0.60, "Show me the"))
        #expect(reopens(.answer, hangover: 0.40, "no"))
        #expect(!reopens(.answer, hangover: 0.40, "two"))
        #expect(!reopens(.answer, hangover: 0.40, "the second one"))
        #expect(!reopens(hangover: 0.60, "Open WWT Relaunch"))
        #expect(!reopens(hangover: 1.10, "Open WWT ticket"))
        #expect(!reopens(hangover: 0.60, ""))
    }
}

@Suite struct EnglishSessionTests {
    @Test func sessionLanguageFollowsTheLocale() {
        #expect(VoiceSession().language == .de)
        #expect(VoiceSession(locale: AppLanguage.en.speechLocale).language == .en)
        #expect(VoiceSession(locale: AppLanguage.en.speechLocale).locale.identifier == "en_US")
    }

    @Test func selfCheckTexts() {
        #expect(SpeechSelfCheck.phrase(.de) == SpeechSelfCheck.defaultPhrase)
        #expect(SpeechSelfCheck.phrase(.en) == "Open the project")
        #expect(SpeechSelfCheck.words(SpeechSelfCheck.phrase(.en), .en) == ["open", "the", "project"])
        #expect(SpeechSelfCheck.Status.ready.in(.en) == "Speech recognition ready")
        #expect(SpeechSelfCheck.Status.ready.in(.de) == "Spracherkennung bereit")
        #expect(SpeechSelfCheck.Status.noVoice.in(.en) == "Install an English system voice")
        #expect(SpeechError.assetsUnavailable.message(.en) == "Speech model not available")
        #expect(SpeechError.assetsUnavailable.message == "Sprachmodell nicht verfügbar")
        for s in [SpeechSelfCheck.Status.noVoice, .noAnswer, .ready, .noText, .notUnderstood] {
            let t = s.in(.en)
            #expect(!t.contains("!") && !t.hasSuffix(".") && t.first?.isUppercase == true, "\(t)")
        }
    }
}
