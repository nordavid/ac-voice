import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

@Suite struct HangoverTests {
    /// Hangover after one partial in the command phase.
    func hangover(_ text: String) -> Double {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial(text)
        return h.hangover!
    }

    @Test(arguments: [
        ("Öffne WWT Relaunch", 0.45), ("Meine Aufgaben", 0.45), ("Ticket 412 im WWT Relaunch", 0.45),
        ("Zeige meine Aufgabe", 0.45), ("WWT Relaunch bitte", 0.45),
        ("Öffne das WWT-Projekt", 0.6), ("Öffne WWT", 0.6), ("Hallo Welt", 0.6),
        // A trailing number may still grow: "Ticket 4…12", "vierhundert…zwölf", "47000…285" (REVIEW M1).
        ("Öffne WWT Ticket 4", 1.1), ("Öffne WWT Relaunch Ticket 412", 1.1), ("Ticket 47285", 1.1),
        ("Öffne WWT Ticket vier", 1.1), ("Ticket vierhundert", 1.1), ("Öffne WWT 41", 1.1),
        ("Öffne", 1.1), ("Öffne das", 1.1), ("Öffne WWT Ticket", 1.1), ("Zeige meine", 1.1),
        // Every ticket keyword of the parser dangles, not only "Ticket" and "Nummer".
        ("Öffne WWT Ticketnummer", 1.1), ("Öffne WWT Aufgabennummer", 1.1), ("Öffne WWT Tasknummer", 1.1),
        ("Öffne WWT Tickets", 1.1), ("Öffne WWT Tasks", 1.1), ("Öffne WWT Ticker", 1.1), ("Öffne WWT Issue", 1.1),
        ("Öffne WWT Aufgabe", 1.1), ("Öffne WWT Ticket Nummer", 1.1), ("Öffne WWT Ticket Nr", 1.1),
        // "Projekt" without a name, fillers only.
        ("Öffne das Projekt", 1.1), ("Öffne Projekt", 1.1), ("Öffne mir mal", 1.1), ("Hey Jarvis", 1.1),
        ("Öffne WWT und", 1.1), ("Ticket 412 im", 1.1),
    ])
    func policy(text: String, expect: Double) {
        #expect(hangover(text) == expect, "\(text)")
    }

    @Test func emittedOnlyOnChange() {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("Öffne WWT")
        #expect(!h.last.contains { if case .setHangover = $0 { return true }; return false })
        h.partial("Öffne WWT Relaunch")
        #expect(h.has(.setHangover(0.45)))
        h.partial("Öffne WWT Relaunch.")
        #expect(!h.last.contains { if case .setHangover = $0 { return true }; return false })
        h.partial("Öffne WWT Relaunch Ticket 4")
        #expect(h.has(.setHangover(1.1)))
    }

    @Test func trailingNumberHangoverIsTunable() {
        var t = FlowTimings()
        t.trailingNumberHangover = 0.6
        var h = Harness(timings: t)
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("Öffne WWT Ticket 4")
        #expect(h.hangover == 0.6)
    }

    /// REVIEW M1 prefix trap: a pause inside a ticket number must not open the ticket of its first digits.
    @Test func pauseInsideATicketNumberDoesNotOpenTheWrongTicket() {
        var index = Fixture.index
        index.add(TaskRef(id: 40_004, projectId: 628, number: 4))
        var h = Harness(index: index)
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("Öffne WWT Relaunch Ticket vier")
        let ended6 = h.pause(0.7)
        #expect(!ended6)
        #expect(h.phase == .listening && h.opened == nil)
        h.partial("Öffne WWT Relaunch Ticket vierhundertzwölf")
        let ended7 = h.pause(1.1)
        #expect(ended7)
        h.final("Öffne WWT Relaunch Ticket vierhundertzwölf")
        #expect(h.opened == Fixture.taskURL(628, 50_000))
    }

    /// One rule (Core `Parser.looksIncomplete`): the flow keeps no word lists of its own. A verb at the end of a
    /// German command completes it ("WWT Relaunch öffnen"); the old flow list kept it open.
    @Test func policyFollowsTheParser() {
        for text in ["Öffne WWT Relaunch", "WWT Relaunch öffnen", "Öffne WWT Ticket", "Öffne WWT Ticket 4", "Öffne das",
                     "Zeige meine Aufgabe", "Hey Jarvis", "Öffne WWT Relaunch Tasknummer"] {
            let i = Fixture.interpreter.command([Hypothesis(text)], now: Fixture.now)
            let expected = Parser.looksIncomplete(text) ? 1.1 : (i.isCompleteIntent ? 0.45 : 0.6)
            #expect(hangover(text) == expected, "\(text)")
        }
        #expect(hangover("WWT Relaunch öffnen") == 0.45)
    }

    /// DT or ST may lag behind on the last word: the hypothesis that heard more words decides (as the gate did).
    @Test func theLongerBestHypothesisDecides() {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.send(.partial(h.gen!, Transcript(volatile: "Öffne WWT"), [Hypothesis("Öffne WWT"), Hypothesis("Öffne WWT Ticket")]))
        #expect(h.hangover == 1.1)
        // An alternative (weight < 1) does not decide while a best hypothesis exists.
        h.send(.partial(h.gen!, Transcript(volatile: "Öffne WWT Relaunch"),
                        [Hypothesis("Öffne WWT Relaunch"), Hypothesis("Öffne WWT Relaunch Ticket", weight: 0.9)]))
        #expect(h.hangover == 0.45)
    }

    @Test func timingsFeedTheCorePolicy() {
        var t = FlowTimings()
        #expect(t.hangovers == HangoverPolicy.standard)
        #expect(t.answerHangover == 0.40)
        t.fastHangover = 0.3
        #expect(t.hangovers.fast == 0.3)
    }

    @Test func retryResetsToCommandHangover() {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("Hallo Welt Ticket")
        #expect(h.hangover == 1.1)
        h.ended(); h.final("Hallo Welt")
        #expect(h.phase == .retry && h.hangover == 0.6)
    }

    @Test(arguments: [
        ("Öffne WWT Relaunch", "WWT: Website Relaunch"), ("Öffne das WWT-Projekt", "4 WWT-Projekte"),
        ("Hollenstein", "5 Projekte"), ("Meine Aufgaben", "Meine Aufgaben"), ("Ticket 412", "Ticket 412"),
        ("Ticket 412 im WWT Relaunch", "Ticket 412 · WWT: Website Relaunch"), ("WWT Ticket 412", "Ticket 412 · WWT"),
    ])
    func preview(text: String, expect: String) {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial(text)
        #expect(h.model.preview == expect && h.state.preview == expect, "\(text)")
    }

    @Test func noPreviewWhenNotUnderstood() {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("Hallo Welt")
        #expect(h.model.preview == nil)
    }
}

@Suite struct OverlayModelTests {
    @Test func wirePhases() {
        #expect(FlowPhase.allCases.map(\.wire) == [.idle, .listening, .listening, .processing, .processing, .choices, .success, .error])
    }

    @Test func choicesState() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        let s = h.state
        #expect(s.phase == .choices && s.seq == h.model.seq && s.transcript == "Öffne das WWT-Projekt")
        #expect(s.choices == [
            IPC.Choice(n: 1, label: "Relaunch", detail: "WWT: Website Relaunch [AGIL]"),
            IPC.Choice(n: 2, label: "Maintenance", detail: "WWT: Maintenance [SLA]"),
            IPC.Choice(n: 3, label: "TYPO3", detail: "WWT: TYPO3 Website maintenance [AGIL]"),
            IPC.Choice(n: 4, label: "Navigation", detail: "WWT: Grand Navigation [AGIL]"),
        ])
        #expect(s.total == nil && s.micReady == nil && s.message == nil)
        #expect(s.deadline == OverlayModel.epochMs(h.now.addingTimeInterval(6)))
        #expect(h.model.choices[0].badges == [.favorite, .recent] && h.model.choices[3].badges.isEmpty)
        #expect(h.model.choices[0].title == "Website Relaunch" && h.model.choices[0].code == "WWT" && h.model.choices[0].type == "AGIL")
    }

    @Test func sinceChangesWithThePhaseOnly() {
        var h = Harness()
        h.press()
        let since = h.state.since
        #expect(since == OverlayModel.epochMs(Fixture.now))
        h.advance(0.5)
        h.micReady(); h.onset(); h.partial("WWT")
        #expect(h.state.since == since)
        h.ended()
        #expect(h.state.since == OverlayModel.epochMs(Fixture.now.addingTimeInterval(0.5)))
    }

    @Test func seqIsMonotonicAndPublishComesFirst() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.say("Website")
        h.say("eins")
        var last = 0
        for e in h.all { if case .publish(let m) = e { #expect(m.seq == last + 1); last = m.seq } }
        #expect(last > 5)
        var g = Harness()
        g.press()
        g.micReady()
        if case .publish = g.last.first {} else { Issue.record("publish must come first") }
    }

    @Test func noPublishWithoutChange() {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("WWT Relaunch")
        let fx = h.voice(false)
        #expect(!fx.contains { if case .publish = $0 { return true }; return false })
    }

    @Test func idleStateIsBare() {
        let s = OverlayModel().ipcState()
        #expect(s.phase == .idle && s.transcript == nil && s.choices == nil && s.message == nil && s.micReady == nil)
    }

    @Test func labelsFitTheKey() {
        let items = ChoiceBuilder.projects(Fixture.projects, now: Fixture.now)
        #expect(items.allSatisfy { $0.label.count <= 12 && !$0.label.isEmpty })
        #expect(Set(items.map(\.label)).count > items.count / 2)
        let rbz = Fixture.projects.filter { $0.code == "RBZ" }
        let labels = ChoiceBuilder.labels(rbz)
        #expect(Set(labels).count == labels.count, "\(labels.count)")
    }

    @Test func equalLabelsGetTheCode() {
        let a = ProjectEntry(id: 1, name: "AAA: Relaunch Portal Neu"), b = ProjectEntry(id: 2, name: "BBB: Relaunch Portal Neu")
        #expect(ChoiceBuilder.labels([a, b]) == ["AAA Relaunch", "BBB Relaunch"])
        let e = ProjectEntry(id: 5, name: "AAA: Weiterentwicklung"), f = ProjectEntry(id: 6, name: "BBB: Weiterentwicklung")
        #expect(ChoiceBuilder.labels([e, f]) == ["AAA Weitere…", "BBB Weitere…"])
        let c = ProjectEntry(id: 3, name: "AAA: Shop"), d = ProjectEntry(id: 4, name: "BBB: Shop")
        #expect(ChoiceBuilder.labels([c, d]) == ["AAA Shop", "BBB Shop"])
    }
}

@Suite struct TextStyleTests {
    @Test func germanStringsFollowTheStyleRules() {
        for s in FlowText.all {
            #expect(!s.contains("–") && !s.contains("—"), "\(s)")
            let lower = s.lowercased()
            for word in ["könnte", "sollte", "würde", "wäre"] { #expect(!lower.contains(word), "\(s)") }
            // The automation hints run over two overlay lines (success card, 14 pt); everything else fits one.
            let limit = s == FlowText.automationHint || s == FlowText.automationSetupHint ? 90 : 60
            #expect(!s.isEmpty && s.count <= limit, "\(s)")
        }
    }

    @Test func failureTexts() {
        #expect(FlowText.failure(.micDenied) == "Erlaube das Mikrofon in der Einrichtung")
        #expect(FlowText.failure(.noInput) == "Mikrofon fehlt")
        #expect(FlowText.failure(.modelUnavailable) == "Sprachmodell fehlt")
        #expect(FlowText.failure(.engine) == "Die Spracherkennung meldet einen Fehler")
    }
}
