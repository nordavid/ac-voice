import ACVoiceCore
import Foundation
@testable import ACVoiceSpeech
import Testing

/// REVIEW M1 cases on synthetic 20 ms RMS sequences (no audio).
@Suite struct EndpointGateTests {
    @Test func keyClickIsNoOnset() {
        var d = GateDriver()
        #expect(d.run([(-60, 0.3), (-20, 0.02), (-60, 2)]).isEmpty)
    }

    @Test func blankedEarconIsIgnored() {
        var d = GateDriver()
        d.at(0.1) { $0.blank(from: 0.1, duration: 0.16) }
        #expect(d.run([(-60, 0.1), (-25, 0.16), (-60, 2)]).isEmpty)
    }

    @Test func earconWithoutBlankingFakesAnUtterance() {
        // Reproduces the bug the blanking fixes: onset and end before the user said anything.
        var d = GateDriver()
        let out = d.run([(-60, 0.1), (-25, 0.16), (-60, 2)])
        #expect(out.count == 2)
        guard case .onset(let start)? = out.first?.out else { Issue.record("no onset"); return }
        #expect(near(start, 0.1))
        #expect(out.last?.out.ending?.reason == .pause)
    }

    @Test func commandEndsAfterCommandHangover() throws {
        var d = GateDriver()
        d.partial(0.8, "Öffne WWT")
        d.partial(1.2, "Öffne WWT Relaunch")
        let out = d.run([(-60, 0.4), (-28, 0.9), (-60, 2)])
        #expect(out.count == 2)
        #expect(near(try #require(out.first).t, 0.52))   // 6 voiced slices of 20 ms
        let e = try #require(out.last?.out.ending)
        #expect(near(e.lastVoiced, 1.30))
        #expect(near(e.decidedAt, 1.90))
        #expect(e.reason == .pause)
    }

    @Test func hesitationAfterDanglingVerbDoesNotEnd() throws {
        // The controller asks for the incomplete hangover after "Öffne" and for the fast one after the name.
        var d = GateDriver()
        d.say(0.7, "Öffne")
        d.say(1.8, "Öffne WWT Relaunch")
        let out = d.run([(-60, 0.4), (-28, 0.4), (-60, 0.8), (-28, 0.6), (-60, 2)])
        let e = try #require(out.last?.out.ending)
        #expect(out.filter { $0.out.ending != nil }.count == 1)
        #expect(near(e.lastVoiced, 2.20))
        #expect(near(e.decidedAt, 2.20 + 0.45))
    }

    /// The flow owns the live policy: a dangling partial alone does not extend the budget the controller set.
    @Test func theGateAppliesTheControllersHangover() throws {
        var alone = GateDriver()
        alone.partial(1.2, "Öffne WWT Ticket")
        #expect(near(try #require(alone.run([(-60, 0.4), (-28, 0.9), (-60, 2)]).last?.out.ending).decidedAt, 1.30 + 0.60))
        #expect(alone.gate.transcriptIncomplete)   // still no stable-transcript end
        var custom = GateDriver(hangover: 0.75)
        custom.partial(1.2, "Öffne WWT Relaunch")
        #expect(custom.gate.hangover == 0.75)
        #expect(near(try #require(custom.run([(-60, 0.4), (-28, 0.9), (-60, 2)]).last?.out.ending).decidedAt, 1.30 + 0.75))
    }

    @Test func hesitationAfterCompleteWordsEndsEarly() throws {
        // Documented limit: only dangling words extend the budget.
        var d = GateDriver()
        d.partial(0.7, "Öffne WWT")
        let out = d.run([(-60, 0.4), (-28, 0.4), (-60, 0.8), (-28, 0.6), (-60, 2)])
        #expect(near(try #require(out.last?.out.ending).decidedAt, 1.40))
    }

    @Test func chatterAboveMaxThresholdEndsOnStableTranscript() throws {
        var d = GateDriver()
        d.partial(0.9, "Öffne WWT")
        d.partial(1.3, "Öffne WWT Relaunch")
        let out = d.run([(-25, 0.5), (-15, 0.8), (-25, 3)])
        let e = try #require(out.last?.out.ending)
        #expect(e.reason == .stableTranscript)
        #expect(near(e.decidedAt, 2.20))
    }

    @Test func musicBelowMaxThresholdAdaptsTheFloor() throws {
        var d = GateDriver()
        d.partial(1.0, "Öffne WWT Relaunch")
        let out = d.run([(-35, 0.5), (-20, 0.8), (-35, 2)])
        let e = try #require(out.last?.out.ending)
        #expect(e.reason == .pause)
        #expect(near(e.lastVoiced, 1.30))
        #expect(near(e.decidedAt, 1.90))
    }

    @Test func thresholdIsClamped() {
        var quiet = GateDriver()
        _ = quiet.run([(-80, 0.1)])
        #expect(quiet.gate.thresholdDB == -50)
        var loud = GateDriver()
        _ = loud.run([(-10, 0.02)])
        #expect(loud.gate.thresholdDB == -30)
    }

    @Test func floorFollowsDownAtOnceAndUpSlowly() throws {
        var d = GateDriver()
        _ = d.run([(-50, 0.02), (-70, 0.02)])
        #expect(d.gate.floorDB == -70)
        _ = d.run([(-60, 0.2)])   // 10 slices at 15 dB/s = +3 dB
        #expect(abs(try #require(d.gate.floorDB) - -67) < 0.01)
    }

    @Test func floorFreezesAtOnset() throws {
        var d = GateDriver()
        d.partial(0.4, "Öffne WWT Relaunch")
        _ = d.run([(-60, 0.2), (-28, 0.3)])
        #expect(d.gate.phase == .speaking)
        let atOnset = try #require(d.gate.floorDB)
        #expect(atOnset < -58)   // at most 6 slices of 0.3 dB rise during the onset window
        _ = d.run([(-75, 0.2)])
        #expect(d.gate.floorDB == atOnset)
    }

    /// The controller's number rule (REVIEW M1, Core `HangoverPolicy.trailingNumber`): a trailing number waits.
    @Test func trailingNumberWaitsForTheIncompleteHangover() throws {
        var d = GateDriver()
        d.say(1.2, "Öffne WWT Ticket 412")
        let e = try #require(d.run([(-60, 0.4), (-28, 0.9), (-60, 2)]).last?.out.ending)
        #expect(near(e.decidedAt, 1.30 + 1.10))
    }

    @Test func fastHangoverForResolvedPreview() throws {
        var d = GateDriver()
        d.say(1.2, "Öffne WWT Relaunch")
        #expect(near(try #require(d.run([(-60, 0.4), (-28, 0.9), (-60, 2)]).last?.out.ending).decidedAt, 1.75))
    }

    @Test func answersUseAnswerHangoverAndNumbersAreComplete() throws {
        var d = GateDriver(.answer)
        d.partial(0.7, "zwei")
        let e = try #require(d.run([(-60, 0.4), (-28, 0.3), (-60, 2)]).last?.out.ending)
        #expect(near(e.decidedAt, 0.70 + 0.40))
        // A dangling live partial keeps the answer budget; the final text decides (`resume`).
        var negDefault = GateDriver(.answer)
        negDefault.partial(0.7, "nein")
        let early = try #require(negDefault.run([(-60, 0.4), (-28, 0.3), (-60, 2)]).last?.out.ending)
        #expect(near(early.decidedAt, 0.70 + 0.40))
        let resumed = negDefault.gate.resume(transcript: "Nein", at: 1.20)
        #expect(resumed)
        negDefault.partial(1.3, "Nein")   // the same words again keep it open
        #expect(negDefault.gate.effectiveHangover == 1.10)
    }

    @Test func emptyTranscriptCountsAsIncompleteForCommandsOnly() throws {
        var d = GateDriver()
        #expect(near(try #require(d.run([(-60, 0.4), (-28, 0.9), (-60, 2)]).last?.out.ending).decidedAt, 2.40))
        var config = EndpointGate.Config()
        config.emptyTranscriptIsIncomplete = false
        var off = GateDriver(config: config)
        #expect(near(try #require(off.run([(-60, 0.4), (-28, 0.9), (-60, 2)]).last?.out.ending).decidedAt, 1.90))
        var answer = GateDriver(.answer)
        #expect(near(try #require(answer.run([(-60, 0.4), (-28, 0.3), (-60, 2)]).last?.out.ending).decidedAt, 1.10))
    }

    @Test func noSpeechOnlyInCommandPhase() throws {
        var d = GateDriver()
        let out = d.run([(-60, 5)])
        #expect(out.count == 1)
        #expect(out[0].out == .noSpeech)
        #expect(near(out[0].t, 4.0))
        var answer = GateDriver(.answer)
        #expect(answer.run([(-60, 5)]).isEmpty)
    }

    @Test func maxUtteranceEndsEndlessSpeech() throws {
        var d = GateDriver()
        for i in 1...20 { d.partial(Double(i) * 0.5, "Wort \(i) Wort") }
        let e = try #require(d.run([(-60, 0.2), (-20, 10)]).last?.out.ending)
        #expect(e.reason == .maxDuration)
        #expect(near(e.decidedAt, 0.2 + 8.0))
    }

    @Test func holdSuspendsPausesAndEndNowEnds() throws {
        var d = GateDriver()
        d.at(0.1) { $0.setHold(true) }
        d.partial(1.0, "Öffne WWT Relaunch")
        #expect(d.run([(-60, 0.4), (-28, 0.9), (-60, 2)]).count == 1)   // onset only
        let e = try #require(d.gate.endNow(at: 3.3).ending)
        #expect(e.reason == .manual)
        #expect(near(e.lastVoiced, 1.30))
    }

    @Test func endNowBeforeOnsetIsIgnored() {
        var d = GateDriver()
        _ = d.run([(-60, 0.5)])
        #expect(d.gate.endNow(at: 0.5) == .none)
        #expect(d.gate.phase == .waiting)
    }

    @Test func theLongerPartialDecides() {
        var g = EndpointGate()
        g.arm(.command, at: 0)
        g.partial(dt: "Öffne WWT", st: "Öffne WWT Ticket", at: 1)   // DT lags on the last word
        #expect(g.transcriptIncomplete)
        g.partial(dt: "Öffne das WWD Projekt", st: "Öffne das", at: 2)   // ST lags
        #expect(!g.transcriptIncomplete)
        #expect(EndpointGate.leading("zwei", "Zwei.") == "zwei")
    }

    @Test func nearestChunkBoundaryDecides() throws {
        var d = GateDriver()
        d.partial(1.2, "Öffne WWT Relaunch")
        _ = d.run([(-60, 0.4), (-28, 0.9), (-60, 0.5)])   // silence 0.50 s at t = 1.80
        #expect(d.gate.chunkEnd(at: 1.80, chunkDuration: 0.1) == .none)   // 0.50 + 0.05 < 0.6
        _ = d.run([(-60, 0.06)])
        let e = try #require(d.gate.chunkEnd(at: 1.86, chunkDuration: 0.1).ending)   // 0.56 + 0.05 >= 0.6
        #expect(near(e.lastVoiced, 1.30))
        var config = EndpointGate.Config()
        config.nearestChunkDecision = false
        var strict = GateDriver(config: config)
        strict.partial(1.2, "Öffne WWT Relaunch")
        _ = strict.run([(-60, 0.4), (-28, 0.9), (-60, 0.56)])
        #expect(strict.gate.chunkEnd(at: 1.86, chunkDuration: 0.1) == .none)
    }

    @Test func resumeAfterADanglingFinal() throws {
        var d = GateDriver()
        d.partial(1.2, "Öffne WWT")
        let first = try #require(d.run([(-60, 0.4), (-28, 0.9), (-60, 0.6)]).last?.out.ending)
        #expect(near(first.decidedAt, 1.90))
        // The final text says "Öffne WWT Ticket": listen on until speech end + 1.1 s.
        let resumed = d.gate.resume(transcript: "Öffne WWT Ticket", at: 1.94)
        #expect(resumed)
        #expect(d.gate.effectiveHangover == 1.10)
        d.say(2.3, "Öffne WWT Ticket 412")   // new words: the controller's number hangover applies
        let out = d.run([(-60, 0.1), (-28, 0.3), (-60, 2)])   // "412" from 2.00 to 2.30
        let second = try #require(out.last?.out.ending)
        #expect(near(second.lastVoiced, 2.30))
        #expect(near(second.decidedAt, 2.30 + 1.10))   // still ends in a number
        // Too late: the budget is used up.
        var late = GateDriver()
        late.partial(1.2, "Öffne WWT")
        _ = late.run([(-60, 0.4), (-28, 0.9), (-60, 0.6)])
        let lateResumed = late.gate.resume(transcript: "Öffne WWT Ticket", at: 2.5)
        #expect(!lateResumed)
        #expect(late.gate.phase == .idle)
    }

    @Test func rearmKeepsTheFloorAndResetsTheHangover() throws {
        var d = GateDriver()
        d.partial(1.2, "Öffne WWT")
        d.at(1.2) { $0.setHangover(0.45) }
        _ = d.run([(-58, 0.4), (-28, 0.9), (-60, 2)])
        let floor = d.gate.floorDB
        d.gate.arm(.answer, at: 2)
        #expect(d.gate.floorDB == floor)
        #expect(d.gate.hangover == 0.40)
        #expect(d.gate.effectiveHangover == 0.40)
        d.gate.arm(.command, at: 3, hangover: 0.5)
        #expect(d.gate.hangover == 0.5)
        #expect(d.gate.effectiveHangover == 1.10)   // no word yet
    }

    /// Review: PLAN's "hangover >= finalize lead + 50 ms" predates the synthetic tail. What must hold now: the
    /// audio fed at the decision (hangover minus up to half a chunk) plus the tail covers `speechEnd + lead`, so
    /// `finalize` never waits for real audio, with every hangover.
    /// Every hangover the flow sends by default (Core `HangoverPolicy.standard`, the source of `FlowTimings`) and
    /// the gate's own defaults qualify.
    @Test func syntheticTailCoversFinalizeForEveryHangover() {
        let t = VoiceSession.Tuning()
        let p = HangoverPolicy.standard
        #expect(t.gate.answerHangover == 0.40 && p.answer == 0.40)
        let chunk = 0.1
        for h in [p.command, p.fast, p.answer, p.incomplete, p.trailingNumber, t.gate.commandHangover, t.gate.answerHangover,
                  t.gate.incompleteHangover] {
            #expect(h - chunk / 2 + t.syntheticTail >= t.finalizeLead + 0.05, "hangover \(h)")
        }
        // With these tail and lead values any hangover qualifies, so M7 tuning is free to go lower.
        #expect(t.finalizeLead + 0.05 - t.syntheticTail + chunk / 2 <= 1e-9)
    }

    /// Review: a cough long enough for an onset ends as an utterance without words. `rewait` listens on, and the
    /// no-speech timeout still counts from `arm`.
    @Test func rewaitAfterAWordlessUtterance() throws {
        var d = GateDriver()
        let first = d.run([(-60, 0.3), (-22, 0.26), (-60, 1.5)])
        #expect(first.count == 2)
        let e = try #require(first.last?.out.ending)
        #expect(near(e.decidedAt, 0.56 + 1.10))   // no words: incomplete hangover
        d.gate.rewait(at: e.decidedAt)
        #expect(d.gate.phase == .waiting)
        #expect(d.gate.effectiveHangover == 1.10)
        let quiet = d.run([(-60, 3)])
        #expect(quiet.count == 1)
        #expect(quiet.first?.out == .noSpeech)
        #expect(near(try #require(quiet.first).t, 4.0))

        // Speech after the cough gets a fresh onset and a normal end.
        var s = GateDriver()
        let cough = try #require(s.run([(-60, 0.3), (-22, 0.26), (-60, 1.5)]).last?.out.ending)
        s.gate.rewait(at: cough.decidedAt)
        s.partial(2.6, "Zeig meine Aufgaben")
        let out = s.run([(-60, 0.4), (-28, 0.8), (-60, 2)])
        guard case .onset(let start)? = out.first?.out else { Issue.record("no onset after rewait"); return }
        #expect(near(start, 2.06))
        let end = try #require(out.last?.out.ending)
        #expect(near(end.lastVoiced, 2.86))
        #expect(near(end.decidedAt, 2.86 + 0.60))
        // Only from idle: a running utterance is not reset.
        s.gate.arm(.command, at: 5)
        _ = s.run([(-28, 0.2)])
        #expect(s.gate.phase == .speaking)
        s.gate.rewait(at: 5.2)
        #expect(s.gate.phase == .speaking)
    }

    /// Review C1: the app's gate (`noSpeechTimeout = .infinity`, the flow owns the timeout) keeps waiting for onset.
    /// With the 4 s default it went idle while the flow still listened: a held key and speech after 4.5 s, or a cough
    /// (rewait keeps the arm clock) and speech after 4 s, gave no onset at all.
    @Test func appGateLeavesTheNoSpeechTimeoutToTheFlow() throws {
        var config = EndpointGate.Config()
        config.noSpeechTimeout = .infinity
        var held = GateDriver(config: config)
        held.at(0.02) { $0.setHold(true) }
        let out = held.run([(-60, 4.5), (-20, 1.0)])
        guard case .onset(let start)? = out.first?.out else { Issue.record("held key: no onset after 4.5 s, \(out)"); return }
        #expect(near(start, 4.5))
        #expect(held.gate.phase == .speaking)

        var cough = GateDriver(config: config)
        let first = try #require(cough.run([(-60, 0.3), (-20, 0.25), (-60, 3)]).last?.out.ending)
        cough.gate.rewait(at: first.decidedAt)
        let after = cough.run([(-60, 3.0), (-20, 1.0), (-60, 2)])
        guard case .onset? = after.first?.out else { Issue.record("after rewait: no onset, \(after)"); return }
        #expect(after.last?.out.ending != nil)

        // The default (standalone use) still reports no speech 4 s after arming.
        var standalone = GateDriver()
        standalone.at(0.02) { $0.setHold(true) }
        #expect(standalone.run([(-60, 4.5)]).last?.out == .noSpeech)
    }

    /// Review (REVIEW m11 risk): a tap that starts with digital silence set the floor near -120 dB; it then rose at
    /// 15 dB/s only, so a -45 dBFS room counted as speech.
    @Test func digitalSilenceDoesNotMoveTheFloor() throws {
        var d = GateDriver()
        #expect(d.run([(-120, 0.2), (-45, 1.0)]).isEmpty)
        #expect(abs(try #require(d.gate.floorDB) - -45) < 0.01)
        _ = d.run([(-120, 0.1)])   // a dropout later does not lower it either
        #expect(abs(try #require(d.gate.floorDB) - -45) < 0.01)
        #expect(d.run([(-45, 1.0)]).isEmpty)
        // Without the guard the same room fakes an onset.
        var config = EndpointGate.Config()
        config.floorIgnoreBelowDB = -200
        var unguarded = GateDriver(config: config)
        guard case .onset? = unguarded.run([(-120, 0.2), (-45, 1.0)]).first?.out else {
            Issue.record("expected the unguarded gate to fake an onset"); return
        }
    }
}

/// The gate's text rule is Core's (`Parser.looksIncomplete`): the cases of the old speech word lists still hold.
@Suite struct GateTextRuleTests {
    @Test(arguments: [
        ("Öffne", true), ("Öffne das", true), ("Öffne WWT", false), ("Öffne WWT Ticket", true),
        ("Öffne WWT Ticket 412", true), ("Öffne Ticket 47.285", true), ("Zeige meine Aufgabe", false),
        ("Öffne Aufgabe", true), ("Öffne das WWT-Projekt", false), ("Öffne das Projekt", true),
        ("Öffne mir bitte das Projekt", true), ("Meine Aufgaben", false), ("Öffne K und", true), ("TYPO 3", true),
        ("Öffne WWT bitte", false), ("Hey Jarvis", true),
    ])
    func command(_ text: String, _ incomplete: Bool) {
        var g = EndpointGate()
        g.arm(.command, at: 0)
        g.partial(text, at: 0.1)
        #expect(g.transcriptIncomplete == incomplete, "\(text)")
    }

    @Test(arguments: [
        ("zwei", false), ("die", true), ("nein", true), ("nein, die zweite", false), ("Nummer", true), ("Relaunch", false),
        ("2.", false),
    ])
    func answer(_ text: String, _ incomplete: Bool) {
        var g = EndpointGate()
        g.arm(.answer, at: 0)
        g.partial(text, at: 0.1)
        #expect(g.transcriptIncomplete == incomplete, "\(text)")
    }

    @Test func emptyTextFollowsTheSwitch() {
        var on = EndpointGate()
        on.arm(.command, at: 0, hangover: 0.45)
        #expect(on.effectiveHangover == 1.10)
        var config = EndpointGate.Config()
        config.emptyTranscriptIsIncomplete = false
        var off = EndpointGate(config: config)
        off.arm(.command, at: 0, hangover: 0.45)
        #expect(off.effectiveHangover == 0.45)
        var answer = EndpointGate()
        answer.arm(.answer, at: 0)
        #expect(answer.effectiveHangover == 0.40)
    }
}
