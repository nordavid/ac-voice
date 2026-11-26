import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import ACVoiceSystem
import Foundation
import Testing
@testable import ACVoiceRuntime

/// The confirmed findings of the app stage reviews (correctness C1-C9, UX U2-U27), each with the scenario that showed
/// it. Fakes only: no microphone, no sound, no Apple Event, no window.
@MainActor
@Suite struct SpeechWiringTests {
    /// Review C1: the gate leaves the no-speech timeout to the flow (it went deaf 4 s after arming).
    @Test func liveGateLeavesTheNoSpeechTimeoutToTheFlow() {
        let t = FlowTimings()
        let tuning = LiveSpeech.tuning(t)
        #expect(tuning.gate.noSpeechTimeout == .infinity)
        #expect(tuning.gate.commandHangover == t.commandHangover && tuning.gate.answerHangover == t.answerHangover)
        #expect(tuning.gate.incompleteHangover == t.incompleteHangover && tuning.gate.maxUtterance == t.maxUtterance)
    }

    /// Review C4: while the model loads, the gate's end starts the (cold) finalize watchdog at once. It used to start
    /// only at maxUtterance: "Sprachmodell lädt noch" came 18 s after the onset instead of about 11 s.
    @Test func coldEndpointStartsTheFinalizeWatchdog() async {
        let rig = Rig()
        rig.speech.warmUpError = SpeechError.assetsUnavailable
        await rig.start()
        await rig.listen()
        await rig.emit(.warming)
        await rig.emit(.speechStarted)
        await rig.advance(1)
        await rig.emit(.endpoint)
        #expect(rig.phase == .processing && rig.model.warming)
        await rig.advance(FlowTimings().coldFinalize - 0.1)
        #expect(rig.phase == .processing)
        await rig.advance(0.2)
        #expect(rig.phase == .error && rig.model.message == FlowText.de.modelStillLoading)
    }

    /// A warm end is not forwarded: the final follows within ~50 ms, and a resume or a discard would only flash
    /// "processing".
    @Test func warmEndpointKeepsListening() async {
        let rig = Rig()
        await rig.start()
        await rig.listen()
        await rig.emit(.speechStarted)
        await rig.emit(.endpoint)
        #expect(rig.phase == .listening)
    }

    @Test func resumeAndDiscardReachTheFlow() async {
        let rig = Rig()
        rig.speech.warmUpError = SpeechError.assetsUnavailable
        await rig.start()
        await rig.listen()
        await rig.emit(.warming)
        await rig.emit(.speechStarted)
        await rig.emit(.endpoint)
        #expect(rig.phase == .processing)
        await rig.emit(.resumed)
        #expect(rig.phase == .listening)
        await rig.emit(.endpoint)
        await rig.emit(.discarded)
        #expect(rig.phase == .listening && rig.model.transcript.isEmpty)
        // Review C1: the cough counts no more, the no-speech timeout runs again.
        await rig.advance(FlowTimings().noSpeech + 0.1)
        #expect(rig.phase == .error && rig.model.message == FlowText.de.nothingHeard)
    }

    /// Review U27: the overlay says "Die Einrichtung ist offen": a microphone refusal from the speech layer opens it.
    @Test func micRefusedByTheSpeechLayerOpensTheSetup() async {
        let rig = Rig()
        await rig.start()
        await rig.listen()
        let before = rig.setupRequests
        await rig.emit(.failed(.micDenied))
        #expect(rig.phase == .error && rig.model.hint == FlowText.de.setupIsOpen && rig.setupRequests == before + 1)
    }

    /// Review C8: the earcon output starts at the press, not when the first audio (and the first partials) arrive.
    @Test func earconOutputStartsAtThePress() async {
        let rig = Rig()
        await rig.start()
        await rig.press()
        #expect(rig.earcons.prewarms == 1 && rig.earcons.played.isEmpty)
        var quiet = Fixture.config
        quiet.earcons = false
        let silent = Rig(config: quiet)
        await silent.start()
        await silent.press()
        #expect(silent.earcons.prewarms == 0)
    }

    /// Review U4: the overlay's pointer reaches the flow.
    @Test func pointerOnTheCardHoldsTheList() async {
        let rig = Rig()
        await rig.start()
        await rig.command("Öffne das WWT-Projekt")
        rig.overlay.onPointer?(true)
        await rig.settle()
        #expect(rig.model.countdownFrozen != nil)
        await rig.advance(20)
        #expect(rig.phase == .choices)
        rig.overlay.onPointer?(false)
        await rig.advance(6.1)
        #expect(rig.phase == .idle)
    }
}

@MainActor
@Suite struct LifecycleFixTests {
    /// Review C5: a start queued right before the quit ran after the stop and turned the microphone on during
    /// termination.
    @Test func quitRightAfterAPressLeavesTheMicOff() async {
        let rig = Rig()
        await rig.start()
        rig.controller.trigger(.press(Press(id: "p1", source: .streamDeck)))
        await rig.controller.shutdown()
        await rig.settle()
        #expect(rig.speech.calls.last == "stop" && !rig.speech.running)
        #expect(rig.phase == .idle && rig.workspace.stopped == 1)
        // Nothing starts it again afterwards.
        rig.controller.trigger(.press(Press(id: "p2", source: .streamDeck)))
        rig.speech.emit(.micReady)
        await rig.settle()
        #expect(rig.speech.starts.count <= 1 && !rig.speech.running)
    }

    /// Review C6: a 401 of a request that started under the old token arrives after a new token: the status stays.
    @Test func late401OfTheOldTokenKeepsTheNewStatus() async {
        let rig = Rig()
        await rig.start()
        rig.index?.holdArchives = true
        rig.index?.onCheckArchives = { _, _ in IndexCheck(complete: false, errors: [.unauthorized]) }
        await rig.listen()
        rig.speech.emit(.speechStarted)
        rig.speech.emit(.partial(dt: "Öffne WWT Ticket 999", st: ""))
        rig.speech.emit(.utterance([Hypothesis("Öffne WWT Ticket 999")], latencyMs: nil))
        _ = await rig.controller.settle(leaving: 1)
        #expect(await rig.controller.saveToken("538-NewTestTokenAbc"))
        _ = await rig.controller.settle(leaving: 1)
        #expect(rig.controller.status.token == .present)
        rig.index?.releaseArchives()
        await rig.settle()
        #expect(rig.controller.status.token == .present)
        // A 401 of the current token still shows.
        rig.index?.onCheckArchives = { _, _ in IndexCheck(complete: false, errors: [.unauthorized]) }
        await rig.advance(5)
        await rig.command("Öffne WWT Ticket 998")
        await rig.settle()
        #expect(rig.controller.status.token == .invalid)
    }

    /// Review C7: background refreshes may fire late (coalesced wake-ups), pause while the Mac sleeps, refresh once
    /// shortly after the wake and keep a transport error of that first refresh out of the menu.
    @Test func backgroundRefreshSleepsAndWakes() async throws {
        let rig = Rig()
        await rig.start()
        let fast = try #require(rig.clock.tolerances.first { $0.delay == Controller.fastRefreshInterval })
        #expect(abs(fast.tolerance - Controller.fastRefreshInterval * Controller.backgroundTolerance) < 1e-9)
        #expect(rig.controller.backgroundJobs >= 1)
        let index = try #require(rig.index)
        let before = index.count("refreshFast")

        rig.workspace.post(.sleep)
        #expect(rig.controller.asleep && rig.controller.backgroundJobs == 0)
        await rig.advance(3600)
        #expect(index.count("refreshFast") == before)

        index.fastReport = FakeIndex.report(errors: [.transport(code: -1009)])
        rig.workspace.post(.wake)
        #expect(!rig.controller.asleep)
        await rig.advance(Controller.wakeDelay - 1)
        #expect(index.count("refreshFast") == before)
        await rig.advance(1.5)
        #expect(index.count("refreshFast") == before + 1)
        #expect(rig.controller.status.indexError == nil)   // the network is not back yet: no menu error
        // Later failures show again.
        await rig.advance(Controller.fastRefreshInterval * 1.1)
        #expect(rig.controller.status.indexError == FlowText.de.acUnreachable)
    }

    @Test func workspaceObserverStartsAndStops() async {
        let rig = Rig()
        await rig.start()
        #expect(rig.workspace.started == 1)
        await rig.controller.shutdown()
        #expect(rig.workspace.stopped == 1)
    }
}

@MainActor
@Suite struct ChromeSetupTests {
    /// Review C2/U6: undetermined Automation turned every open into a new tab without a word. Now the overlay says it
    /// once, the menu shows a badge and a line, and the setup window opens once after the card.
    @Test func undeterminedAutomationIsExplainedOnce() async {
        let rig = Rig()
        await rig.start()
        let before = rig.setupRequests
        rig.chrome.defaultResult = .fallback(.undetermined)
        await rig.command("WWT Relaunch")
        #expect(rig.phase == .success && rig.model.hint == FlowText.de.automationSetupHint)
        #expect(rig.controller.status.chromeAutomation == .notDetermined && rig.controller.needsAttention)
        #expect(rig.controller.statusLines.contains(AppText.de.chromeAutomationMissing))
        #expect(rig.controller.menuIcon.attention)
        #expect(rig.setupRequests == before)                 // not over the success card
        await rig.advance(FlowTimings().hintHold + 0.1)
        #expect(rig.phase == .idle && rig.setupRequests == before + 1)
        await rig.command("WWT Relaunch")
        await rig.advance(1)
        #expect(rig.model.hint == nil && rig.setupRequests == before + 1)
        // Allowed later: the badge goes away with the next scripted open.
        rig.chrome.defaultResult = .reused
        await rig.command("WWT Relaunch")
        #expect(rig.controller.status.chromeAutomation == .granted && !rig.controller.needsAttention)
    }

    /// Review C2/U5: with autostart Chrome usually starts after the app. Its launch checks the status (no prompt)
    /// and tells the setup window to re-read its Chrome row.
    @Test func chromeLaunchChecksTheAutomation() async {
        let rig = Rig()
        rig.permissions.isChromeRunning = false
        await rig.start()
        await rig.controller.checkChromeAutomation()        // the launch check: Chrome is not running
        #expect(rig.chrome.preflights.isEmpty)
        var running: [Bool] = []
        rig.controller.onChromeRunningChanged = { running.append($0) }
        let before = rig.setupRequests
        rig.permissions.isChromeRunning = true
        rig.chrome.automation = .notDetermined
        rig.workspace.post(.chromeLaunched)
        await rig.settle()
        #expect(running == [true] && rig.chrome.preflights == [false] && rig.setupRequests == before + 1)
        #expect(rig.controller.status.chromeAutomation == .notDetermined)
        rig.workspace.post(.chromeTerminated)
        rig.workspace.post(.chromeLaunched)
        await rig.settle()
        #expect(running == [true, false, true] && rig.setupRequests == before + 1)   // once per run
    }

    /// Review U5: the setup window re-reads Chrome's row when Chrome starts (it stayed "Starte Chrome").
    @Test func setupRowFollowsChrome() async {
        let rig = Rig()
        rig.permissions.isChromeRunning = false
        rig.chrome.automation = .notDetermined
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in })
        await model.refresh()
        #expect(model.steps.first { $0.id == .chrome }?.status == AppText.de.chromeNotRunning)
        rig.permissions.isChromeRunning = true
        await model.refresh()
        let row = model.steps.first { $0.id == .chrome }
        #expect(row?.status == AppText.de.chromeNotDetermined && row?.action?.kind == .requestAutomation && row?.action?.enabled == true)
        #expect(rig.controller.status.chromeAutomation == .notDetermined)
    }
}

@MainActor
@Suite struct SetupWindowFixTests {
    /// Review U23: the commands name the plugin folder with an absolute path (bundle.sh writes ACVoiceSourceRoot).
    @Test func streamDeckCommandsUseTheSourceFolder() async {
        let rig = Rig(token: .missing)
        await rig.start()
        var copied: [String] = []
        let model = OnboardingModel(controller: rig.controller, copy: { copied.append($0) }, sourceRoot: "/Users/x/ac voice")
        await model.perform(.copyStreamDeckCommands)
        #expect(copied == [#"cd "/Users/x/ac voice/streamdeck" && npm install && npm run build && npm run link"#])
        #expect(model.steps.first { $0.id == .streamDeck }?.status.contains("/Users/x/ac voice/streamdeck") == true)
        #expect(AppText.streamDeckCommands(sourceRoot: nil).hasPrefix("cd ac-voice/streamdeck && "))
    }

    /// Review U24: a stored token hides the sign-in fields behind "Neu anmelden oder Adresse ändern"; the autostart
    /// row lets the switch speak; "Fertig" says how to try it.
    @Test func rowsShowOnlyWhatIsToDo() async {
        let rig = Rig()
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in })
        #expect(!model.showsSignIn)
        model.beginSignInAgain()
        #expect(model.showsSignIn && !model.showsTokenSignIn)
        #expect(model.steps.first { $0.id == .autostart }?.status.isEmpty == true)
        rig.login.statusValue = .requiresApproval
        await model.refresh()
        let autostart = model.steps.first { $0.id == .autostart }
        #expect(autostart?.status == LoginItemStatus.requiresApproval.hint(.de) && autostart?.action?.kind == .openLoginItems)
        #expect(model.launchAtLogin)
        #expect(model.tryItText == "Drück ⌃⌥Leertaste und sag „Meine Aufgaben“.")
        let missing = Rig(token: .missing)
        await missing.start()
        #expect(OnboardingModel(controller: missing.controller, copy: { _ in }).showsSignIn)
    }
}
