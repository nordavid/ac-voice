import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

@Suite struct ChoicesTests {
    static let qz = [2073, 2071, 2072, 2074, 2075, 2076, 2077, 2078, 2079, 2080, 2081, 2082]

    func wwtList(config: Config = .init()) -> Harness {
        var h = Harness(config: config)
        h.command("Öffne das WWT-Projekt")
        return h
    }

    // MARK: Paging

    @Test func pagesOfSixWithMore() {
        var h = Harness()
        h.command("Öffne QZ")
        #expect(h.phase == .choices)
        #expect(h.model.choices.map(\.n) == Array(1...6) && h.model.total == 12 && h.model.pageCount == 2)
        #expect(h.model.choices.map(\.target.projectId) == Array(Self.qz.prefix(6)))
        #expect(h.state.total == 12 && h.state.choices?.count == 6 && h.model.hiddenCount == 6)
        let seq = h.model.seq
        h.advance(3)
        h.say("mehr")
        #expect(h.model.page == 1 && h.model.choices.map(\.n) == Array(7...12))
        #expect(h.model.choices.map(\.target.projectId) == Array(Self.qz.suffix(6)))
        #expect(h.dueIs(.choicesDeadline, 6.0) && h.model.deadline == h.now.addingTimeInterval(6))
        #expect(h.gen == SpeechGen(session: 1, utterance: 3))
        // The answer context follows the page: its titles only, numbered from 7.
        let page2 = h.model.choices.map(\.title)
        #expect(h.mode == .answer(titles: page2, firstNumber: 7, hasMore: true))
        // Numbers stay absolute: "sieben" is the first row of page 2; old keys still pick by number.
        #expect(h.flow.list?.listSeq == seq)
        h.say("sieben")
        #expect(h.opened == Fixture.projectURL(Self.qz[6]))
    }

    @Test func moreWrapsAround() {
        var h = Harness()
        h.command("Öffne QZ")
        h.say("mehr")
        h.say("weitere")
        #expect(h.model.page == 0 && h.model.choices.first?.n == 1)
    }

    @Test func moreOnASinglePageHints() {
        var h = wwtList()
        h.say("mehr")
        #expect(h.phase == .choices && h.model.page == 0 && h.model.hint == "Mehr Einträge gibt es nicht")
        #expect(h.flow.list?.unclear == 0)
    }

    @Test func visibleChoicesFromConfig() {
        var config = Config()
        config.visibleChoices = 4
        var h = Harness(config: config)
        h.command("Öffne QZ")
        #expect(h.model.choices.count == 4 && h.model.pageCount == 3)
    }

    // MARK: Narrow

    @Test func narrowRendersASubsetWithFreshDeadlineAndSeq() {
        var h = wwtList()
        let oldSeq = h.flow.list!.listSeq
        h.advance(4)
        h.say("Website")
        #expect(h.phase == .choices)
        #expect(h.model.choices.map(\.target.projectId) == [628, 315] && h.model.choices.map(\.n) == [1, 2])
        #expect(h.dueIs(.choicesDeadline, 6.0))
        let newSeq = h.flow.list!.listSeq
        #expect(newSeq > oldSeq && newSeq == h.model.seq)
        // A key pressed on the old numbering is stale ("2" was 314 there).
        #expect(h.send(.choose(n: 2, seq: oldSeq)).isEmpty)
        h.send(.choose(n: 2, seq: newSeq))
        #expect(h.opened == Fixture.projectURL(315))
        h.confirmOpen()
        #expect(h.has(.recordPick(query: "wwt", projectId: 315)))
    }

    /// FlowEvent.choose contract (REVIEW m4): a row carries the seq of the snapshot it was drawn from.
    @Test func clickOnARowDrawnBeforeTheNarrowIsStale() {
        var h = wwtList()
        // The overlay draws the rows of this snapshot and keeps its seq with them.
        let drawn = h.model.seq
        #expect(h.model.choices.map(\.target.projectId) == [628, 314, 315, 693])
        h.say("Website")                                   // narrow lands before the click is handled
        #expect(h.model.choices.map(\.target.projectId) == [628, 315])
        #expect(h.send(.choose(n: 2, seq: drawn)).isEmpty)  // row "2" was 314: dropped, not 315
        #expect(h.phase == .choices)
    }

    @Test func narrowThenSpokenPick() {
        var h = wwtList()
        h.say("Website")
        h.say("eins")
        #expect(h.opened == Fixture.projectURL(628))
    }

    // MARK: Choose (keys and clicks)

    @Test func chooseWithCurrentOrNewerSeq() {
        var h = wwtList()
        let seq = h.model.seq
        h.partial("hmm")    // transcript update: new snapshot, same numbering
        #expect(h.model.seq > seq)
        h.send(.choose(n: 3, seq: seq))
        #expect(h.opened == Fixture.projectURL(315))
    }

    @Test func chooseWithoutSeqFromOlderPlugins() {
        var h = wwtList()
        h.send(.choose(n: 4, seq: nil))
        #expect(h.opened == Fixture.projectURL(693))
    }

    @Test func chooseOutOfRangeOrOutsideChoicesIsIgnored() {
        var h = wwtList()
        #expect(h.send(.choose(n: 9, seq: nil)).isEmpty)
        #expect(h.send(.choose(n: 0, seq: nil)).isEmpty)
        var l = Harness()
        l.press()
        #expect(l.send(.choose(n: 1, seq: nil)).isEmpty)
    }

    // MARK: Answers

    @Test func unclearHintsExtendsAndFailsAfterTheLimit() {
        var h = wwtList()
        h.advance(2)
        let deadline = h.flow.list!.deadline
        h.say("Hallo")
        // Review U11: the hint quotes what did not fit; the headline keeps the command.
        let hint = "„Hallo“ passt zu keiner Zeile. Sag eine Zahl."
        #expect(h.phase == .choices && h.model.hint == hint && h.state.message == hint && h.model.hintIsAlert)
        #expect(h.model.transcript.text == "Öffne das WWT-Projekt" && h.model.answer.isEmpty)
        #expect(h.flow.list!.deadline == deadline.addingTimeInterval(4) && h.model.deadline == h.flow.list!.deadline)
        #expect(h.dueIs(.choicesDeadline, 8.0))
        h.say("Hallo")
        #expect(h.phase == .choices && h.flow.list?.unclear == 2)
        h.say("Hallo")
        #expect(h.phase == .error && h.model.message == "Ich verstehe die Auswahl nicht" && !h.micOn)
    }

    @Test func unclearLimitFromConfig() {
        var config = Config()
        config.maxUnclearAnswers = 0
        var h = wwtList(config: config)
        h.say("Hallo")
        #expect(h.phase == .error)
    }

    @Test func neinKeepsListeningWithoutAFailure() {
        var h = wwtList()
        h.say("Nein.")
        #expect(h.phase == .choices && h.flow.list?.unclear == 0 && h.model.hint == nil)
        #expect(h.gen == SpeechGen(session: 1, utterance: 3))
        h.say("nein, die zweite")
        #expect(h.opened == Fixture.projectURL(314))
    }

    @Test func confirmWordNeedsASingleItem() {
        var h = wwtList()
        h.say("Ja")
        #expect(h.phase == .choices && h.flow.list?.unclear == 0)
    }

    @Test func emptyAnswerRearms() {
        var h = wwtList()
        h.onset(); h.ended(); h.final()
        #expect(h.phase == .choices && h.gen == SpeechGen(session: 1, utterance: 3) && h.flow.list?.unclear == 0)
    }

    @Test func pickByName() {
        var h = wwtList()
        h.say("Relonch")
        #expect(h.opened == Fixture.projectURL(628))
        h.confirmOpen()
        #expect(h.has(.recordPick(query: "wwt", projectId: 628)))
    }

    // MARK: Hesitation in answers (REVIEW M1)

    /// Hangover after one answer partial while the WWT list is visible.
    func answerHangover(_ text: String) -> Double {
        var h = wwtList()
        #expect(h.hangover == 0.40)
        h.onset()
        h.partial(text)
        return h.hangover!
    }

    /// Answers keep 0.40 s, also after a dangling word: the speech layer reopens a final that dangles ("die", "nein").
    @Test(arguments: [
        ("zwei", 0.40), ("die zweite", 0.40), ("Nummer drei", 0.40), ("Relaunch", 0.40), ("abbrechen", 0.40),
        ("mehr", 0.40), ("Website", 0.40), ("Hallo", 0.40),
        ("die", 0.40), ("Nummer", 0.40), ("die Nummer", 0.40), ("nein", 0.40), ("äh", 0.40), ("Option", 0.40),
        ("Öffne", 0.40), ("Öffne das", 0.40), ("Ticket", 0.40),
        // New commands follow the command rules: a trailing number may still grow.
        ("Öffne WWT Ticket", 1.1), ("Öffne WWT Ticket 4", 1.1), ("Ticket 47285", 1.1), ("Öffne ORV", 0.45),
    ])
    func answerHangoverPolicy(text: String, expect: Double) {
        #expect(answerHangover(text) == expect, "\(text)")
    }

    /// The gate ends the answer after "die"; the flow listens on without a failed answer (the speech layer reopens a
    /// dangling final first, so this is the fallback).
    @Test func pauseAfterADanglingWordKeepsTheListOpen() {
        var h = wwtList()
        h.onset()
        h.partial("die")
        let ended1 = h.pause(0.7)
        #expect(ended1)
        h.final("die")
        #expect(h.phase == .choices && h.flow.list?.unclear == 0 && h.gen == SpeechGen(session: 1, utterance: 3))
        h.onset()
        h.partial("zweite")
        let ended2 = h.pause(0.40)
        #expect(ended2)
        h.final("zweite")
        #expect(h.opened == Fixture.projectURL(314))
    }

    @Test func pauseBeforeANewCommandKeepsItWhole() {
        var h = wwtList()
        h.onset()
        h.partial("Öffne WWT Ticket")
        let ended3 = h.pause(0.7)
        #expect(!ended3)
        h.partial("Öffne WWT Ticket 58")
        let ended4 = h.pause(0.7)
        #expect(!ended4)
        let ended5 = h.pause(1.1)
        #expect(ended5)
        h.final("Öffne WWT Ticket 58")
        #expect(h.phase == .processing && h.has(.fetchArchive(projectIds: [693], request: h.pendingRequest!)))
    }

    @Test(arguments: ["die", "Nummer", "die Nummer", "Öffne", "Öffne das", "Ticket", "äh"])
    func hesitationFinalListensOnWithoutAFailure(text: String) {
        var h = wwtList()
        h.say(text)
        #expect(h.phase == .choices && h.flow.list?.unclear == 0 && h.model.hint == nil, "\(text)")
        #expect(h.gen == SpeechGen(session: 1, utterance: 3) && h.hangover == 0.40)
        h.say("zwei")
        #expect(h.opened == Fixture.projectURL(314))
    }

    @Test func hesitationsDoNotUseUpTheUnclearAnswers() {
        var h = wwtList()
        h.say("die")
        h.say("Nummer")
        h.say("Hallo")
        h.say("Öffne das")
        #expect(h.phase == .choices && h.flow.list?.unclear == 1)
    }

    @Test func aRealWordNextToAHesitationStillCounts() {
        // ST heard a name the list does not have: unclear, even though DT only heard "die".
        var h = wwtList()
        h.onset(); h.ended()
        h.send(.utterance(h.gen!, [Hypothesis("die"), Hypothesis("die Hallo")]))
        #expect(h.flow.list?.unclear == 1 && h.model.hint == FlowText.de.unclearAnswer("die"))
    }

    // MARK: Deadline

    @Test func speechExtendsTheDeadline() {
        var h = wwtList()
        h.advance(5)
        h.onset()                    // deadline >= 7.5
        h.advance(0.5)
        h.voice(false)               // deadline >= 8.0
        h.advance(0.6)               // 6.1: the old deadline passed
        #expect(h.phase == .choices && h.dateIs(h.model.deadline, 8.0))
        h.advance(1.8)
        #expect(h.phase == .choices)
        h.advance(0.2)
        #expect(h.phase == .idle)
    }

    @Test func ongoingVoiceHoldsTheDeadline() {
        var h = wwtList()
        h.advance(5)
        h.onset()
        h.advance(4)                 // still voiced at 9.0 (deadline 7.5 passed while speaking)
        #expect(h.phase == .choices)
        h.voice(false)
        h.advance(2.6)
        #expect(h.phase == .idle)
    }

    @Test func continuousNoiseHitsTheHardCap() {
        var h = wwtList()
        h.onset()
        for _ in 0..<40 { h.advance(1); h.voice(true) }
        #expect(h.phase != .choices)
    }

    // MARK: Tickets in a list

    @Test func ticketListPicksByNumberOrName() {
        var index = Fixture.index
        index.archiveComplete.insert(693)
        var h = Harness(index: index)
        h.command("Öffne WWT Ticket 412")
        #expect(h.phase == .choices)
        #expect(h.model.choices.map(\.target) == [.task(projectId: 314, taskId: 45_000, number: 412),
                                                   .task(projectId: 628, taskId: 50_000, number: 412)])
        #expect(h.model.choices[1].badges.contains(.completed) && h.model.choices[1].badges.contains(.favorite))
        #expect(h.model.choices[0].detail == "Ticket 412 · WWT: Maintenance [SLA]")
        h.say("Relaunch")
        #expect(h.opened == Fixture.taskURL(628, 50_000) && h.model.preview == "Ticket 412 · WWT: Website Relaunch")
        // Ticket lists do not teach project picks.
        h.confirmOpen()
        #expect(h.has(.recordOpen(projectId: 628)) && h.picks.isEmpty)
    }

    @Test func singleItemConfirmList() {
        var h = Harness()
        h.command("Öffne WWT Ticket 530 und 5")
        #expect(h.phase == .choices && h.model.choices.count == 1)
        #expect(h.model.hint == "Sag ja oder nein")
        h.say("Hallo")
        #expect(h.model.hint == "Sag ja oder nein")
        h.say("ja")
        #expect(h.opened == Fixture.taskURL(628, 61_834))
    }

    /// A one-item list is a confirm prompt: "nein" closes it (a longer list keeps listening).
    @Test func noClosesAConfirmPrompt() {
        var h = Harness()
        h.command("Öffne WWT Ticket 530 und 5")
        #expect(h.phase == .choices && h.model.choices.count == 1)
        h.say("Nein.")
        #expect(h.phase == .idle && !h.micOn)
        var list = wwtList()
        list.say("Nein.")
        #expect(list.phase == .choices)
    }
}

@Suite struct FastSelectTests {
    func list(fastSelect: Bool = true) -> Harness {
        var config = Config()
        config.fastSelect = fastSelect
        var h = Harness(config: config)
        h.command("Öffne das WWT-Projekt")
        h.onset()
        return h
    }

    @Test func twoEqualPartialPicksCommit() {
        var h = list()
        h.partial("zwei")
        #expect(h.phase == .choices && h.flow.list?.pendingPick == 1)
        h.partial("Zwei.")
        #expect(h.phase == .opening && h.opened == Fixture.projectURL(314))
        // The final of that answer is dropped.
        #expect(h.send(.utterance(SpeechGen(session: 1, utterance: 2), [Hypothesis("zwei")])).isEmpty)
    }

    @Test func silenceAfterAPartialPickCommits() {
        var h = list()
        h.partial("drei")
        h.voice(false)
        #expect(h.dueIs(.fastSelect, 0.25))
        h.advance(0.24)
        #expect(h.phase == .choices)
        h.advance(0.02)
        #expect(h.opened == Fixture.projectURL(315))
    }

    @Test func partialAfterSilenceCommitsAtOnce() {
        var h = list()
        h.voice(false)
        h.advance(0.3)
        h.partial("vier")
        #expect(h.opened == Fixture.projectURL(693))
    }

    @Test func voiceCancelsThePendingCommit() {
        var h = list()
        h.partial("zwei")
        h.voice(false)
        h.advance(0.1)
        h.voice(true)
        #expect(h.due(.fastSelect) == nil)
        h.advance(1)
        #expect(h.phase == .choices)
        h.partial("zwei, nein drei")
        #expect(h.flow.list?.pendingPick == nil && h.phase == .choices)
        h.ended(); h.final("zwei, nein drei")
        #expect(h.phase == .choices && h.model.hint == FlowText.de.unclearAnswer("zwei, nein drei"))
    }

    @Test func changingPartialResetsThePick() {
        var h = list()
        h.partial("zwei")
        h.partial("Relaunch")
        #expect(h.flow.list?.pendingPick == 0)
        h.partial("Website")
        #expect(h.flow.list?.pendingPick == nil && h.phase == .choices)
    }

    @Test func singlePartialWithoutVoiceEventsWaitsForTheFinal() {
        var h = list()
        h.partial("zwei")
        h.advance(1)
        #expect(h.phase == .choices)
        h.ended(); h.final("zwei")
        #expect(h.opened == Fixture.projectURL(314))
    }

    @Test func disabledFlagWaitsForTheFinal() {
        var h = list(fastSelect: false)
        h.partial("zwei")
        h.partial("zwei")
        h.voice(false)
        h.advance(1)
        #expect(h.phase == .choices && h.due(.fastSelect) == nil)
        h.ended(); h.final("zwei")
        #expect(h.opened == Fixture.projectURL(314))
    }

    @Test func strongCancelInAPartial() {
        var h = list()
        h.partial("abbrechen")
        #expect(h.phase == .idle)
    }
}
