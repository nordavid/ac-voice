import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

/// One test per row (and exit) of the PLAN section 3 state table.
@Suite struct StateTableTests {
    // MARK: idle

    @Test func idlePressListens() {
        var h = Harness()
        let fx = h.press()
        #expect(h.phase == .listening)
        let g = SpeechGen(session: 1, utterance: 1)
        guard case .publish(let m)? = fx.first else { Issue.record("publish first"); return }
        #expect(m.phase == .listening && m.visible && !m.micReady && m.seq == 1)
        #expect(Array(fx.dropFirst().prefix(5)) == [
            .showOverlay, .startMic(g, mode: .command, hangover: 0.6), .suspendEndpointing(true), .refreshIndex,
            .schedule(TimerID(kind: .micStart, token: 1), after: 10.0),
        ])
        #expect(h.state.phase == .listening && h.state.micReady == false)
    }

    // MARK: listening

    @Test func micReadyArmsNoSpeechAndTicks() {
        var h = Harness()
        h.press()
        h.micReady()
        #expect(h.has(.earcon(.listen)) && h.has(.cancelTimer(.micStart)))
        #expect(h.dueIs(.noSpeech, 4.0))
        #expect(h.model.micReady && h.state.micReady == true)
        // A second micReady of the same session changes nothing.
        #expect(h.micReady().isEmpty)
    }

    @Test func noEarconWhenDisabled() {
        var config = Config()
        config.earcons = false
        var h = Harness(config: config)
        h.press()
        h.micReady()
        #expect(!h.all.contains { if case .earcon = $0 { return true }; return false })
    }

    @Test func speechEndGoesToProcessing() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        #expect(h.due(.noSpeech) == nil && h.dueIs(.maxUtterance, 8.0))
        h.partial("Öffne WWT Relaunch")
        h.ended()
        #expect(h.phase == .processing && h.state.phase == .processing)
        #expect(h.dueIs(.finalize, 2.0) && h.due(.maxUtterance) == nil)
        h.final("Öffne WWT Relaunch")
        #expect(h.phase == .opening && h.opened == Fixture.projectURL(628))
    }

    @Test func utteranceWithoutSpeechEndedEvent() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        h.final("Meine Aufgaben")
        #expect(h.phase == .opening && h.opened == Config().myWorkURL)
    }

    /// Esc (or a press) on the "Öffne …" card: the open already went to Chrome and is not undone. The overlay closes at
    /// once and the late answer from Chrome changes nothing (README and PLAN say so).
    @Test func cancelOnTheOpeningCardKeepsTheSentOpen() {
        var h = Harness()
        h.command("WWT Relaunch")
        #expect(h.phase == .opening && h.opened != nil)
        let request = h.pendingRequest!
        _ = h.send(.cancel)
        #expect(h.phase == .idle && h.has(.hideOverlay(fade: 0.2)))
        _ = h.send(.opened(request: request, .reused))
        #expect(h.phase == .idle && h.last.isEmpty)
    }

    @Test func pressWhileSpeakingEndsUtterance() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        h.partial("Öffne WWT")
        h.press("p2")
        #expect(h.has(.endUtteranceNow(SpeechGen(session: 1, utterance: 1))))
        #expect(h.phase == .processing)
        h.final("Öffne WWT")
        #expect(h.phase == .choices)
    }

    @Test func partialCancelWordGoesIdle() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        h.partial("abbrechen")
        #expect(h.phase == .idle && h.has(.stopMic) && h.has(.hideOverlay(fade: 0.2)) && !h.visible)
        #expect(h.state.phase == .idle)
    }

    @Test func partialNeinDoesNotCancel() {
        // "Nein, Ticket 412" starts with a cancel word; only strong cancel words act on partials.
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        h.partial("Nein")
        #expect(h.phase == .listening)
        h.partial("Nein, Ticket 47285")
        h.ended()
        h.final("Nein, Ticket 47285")
        #expect(h.opened == Fixture.taskURL(2032, 47_285))
    }

    @Test func noSpeechAfterMicReadyIsAnError() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.advance(3.9)
        #expect(h.phase == .listening)
        h.advance(0.2)
        #expect(h.phase == .error && h.model.message == "Ich höre nichts" && h.state.phase == .error)
        #expect(h.all.contains(.stopMic) && h.all.contains(.earcon(.error)) && !h.micOn)
        // Review U27: the next step under the error. Review U16: it holds 3.0 s.
        #expect(h.model.hint == FlowText.tryMyTasks)
        h.advance(2.8)
        #expect(h.phase == .error)
        h.advance(0.2)
        #expect(h.phase == .idle && h.has(.hideOverlay(fade: 0.2)))
    }

    @Test func speechLayerNoSpeechEventIsHandledToo() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.send(.noSpeech(h.gen!))
        #expect(h.phase == .error && h.model.message == "Ich höre nichts")
    }

    @Test func maxUtteranceEndsTheUtterance() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.advance(1)
        h.onset()
        h.partial("Öffne das WWT Projekt und dann noch")
        h.advance(7.9)
        #expect(h.phase == .listening)
        h.advance(0.2)
        #expect(h.phase == .processing && h.all.contains(.endUtteranceNow(SpeechGen(session: 1, utterance: 1))))
    }

    @Test func micThatNeverStartsIsAnError() {
        var h = Harness()
        h.press(); h.release()
        h.advance(10.1)
        #expect(h.phase == .error && h.model.message == "Mikrofon startet nicht")
    }

    @Test func speechFailureIsAnError() {
        var h = Harness()
        h.press(); h.micReady()
        h.send(.speechFailed(h.gen!, .micDenied))
        #expect(h.phase == .error && h.model.message == "Erlaube das Mikrofon in der Einrichtung" && !h.micOn)
        // Failures of another session are ignored.
        var g = Harness()
        g.press(); g.micReady()
        #expect(g.send(.speechFailed(SpeechGen(session: 9, utterance: 1), .engine)).isEmpty)
    }

    @Test func speechFailureCountsForTheWholeSession() {
        // The engine fails while the list waits for an answer; the speech layer stamps it with the session start.
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        #expect(h.gen == SpeechGen(session: 1, utterance: 2))
        h.send(.speechFailed(SpeechGen(session: 1, utterance: 1), .engine))
        #expect(h.phase == .error && h.model.message == "Die Spracherkennung meldet einen Fehler" && !h.micOn)
    }

    // MARK: processing

    @Test func uniqueProjectOpens() {
        var h = Harness()
        h.command("WWT Relaunch")
        #expect(h.phase == .opening && h.state.phase == .processing)
        #expect(h.opened == Fixture.projectURL(628) && h.has(.stopMic) && !h.micOn)
        #expect(h.model.preview == "WWT: Website Relaunch")
    }

    @Test func myTasksOpensMyWork() {
        var config = Config()
        config.myTasksPath = "/users/{me}/tasks"
        config.userId = 538
        var h = Harness(config: config)
        h.command("Zeige meine Aufgaben")
        #expect(h.opened == URL(string: "https://ac.example.com/users/538/tasks"))
    }

    @Test func ambiguousShowsChoices() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        #expect(h.phase == .choices && h.state.phase == .choices)
        #expect(h.model.choices.map(\.target.projectId) == [628, 314, 315, 693])
        #expect(h.model.choices.map(\.n) == [1, 2, 3, 4])
        // The answer context gets the titles of the visible page (no truncated labels) and its first number.
        let titles = ["Website Relaunch", "Maintenance", "TYPO3 Website maintenance", "Grand Navigation"]
        #expect(h.has(.rearm(SpeechGen(session: 1, utterance: 2), mode: .answer(titles: titles, firstNumber: 1, hasMore: false),
                             hangover: 0.40)))
        #expect(h.dueIs(.choicesDeadline, 6.0) && h.model.deadline == h.now.addingTimeInterval(6))
        #expect(h.micOn)
    }

    @Test func notUnderstoodRetriesOnce() {
        var h = Harness()
        h.command("Hallo Welt")
        #expect(h.phase == .retry && h.state.phase == .listening)
        #expect(h.model.message == "Das verstehe ich nicht. Sag es nochmal." && h.state.message == h.model.message)
        #expect(h.has(.rearm(SpeechGen(session: 1, utterance: 2), mode: .command, hangover: 0.6)))
        #expect(h.dueIs(.retrySilence, 5.0) && h.micOn)
        #expect(h.model.transcript.text == "Hallo Welt")
    }

    @Test func finalizeTimeoutUsesTheLastPartial() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        h.partial("WWT Relaunch")
        h.ended()
        h.advance(2.1)
        #expect(h.phase == .opening && h.opened == Fixture.projectURL(628))
        // The late final of that utterance is dropped.
        #expect(h.send(.utterance(SpeechGen(session: 1, utterance: 1), [Hypothesis("Meine Aufgaben")])).isEmpty)
    }

    @Test func emptyFinalRetriesWithNothingHeard() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        h.ended()
        h.final("")
        #expect(h.phase == .retry && h.model.message == "Ich höre nichts. Sag es nochmal.")
    }

    @Test func noProjectDataIsAnError() {
        var h = Harness()
        h.env.interpreter = Interpreter(resolver: Resolver(projects: []))
        h.command("WWT Relaunch")
        #expect(h.phase == .error && h.model.message == "Die Projektliste fehlt")
    }

    // MARK: retry

    @Test func retryUtteranceProcesses() {
        var h = Harness()
        h.command("Hallo Welt")
        h.say("WWT Relaunch")
        #expect(h.phase == .opening && h.opened == Fixture.projectURL(628))
    }

    @Test func retrySilenceGoesIdle() {
        var h = Harness()
        h.command("Hallo Welt")
        h.advance(4.9)
        #expect(h.phase == .retry)
        h.advance(0.2)
        #expect(h.phase == .idle && h.has(.stopMic) && h.has(.hideOverlay(fade: 0.2)))
    }

    @Test func secondFailureIsAnError() {
        var h = Harness()
        h.command("Hallo Welt")
        h.say("YouTube")
        #expect(h.phase == .error && h.model.message == "Das verstehe ich nicht" && !h.micOn)
    }

    @Test func retrySpeechStopsTheSilenceTimer() {
        var h = Harness()
        h.command("Hallo Welt")
        h.advance(3)
        h.onset()
        #expect(h.due(.retrySilence) == nil)
        h.advance(4)
        #expect(h.phase == .retry)
    }

    // MARK: choices (exits; details in ChoicesTests)

    @Test func choicesPickOpensAndRecordsThePickOnceOpened() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.say("zwei")
        #expect(h.phase == .opening && h.opened == Fixture.projectURL(314) && h.has(.stopMic))
        // History learns real opens only: nothing before Chrome confirms.
        #expect(h.picks.isEmpty)
        h.confirmOpen()
        #expect(h.phase == .success)
        let open = h.last.firstIndex(of: .recordOpen(projectId: 314))
        let record = h.last.firstIndex(of: .recordPick(query: "wwt", projectId: 314))
        #expect(open != nil && record != nil && open! < record!)
        #expect(h.picks.count == 1)
    }

    @Test func pickWithoutAConfirmedOpenTeachesNothing() {
        // Cancelled while Chrome opens (the usual reason: a wrong pick).
        var a = Harness()
        a.command("Öffne das WWT-Projekt")
        a.say("zwei")
        let r = a.pendingRequest!
        a.press("p2")
        #expect(a.phase == .idle)
        #expect(a.send(.opened(request: r, .reused)).isEmpty)
        #expect(a.picks.isEmpty && !a.all.contains(.recordOpen(projectId: 314)))

        // Chrome and the fallback failed.
        var b = Harness()
        b.command("Öffne das WWT-Projekt")
        b.say("zwei")
        b.send(.openFailed(request: b.pendingRequest!))
        #expect(b.phase == .error && b.picks.isEmpty)

        // Open watchdog.
        var c = Harness()
        c.command("Öffne das WWT-Projekt")
        c.say("zwei")
        c.advance(5.1)
        #expect(c.phase == .error && c.picks.isEmpty)
    }

    @Test func fallbackOpenRecordsThePick() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.say("Relaunch")
        h.confirmOpen(.fallback(.denied))
        #expect(h.has(.recordOpen(projectId: 628)) && h.has(.recordPick(query: "wwt", projectId: 628)))
    }

    @Test func choicesNewCommandReplacesTheList() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.say("Ticket 47285")
        #expect(h.opened == Fixture.taskURL(2032, 47_285))
        h.confirmOpen()
        #expect(h.has(.recordOpen(projectId: 2032)) && h.picks.isEmpty)
    }

    @Test func choicesCancelWordGoesIdle() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        // "egal" cancels only in the final; "abbrechen" already in a partial (FastSelectTests).
        h.say("egal")
        #expect(h.phase == .idle && h.has(.stopMic) && h.has(.hideOverlay(fade: 0.2)))
    }

    @Test func choicesDeadlineGoesIdle() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.advance(5.9)
        #expect(h.phase == .choices)
        h.advance(0.2)
        #expect(h.phase == .idle && h.has(.stopMic) && h.has(.hideOverlay(fade: 0.2)))
    }

    // MARK: opening

    @Test func openedGoesToSuccessAndRecordsTheOpen() {
        var h = Harness()
        h.command("WWT Relaunch")
        h.send(.opened(request: h.pendingRequest!, .reused))
        #expect(h.phase == .success && h.state.phase == .success)
        #expect(h.model.message == "WWT: Website Relaunch" && h.model.hint == nil)
        #expect(h.has(.recordOpen(projectId: 628)) && h.has(.earcon(.done)))
        #expect(h.dueIs(.success, 0.7))
    }

    @Test func fallbackWithDeniedAutomationShowsAHint() {
        var h = Harness()
        h.command("WWT Relaunch")
        h.send(.opened(request: h.pendingRequest!, .fallback(.denied)))
        #expect(h.phase == .success && h.model.hint == FlowText.automationHint)
        #expect(h.state.message == "WWT: Website Relaunch")
        #expect(h.dueIs(.success, 3.5))   // review U16: three lines to read
    }

    /// Review C2: undetermined Automation also opens a new tab; the overlay says why, once per app run.
    @Test func fallbackWithUndeterminedAutomationPointsToTheSetupOnce() {
        var h = Harness()
        h.command("WWT Relaunch")
        h.send(.opened(request: h.pendingRequest!, .fallback(.undetermined)))
        #expect(h.phase == .success && h.model.hint == FlowText.automationSetupHint && h.dueIs(.success, 3.5))
        h.advance(4)
        h.command("WWT Relaunch")
        h.send(.opened(request: h.pendingRequest!, .fallback(.undetermined)))
        #expect(h.phase == .success && h.model.hint == nil && h.dueIs(.success, 0.7))
        // Other fallbacks (Chrome busy, late, missing) have nothing for the user to do.
        h.advance(1)
        h.command("WWT Relaunch")
        h.send(.opened(request: h.pendingRequest!, .fallback(.other)))
        #expect(h.model.hint == nil)
    }

    @Test func openFailureIsAnError() {
        var h = Harness()
        h.command("WWT Relaunch")
        h.send(.openFailed(request: h.pendingRequest!))
        #expect(h.phase == .error && h.model.message == "Chrome öffnet die Seite nicht")
    }

    @Test func openWatchdog() {
        var h = Harness()
        h.command("WWT Relaunch")
        h.advance(5.1)
        #expect(h.phase == .error && h.model.message == "Chrome reagiert nicht")
        // The late result is ignored.
        #expect(h.send(.opened(request: 1, .reused)).isEmpty)
    }

    @Test func staleOpenResultIsIgnored() {
        var h = Harness()
        h.command("WWT Relaunch")
        #expect(h.send(.opened(request: h.pendingRequest! + 7, .reused)).isEmpty)
        #expect(h.phase == .opening)
    }

    @Test func myTasksSuccessRecordsNoOpen() {
        var h = Harness()
        h.command("Meine Aufgaben")
        h.send(.opened(request: h.pendingRequest!, .newTab))
        #expect(h.phase == .success && h.model.message == "Meine Aufgaben")
        #expect(!h.last.contains { if case .recordOpen = $0 { return true }; return false })
    }

    // MARK: success / error

    @Test func successFadesToIdle() {
        var h = Harness()
        h.command("WWT Relaunch")
        h.send(.opened(request: h.pendingRequest!, .reused))
        h.advance(0.69)
        #expect(h.phase == .success)
        h.advance(0.02)
        #expect(h.phase == .idle && h.has(.hideOverlay(fade: 0.2)) && h.state.phase == .idle)
    }

    @Test func pressDuringSuccessListensAgain() {
        var h = Harness()
        h.command("WWT Relaunch")
        h.send(.opened(request: h.pendingRequest!, .reused))
        h.press("p2")
        #expect(h.phase == .listening && h.has(.startMic(SpeechGen(session: 2, utterance: 1), mode: .command, hangover: 0.6)))
        #expect(h.has(.cancelTimer(.success)) && h.has(.showOverlay))
        #expect(h.model.transcript.isEmpty && h.model.message == nil)
    }

    @Test func pressDuringErrorListensAgain() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.advance(4.1)
        #expect(h.phase == .error)
        h.press("p2")
        #expect(h.phase == .listening && h.micOn && h.has(.cancelTimer(.error)))
    }

    @Test func pluginCancelGoesIdleFromAnyPhase() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.send(.cancel)
        #expect(h.phase == .idle && !h.micOn)
        #expect(h.send(.cancel).isEmpty)
    }
}
