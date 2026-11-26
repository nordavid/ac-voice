import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

/// Press semantics (REVIEW m4/m5), push-to-talk, generations (REVIEW M3) and cold start.
@Suite struct PressSemanticsTests {
    @Test func idleSuccessErrorListen() {
        var h = Harness()
        h.press()
        #expect(h.phase == .listening)

        var s = Harness()
        s.command("WWT Relaunch")
        s.send(.opened(request: s.pendingRequest!, .reused))
        s.press("p2")
        #expect(s.phase == .listening)

        var e = Harness()
        e.command("Hallo"); e.say("Welt")
        #expect(e.phase == .error)
        e.press("p2")
        #expect(e.phase == .listening)
    }

    @Test func listeningAfterSpeechEndsNow() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        h.press("p2")
        #expect(h.has(.endUtteranceNow(SpeechGen(session: 1, utterance: 1))) && h.phase == .processing)
    }

    @Test func partialCountsAsSpeechWithoutOnset() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.partial("WWT Relaunch")
        h.press("p2")
        #expect(h.has(.endUtteranceNow(SpeechGen(session: 1, utterance: 1))))
    }

    @Test func doubleTapBeforeOnsetIsIgnored() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.advance(0.3)
        #expect(h.press("p2").isEmpty)
        #expect(h.phase == .listening && h.micOn)
    }

    @Test func laterPressWithoutSpeechCancels() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.advance(1.5)
        h.press("p2")
        #expect(h.phase == .idle && h.has(.stopMic) && h.has(.hideOverlay(fade: 0.2)))

        // The guard is 0.4 s: a deliberate second press after half a second already cancels (1 s felt too long).
        var g = Harness()
        #expect(FlowTimings().doubleTap == 0.4)
        g.press(); g.micReady(); g.release()
        g.advance(0.5)
        g.press("p2")
        #expect(g.phase == .idle && g.has(.stopMic))
    }

    @Test func retryWithoutSpeechCancelsWithSpeechEnds() {
        var h = Harness()
        h.command("Hallo Welt")
        h.press("p2")
        #expect(h.phase == .idle)

        var g = Harness()
        g.command("Hallo Welt")
        g.onset()
        g.press("p2")
        #expect(g.has(.endUtteranceNow(SpeechGen(session: 1, utterance: 2))) && g.phase == .processing)
    }

    @Test func choicesPressCancels() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.press("p2")
        #expect(h.phase == .idle && h.has(.stopMic))
    }

    @Test func processingPressCancels() {
        // Finalizing.
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset(); h.ended()
        h.press("p2")
        #expect(h.phase == .idle && h.has(.stopMic))

        // Archive search (REVIEW m5): the late result is dropped.
        var a = Harness()
        a.command("Öffne WWT Ticket 58")
        let r = a.pendingRequest!
        a.press("p2")
        #expect(a.phase == .idle)
        #expect(a.send(.archiveFetched(request: r, complete: true)).isEmpty)
    }

    @Test func openingPressCancels() {
        var h = Harness()
        h.command("WWT Relaunch")
        let r = h.pendingRequest!
        h.press("p2")
        #expect(h.phase == .idle)
        #expect(h.send(.opened(request: r, .reused)).isEmpty && h.phase == .idle)
    }

    @Test func stalePressIsDropped() {
        var h = Harness()
        #expect(h.press(at: h.now.addingTimeInterval(-3.5)).isEmpty)
        #expect(h.phase == .idle)
        h.press(at: h.now.addingTimeInterval(-2.0))
        #expect(h.phase == .listening)
    }

    @Test func ipcCommandsMapToEvents() {
        let at = Int64(Fixture.now.timeIntervalSince1970 * 1000)
        #expect(FlowEvent(.press(id: "sd-7", at: at)) == .press(Press(id: "sd-7", source: .streamDeck, at: Fixture.now)))
        #expect(FlowEvent(.press(id: "sd-7", at: 0)) == .press(Press(id: "sd-7", source: .streamDeck, at: nil)))
        #expect(FlowEvent(.release(id: "sd-8", pressId: "sd-7", heldMs: 812)) == .release(pressId: "sd-7", heldMs: 812))
        #expect(FlowEvent(.choose(id: "sd-9", index: 2, seq: 6)) == .choose(n: 2, seq: 6))
        #expect(FlowEvent(.cancel(id: "sd-10")) == .cancel)
        #expect(FlowEvent(.ping(id: "x")) == nil && FlowEvent(.hello(client: "streamdeck", version: "1")) == nil)
    }
}

@Suite struct PushToTalkTests {
    @Test func tapResumesEndpointing() {
        var h = Harness()
        h.press()
        #expect(h.suspended)
        h.release(heldMs: 120)
        #expect(!h.suspended && h.last.contains(.suspendEndpointing(false)) && h.phase == .listening)
    }

    @Test func holdReleaseEndsTheUtterance() {
        var h = Harness()
        h.press(); h.micReady()
        h.onset()
        h.partial("Öffne WWT Relaunch")
        h.advance(1.4)
        h.release(heldMs: 1500)
        #expect(h.last == [.publish(h.model), .suspendEndpointing(false), .endUtteranceNow(SpeechGen(session: 1, utterance: 1)),
                           .cancelTimer(.maxUtterance), .schedule(TimerID(kind: .finalize, token: h.timers[.finalize]!.id.token), after: 2.0)])
        #expect(h.phase == .processing)
    }

    @Test func holdOf599IsATap() {
        var h = Harness()
        h.press(); h.micReady(); h.onset()
        h.release(heldMs: 599)
        #expect(h.phase == .listening)
        h.release(heldMs: 900)   // no key down any more
        #expect(h.phase == .listening)
    }

    @Test func releaseMustMatchThePress() {
        var h = Harness()
        h.press("sd-1"); h.micReady(); h.onset()
        #expect(h.release("sd-9", heldMs: 1000).isEmpty)
        #expect(h.phase == .listening && h.suspended)
        h.release("sd-1", heldMs: 1000)
        #expect(h.phase == .processing)
    }

    @Test func releaseWithoutPressIdMatchesAnyHeldKey() {
        var h = Harness()
        h.press("sd-1"); h.micReady(); h.onset()
        h.release(nil, heldMs: 1000)
        #expect(h.phase == .processing)
    }

    @Test func releaseOfAnEndPressIsIgnored() {
        // The press that ended the utterance is not a hold of the listening press.
        var h = Harness()
        h.press("sd-1"); h.micReady(); h.release("sd-1"); h.onset()
        h.press("sd-2")
        #expect(h.phase == .processing)
        #expect(h.release("sd-2", heldMs: 900).isEmpty)
    }

    @Test func hotkeySuspendsMenuDoesNot() {
        var k = Harness()
        k.press("hk-1", source: .hotkey)
        #expect(k.suspended)

        var m = Harness()
        m.press(nil, source: .menu)
        #expect(!m.suspended && !m.last.contains(.suspendEndpointing(true)))
        #expect(m.release(nil, heldMs: 2000).isEmpty)
    }

    @Test func holdWithoutSpeechKeepsListening() {
        // A slow tap (or a hold before speaking) is not an empty push-to-talk utterance.
        var h = Harness()
        h.press(); h.micReady()
        h.advance(1.0)
        h.release(heldMs: 1000)
        #expect(h.phase == .listening && !h.last.contains(.endUtteranceNow(SpeechGen(session: 1, utterance: 1))))
        #expect(!h.suspended && h.dueIs(.noSpeech, 4.0))
        h.advance(2)
        h.say("WWT Relaunch")
        #expect(h.opened == Fixture.projectURL(628))
    }

    @Test func holdWithoutSpeechThenSilence() {
        var h = Harness()
        h.press(); h.micReady()
        h.advance(1.0)
        h.release(heldMs: 1000)
        h.advance(3.9)
        #expect(h.phase == .listening)
        h.advance(0.2)
        #expect(h.phase == .error && h.model.message == "Ich höre nichts")
    }

    @Test func heldKeyDefersNoSpeechUpToMaxUtterance() {
        var h = Harness()
        h.press(); h.micReady()
        h.advance(4.5)
        #expect(h.phase == .listening)
        h.advance(3.4)
        #expect(h.phase == .listening)
        h.advance(0.2)
        #expect(h.phase == .error && h.model.message == "Ich höre nichts")
        #expect(h.release(heldMs: 8200).isEmpty)
    }
}

@Suite struct GenerationTests {
    @Test func lateFinalOfAnOldSessionIsDropped() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        let old = h.gen!
        #expect(old == SpeechGen(session: 1, utterance: 2))
        h.press("p2")          // cancel the list
        #expect(h.phase == .idle)
        h.press("p3")          // listen again
        #expect(h.gen == SpeechGen(session: 2, utterance: 1))
        #expect(h.send(.utterance(old, [Hypothesis("zwei")])).isEmpty)
        #expect(h.send(.partial(old, Transcript(volatile: "zwei"), [])).isEmpty)
        #expect(h.send(.speechStarted(old)).isEmpty)
        #expect(h.send(.micReady(old)).isEmpty)
        #expect(h.phase == .listening)
        h.micReady()
        h.say("WWT Relaunch")
        #expect(h.opened == Fixture.projectURL(628))
    }

    @Test func lateCommandFinalDoesNotAnswerTheList() {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("Öffne das WWT-Projekt")
        h.ended()
        h.advance(2.1)          // finalize timeout: list from the partial
        #expect(h.phase == .choices)
        #expect(h.send(.utterance(SpeechGen(session: 1, utterance: 1), [Hypothesis("zwei")])).isEmpty)
        #expect(h.phase == .choices)
    }

    @Test func eachAnswerGetsAFreshStamp() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.say("Hallo")
        #expect(h.gen == SpeechGen(session: 1, utterance: 3))
        #expect(h.send(.utterance(SpeechGen(session: 1, utterance: 2), [Hypothesis("zwei")])).isEmpty)
        #expect(h.phase == .choices)
    }

    @Test func lateFailureOfAnOldSessionIsDropped() {
        // Session 1's teardown error (cancelAndFinishNow, device stop) arrives after session 2 started (REVIEW M3).
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        let old = h.gen!
        h.press("p2")          // cancel the list: stopMic for session 1
        h.press("p3")          // session 2
        h.micReady()
        #expect(h.send(.speechFailed(old, .engine)).isEmpty)
        #expect(h.send(.speechFailed(SpeechGen(session: 1, utterance: 1), .engine)).isEmpty)
        #expect(h.phase == .listening && h.micOn)
        h.release()
        h.say("WWT Relaunch")
        #expect(h.opened == Fixture.projectURL(628))
    }

    @Test func staleTimersAreIgnored() {
        var h = Harness()
        h.press(); h.micReady()
        let token = h.timers[.noSpeech]!.id
        h.release(); h.onset()
        #expect(h.send(.timer(token)).isEmpty)
        #expect(h.phase == .listening)
    }
}

@Suite struct ColdStartTests {
    @Test func pressBeforeWarmListensWithMessage() {
        var h = Harness(warm: false)
        h.press()
        #expect(h.phase == .listening && h.micOn)
        #expect(h.model.warming && h.model.message == "Sprachmodell lädt" && h.state.message == "Sprachmodell lädt")
        h.send(.speechWarm(true))
        #expect(!h.model.warming && h.model.message == nil && h.flow.speechWarm)
        h.micReady(); h.release()
        h.say("WWT Relaunch")
        #expect(h.opened == Fixture.projectURL(628))
    }

    @Test func firstPartialClearsTheLoadingMessage() {
        var h = Harness(warm: false)
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("WWT")
        #expect(!h.model.warming && h.model.message == nil)
    }

    @Test func queuedPressFromALaunchIsDroppedWhenOld() {
        var h = Harness(warm: false)
        #expect(h.press(at: h.now.addingTimeInterval(-4)).isEmpty)
        h.press(at: h.now.addingTimeInterval(-1))
        #expect(h.phase == .listening && h.model.message == "Sprachmodell lädt")
    }

    @Test func modelLostAgainShowsLoadingOnNextPress() {
        var h = Harness()
        h.send(.speechWarm(false))
        h.press()
        #expect(h.model.warming)
    }

    /// Speech ended before the model was ready (REVIEW m5): wait for the buffered audio, not 2 s.
    func coldUtterance() -> Harness {
        var h = Harness(warm: false)
        h.press(); h.micReady(); h.release()
        h.onset()
        h.advance(1.0)
        h.ended()
        return h
    }

    @Test func coldFinalizeWaitsForTheModel() {
        var h = coldUtterance()
        #expect(h.phase == .processing && h.model.warming && h.model.message == "Sprachmodell lädt")
        #expect(h.dueIs(.finalize, 10.0))
        h.advance(2.1)
        #expect(h.phase == .processing && h.gen == SpeechGen(session: 1, utterance: 1))
        h.send(.speechWarm(true))
        #expect(!h.model.warming && h.model.message == nil && h.dueIs(.finalize, 2.0))
        h.final("WWT Relaunch")
        #expect(h.opened == Fixture.projectURL(628))
    }

    @Test func coldFinalizeFirstPartialRestartsTheWatchdog() {
        var h = coldUtterance()
        h.advance(3)
        h.partial("WWT Relaunch")
        #expect(h.flow.speechWarm && !h.model.warming && h.dueIs(.finalize, 2.0))
        h.advance(2.1)    // no final: decide with that partial
        #expect(h.opened == Fixture.projectURL(628))
    }

    @Test func modelThatNeverGetsReadyIsAnError() {
        var h = coldUtterance()
        h.advance(9.9)
        #expect(h.phase == .processing)
        h.advance(0.2)
        #expect(h.phase == .error && h.model.message == "Sprachmodell lädt noch" && !h.micOn)
    }

    @Test func warmFinalizeKeepsItsShortWatchdog() {
        var h = Harness()
        h.press(); h.micReady(); h.release(); h.onset()
        h.ended()
        #expect(h.dueIs(.finalize, 2.0) && !h.model.warming)
        h.advance(2.1)
        #expect(h.phase == .retry && h.model.message == "Ich höre nichts. Sag es nochmal.")
    }
}

/// Timers run on the controller's monotonic clock, deadlines on the wall clock: a clock step must never keep the
/// list or the mic up (REVIEW finding: wall-clock reschedules).
@Suite struct WallClockTests {
    @Test func listClosesWhenTheClockGoesBack() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.jumpWallClock(-3600)
        h.advance(6.1)
        #expect(h.phase == .idle && !h.micOn && h.due(.choicesDeadline) == nil)
    }

    @Test func unclearAnswerAfterAJumpClosesTheList() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.jumpWallClock(-3600)
        h.say("Hallo")
        #expect(h.phase == .idle && !h.micOn)
    }

    @Test func clockForwardClosesTheListEarly() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.jumpWallClock(3600)
        h.say("Hallo")
        #expect(h.phase == .idle && !h.micOn)
    }

    @Test func unclearNeverPassesTheHardCap() {
        var config = Config()
        config.maxUnclearAnswers = 5
        var h = Harness(config: config)
        h.command("Öffne das WWT-Projekt")
        h.advance(5)
        for _ in 0..<5 {
            h.onset()
            h.advance(4)
            h.voice(false)
            h.advance(0.5)
            h.ended()
            h.final("Hallo")
            if h.phase != .choices { break }
            #expect(h.flow.list!.deadline <= Fixture.now.addingTimeInterval(30 + 1e-6))
        }
        h.advance(30)
        #expect(h.phase == .idle)
    }

    @Test func heldKeyWithTheClockGoingBackStillTimesOut() {
        var h = Harness()
        h.press(at: h.now)
        h.micReady()
        h.jumpWallClock(-3600)
        h.advance(4.1)
        #expect(h.phase == .listening && h.due(.noSpeech).map { $0 <= 8 } == true)
        h.advance(8)
        #expect(h.phase == .error && h.model.message == "Ich höre nichts" && !h.micOn)
    }

    @Test func fastSelectWaitIsBounded() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.onset()
        h.voice(false)         // silence starts at wall time t
        h.jumpWallClock(-3600)
        h.partial("drei")      // pick while silent: commit after fastSelectSilence, not after the jump
        #expect(h.dueIs(.fastSelect, 0.25))
        h.advance(0.26)
        #expect(h.opened == Fixture.projectURL(315))
    }

    @Test func smallClockStepBackKeepsTheList() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        h.jumpWallClock(-0.5)
        h.advance(6.0)
        #expect(h.phase == .choices && h.dueIs(.choicesDeadline, 0.5))
        h.advance(0.5)
        #expect(h.phase == .idle)
    }
}
