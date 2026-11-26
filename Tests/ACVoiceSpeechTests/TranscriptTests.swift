import ACVoiceCore
import Foundation
@testable import ACVoiceSpeech
import Testing

@Suite struct HypothesisBuilderTests {
    @Test func weightsOrderAndDedupe() {
        let dt = TranscriberText(best: "Öffne das WWT-Projekt", alternatives: ["Öffne das WWD Projekt", "Öffne das WWT-Projekt."])
        let st = TranscriberText(best: "Öffne das WWT Projekt.", alternatives: ["Öffne das W W T Projekt", "Öffne das Wette Projekt"])
        let h = HypothesisBuilder.build(dictation: dt, speech: st)
        // ST best and the spelled ST alternative have the same tokens as DT best.
        #expect(h == [Hypothesis("Öffne das WWT-Projekt"), Hypothesis("Öffne das WWD Projekt", weight: 0.9),
                      Hypothesis("Öffne das Wette Projekt", weight: 0.9)])
    }

    @Test func emptyAndPunctuationOnlyTextsAreDropped() {
        let h = HypothesisBuilder.build(dictation: TranscriberText(best: "  "), speech: TranscriberText(best: "Zwei.", alternatives: [".", "2.", "Zwei"]))
        #expect(h == [Hypothesis("Zwei."), Hypothesis("2.", weight: 0.9)])
    }

    @Test func bothBestTextsKeepFullWeight() {
        let h = HypothesisBuilder.build(dictation: TranscriberText(best: "Öffne TKZ Tauben"), speech: TranscriberText(best: "Öffne CKZ Touren."))
        #expect(h.map(\.weight) == [1.0, 1.0])
    }

    @Test func alternativesAreCapped() {
        let alts = (1...6).map { "Variante \($0)" }
        let h = HypothesisBuilder.build(dictation: TranscriberText(best: "a b", alternatives: alts), speech: TranscriberText(), maxAlternatives: 2)
        #expect(h.count == 3)
    }
}

@Suite struct ModuleResultsTests {
    let tol: Int64 = 800

    @Test func resentFinalsAreKeptOnce() {
        var m = ModuleResults()
        m.record(Segment(start: 0, end: 1000, texts: ["Öffne das"]), isFinal: true, finalizedThrough: 1000)
        m.record(Segment(start: 1000, end: 3000, texts: ["WWD Projekt"]), isFinal: true, finalizedThrough: 3000)
        // DT sends the same results again after a mid-session finalize, one with a longer range and a leading space.
        m.record(Segment(start: 0, end: 1000, texts: ["Öffne das"]), isFinal: true, finalizedThrough: 1000)
        m.record(Segment(start: 1000, end: 3500, texts: [" WWD Projekt"]), isFinal: true, finalizedThrough: 3500)
        #expect(m.transcript(from: 0, through: 4000, tolerance: tol, includeVolatile: false).best == "Öffne das WWD Projekt")
        #expect(m.finalizedThrough == 3500)
    }

    @Test func overlappingIdenticalFinalsCountOnce() {
        var m = ModuleResults()
        m.record(Segment(start: 0, end: 2000, texts: ["Zwei"]), isFinal: true, finalizedThrough: 2000)
        m.record(Segment(start: 100, end: 2000, texts: ["Zwei"]), isFinal: true, finalizedThrough: 2000)
        #expect(m.transcript(from: 0, through: 3000, tolerance: tol, includeVolatile: false).best == "Zwei")
    }

    @Test func volatileTextExtendsTheLiveTranscriptOnly() {
        var m = ModuleResults()
        m.record(Segment(start: 0, end: 1000, texts: ["Öffne"]), isFinal: true, finalizedThrough: 1000)
        m.record(Segment(start: 1000, end: 2000, texts: ["WWT Rel"]), isFinal: false, finalizedThrough: 1000)
        #expect(m.transcript(from: 0, through: nil, tolerance: tol, includeVolatile: true).best == "Öffne WWT Rel")
        #expect(m.transcript(from: 0, through: 5000, tolerance: tol, includeVolatile: false).best == "Öffne")
        m.record(Segment(start: 1000, end: 2500, texts: ["WWT Relaunch"]), isFinal: true, finalizedThrough: 2500)
        #expect(m.volatile == nil)
        #expect(m.transcript(from: 0, through: nil, tolerance: tol, includeVolatile: true).best == "Öffne WWT Relaunch")
    }

    @Test func volatileIsTheFallbackWithoutFinals() {
        var m = ModuleResults()
        m.record(Segment(start: 4000, end: 6000, texts: ["eins"]), isFinal: false, finalizedThrough: 0)
        let t = m.transcript(from: 4000, through: 8000, tolerance: tol, includeVolatile: false)
        #expect(t == TranscriberText(best: "eins", alternatives: [], fromVolatile: true))
    }

    @Test func utteranceRangeSelectsSegments() {
        var m = ModuleResults()
        m.record(Segment(start: 0, end: 30000, texts: ["Öffne das WWT-Projekt"]), isFinal: true, finalizedThrough: 30000)
        m.record(Segment(start: 40000, end: 46000, texts: ["zwei", "2", "zwo"]), isFinal: true, finalizedThrough: 46000)
        let answer = m.transcript(from: 40500, through: 50000, tolerance: tol, includeVolatile: false)
        #expect(answer == TranscriberText(best: "zwei", alternatives: ["2", "zwo"]))
        let command = m.transcript(from: 0, through: 36400, tolerance: tol, includeVolatile: false)
        #expect(command.best == "Öffne das WWT-Projekt")
        // Alternatives only describe a single segment.
        #expect(m.transcript(from: 0, through: nil, tolerance: tol, includeVolatile: false).alternatives.isEmpty)
    }
}

@Suite struct ContextBuilderTests {
    let projects = Fixture.projects
    let now = Fixture.now

    @Test func commandContextIsOrderedAndLimited() throws {
        let ctx = ContextBuilder.command(projects: projects, now: now)
        #expect(ctx.count == ContextBuilder.defaultLimit)
        #expect(Array(ctx.prefix(3)) == ContextBuilder.commandPhrases)
        for phrase in ["WWT", "S+K", "S und K", "eben", "Website Relaunch", "QZ", "WKT", "IBN"] {
            #expect(ctx.contains(phrase), "missing \(phrase)")
        }
        // Codes with personal signals come before the others (REVIEW m10).
        let wwt = try #require(ctx.firstIndex(of: "WWT")), wkt = try #require(ctx.firstIndex(of: "WKT"))
        #expect(wwt < wkt)
        #expect(Set(ctx.map(TextNorm.fold)).count == ctx.count)
        #expect(ctx.allSatisfy { $0.split(separator: " ").count <= 3 })
    }

    @Test(arguments: [0, 19, 35, 50, 100])
    func limitCutsTheSameOrder(_ limit: Int) {
        let full = ContextBuilder.command(projects: projects, now: now, limit: 500)
        let cut = ContextBuilder.command(projects: projects, now: now, limit: limit)
        #expect(cut == Array(full.prefix(limit)))
    }

    @Test func codeVariants() {
        #expect(ContextBuilder.codeVariants("S+K") == ["S+K", "S und K"])
        #expect(ContextBuilder.codeVariants("Hollenstein & Co") == ["Hollenstein & Co", "Hollenstein und Co"])
        #expect(ContextBuilder.codeVariants("S+K Partner") == ["S+K Partner"])
        #expect(ContextBuilder.codeVariants("Hollenstein TS Nordic") == ["Hollenstein TS Nordic"])
        #expect(ContextBuilder.codeVariants("ZLK Holding Europe Nord") == ["ZLK Holding"])
    }

    @Test func titleWords() {
        #expect(ContextBuilder.words("Schulungen 2027 - Zeiten nur im CRM!!!") == ["Schulungen", "Zeiten", "CRM"])
        #expect(ContextBuilder.words("Mitgliedermagazin \"Unser Blatt\"") == ["Mitgliedermagazin", "Unser", "Blatt"])
        #expect(ContextBuilder.words("Presse / Events Website") == ["Presse", "Events", "Website"])
    }

    @Test func answerContextForTheWWTList() {
        let choices = Fixture.wwtList.map(Fixture.project)
        let ctx = ContextBuilder.answer(choices: choices)
        #expect(Array(ctx.prefix(5)) == ["eins", "zwei", "drei", "vier", "zwo"])
        for phrase in ["Website Relaunch", "Maintenance", "Grand Navigation", "TYPO3", "die zweite", "die letzte", "abbrechen", "nein"] {
            #expect(ctx.contains(phrase), "missing \(phrase)")
        }
        #expect(!ctx.contains("fünf"))
        #expect(!ctx.contains("mehr"))
        #expect(ContextBuilder.answer(choices: choices, hasMore: true).contains("mehr"))
        #expect(ContextBuilder.answer(choices: choices, limit: 6).count == 6)
    }

    /// Review: rows are numbered absolutely across "mehr" pages (PLAN 4.5); page 2 of 6-row pages shows 7-12.
    @Test func answerContextNumbersRowsAbsolutely() {
        let titles = ["Website Relaunch", "Maintenance", "Grand Navigation", "Intranet", "Shop", "Newsletter"]
        let page2 = ContextBuilder.answer(titles: titles, hasMore: true, firstNumber: 7)
        #expect(Array(page2.prefix(6)) == ["sieben", "acht", "neun", "zehn", "elf", "zwölf"])
        for phrase in ["die siebte", "die achte", "die neunte", "die zehnte", "die letzte", "mehr", "Relaunch"] {
            #expect(page2.contains(phrase), "missing \(phrase)")
        }
        for phrase in ["eins", "zwei", "zwo", "sechs", "die erste", "die zweite"] {
            #expect(!page2.contains(phrase), "\(phrase) is not on page 2")
        }
        let page3 = ContextBuilder.answer(titles: Array(titles.prefix(2)), firstNumber: 13)
        #expect(Array(page3.prefix(2)) == ["dreizehn", "vierzehn"])
        #expect(!page3.contains { $0.hasPrefix("die ") && $0 != "die letzte" })   // ordinals stop at "zehnte"
        // The first page is unchanged.
        let page1 = ContextBuilder.answer(titles: titles, hasMore: true)
        #expect(Array(page1.prefix(7)) == ["eins", "zwei", "drei", "vier", "fünf", "sechs", "zwo"])
        #expect(page1.contains("die sechste"))
        #expect(ContextBuilder.answer(choices: Fixture.wwtList.map(Fixture.project), firstNumber: 5).first == "fünf")
    }

    /// The written numbers parse back to their value with the resolver's number reading.
    @Test func spelledNumbersParseBack() throws {
        for n in 1...99 {
            let word = try #require(GermanNumbers.spelled(n))
            let tokens = TextNorm.tokenize(word)
            #expect(tokens.count == 1, "\(word)")
            #expect(tokens.first.flatMap { GermanNumbers.cardinal($0.key) } == n, "\(word)")
        }
        #expect(GermanNumbers.spelled(0) == nil)
        #expect(GermanNumbers.spelled(100) == nil)
        for (i, stem) in ContextBuilder.ordinalStems.enumerated() {
            #expect(GermanNumbers.ordinal(TextNorm.fold(stem + "e")) == i + 1, "\(stem)")
        }
    }

    @Test func singleChoiceAsksForYesOrOne() {
        let ctx = ContextBuilder.answer(titles: ["Website Relaunch"])
        #expect(ctx.first == "eins")
        #expect(!ctx.contains("zwo"))
        #expect(!ctx.contains("die letzte"))
    }
}
