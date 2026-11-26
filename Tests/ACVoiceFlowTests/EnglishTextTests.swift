import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

/// German left in an English text: umlauts, German quote marks and frequent German words.
func germanLeftovers(_ s: String) -> [String] {
    var found = s.unicodeScalars.filter { "äöüÄÖÜß„".unicodeScalars.contains($0) }.map { String($0) }
    let words = Set(s.lowercased().split { !$0.isLetter }.map(String.init))
    let german: Set<String> = [
        "der", "die", "das", "und", "nicht", "ich", "du", "dein", "deine", "sag", "zum", "beispiel", "projekt",
        "projekte", "zeile", "zeilen", "einrichtung", "mikrofon", "sprachmodell", "spracherkennung", "fehlt", "steuerung",
        "erlaube", "melde", "mehr", "seite", "einen", "eine", "ist", "mit", "von", "noch", "kein", "keine", "bitte",
        "nummer", "zwei", "aufgaben", "meine", "suche", "lädt", "welches", "dieses", "weitere", "zeigt",
    ]
    found += words.intersection(german).sorted()
    return found
}

/// English UI style: no en or em dash, no spaced hyphen, no exclamation mark, no "would/could/should", sentence case
/// (a text that starts with a letter starts with a capital).
func englishStyleViolations(_ s: String) -> [String] {
    var v: [String] = []
    if s.contains("\u{2013}") || s.contains("\u{2014}") { v.append("dash") }
    if s.contains(" - ") { v.append("dash inside a sentence") }
    if s.contains("!") { v.append("exclamation mark") }
    // English puts the ellipsis right after the word ("Opening in Chrome…"); the space is German style.
    if s.contains(" …") { v.append("space before ellipsis") }
    let words = Set(s.lowercased().split { !$0.isLetter }.map(String.init))
    for w in ["would", "could", "should", "might"] where words.contains(w) { v.append(w) }
    if let first = s.first, first.isLetter, !first.isUppercase { v.append("sentence case") }
    return v
}

@Suite struct EnglishTextTests {
    @Test func everyEnglishTextIsFilledAndFreeOfGerman() {
        #expect(FlowText.en.all.count == FlowText.de.all.count)
        for s in FlowText.en.all {
            #expect(!s.isEmpty, "\(s)")
            #expect(germanLeftovers(s).isEmpty, "\(s): \(germanLeftovers(s))")
            #expect(englishStyleViolations(s).isEmpty, "\(s): \(englishStyleViolations(s))")
            // The same room as the German texts: one overlay line, the automation hints two.
            let limit = s == FlowText.en.automationHint || s == FlowText.en.automationSetupHint ? 90 : 60
            #expect(s.count <= limit, "\(s)")
        }
    }

    /// Every text but the language-neutral ticket title is translated.
    @Test func englishDiffersFromGerman() {
        for (de, en) in zip(FlowText.de.all, FlowText.en.all) where !de.hasPrefix("Ticket 412") {
            #expect(de != en, "\(de)")
        }
        #expect(FlowText(.en) == FlowText.en && FlowText(.de).language == .de)
    }

    /// The hint under an error card names the English command words.
    @Test func englishHintsAndExamples() {
        let en = FlowText.en
        #expect(en.hint(forError: en.nothingHeard) == en.tryMyTasks)
        #expect(en.tryMyTasks == "For example, say “my tasks”")
        #expect(en.hint(forError: en.tokenRejected) == en.signInAgain)
        #expect(en.hint(forError: en.acUnreachable) == en.checkNetwork)
        #expect(en.hint(forError: en.micDenied) == en.setupIsOpen)
        // A German message never maps to an English hint (each table answers its own texts).
        #expect(en.hint(forError: FlowText.de.nothingHeard) == nil)
        #expect(en.unclearAnswer("Hi.") == "“Hi.” matches no row. Say a number.")
        #expect(en.narrowed("Website", count: 2) == "“Website” matches 2 rows")
        #expect(en.narrowed("", count: 1) == "That matches one row")
        #expect(en.projectCount(4, code: "WWT") == "4 WWT projects" && en.ticketNotFound(412, code: "WWT") == "WWT has no ticket 412")
        #expect(en.failure(.micDenied) == en.micDenied && en.failure(.engine) == "Speech recognition reports an error")
    }
}

/// The reducer takes its texts from `FlowEnv.language`; the interpreter (German here) does not matter for them.
@Suite struct EnglishFlowTests {
    static func english() -> Harness {
        var h = Harness()
        h.env.language = .en
        return h
    }

    @Test func nothingHeardShowsTheEnglishErrorAndHint() {
        var h = Self.english()
        h.press(); h.micReady(); h.release()
        #expect(h.model.language == .en && h.state.lang == "en")
        h.advance(FlowTimings().noSpeech + 0.01)
        #expect(h.phase == .error && h.model.message == "I can’t hear anything")
        #expect(h.model.hint == FlowText.en.tryMyTasks && h.state.message == "I can’t hear anything")
    }

    @Test func coldPressShowsTheEnglishLoadingLine() {
        var h = Harness(warm: false)
        h.env.language = .en
        h.press()
        #expect(h.model.warming && h.model.message == FlowText.en.loadingModel)
        h.send(.speechWarm(true))
        #expect(!h.model.warming && h.model.message == nil)
    }

    @Test func micFailureInEnglish() {
        var h = Self.english()
        h.press(); h.micReady()
        h.send(.speechFailed(h.gen!, .micDenied))
        #expect(h.phase == .error && h.model.message == FlowText.en.micDenied && h.model.hint == FlowText.en.setupIsOpen)
    }

    @Test func listHintsInEnglish() {
        var h = Self.english()
        h.command("Öffne das WWT-Projekt")
        #expect(h.phase == .choices && h.model.choices.count == 4 && h.model.language == .en)
        h.advance(2)
        h.say("Hallo")
        #expect(h.model.hint == "“Hallo” matches no row. Say a number." && h.model.hintIsAlert)
        h.say("Hallo")
        h.say("Hallo")
        #expect(h.phase == .error && h.model.message == FlowText.en.selectionFailed)
    }

    @Test func ticketMessagesInEnglish() {
        var a = Self.english()
        a.command("Ticket 61234")
        #expect(a.model.message == "Looking for ticket 61234…")
        a.send(.probed(request: a.pendingRequest!, .notFound))
        #expect(a.phase == .error && a.model.message == "AC has no ticket 61234")

        var b = Self.english()
        b.command("Ticket 61234")
        b.send(.probed(request: b.pendingRequest!, .failed))
        #expect(b.model.message == FlowText.en.acUnreachable && b.model.hint == FlowText.en.checkNetwork)
    }

    /// The language rides along with every snapshot but never publishes one alone; German stays the default.
    @Test func languageAloneNeverPublishes() {
        var h = Self.english()
        let fx = h.send(.speechWarm(true))
        #expect(!fx.contains { if case .publish = $0 { return true }; return false })
        var g = Harness()
        g.press()
        #expect(g.model.language == .de && g.state.lang == "de")
    }

    @Test func ticketRowsUseTheTextsOfTheList() {
        let refs = [TaskRef(id: 45_000, projectId: 314, number: 412)]
        let byId = Dictionary(uniqueKeysWithValues: Fixture.projects.map { ($0.id, $0) })
        let en = ChoiceBuilder.tickets(refs, projects: byId, mine: [], now: Fixture.now, texts: .en)
        #expect(en.first?.detail.hasPrefix("Ticket 412 · ") == true)
        #expect(LivePolicy.preview(.myTasks, .en) == "My tasks" && LivePolicy.preview(.myTasks) == "Meine Aufgaben")
    }
}

/// The live rules (strong cancel, hesitation, hangovers) follow `FlowEnv.language`. An English session with an English
/// interpreter, as the controller builds it on an English Mac.
@Suite struct EnglishLiveRuleTests {
    static func english() -> Harness {
        var h = Harness()
        h.env.language = .en
        h.env.interpreter = Interpreter(resolver: Resolver(projects: Fixture.projects), language: .en)
        return h
    }

    /// The gate cut a hesitation: the list listens on without an alert and without a failed answer. More hesitations
    /// than `maxUnclearAnswers` keep the list, and a number still picks afterwards.
    @Test(arguments: ["The", "Uh", "um", "Number", "the", "wait a second", "One second.", "hang on", "Just a sec"])
    func hesitationInAListListensOn(_ answer: String) {
        var h = Self.english()
        h.command("open the WWT project")
        #expect(h.phase == .choices && h.model.choices.count == 4)
        for _ in 0...h.env.config.maxUnclearAnswers {
            h.say(answer)
            #expect(h.phase == .choices && !h.model.hintIsAlert, "\(answer): \(h.model.hint ?? "")")
        }
        h.say("two")
        #expect(h.phase == .opening, "\(answer)")
    }

    /// German keeps its own rule: "die" listens on, "the" is no German hesitation word.
    @Test func germanHesitationStaysGerman() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.say("die")
        #expect(h.phase == .choices && !h.model.hintIsAlert)
        h.say("the")
        #expect(h.phase == .choices && h.model.hintIsAlert)
    }

    @Test(arguments: ["never mind", "abort", "Cancel."])
    func liveStrongCancel(_ text: String) {
        var command = Self.english()
        command.press(); command.micReady(); command.release(); command.onset()
        command.partial(text)
        #expect(command.phase == .idle, "\(text)")

        var list = Self.english()
        list.command("open the WWT project")
        list.onset()
        list.partial(text)
        #expect(list.phase == .idle, "\(text)")
    }

    /// A German session does not cancel on the English phrase "never mind" in a partial.
    @Test func germanSessionKeepsGermanStrongCancel() {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("never mind")
        #expect(h.phase == .listening)
        h.partial("abbrechen")
        #expect(h.phase == .idle)
    }

    @Test func hangoversFollowTheEnglishRules() {
        var h = Self.english()
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("Show my tasks")
        #expect(h.hangover == 0.45)
        h.partial("Open the")
        #expect(h.hangover == 1.10)
        h.partial("Show me")
        #expect(h.hangover == 1.10)
        h.partial("No.")
        #expect(h.hangover == 0.60)
        // The same partials in a German session: "tasks" dangles as a German task word, "the" is a project word.
        var g = Harness()
        g.press(); g.micReady(); g.release(); g.onset()
        g.partial("Show my tasks")
        #expect(g.hangover == 1.10)
        g.partial("Open the")
        #expect(g.hangover == 0.60)
    }

    /// "wait a second" while a list is visible is no pick of row 2; "close it" closes the list.
    @Test func stallingAndClosingPhrasesInAList() {
        var h = Self.english()
        h.command("open the WWT project")
        h.say("wait a second")
        #expect(h.phase == .choices && h.pendingRequest == nil)
        h.say("close it")
        #expect(h.phase == .idle)
    }
}
