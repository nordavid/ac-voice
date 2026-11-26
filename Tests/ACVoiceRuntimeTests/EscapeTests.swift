import ACVoiceCore
import ACVoiceFlow
@testable import ACVoiceRuntime
import Foundation
import Testing

/// Esc closes the overlay in every phase, like its close button: the command is cancelled and nothing new opens (a
/// page already sent to Chrome on the "Öffne …" card still appears, see `StateTableTests`). The Carbon hotkey
/// consumes Esc in every app, so it is registered only while the overlay shows, and released by every hide.
@MainActor
@Suite struct EscapeTests {
    @Test func escapeIsRegisteredOnlyWhileTheOverlayShows() async {
        let rig = Rig()
        await rig.start()
        #expect(!rig.escape.isActive)
        await rig.listen()
        #expect(rig.phase == .listening && rig.escape.isActive)
        rig.escape.fire()
        await rig.settle()
        #expect(rig.phase == .idle && !rig.escape.isActive && !rig.overlay.isShown)
        #expect(rig.speech.stops >= 1 && rig.chrome.opened.isEmpty)
        // Inactive: a press of Esc reaches the other apps and AC Voice ignores it.
        rig.escape.fire()
        await rig.settle()
        #expect(rig.phase == .idle)
        // The next command registers it again.
        await rig.listen()
        #expect(rig.escape.isActive && rig.escape.activations == 2)
    }

    @Test func escapeCancelsAfterSpeechWithoutOpening() async {
        // A second press would end the sentence and open the project; Esc always cancels.
        let rig = Rig()
        await rig.start()
        await rig.listen()
        rig.speech.emit(.speechStarted)
        rig.speech.emit(.partial(dt: "WWT Relaunch", st: "WWT Relaunch"))
        await rig.settle()
        rig.escape.fire()
        await rig.settle()
        #expect(rig.phase == .idle && rig.chrome.opened.isEmpty && !rig.escape.isActive)
    }

    @Test func escapeClosesTheList() async {
        let rig = Rig()
        await rig.start()
        await rig.command("Öffne das WWT-Projekt")
        #expect(rig.phase == .choices && rig.escape.isActive)
        rig.escape.fire()
        await rig.settle()
        #expect(rig.phase == .idle && rig.chrome.opened.isEmpty && !rig.escape.isActive)
    }

    @Test func escapeClosesTheErrorCardAndTheRetry() async {
        let rig = Rig()
        await rig.start()
        await rig.command("Hallo Welt")
        #expect(rig.phase == .retry && rig.escape.isActive)
        await rig.say("Hallo Welt")
        #expect(rig.phase == .error && rig.escape.isActive)
        rig.escape.fire()
        await rig.settle()
        #expect(rig.phase == .idle && !rig.escape.isActive && !rig.overlay.isShown)

        // In the retry itself as well.
        await rig.command("Hallo Welt")
        #expect(rig.phase == .retry)
        rig.escape.fire()
        await rig.settle()
        #expect(rig.phase == .idle && !rig.escape.isActive)
    }

    @Test func escapeDuringPushToTalkIgnoresTheLateRelease() async {
        let rig = Rig()
        await rig.start()
        await rig.press("hold")
        await rig.emit(.micReady)
        rig.escape.fire()
        await rig.settle()
        #expect(rig.phase == .idle)
        await rig.release("hold", heldMs: 2400)
        #expect(rig.phase == .idle && rig.chrome.opened.isEmpty && !rig.escape.isActive)
    }

    @Test func escapeDuringHotkeyPushToTalk() async {
        // ⌃⌥Space held: the keyboard reports ⌃⌥Esc, which `EscapeKey` registers too (CarbonHotkey.escape(heldWith:)).
        let rig = Rig()
        await rig.start()
        rig.hotkey.fire(.pressed)
        await rig.settle()
        await rig.emit(.micReady)
        rig.speech.emit(.speechStarted)
        await rig.emit(.partial(dt: "WWT Relaunch", st: ""))
        rig.escape.fire()
        await rig.settle()
        rig.hotkey.fire(.released(heldMs: 2400))
        await rig.settle()
        #expect(rig.phase == .idle && rig.chrome.opened.isEmpty && rig.speech.endNows == 0 && !rig.escape.isActive)
    }

    // Every other way the overlay closes releases Esc as well, or Esc stays swallowed in every app.

    @Test func successCardFadeReleasesEscape() async {
        let rig = Rig()
        await rig.start()
        await rig.command("Meine Aufgaben")
        #expect(rig.phase == .success && rig.escape.isActive)
        await rig.advance(5)
        #expect(rig.phase == .idle && !rig.escape.isActive && !rig.overlay.isShown)
    }

    @Test func errorCardTimeoutReleasesEscape() async {
        let rig = Rig()
        await rig.start()
        await rig.command("Hallo Welt")
        await rig.say("Hallo Welt")
        #expect(rig.phase == .error && rig.escape.isActive)
        await rig.advance(5)
        #expect(rig.phase == .idle && !rig.escape.isActive)
    }

    @Test func closeButtonAndKeyCancelReleaseEscape() async {
        let rig = Rig()
        await rig.start()
        await rig.listen()
        rig.overlay.onDismiss?()   // the x on the card
        await rig.settle()
        #expect(rig.phase == .idle && !rig.escape.isActive)

        await rig.command("Öffne das WWT-Projekt")
        #expect(rig.phase == .choices && rig.escape.isActive)
        await rig.press("p9")      // a press closes the list
        #expect(rig.phase == .idle && !rig.escape.isActive)
    }

    @Test func escapeStopsTheOverlayDemo() async {
        let rig = Rig()
        await rig.start()
        rig.controller.startDemo()
        await rig.settle()
        #expect(rig.controller.isDemoRunning && rig.escape.isActive)
        rig.escape.fire()
        await rig.settle()
        #expect(!rig.controller.isDemoRunning && !rig.escape.isActive && !rig.overlay.isShown)
    }
}
