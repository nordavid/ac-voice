import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import ACVoiceSystem
import ACVoiceUI
import Foundation
import Testing
@testable import ACVoiceRuntime

/// End-to-end scenarios: the real reducer and controller, every service faked, a fake clock.
@MainActor
@Suite struct CommandScenarioTests {
    @Test func uniqueProjectOpensAndSucceeds() async throws {
        let rig = Rig()
        await rig.start()
        #expect(rig.speech.warmUpContext?.contains("Ticket") == true)
        #expect(rig.controller.status.speech == .ready && rig.controller.flow.speechWarm)
        #expect(rig.fakeIPC.started && rig.hotkey.registered == .default && rig.earcons.prepared == 1)
        #expect(rig.controller.isRunning)
        #expect(rig.index?.calls.prefix(2) == ["loadFromDisk", "refreshFast"])

        rig.chrome.tabURL = URL(string: "https://ac.example.com/projects/628/tasks/31412")
        await rig.press()
        #expect(rig.phase == .listening && rig.overlay.shows == 1 && rig.overlay.isShown)
        let start = try #require(rig.speech.starts.first)
        #expect(start.gen == SpeechGen(session: 1, utterance: 1) && start.mode == .command && start.hangover == 0.60)
        #expect(start.context == rig.controller.commandContext && start.context.contains("WWT"))
        #expect(rig.speech.held)   // the Stream Deck key is down: no energy end of utterance
        #expect(rig.index?.count("refreshFast") == 2)   // launch, press
        #expect(rig.controller.env.activeProjectId == 628)
        #expect(rig.fakeIPC.states.last?.phase == .listening && rig.fakeIPC.states.last?.micReady == false)

        await rig.emit(.micReady)
        #expect(rig.earcons.played == [.listen] && rig.speech.earconBlanks == [0.25])
        #expect(rig.model.micReady)
        await rig.release()
        #expect(!rig.speech.held)

        rig.speech.emit(.speechStarted)
        rig.speech.emit(.partial(dt: "WWT Relaunch", st: "WWT Relaunch"))
        #expect(rig.model.preview == "WWT: Website Relaunch")
        #expect(rig.speech.hangover == 0.45)   // a complete intent: the fast hangover
        rig.speech.emit(.endpoint)
        rig.clock.advance(0.05)
        rig.speech.emit(.utterance([Hypothesis("WWT Relaunch")], latencyMs: 580))
        await rig.settle()

        #expect(rig.chrome.opened == [Fixture.projectURL(628)])
        #expect(rig.phase == .success && rig.model.message == "WWT: Website Relaunch")
        #expect(rig.speech.stops == 1 && !rig.speech.running)
        #expect(rig.earcons.played == [.listen, .done])
        #expect(rig.controller.history.recentOpens(628).count == 1)
        #expect(rig.store.savedHistories.isEmpty)
        await rig.advance(Controller.historySaveDelay)
        #expect(rig.store.savedHistories.count == 1 && rig.store.savedHistories[0].recentOpens(628).count == 1)

        await rig.advance(0.7)
        #expect(rig.phase == .idle && rig.overlay.hides == [0.2])
        // The launch sends the idle state with the app language first (a plugin that connects before any press).
        #expect(rig.fakeIPC.phases == [.idle, .listening, .processing, .success, .idle])
        #expect(rig.fakeIPC.states.first?.lang == "de" && rig.fakeIPC.states.first?.seq == 0)
        let lat = rig.controller.latencies
        #expect(lat[.speechEndToFinal]?.last == 580)
        #expect(lat[.finalToOpened]?.count == 1 && lat[.pressToMic]?.count == 1)
    }

    @Test func ambiguousWWTListsChoicesAndZweiOpensTheSecond() async throws {
        let rig = Rig()
        await rig.start()
        await rig.command("Öffne das WWT-Projekt")
        #expect(rig.phase == .choices)
        let list = rig.model.choices
        #expect(list.count == 4 && list.first?.target.projectId == 628)
        #expect(Set(list.map(\.target.projectId)) == [628, 314, 315, 693])
        #expect(rig.overlay.last?.choices == list && rig.fakeIPC.states.last?.choices?.count == 4)
        let rearm = try #require(rig.speech.rearms.last)
        #expect(rearm.mode == .answer && rearm.hangover == 0.40 && rearm.gen == SpeechGen(session: 1, utterance: 2))
        #expect(rearm.context?.contains("zwei") == true && rearm.context?.contains("vier") == true)
        #expect(rig.speech.running)   // the microphone stays open for the answer

        await rig.say("zwei")
        let second = list[1].target.projectId
        #expect(rig.chrome.opened == [Fixture.projectURL(second)])
        #expect(rig.phase == .success)
        #expect(rig.controller.history.picks(for: "wwt") == [second: 1])
        // The learned pick reaches the interpreter at once.
        #expect(rig.controller.env.interpreter.history.picks(for: "wwt") == [second: 1])
    }

    @Test func aClickWithTheSeqOfAnOlderListIsIgnored() async throws {
        let rig = Rig()
        await rig.start()
        await rig.command("Öffne das WWT-Projekt")
        let drawn = try #require(rig.overlay.last).seq
        await rig.say("Website")   // narrows to two rows, renumbered
        #expect(rig.phase == .choices && rig.model.choices.map(\.target.projectId) == [628, 315])
        let narrowed = rig.model.seq
        #expect(narrowed > drawn)
        // Row "2" of the old list (314) clicked after the narrow: dropped, not 315.
        rig.overlay.onChoose?(2, drawn)
        await rig.settle()
        #expect(rig.phase == .choices && rig.chrome.opened.isEmpty)
        rig.overlay.onChoose?(2, narrowed)
        await rig.settle()
        #expect(rig.chrome.opened == [Fixture.projectURL(315)])
    }

    @Test func myTasksOpensMyWork() async {
        let rig = Rig()
        await rig.start()
        await rig.command("Meine Aufgaben")
        #expect(rig.chrome.opened == [Fixture.myTasksURL])
        #expect(rig.phase == .success && rig.model.message == "Meine Aufgaben")
        #expect(rig.controller.history.opens.isEmpty)   // no project to learn
    }

    @Test func myTasksUserIdComesFromConfigOrToken() async {
        // Without a token the user id is unknown: "/my-work" still opens (needs no AC data).
        let none = Rig(token: .missing)
        await none.start()
        await none.command("Meine Aufgaben")
        #expect(none.chrome.opened == [URL(string: "https://ac.example.com/my-work")!])

        // userId in config.json fills in for a token without the prefix.
        var config = Fixture.config
        config.userId = 4711
        let pinned = Rig(token: .present(userId: nil), config: config)
        await pinned.start()
        await pinned.command("Meine Aufgaben")
        #expect(pinned.chrome.opened == [URL(string: "https://ac.example.com/users/4711/tasks")!])
        #expect(pinned.factory.made.map(\.userId) == [4711] && pinned.controller.status.token == .present)
        // Without a token the pinned id still names "Meine Aufgaben".
        let pinnedNoToken = Rig(token: .missing, config: config)
        await pinnedNoToken.start()
        await pinnedNoToken.command("Meine Aufgaben")
        #expect(pinnedNoToken.chrome.opened == [URL(string: "https://ac.example.com/users/4711/tasks")!])

        // A token with a prefix wins over a pinned id that differs: that id belongs to another account or another
        // AC address. config.json keeps it.
        let other = Rig(config: config)
        await other.start()
        await other.command("Meine Aufgaben")
        #expect(other.chrome.opened == [Fixture.myTasksURL] && other.factory.made.map(\.userId) == [538])
        #expect(other.controller.config.userId == 4711 && other.store.config.userId == 4711)

        // A token saved later fills the id in without a restart.
        let later = Rig(token: .missing)
        await later.start()
        #expect(await later.controller.saveToken("538-testtokenabc"))   // user id 538 from the token prefix
        await later.settle()
        await later.command("Meine Aufgaben")
        #expect(later.chrome.opened == [Fixture.myTasksURL])
        // The filled-in id stays out of config.json.
        #expect(later.controller.config.userId == nil)

        // Another user's token: the new index brings its id, even when the project list stays the same and the
        // interpreter is not rebuilt (only attachIndex updates the flow's config then).
        #expect(await later.controller.saveToken("4711-testtoken"))
        await later.settle()
        #expect(later.factory.made.map(\.userId) == [538, 4711])
        await later.command("Meine Aufgaben")
        #expect(later.chrome.opened.last == URL(string: "https://ac.example.com/users/4711/tasks")!)
    }

    @Test func launchAtLoginToggleKeepsTheTokenUserId() async {
        // setLaunchAtLogin writes the flow's config; it must not drop the id from the token prefix.
        let rig = Rig()
        await rig.start()
        rig.controller.setLaunchAtLogin(true)
        await rig.command("Meine Aufgaben")
        #expect(rig.chrome.opened == [Fixture.myTasksURL])
    }

    @Test func notUnderstoodRetriesAndTheOpenTeachesTheHeardWords() async throws {
        let rig = Rig()
        await rig.start()
        await rig.command("Hallo Welt")
        #expect(rig.phase == .retry && rig.model.message == FlowText.de.notUnderstoodRetry)
        let rearm = try #require(rig.speech.rearms.last)
        #expect(rearm.mode == .command && rearm.gen == SpeechGen(session: 1, utterance: 2))
        #expect(rearm.context == rig.controller.commandContext)
        #expect(rig.fakeIPC.states.last?.phase == .listening && rig.fakeIPC.states.last?.message == FlowText.de.notUnderstoodRetry)

        await rig.say("Öffne WWT Relaunch")
        #expect(rig.chrome.opened == [Fixture.projectURL(628)])
        #expect(rig.controller.history.picks(for: "hallo welt") == [628: 1])
        await rig.advance(Controller.historySaveDelay)
        #expect(rig.store.savedHistories.last?.picks(for: "hallo welt") == [628: 1])
    }

    @Test func secondFailureEndsInAnError() async {
        let rig = Rig()
        await rig.start()
        await rig.command("Hallo Welt")
        await rig.say("Hallo Welt")
        #expect(rig.phase == .error && rig.model.message == FlowText.de.notUnderstood)
        #expect(rig.earcons.played.last == .error && !rig.speech.running)
        await rig.advance(FlowTimings().errorHold)
        #expect(rig.phase == .idle)
    }

    @Test func chromeFallbackAndFailure() async {
        let rig = Rig()
        await rig.start()
        rig.chrome.results = [.success(.fallback(.denied))]
        await rig.command("WWT Relaunch")
        #expect(rig.phase == .success && rig.model.hint == FlowText.de.automationHint)
        #expect(rig.controller.status.chromeAutomation == .denied)
        await rig.advance(FlowTimings().hintHold)
        #expect(rig.phase == .idle)

        rig.chrome.results = [.failure(.openFailed)]
        await rig.command("WWT Relaunch")
        #expect(rig.phase == .error && rig.model.message == FlowText.de.openFailed)
        #expect(rig.controller.history.recentOpens(628).count == 1)   // only the first open counts
    }
}

@MainActor
@Suite struct TicketScenarioTests {
    @Test func ticketInTheActiveTabProjectRevalidatesThenOpens() async {
        let rig = Rig()
        await rig.start()
        rig.chrome.tabURL = URL(string: "https://ac.example.com/projects/628")
        await rig.command("Öffne WWT Ticket 412")
        #expect(rig.index?.revalidations.map(\.number) == [412])
        #expect(rig.index?.revalidations.first?.activeProjectId == 628)
        #expect(rig.chrome.opened == [Fixture.taskURL(628, 31_412)])
        #expect(rig.model.message == "Ticket 412 · WWT: Website Relaunch")
    }

    @Test func ticketMissFetchesTheArchiveThenOpens() async {
        let rig = Rig()
        await rig.start()
        await rig.settle()
        rig.index?.onCheckArchives = { snapshot, pids in
            // The archive of 693 arrives: its completed task has another number.
            snapshot.projectTasks[693]?.archived = [TaskRow(id: 60_001, number: 77)]
            return IndexCheck(complete: true)
        }
        await rig.command("Öffne WWT Ticket 412")
        #expect(rig.index?.archiveRequests == [[693]])
        #expect(rig.chrome.opened == [Fixture.taskURL(628, 31_412)])
        #expect(rig.controller.env.index.archiveComplete.contains(693))   // the env got the new index first
    }

    @Test func archiveErrorShowsTheACMessage() async {
        let rig = Rig()
        await rig.start()
        rig.index?.onCheckArchives = { _, _ in IndexCheck(complete: false, errors: [.transport(code: -1009)]) }
        await rig.command("Öffne WWT Ticket 999")
        #expect(rig.phase == .error && rig.model.message == "AC antwortet nicht")
    }

    @Test func staleListsTurnASingleHitIntoAConfirmPrompt() async {
        let rig = Rig()
        await rig.start()
        rig.index?.revalidateCheck = IndexCheck(complete: false, timedOut: true)
        rig.chrome.tabURL = URL(string: "https://ac.example.com/projects/628")
        await rig.command("Öffne WWT Ticket 412")
        #expect(rig.phase == .choices && rig.model.choices.count == 1 && rig.model.hint == FlowText.de.sayYesOrOne)
        await rig.say("ja")
        #expect(rig.chrome.opened == [Fixture.taskURL(628, 31_412)])
    }

    @Test func globalIdIsProbed() async {
        let rig = Rig()
        await rig.start()
        rig.index?.probeResult = .success(TaskRef(id: 47_285, projectId: 2032, number: 7))
        await rig.command("Ticket 47285")
        #expect(rig.index?.calls.contains("probe 47285") == true)
        #expect(rig.index?.revalidations.isEmpty == true)   // a global id needs no task lists
        #expect(rig.chrome.opened == [Fixture.taskURL(2032, 47_285)])
    }

    @Test func probeNotFoundAndRejectedToken() async {
        let rig = Rig()
        await rig.start()
        await rig.command("Ticket 47285")
        #expect(rig.phase == .error && rig.model.message == FlowText.de.ticketNotFound(47_285))
        await rig.advance(2)

        rig.index?.probeResult = .failure(.unauthorized)
        await rig.command("Ticket 47285")
        // The card names the next step, and so does the menu: a 401 needs a new sign-in.
        #expect(rig.phase == .error && rig.model.message == FlowText.de.tokenRejected && rig.model.hint == FlowText.de.signInAgain)
        #expect(ACError.unauthorized.userMessage == FlowText.de.tokenRejected)
        #expect(rig.controller.status.token == .invalid && rig.controller.statusLines.contains(AppText.de.tokenInvalid))
        #expect(AppText.de.tokenInvalid == "AC lehnt den Token ab. Melde dich in der Einrichtung neu an.")
    }
}

@MainActor
@Suite struct CancelAndPressTests {
    @Test func pressDuringChoicesCancels() async {
        let rig = Rig()
        await rig.start()
        await rig.command("Öffne das WWT-Projekt")
        await rig.press("p2")
        #expect(rig.phase == .idle && !rig.speech.running && rig.overlay.hides == [0.2])
        #expect(rig.fakeIPC.states.last?.phase == .idle)
    }

    @Test func spokenCancelDismissAndIPCCancel() async {
        let rig = Rig()
        await rig.start()
        await rig.listen()
        rig.speech.emit(.speechStarted)
        await rig.emit(.partial(dt: "abbrechen", st: "abbrechen"))
        #expect(rig.phase == .idle && rig.speech.stops == 1)

        await rig.command("Öffne das WWT-Projekt")
        rig.overlay.onDismiss?()   // close button
        await rig.settle()
        #expect(rig.phase == .idle)

        await rig.command("Öffne das WWT-Projekt")
        rig.fakeIPC.command(.cancel(id: "sd-9"))
        await rig.settle()
        #expect(rig.phase == .idle)

        await rig.listen()
        #expect(rig.controller.handleURL(URL(string: "acvoice://cancel")!))
        await rig.settle()
        #expect(rig.phase == .idle)
    }

    @Test func pressSemantics() async {
        let rig = Rig()
        await rig.start()
        // An accidental double tap before any speech is ignored.
        await rig.listen()
        rig.clock.advance(0.3)
        await rig.press("p2")
        #expect(rig.phase == .listening && rig.speech.endNows == 0)
        // A press while speaking ends the utterance now.
        rig.speech.emit(.speechStarted)
        await rig.emit(.partial(dt: "Öffne WWT", st: ""))
        await rig.press("p3")
        #expect(rig.speech.endNows == 1 && rig.phase == .processing)
        await rig.emit(.utterance([Hypothesis("Öffne WWT Relaunch")], latencyMs: nil))
        #expect(rig.chrome.opened == [Fixture.projectURL(628)])
        await rig.advance(1)

        // Without speech, a later press cancels.
        await rig.listen()
        rig.clock.advance(1.5)
        await rig.press("p5")
        #expect(rig.phase == .idle)
    }

    @Test func pushToTalkReleaseEndsTheUtterance() async {
        let rig = Rig()
        await rig.start()
        await rig.press("p1")
        await rig.emit(.micReady)
        #expect(rig.speech.held)
        rig.speech.emit(.speechStarted)
        await rig.emit(.partial(dt: "Meine Aufgaben", st: ""))
        await rig.release("p1", heldMs: 900)
        #expect(!rig.speech.held && rig.speech.endNows == 1)
        await rig.emit(.utterance([Hypothesis("Meine Aufgaben")], latencyMs: nil))
        #expect(rig.chrome.opened == [Fixture.myTasksURL])
    }

    @Test func pressDuringTheArchiveSearchCancelsAndTheLateResultIsIgnored() async {
        let rig = Rig()
        await rig.start()
        rig.index?.holdArchives = true
        await rig.listen()
        rig.speech.emit(.speechStarted)
        rig.speech.emit(.partial(dt: "Öffne WWT Ticket 999", st: ""))
        rig.speech.emit(.utterance([Hypothesis("Öffne WWT Ticket 999")], latencyMs: nil))
        #expect(await rig.controller.settle(leaving: 1))   // the archive call waits
        #expect(rig.phase == .processing && rig.model.message == FlowText.de.searchingTicket(999))
        #expect(rig.index?.archiveRequests == [[693]])
        // A press while AC searches cancels (REVIEW m5).
        rig.controller.trigger(.press(Press(id: "p2", source: .streamDeck)))
        #expect(await rig.controller.settle(leaving: 1))
        #expect(rig.phase == .idle && !rig.speech.running)
        // The late answer finds no request waiting for it.
        rig.index?.releaseArchives()
        await rig.settle()
        #expect(rig.phase == .idle && rig.chrome.opened.isEmpty)
    }

    @Test func staleIPCPressIsDropped() async {
        let rig = Rig()
        await rig.start()
        let old = Int64((Fixture.now.timeIntervalSince1970 - 5) * 1000)
        rig.fakeIPC.command(.press(id: "sd-1", at: old))
        await rig.settle()
        #expect(rig.phase == .idle && rig.speech.starts.isEmpty)
    }
}

@MainActor
@Suite struct FailureScenarioTests {
    @Test func microphoneThatDoesNotStart() async {
        let rig = Rig()
        await rig.start()
        rig.speech.startError = .sourceFailed("no device")
        await rig.press()
        #expect(rig.phase == .error && rig.model.message == FlowText.de.noInput)
        #expect(rig.earcons.played == [.error])
    }

    @Test func deniedMicrophoneNeverStartsAndAsksForSetup() async {
        let rig = Rig(mic: .denied)
        await rig.start()
        #expect(rig.setupRequests == 1)   // at launch
        await rig.press()
        #expect(rig.phase == .error && rig.model.message == FlowText.de.micDenied)
        #expect(rig.speech.calls.contains("start") == false && rig.setupRequests == 2)
        #expect(rig.permissions.micRequests == 0)   // a press never asks: only a click in the setup window does
    }

    @Test func speechFailureMidSessionAndStaleFailures() async {
        let rig = Rig()
        await rig.start()
        await rig.listen()
        // A failure of another session is dropped.
        rig.speech.emit(.failed(.engine), gen: SpeechGen(session: 7, utterance: 1))
        await rig.settle()
        #expect(rig.phase == .listening)
        await rig.emit(.failed(.modelUnavailable))
        #expect(rig.phase == .error && rig.model.message == FlowText.de.modelUnavailable)
    }

    @Test func warmingAndReadyDriveTheModelLine() async {
        let rig = Rig()
        rig.speech.warmUpError = SpeechError.assetsUnavailable
        await rig.start()
        #expect(rig.controller.status.speech == .unavailable && !rig.controller.flow.speechWarm)
        #expect(rig.controller.statusLines.contains(AppText.de.speechUnavailable) && rig.controller.needsAttention)
        await rig.press()
        #expect(rig.model.warming && rig.model.message == FlowText.de.loadingModel)
        await rig.emit(.warming)
        await rig.emit(.ready)
        #expect(!rig.model.warming && rig.controller.status.speech == .ready)
    }

    @Test func levelsReachOverlayAndIPCForTheCurrentSessionOnly() async {
        let rig = Rig()
        await rig.start()
        await rig.listen()
        await rig.emit(.level(dB: -36))
        let v = ACVoiceUI.LevelMeter.normalized(dB: -36)
        #expect(rig.overlay.levels == [v] && rig.fakeIPC.levels == [v])
        rig.speech.emit(.level(dB: -20), gen: SpeechGen(session: 9, utterance: 1))
        #expect(rig.overlay.levels.count == 1)
    }

    @Test func secondInstanceStopsTheLaunch() async {
        let ipc = FakeIPC()
        ipc.startError = IPCServerError.alreadyRunning
        let rig = Rig(ipc: ipc)
        await rig.start()
        #expect(rig.secondInstance && rig.speech.calls.isEmpty && rig.index == nil && !rig.controller.isRunning)
        #expect(rig.hotkey.registered == nil)
    }

    @Test func otherIPCErrorsKeepTheAppRunning() async {
        let ipc = FakeIPC()
        ipc.startError = IPCServerError.pathOccupied
        let rig = Rig(ipc: ipc)
        await rig.start()
        #expect(!rig.secondInstance && rig.controller.status.ipcError == AppText.de.ipcUnavailable)
        #expect(rig.controller.statusLines.contains(AppText.de.ipcUnavailable))
    }
}

@MainActor
@Suite struct TokenScenarioTests {
    /// A 401 only marks the token invalid: nothing renews it behind the user's back, the setup row asks for a new
    /// sign-in, and a new token for the same user resets the client instead of making a new index.
    @Test func rejectedTokenThenNewTokenResetsTheClient() async {
        let rig = Rig()
        rig.factory.snapshot = Fixture.snapshot()
        await rig.start()
        #expect(rig.controller.status.token == .present)
        rig.index?.fastReport = FakeIndex.report(errors: [.unauthorized])
        rig.controller.refreshIndexNow()
        await rig.settle()
        #expect(rig.controller.status.token == .invalid && rig.controller.needsSetup)
        #expect(rig.controller.statusLines.contains(AppText.de.tokenInvalid))
        #expect(rig.tokens.logins.isEmpty && rig.tokens.saved.isEmpty)
        let model = OnboardingModel(controller: rig.controller, copy: { _ in }, openURL: { _ in })
        let row = model.steps.first { $0.id == .token }
        #expect(row?.status == AppText.de.tokenRejected && row?.tone == .todo && model.showsSignIn)

        rig.index?.fastReport = FakeIndex.report(notModified: 4)
        #expect(await rig.controller.saveToken("538-NewTestTokenAbc"))
        await rig.settle()
        #expect(rig.tokens.saved == ["538-NewTestTokenAbc"] && rig.index?.resets == 1)
        #expect(rig.controller.status.token == .present && rig.controller.status.tokenMessage == nil)
        #expect(rig.factory.made.count == 1)   // same user: same index, token state reset
        #expect(rig.index?.calls.suffix(2).contains("refreshFast") == true)
    }

    @Test func missingTokenThenTokenAttachesTheIndex() async {
        let rig = Rig(token: .missing)
        await rig.start()
        #expect(rig.controller.status.token == .missing && rig.index == nil && rig.setupRequests == 1)
        #expect(rig.controller.statusLines.contains(AppText.de.tokenMissing))
        await rig.command("WWT Relaunch")
        #expect(rig.phase == .error && rig.model.message == FlowText.de.noProjectData)
        await rig.advance(2)

        // The address is still the placeholder: no password goes there.
        #expect(await rig.controller.login(username: "someone@example.com", password: "not-a-real-password") == false)
        #expect(rig.controller.status.tokenMessage == AppText.de.addressMissing && rig.tokens.logins.isEmpty)
        #expect(rig.controller.status.token == .missing && rig.index == nil)

        #expect(await rig.controller.saveToken("538-testtokenabc"))
        await rig.settle()
        #expect(rig.factory.made.map(\.userId) == [538] && rig.controller.status.token == .present)
        #expect(rig.index?.calls.prefix(2) == ["loadFromDisk", "refreshFast"])
        await rig.command("WWT Relaunch")
        #expect(rig.chrome.opened == [Fixture.projectURL(628)])
    }

    @Test func pastedTokenWithoutUserIdNeedsTheConfig() async {
        let rig = Rig(token: .missing)
        await rig.start()
        #expect(await rig.controller.saveToken("abcdefghijklmnop"))
        #expect(rig.controller.status.token == .needsUserId && rig.index == nil)
        #expect(await rig.controller.saveToken("538-abcdefghijklmnop"))
        await rig.settle()
        #expect(rig.controller.status.token == .present && rig.factory.made.map(\.userId) == [538])
    }

    @Test func refreshAddsAProjectAndTheInterpreterFollows() async {
        let rig = Rig(snapshot: Fixture.snapshot(without: [2081]))
        await rig.start()
        let before = rig.controller.env.interpreter.resolver.projects.count
        await rig.command("Öffne R3NO")
        #expect(rig.phase == .retry)
        rig.index?.onRefreshFast = { s in
            if !s.projects.contains(where: { $0.id == 2081 }) { s.projects.append(ProjectRecord(id: 2081, name: "QZ: R3NO [INT]")) }
        }
        // The press refreshes in parallel to speech; the next command sees the new project.
        await rig.press("p9")   // cancels the retry
        await rig.command("Öffne R3NO")
        #expect(rig.controller.env.interpreter.resolver.projects.count == before + 1)
        #expect(rig.chrome.opened == [Fixture.projectURL(2081)])
    }
}

@MainActor
@Suite struct TriggerMappingTests {
    @Test func ipcCommandsMapToFlowEvents() async throws {
        let rig = Rig()
        await rig.start()
        rig.fakeIPC.command(.hello(client: "streamdeck", version: "0.1.0"))
        await rig.settle()
        #expect(rig.phase == .idle)

        rig.fakeIPC.command(.press(id: "sd-1", at: 0))
        await rig.settle()
        #expect(rig.phase == .listening && rig.speech.held)
        let listening = try #require(rig.fakeIPC.states.last)
        #expect(listening.phase == .listening && listening.seq == rig.model.seq && listening == rig.model.ipcState())
        await rig.emit(.micReady)
        rig.speech.emit(.speechStarted)
        await rig.emit(.partial(dt: "Öffne das WWT-Projekt", st: ""))
        rig.fakeIPC.command(.release(id: "sd-2", pressId: "sd-1", heldMs: 900))
        await rig.settle()
        #expect(rig.speech.endNows == 1 && !rig.speech.held)
        await rig.emit(.utterance([Hypothesis("Öffne das WWT-Projekt")], latencyMs: nil))
        #expect(rig.phase == .choices)
        let state = try #require(rig.fakeIPC.states.last)
        #expect(state.choices?.count == 4 && state.deadline != nil)
        let third = rig.model.choices[2].target.projectId
        rig.fakeIPC.command(.choose(id: "sd-3", index: 3, seq: state.seq))
        await rig.settle()
        #expect(rig.chrome.opened == [Fixture.projectURL(third)])
    }

    @Test func hotkeyEdgesBecomePressAndRelease() async {
        let rig = Rig()
        await rig.start()
        rig.hotkey.fire(.pressed)
        await rig.settle()
        #expect(rig.phase == .listening && rig.speech.held)
        await rig.emit(.micReady)
        rig.speech.emit(.speechStarted)
        await rig.emit(.partial(dt: "Meine Aufgaben", st: ""))
        rig.hotkey.fire(.released(heldMs: 1200))
        await rig.settle()
        #expect(rig.speech.endNows == 1)
        await rig.emit(.utterance([Hypothesis("Meine Aufgaben")], latencyMs: nil))
        #expect(rig.chrome.opened == [Fixture.myTasksURL])
        // A release without a press does nothing.
        rig.hotkey.fire(.released(heldMs: 10))
        await rig.settle()
        #expect(rig.speech.endNows == 1)
    }

    @Test func hotkeyRegistrationFailureShowsInTheMenu() async {
        let rig = Rig()
        rig.hotkey.error = .registrationFailed(-9878)
        await rig.start()
        #expect(rig.controller.status.hotkeyError == "Eine andere App nutzt das Tastenkürzel. Ändere hotkey in config.json.")
        #expect(rig.controller.menuState().hotkey == nil)
    }

    @Test func urlSchemeAndMenuListen() async {
        let rig = Rig()
        await rig.start()
        #expect(rig.controller.handleURL(URL(string: "acvoice://press")!))
        await rig.settle()
        #expect(rig.phase == .listening && !rig.speech.held)   // a URL has no release edge
        #expect(rig.controller.handleURL(URL(string: "acvoice://setup")!) && rig.setupRequests == 1)
        #expect(!rig.controller.handleURL(URL(string: "https://example.com/press")!))
        #expect(!rig.controller.handleURL(URL(string: "acvoice://unknown")!))
        await rig.press("p2")   // listening without speech for less than the double-tap window: ignored
        rig.clock.advance(1.5)
        await rig.press("p3")
        #expect(rig.phase == .idle)
        rig.controller.listen()
        await rig.settle()
        #expect(rig.phase == .listening && rig.speech.starts.count == 2)
    }

    @Test func timersFollowTheFlow() async {
        let rig = Rig()
        await rig.start()
        await rig.listen()
        // No speech for 4 s after the mic is ready: "Ich höre nichts".
        await rig.advance(4.1)
        #expect(rig.phase == .error && rig.model.message == FlowText.de.nothingHeard)
        await rig.advance(FlowTimings().errorHold)
        #expect(rig.phase == .idle)
        // The choices window closes the list after 6 s.
        await rig.command("Öffne das WWT-Projekt")
        await rig.advance(6.1)
        #expect(rig.phase == .idle && !rig.speech.running)
    }
}

@MainActor
@Suite struct BackgroundAndLifecycleTests {
    @Test func backgroundRefreshRunsWhileIdleOnly() async {
        let rig = Rig()
        await rig.start()
        func fast() -> Int { rig.index?.count("refreshFast") ?? 0 }
        let f0 = fast()
        #expect(f0 == 1 && rig.index?.count("refreshTaskLists") == 0)   // the cached lists are fresh at launch
        await rig.advance(Controller.fastRefreshInterval)               // t = 300
        #expect(fast() == f0 + 1)
        await rig.advance(Controller.fastRefreshInterval - 0.5)         // t = 599.5
        await rig.press()                                               // the press refreshes too
        #expect(fast() == f0 + 2)
        await rig.advance(1)                                            // tick at 600 finds the flow busy
        #expect(fast() == f0 + 2 && rig.phase == .listening)
        await rig.advance(Controller.busyRetry)                         // idle again ("Mikrofon startet nicht")
        #expect(fast() == f0 + 3 && rig.phase == .idle)
        await rig.advance(100)                                          // t = 730: the task lists, then archives
        #expect(rig.index?.count("refreshTaskLists") == 1 && rig.index?.count("extendArchives") == 1)
    }

    @Test func staleListsRefreshAtLaunch() async {
        var snapshot = Fixture.snapshot()
        snapshot.taskListsFetchedAt = Fixture.now.addingTimeInterval(-3600)
        let rig = Rig(snapshot: snapshot)
        await rig.start()
        #expect(rig.index?.calls == ["loadFromDisk", "refreshFast", "refreshTaskLists", "extendArchives"])
    }

    @Test func shutdownStopsEverything() async {
        let rig = Rig()
        await rig.start()
        await rig.command("WWT Relaunch")   // history changed, not yet written
        await rig.controller.shutdown()
        #expect(rig.hotkey.unregistered == 1 && rig.fakeIPC.stopped && rig.store.savedHistories.count == 1)
        #expect(rig.store.flushes == 1 && rig.speech.calls.last == "stop")
    }

    @Test func menuActionsSelfTestChromeTestAndLoginItem() async {
        let rig = Rig()
        await rig.start()
        rig.controller.runSelfTest()
        #expect(rig.controller.status.selfCheckRunning)
        await rig.settle()
        #expect(rig.controller.status.selfCheck?.passed == true)
        #expect(rig.controller.diagnosticLines.contains(AppText.de.selfTestPassed(ms: 812)))

        rig.controller.runChromeTest()
        await rig.settle()
        #expect(rig.chrome.opened == [Fixture.myTasksURL])
        #expect(rig.controller.status.chromeTest == AppText.de.chromeTest(.reused))
        await rig.advance(0.6)
        #expect(rig.controller.status.chromeFront == AppText.de.chromeFront(true))

        rig.controller.setLaunchAtLogin(true)
        #expect(rig.login.statusValue == .enabled && rig.store.launchAtLogin == [true])
        #expect(rig.controller.menuState().loginItem == .enabled)
        rig.login.error = TestError()
        rig.controller.setLaunchAtLogin(false)
        #expect(rig.controller.status.loginMessage?.hasPrefix(AppText.de.loginItemFailed) == true)

        // Not while a command runs: the menu disables the Diagnose commands (review U9), the call does nothing.
        await rig.listen()
        rig.controller.runChromeTest()
        #expect(rig.controller.status.notice == nil && rig.chrome.opened.count == 1)
        guard case .submenu(let diag)? = StatusMenuModel.items(rig.controller.menuState()).first(where: {
            $0.title == AppText.de.diagnostics })?.kind else { Issue.record("no Diagnose submenu"); return }
        let commands = diag.filter { if case .command = $0.kind { return true }; return false }
        #expect(commands.filter(\.enabled).map(\.title) == [AppText.de.copyDiagnostics])
        // The test results sit in the submenu, not at the top of the menu.
        #expect(diag.first?.title == AppText.de.selfTestPassed(ms: 812) && !rig.controller.statusLines.contains(AppText.de.selfTestPassed(ms: 812)))
    }

    @Test func diagnosticsHoldNoTranscriptAndNoToken() async {
        let rig = Rig(token: .missing)
        await rig.start()
        #expect(await rig.controller.saveToken("538-SECRETTOKENVALUE123"))
        await rig.settle()
        await rig.command("Öffne WWT Relaunch")
        let input = rig.controller.diagnosticsInput(automation: .granted, appVersion: "0.1.0", build: "1",
                                                    osVersion: "macOS 26.6")
        let text = Diagnostics.text(input)
        #expect(!text.contains("SECRET") && !text.contains("Relaunch") && !text.contains("Öffne"))
        #expect(text.contains("AC-Token: gespeichert") && text.contains("Index: 63 Projekte"))
        #expect(text.contains("Latenz speechEndToFinal: n=1"))
        #expect(text.contains("Chrome-Steuerung: granted"))
    }
}

/// The real IPC server on a temporary socket, driving the controller.
@MainActor
@Suite(.serialized) struct RealIPCTests {
    @Test func pressAndCancelOverTheSocket() async throws {
        let path = tempSocketPath()
        defer { removeTempDir(of: path) }
        let server = IPCServer(path: path)
        let rig = Rig(ipc: server)
        await rig.start()
        #expect(server.isRunning)

        let client = try PosixClient(path: path)
        defer { client.close() }
        let first = await client.waitFor("state")
        #expect(first?["phase"] as? String == "idle")
        client.send(#"{"v":1,"t":"hello","client":"streamdeck","version":"0.1.0"}"# + "\n")
        client.send(#"{"v":1,"t":"press","id":"sd-1","at":0}"# + "\n")
        let listening = await client.waitFor("state", where: { $0["phase"] as? String == "listening" })
        #expect(listening != nil)
        await rig.settle()
        #expect(rig.phase == .listening && rig.speech.starts.count == 1 && rig.speech.held)
        #expect(server.connectedClients.count == 1)

        // Level messages only while listening.
        await rig.emit(.micReady)
        await rig.emit(.level(dB: -30))
        let level = await client.waitFor("level")
        #expect((level?["rms"] as? Double).map { abs($0 - ACVoiceUI.LevelMeter.normalized(dB: -30)) < 0.002 } == true)

        client.send(#"{"v":1,"t":"ping","id":"sd-2"}"# + "\n")
        #expect(await client.waitFor("pong")?["id"] as? String == "sd-2")
        client.send(#"{"v":1,"t":"cancel","id":"sd-3"}"# + "\n")
        let idle = await client.waitFor("state", where: { $0["phase"] as? String == "idle" && ($0["seq"] as? Int ?? 0) > 0 })
        #expect(idle != nil)
        await rig.settle()
        #expect(rig.phase == .idle && rig.speech.stops == 1)

        await rig.controller.shutdown()
        #expect(!server.isRunning && !FileManager.default.fileExists(atPath: path))
    }
}
