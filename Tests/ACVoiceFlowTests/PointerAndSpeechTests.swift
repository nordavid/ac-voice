import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

/// Review findings of the app stage: wire input bounds, the pointer hold, the speech layer's resume and discard,
/// the answer in the footer and the next step under an error.
@Suite struct PointerAndSpeechTests {
    func wwtList() -> Harness {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        return h
    }

    // MARK: Wire input

    /// Review C3: `choose` with Int.min trapped in `n - 1` (one malformed IPC line killed the app).
    @Test(arguments: [Int.min, Int.min + 1, -1, 0, 5, Int.max])
    func chooseOutOfRangeIsIgnored(_ n: Int) {
        var h = wwtList()
        #expect(h.send(.choose(n: n, seq: nil)).isEmpty)
        #expect(h.phase == .choices)
    }

    // MARK: Pointer hold (review U4)

    @Test func pointerOnTheListStopsTheCountdown() {
        var h = wwtList()
        h.advance(2)
        h.send(.pointer(inside: true))
        #expect(h.model.countdownFrozen.map { abs($0 - 4) < 1e-6 } == true)
        #expect(h.state.deadline == nil)                     // the key shows a full ring meanwhile
        #expect(h.dueIs(.choicesDeadline, 28))               // the hard cap: 30 s after the render
        h.advance(20)
        #expect(h.phase == .choices)
        // Speech and an unclear answer while held keep the frozen countdown and the hard cap.
        h.onset()
        #expect(h.dueIs(.choicesDeadline, 8))
        h.ended(); h.final("Hallo")
        #expect(h.model.hintIsAlert && h.model.countdownFrozen.map { abs($0 - 4) < 1e-6 } == true)
        #expect(h.dueIs(.choicesDeadline, 8))
        h.send(.pointer(inside: false))
        #expect(h.model.countdownFrozen == nil && h.dueIs(.choicesDeadline, 4) && h.state.deadline != nil)
        h.advance(4.1)
        #expect(h.phase == .idle)
    }

    @Test func leavingTheListKeepsAtLeastTheExtension() {
        var h = wwtList()
        h.advance(5.5)
        h.send(.pointer(inside: true))
        h.send(.pointer(inside: false))
        #expect(h.dueIs(.choicesDeadline, 2.5))
    }

    @Test func aHeldListStillClosesAtTheHardCap() {
        var h = wwtList()
        h.send(.pointer(inside: true))
        h.advance(29.9)
        #expect(h.phase == .choices)
        h.advance(0.2)
        #expect(h.phase == .idle && !h.micOn)
    }

    @Test func aNewPageUnderThePointerStaysHeld() {
        var h = Harness()
        h.command("Öffne QZ")
        h.send(.pointer(inside: true))
        h.say("mehr")
        #expect(h.model.page == 1 && h.model.countdownFrozen == 6)
        #expect(h.dueIs(.choicesDeadline, 30))
        h.say("Hallo")                                       // unclear: still held
        #expect(h.phase == .choices && h.model.countdownFrozen == 6)
    }

    @Test func pointerHoldsAnErrorUntilItLeaves() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.advance(4.1)
        #expect(h.phase == .error && h.dueIs(.error, 2.9))
        h.send(.pointer(inside: true))
        #expect(h.dueIs(.error, 15))
        h.advance(10)
        #expect(h.phase == .error)
        h.send(.pointer(inside: false))
        #expect(h.dueIs(.error, 1.0))
        h.advance(1.1)
        #expect(h.phase == .idle)
    }

    @Test func pointerAlreadyOnTheCardHoldsTheHint() {
        var h = Harness()
        h.command("WWT Relaunch")
        h.send(.pointer(inside: true))                       // opening: nothing to hold yet
        h.confirmOpen(.fallback(.denied))
        #expect(h.phase == .success && h.dueIs(.success, 15))
        h.send(.pointer(inside: false))
        #expect(h.dueIs(.success, 3.5))                       // the time the card had left
    }

    @Test func aPlainSuccessIsNotHeld() {
        var h = Harness()
        h.command("WWT Relaunch")
        h.confirmOpen()
        h.send(.pointer(inside: true))
        #expect(h.dueIs(.success, 0.7))
        h.advance(0.8)
        #expect(h.phase == .idle && !h.flow.pointerInside)
    }

    // MARK: Speech layer: resume and discard

    /// Review C4: the runtime forwards the gate's end while the model is cold; a final that dangles resumes.
    @Test func resumedUtteranceGoesBackToListening() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        h.partial("Öffne WWT Ticket")
        h.ended()
        #expect(h.phase == .processing && h.dueIs(.finalize, 2))
        h.send(.speechResumed(h.gen!))
        #expect(h.phase == .listening && h.model.phase == .listening && h.due(.finalize) == nil)
        #expect(h.dueIs(.maxUtterance, 8))
        h.partial("Öffne WWT Ticket 412")
        h.ended()
        h.final("Öffne WWT Ticket 412")
        #expect(h.phase != .listening)
    }

    @Test func resumeInRetryKeepsTheRetryMessage() {
        var h = Harness()
        h.command("Hallo Welt")
        #expect(h.phase == .retry)
        h.onset()
        h.partial("Öffne")
        h.ended()
        #expect(h.phase == .processing)
        h.send(.speechResumed(h.gen!))
        #expect(h.phase == .retry && h.model.message == FlowText.notUnderstoodRetry)
    }

    /// Review C1: a cough onset that the speech layer discarded counts no more: the no-speech timeout runs again
    /// and the utterance cap waits for the next onset.
    @Test func discardedNoiseOnsetRestartsTheNoSpeechTimeout() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.advance(1)
        h.onset()
        #expect(h.due(.noSpeech) == nil && h.dueIs(.maxUtterance, 8))
        h.advance(1)
        h.send(.speechDiscarded(h.gen!))
        #expect(h.phase == .listening && h.due(.maxUtterance) == nil && h.dueIs(.noSpeech, 4))
        #expect(h.model.transcript.isEmpty)
        h.advance(4.1)
        #expect(h.phase == .error && h.model.message == FlowText.nothingHeard)
    }

    @Test func discardAfterAForwardedEndListensOn() {
        var h = Harness(warm: false)
        h.press(); h.micReady(); h.release()
        h.onset()
        h.ended()
        #expect(h.phase == .processing)
        h.send(.speechDiscarded(h.gen!))
        #expect(h.phase == .listening && h.due(.finalize) == nil && h.dueIs(.noSpeech, 4))
        // The real command afterwards works as usual.
        h.say("WWT Relaunch")
        #expect(h.opened == Fixture.projectURL(628))
    }

    @Test func discardInRetryRestartsTheRetrySilence() {
        var h = Harness()
        h.command("Hallo Welt")
        h.advance(2)
        h.onset()
        h.send(.speechDiscarded(h.gen!))
        #expect(h.phase == .retry && h.dueIs(.retrySilence, 5))
    }

    /// Review C1: every onset restarts the utterance cap (a discarded noise onset must not cap the real command).
    @Test func everyOnsetRestartsTheUtteranceCap() {
        var h = Harness()
        h.press(); h.micReady(); h.release()
        h.onset()
        h.advance(3)
        h.onset()
        #expect(h.dueIs(.maxUtterance, 8))
    }

    @Test func staleResumeAndDiscardAreDropped() {
        var h = wwtList()
        let old = SpeechGen(session: h.gen!.session, utterance: h.gen!.utterance - 1)
        #expect(h.send(.speechResumed(old)).isEmpty && h.send(.speechDiscarded(old)).isEmpty)
    }

    // MARK: Answer in the footer (review U11)

    @Test func theListKeepsTheCommandAndShowsTheAnswerBelow() {
        var h = wwtList()
        h.onset()
        h.partial("Web")
        #expect(h.model.transcript.text == "Öffne das WWT-Projekt" && h.model.answer.text == "Web")
        h.partial("Website")
        h.ended(); h.final("Website")
        #expect(h.model.choices.count == 2 && h.model.answer.isEmpty)
        #expect(h.model.hint == "„Website“ passt zu 2 Zeilen" && !h.model.hintIsAlert)
        #expect(h.model.transcript.text == "Öffne das WWT-Projekt")
    }

    // MARK: Next step under an error (review U27)

    @Test func errorsNameTheNextStep() {
        var mic = Harness()
        mic.press()
        mic.send(.speechFailed(mic.gen!, .micDenied))
        #expect(mic.model.message == FlowText.micDenied && mic.model.hint == FlowText.setupIsOpen)

        var offline = Harness()
        offline.command("Ticket 61234")
        offline.send(.probed(request: offline.pendingRequest!, .failed))
        #expect(offline.model.message == FlowText.acUnreachable && offline.model.hint == FlowText.checkNetwork)

        var other = Harness()
        other.command("Ticket 61234")
        other.send(.probed(request: other.pendingRequest!, .notFound))
        #expect(other.model.hint == nil)
    }
}
