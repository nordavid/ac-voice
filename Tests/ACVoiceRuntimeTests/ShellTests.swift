import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSystem
import ACVoiceUI
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ACVoiceRuntime

/// Menu, setup window, overlay demo, diagnostics and helpers. Menus are built as plain NSMenu objects without a
/// status item; the setup view lays out in a windowless hosting view. Nothing appears on screen.
@MainActor
@Suite struct MenuTests {
    static func diagnose(_ items: [MenuItemSpec]) -> [MenuItemSpec] {
        for i in items { if case .submenu(let sub) = i.kind, i.title == AppText.diagnostics { return sub } }
        return []
    }

    @Test func menuRowsAndTitles() throws {
        let state = MenuState(phase: .idle, statusLines: ["Bereit", "AC-Token fehlt"], hotkey: .default,
                              loginItem: .enabled, hasIndex: false, selfTestRunning: true)
        let items = StatusMenuModel.items(state)
        #expect(items.prefix(2).map(\.title) == ["Bereit", "AC-Token fehlt"] && items[0].kind == .status && !items[0].enabled)
        let commands = items.compactMap { i -> String? in if case .command = i.kind { return i.title }; return nil }
        #expect(commands == ["Zuhören", "Index aktualisieren", "Einrichten …", "Beim Anmelden starten", "Beenden"])
        let listen = try #require(items.first { $0.kind == .command(.listen) })
        #expect(listen.key == " " && NSEvent.ModifierFlags(rawValue: listen.modifiers) == [.control, .option])
        #expect(items.first { $0.kind == .command(.refreshIndex) }?.enabled == false)
        #expect(items.first { $0.kind == .command(.launchAtLogin) }?.checked == true)
        let diag = Self.diagnose(items)
        #expect(diag.map(\.title) == ["Spracherkennung testen", "Chrome testen", "Overlay vorführen", "Diagnose kopieren"])
        #expect(diag[0].enabled == false && diag[1].enabled)
    }

    /// Review U9: the tests need an idle flow, so the menu disables them while a command runs; their results sit in
    /// the submenu.
    @Test func diagnoseWhileBusyAndResultsInTheSubmenu() {
        let busy = Self.diagnose(StatusMenuModel.items(MenuState(phase: .listening, diagnosticLines: ["Chrome testen"])))
        #expect(busy.first?.kind == .status && busy.first?.title == "Chrome testen" && busy[1].kind == .separator)
        let commands = busy.filter { if case .command = $0.kind { return true }; return false }
        #expect(commands.map(\.enabled) == [false, false, false, true])
    }

    /// Review C9: a login item waiting for approval shows as on (a dash) with a way to System Settings, and the click
    /// turns it off instead of registering again.
    @Test func loginItemWaitingForApproval() async throws {
        let items = StatusMenuModel.items(MenuState(loginItem: .requiresApproval))
        let toggle = try #require(items.first { $0.kind == .command(.launchAtLogin) })
        #expect(toggle.mixed && !toggle.checked)
        #expect(items.contains { $0.kind == .command(.openLoginItems) })
        #expect(!StatusMenuModel.items(MenuState(loginItem: .enabled)).contains { $0.kind == .command(.openLoginItems) })
        let menu = NSMenu()
        StatusMenuBuilder.fill(menu, with: items, perform: { _ in })
        #expect(menu.items.first { $0.title == AppText.launchAtLogin }?.state == .mixed)

        let rig = Rig()
        rig.login.enabledResult = .requiresApproval
        await rig.start()
        rig.controller.toggleLaunchAtLogin()
        #expect(rig.login.calls == [true] && rig.controller.loginStatus == .requiresApproval)
        #expect(rig.controller.status.loginMessage == LoginItemStatus.requiresApproval.hint)
        rig.controller.toggleLaunchAtLogin()
        #expect(rig.login.calls == [true, false] && rig.controller.loginStatus == .disabled)
        let coordinator = AppCoordinator(controller: rig.controller)
        coordinator.perform(.openLoginItems)
        #expect(rig.login.settingsOpened == 1)
    }

    /// Review C8: the icon refresh at every phase change reads no login item status (an XPC call in the app).
    @Test func iconRefreshAvoidsTheLoginItemCall() async {
        let rig = Rig()
        await rig.start()
        let reads = rig.login.statusReads
        await rig.command("WWT Relaunch")
        for _ in 0..<5 { _ = rig.controller.menuIcon }
        #expect(rig.login.statusReads == reads)
        _ = rig.controller.menuState()   // the menu opens: read it then
        #expect(rig.login.statusReads == reads + 1)
    }

    /// Review U9: "Diagnose kopieren" answers with a check on the icon and a line.
    @Test func copyingDiagnosticsFlashesTheIcon() async {
        let rig = Rig()
        await rig.start()
        rig.controller.diagnosticsCopied()
        #expect(StatusMenuModel.symbol(rig.controller.menuIcon) == "checkmark.circle")
        #expect(rig.controller.statusLines.contains(AppText.diagnosticsCopied))
        await rig.advance(1.6)
        #expect(StatusMenuModel.symbol(rig.controller.menuIcon) == "waveform")
        await rig.advance(3)
        #expect(!rig.controller.statusLines.contains(AppText.diagnosticsCopied))
    }

    @Test func nsMenuIsBuiltAndRunsCommands() throws {
        var ran: [MenuCommand] = []
        let menu = NSMenu()
        StatusMenuBuilder.fill(menu, with: StatusMenuModel.items(MenuState(statusLines: ["Bereit"], hotkey: .default)),
                               perform: { ran.append($0) })
        #expect(menu.items.first?.title == "Bereit" && menu.items.first?.isEnabled == false)
        let listen = try #require(menu.items.first { $0.title == "Zuhören" } as? CommandMenuItem)
        #expect(listen.keyEquivalent == " " && listen.keyEquivalentModifierMask == [.control, .option])
        _ = listen.target?.perform(listen.action, with: listen)
        let diag = try #require(menu.items.first { $0.title == "Diagnose" }?.submenu)
        let demo = try #require(diag.items.first { $0.title == AppText.overlayDemo } as? CommandMenuItem)
        _ = demo.target?.perform(demo.action, with: demo)
        #expect(ran == [.listen, .overlayDemo])
        let quit = try #require(menu.items.last)
        #expect(quit.title == "Beenden" && quit.keyEquivalent == "q" && quit.keyEquivalentModifierMask == .command)
    }

    @Test func iconFollowsThePhase() {
        #expect(StatusMenuModel.symbol(phase: .idle, attention: false) == "waveform")
        #expect(StatusMenuModel.symbol(phase: .idle, attention: true) == "waveform.badge.exclamationmark")
        #expect(StatusMenuModel.symbol(phase: .listening, attention: true) == "waveform.circle.fill")
        #expect(StatusMenuModel.symbol(phase: .retry, attention: false) == "waveform.circle.fill")
        #expect(StatusMenuModel.symbol(phase: .opening, attention: false) == "ellipsis.circle")
        #expect(StatusMenuModel.symbol(phase: .choices, attention: false) == "list.number")
        #expect(StatusMenuModel.symbol(phase: .success, attention: false) == "checkmark.circle")
        #expect(StatusMenuModel.symbol(phase: .error, attention: false) == "exclamationmark.triangle")
        for phase in FlowPhase.allCases {
            for attention in [false, true] {
                let name = StatusMenuModel.symbol(phase: phase, attention: attention)
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
                #expect(styleViolations(StatusMenuModel.accessibilityLabel(phase: phase, attention: attention)).isEmpty)
            }
        }
    }

    @Test func hotkeyKeyEquivalents() {
        #expect(StatusMenuModel.keyEquivalent(Hotkey(keyCode: 96, modifiers: Hotkey.cmdKey))?.key
                == String(Character(UnicodeScalar(NSF5FunctionKey)!)))
        #expect(StatusMenuModel.keyEquivalent(Hotkey(keyCode: 0, modifiers: Hotkey.controlKey)) == nil)
    }

    @Test func statusLinesFollowTheController() async {
        let rig = Rig(token: .missing, mic: .notDetermined)
        await rig.start()
        let lines = rig.controller.statusLines
        #expect(lines.first == AppText.ready)
        #expect(lines.contains(AppText.tokenMissing) && lines.contains(AppText.micMissing))
        #expect(rig.controller.menuState().attention && !rig.controller.menuState().hasIndex)
        for line in lines { #expect(styleViolations(line).isEmpty, "\(line)") }
    }
}

@MainActor
@Suite struct OnboardingTests {
    @Test func stepsActionsAndPermissionsOnClickOnly() async throws {
        let rig = Rig(token: .missing, mic: .notDetermined)
        rig.chrome.automation = .notDetermined
        await rig.start()
        var copied: [String] = []
        let model = OnboardingModel(controller: rig.controller, copy: { copied.append($0) })
        await model.refresh()
        #expect(rig.chrome.preflights == [false])   // the status check never prompts
        #expect(model.needsAttention)
        func step(_ id: OnboardingModel.StepID) -> OnboardingModel.Step { model.steps.first { $0.id == id }! }
        #expect(model.steps.map(\.id) == OnboardingModel.StepID.allCases)
        #expect(step(.token).tone == .todo && step(.token).action?.kind == .importToken)
        #expect(step(.microphone).tone == .todo && step(.microphone).action?.kind == .requestMicrophone)
        #expect(step(.chrome).tone == .todo && step(.chrome).action?.kind == .requestAutomation)
        #expect(step(.speech).tone == .done)
        #expect(step(.streamDeck).action?.kind == .copyStreamDeckCommands)
        #expect(step(.autostart).status.isEmpty)   // the switch says it (review U24)
        #expect(rig.permissions.micRequests == 0)

        await model.perform(.importToken)
        await rig.settle()
        #expect(step(.token).tone == .done && step(.token).status == AppText.tokenStored)
        await model.perform(.requestMicrophone)
        #expect(rig.permissions.micRequests == 1 && step(.microphone).tone == .done && step(.microphone).action == nil)
        await model.perform(.requestAutomation)
        #expect(rig.chrome.preflights == [false, true] && step(.chrome).tone == .done)
        await model.perform(.runSelfTest)
        await rig.settle()
        model.rebuild()
        #expect(step(.speech).status == AppText.selfTestPassed(ms: 812))
        await model.perform(.copyStreamDeckCommands)
        #expect(copied == [AppText.streamDeckCommands(sourceRoot: nil)])
        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin && step(.autostart).tone == .done && rig.store.launchAtLogin == [true])
        #expect(!model.needsAttention)
        for s in model.steps {
            #expect(styleViolations(s.status).isEmpty, "\(s.status)")
            if let a = s.action { #expect(styleViolations(a.title).isEmpty) }
        }
    }

    @Test func pastedTokenIsSavedAndCleared() async {
        let rig = Rig(token: .missing)
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in })
        model.pastedToken = "  538-abcdefghijkl \n"
        await model.savePastedToken()
        await rig.settle()
        #expect(rig.tokens.saved == ["538-abcdefghijkl"] && model.pastedToken.isEmpty)
        #expect(rig.controller.status.token == .present)
    }

    @Test func deniedStatesOfferSystemSettings() async {
        let rig = Rig(mic: .denied)
        rig.chrome.automation = .denied
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in })
        await model.refresh()
        let mic = model.steps.first { $0.id == .microphone }!
        let chrome = model.steps.first { $0.id == .chrome }!
        #expect(mic.action?.kind == .openMicrophoneSettings && chrome.action?.kind == .openAutomationSettings)
        await model.perform(.openMicrophoneSettings)
        await model.perform(.openAutomationSettings)
        #expect(rig.permissions.opened == [.microphone, .automation])
        // Chrome not running: no check, the button waits.
        rig.permissions.isChromeRunning = false
        await model.refresh()
        let idle = model.steps.first { $0.id == .chrome }!
        #expect(idle.status == AppText.chromeNotRunning && idle.action?.enabled == false)
    }

    @Test func failedSelfTestAsksForSpeechRecognitionOnClick() async {
        let rig = Rig()
        rig.speech.selfCheckResult = SelfCheckResult(passed: false, elapsedMs: 900, message: "Spracherkennung liefert keinen Text")
        await rig.start()
        rig.controller.runSelfTest()
        await rig.settle()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in })
        let speech = model.steps.first { $0.id == .speech }!
        #expect(speech.tone == .todo && speech.action?.kind == .requestSpeechRecognition)
        #expect(rig.permissions.speechRequests == 0)
        await model.perform(.requestSpeechRecognition)
        #expect(rig.permissions.speechRequests == 1)
    }

    @Test func viewLaysOutWithoutAWindow() async {
        let rig = Rig(token: .missing, mic: .notDetermined)
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in })
        let host = NSHostingView(rootView: OnboardingView(model: model, onDone: {}))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        #expect(size.width >= 500 && size.height > 300)
        #expect(host.window == nil)
    }
}

@MainActor
@Suite struct DemoTests {
    /// Review U7: the demo runs a scripted command through the real reducer (real timings, synthetic speech), then
    /// every gallery state, starting with the most frequent one (mic hot, nothing heard).
    @Test func demoRunsTheScriptedCommandThenEveryState() {
        let overlay = FakeOverlay()
        let clock = ManualClock(now: Fixture.now)
        let demo = OverlayDemo(overlay: overlay, clock: clock)
        var done = 0
        demo.start(loop: false) { done += 1 }
        #expect(overlay.shows == 1 && demo.isRunning && demo.position == -1)
        clock.advance(6.5)
        let phases = overlay.renders.map(\.phase).reduce(into: [FlowPhase]()) { if $0.last != $1 { $0.append($1) } }
        #expect(phases == [.listening, .choices, .opening, .success, .idle])
        #expect(overlay.hides == [0.2])
        let live = overlay.renders.filter { $0.phase == .listening }.map(\.transcript.text)
        #expect(live.contains("Öffne das") && live.last == "Öffne das WWT-Projekt")
        let list = overlay.renders.first { $0.phase == .choices }
        #expect(list?.choices.count == 4 && list?.transcript.text == "Öffne das WWT-Projekt")
        #expect(overlay.renders.contains { $0.phase == .choices && $0.answer.text == "Die zweite" })
        #expect(overlay.renders.first { $0.phase == .opening }?.preview == list?.choices[1].displayName)
        let before = overlay.renders.count
        clock.advance(OverlayDemo.interlude + demo.step * Double(demo.scenarios.count) + 0.1)
        let gallery = Array(overlay.renders.dropFirst(before))
        #expect(gallery.count == demo.scenarios.count && gallery.allSatisfy(\.visible))
        #expect(gallery.first?.phase == .listening && gallery.first?.micReady == true && gallery.first?.transcript.isEmpty == true)
        #expect(Set(gallery.map(\.phase)) == Set(FlowPhase.allCases).subtracting([.idle]))
        #expect(overlay.renders.map(\.seq) == Array(1...overlay.renders.count))
        #expect(overlay.shows == 2 && overlay.hides == [0.2, 0.2] && done == 1 && !demo.isRunning)
        #expect(overlay.levels.count > 10 && overlay.levels.allSatisfy { (0...1).contains($0) })
        // The countdown runs from now: the choices state ends in the future.
        let choices = gallery.first { $0.phase == .choices }!
        #expect(choices.deadline! > choices.since)
        let pending = clock.pending
        clock.advance(10)
        #expect(overlay.renders.count == before + gallery.count && clock.pending <= pending)
    }

    @Test func loopingDemoStopsOnAPress() async {
        let rig = Rig()
        await rig.start()
        rig.controller.startDemo(loop: true)
        #expect(rig.controller.isDemoRunning && rig.controller.statusLines.contains(AppText.demoRunning))
        rig.clock.advance(60)
        #expect(rig.overlay.renders.count > 15)
        await rig.press()
        #expect(!rig.controller.isDemoRunning && rig.overlay.hides.last == 0)
        #expect(rig.phase == .listening && rig.overlay.last?.phase == .listening)
        // Not while a command runs (the menu disables it; the call does nothing).
        rig.controller.startDemo()
        #expect(!rig.controller.isDemoRunning && rig.controller.status.notice == nil)
    }

    @Test func dismissStopsTheDemoWithoutACancel() async {
        let rig = Rig()
        await rig.start()
        rig.controller.startDemo()
        rig.overlay.onDismiss?()
        #expect(!rig.controller.isDemoRunning && rig.phase == .idle && rig.speech.starts.isEmpty)
    }
}

@MainActor
@Suite struct SupportTests {
    @Test func transcriptSplitKeepsSettledWordsStable() {
        var s = TranscriptSplitter()
        #expect(s.next("Öffne") == Transcript(stable: "", volatile: "Öffne"))
        #expect(s.next("Öffne WWT") == Transcript(stable: "Öffne", volatile: "WWT"))
        #expect(s.next("Öffne WWT Relau") == Transcript(stable: "Öffne WWT", volatile: "Relau"))
        #expect(s.next("Öffne WWT Relaunch") == Transcript(stable: "Öffne WWT", volatile: "Relaunch"))
        #expect(s.next("Öffne WKT Relaunch") == Transcript(stable: "Öffne", volatile: "WKT Relaunch"))
        s.reset()
        #expect(s.next("zwei").stable.isEmpty)
    }

    @Test func serialWorkKeepsEffectOrder() async {
        let work = SerialWork()
        var log: [String] = []
        work.perform { log.append("now") }        // idle: runs at once
        #expect(log == ["now"])
        work.enqueue {
            await Task.yield()
            log.append("start")
        }
        work.perform { log.append("hold") }       // queued behind the start
        #expect(log == ["now"] && work.isBusy)
        await work.idle()
        #expect(log == ["now", "start", "hold"] && !work.isBusy)
    }

    @Test func latencyStatsKeepTheLastSamples() {
        var s = LatencyStats()
        for i in 1...30 { s.add(Double(i)) }
        s.add(.nan)
        #expect(s.count == LatencyStats.capacity && s.last == 30 && s.median == 21 && s.p90 == 28)
    }

    @Test func fileStoreKeepsUnknownConfigKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acvoice-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(configURL: dir.appendingPathComponent("config.json"),
                              historyURL: dir.appendingPathComponent("history.json"))
        #expect(store.loadConfig() == Config() && store.loadHistory() == History())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"earcons":false,"myOwnKey":"keep"}"#.utf8).write(to: store.configURL)
        store.saveLaunchAtLogin(true)
        var h = History()
        h.recordOpen(projectId: 628, at: Fixture.now)
        store.save(h)
        store.flush()
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.configURL)) as? [String: Any])
        #expect(json["myOwnKey"] as? String == "keep" && json["launchAtLogin"] as? Bool == true && json["earcons"] as? Bool == false)
        #expect(store.loadConfig().launchAtLogin && !store.loadConfig().earcons)
        #expect(store.loadHistory().recentOpens(628) == [Fixture.now])
    }

    @Test func diagnosticsFormat() {
        var status = RuntimeStatus()
        status.token = .invalid
        status.selfCheck = SelfCheckResult(passed: true, elapsedMs: 812.4, message: "x")
        var lat = LatencyStats()
        lat.add(600)
        let input = DiagnosticsInput(
            appVersion: "0.1.0", build: "202611241500", osVersion: "Version 26.6", phase: .idle, status: status,
            microphone: .granted, speechRecognition: .notDetermined, automation: nil, loginItem: .disabled,
            hotkey: Hotkey.default.display, ipcClients: 1, index: Fixture.snapshot().stats,
            indexFetchedAt: Fixture.now.addingTimeInterval(-90), taskListsFetchedAt: nil,
            latencies: [.speechEndToFinal: lat], config: Fixture.config, now: Fixture.now)
        let text = Diagnostics.text(input)
        #expect(text.hasPrefix("AC Voice 0.1.0 (202611241500), Version 26.6\n"))
        #expect(text.contains("AC-Token: ungültig") && text.contains("Selbsttest: bestanden, 812 ms"))
        #expect(text.contains("Index-Stand: vor 90 s, Aufgabenlisten nie"))
        #expect(text.contains("Chrome-Steuerung: Chrome läuft nicht") && text.contains("Stream Deck: 1 Verbindung"))
        #expect(text.contains("Latenz speechEndToFinal: n=1, Median 600 ms") && text.contains("Latenz pressToMic: keine Messung"))
        #expect(!text.contains("WWT") && !text.contains("Relaunch"))
    }

    @Test func germanTextsFollowTheStyle() {
        for s in AppText.all { #expect(styleViolations(s).isEmpty, "\(s): \(styleViolations(s))") }
        // Menu titles are short.
        for s in [AppText.listen, AppText.refreshIndex, AppText.setup, AppText.launchAtLogin, AppText.diagnostics,
                  AppText.selfTest, AppText.chromeTest, AppText.overlayDemo, AppText.copyDiagnostics, AppText.quit] {
            #expect(s.count <= 24, "\(s)")
        }
    }
}

/// German UI style (company rules): no en or em dash, no colon or spaced dash inside a sentence, no subjunctive.
func styleViolations(_ s: String) -> [String] {
    var v: [String] = []
    if s.contains("\u{2013}") || s.contains("\u{2014}") { v.append("dash") }
    if s.contains(":"), !s.hasPrefix("cd ") { v.append("colon") }
    if s.contains(" - ") { v.append("dash inside a sentence") }
    let lower = s.lowercased()
    for w in ["könnte", "sollte", "würde", "wäre", "hätte", "möchte"] where lower.contains(w) { v.append(w) }
    return v
}

@MainActor
@Suite struct CoordinatorTests {
    /// A launch by `open acvoice://press` delivers the URL before the controller is ready: it waits.
    @Test func urlsWaitForTheLaunch() async {
        let rig = Rig()
        let coordinator = AppCoordinator(controller: rig.controller)
        coordinator.open([URL(string: "acvoice://press")!])
        await rig.settle()
        #expect(rig.phase == .idle && rig.speech.starts.isEmpty && !coordinator.isDemoMode)
    }

    /// SIGTERM, the menu and a second instance quit through `quit()`: the shutdown runs first and once, then the app
    /// terminates, so `applicationShouldTerminate` answers `.terminateNow`. Before, SIGTERM called `NSApp.terminate`
    /// from the dispatch source handler and hung in AppKit's nested run loop until install.sh sent SIGKILL.
    @Test func quitShutsDownOnceBeforeTerminating() async {
        let rig = Rig()
        await rig.start()
        let coordinator = AppCoordinator(controller: rig.controller)
        final class Log { var entries: [String] = [] }
        let log = Log()
        coordinator.terminateApp = { [unowned coordinator] in
            log.entries.append(coordinator.didShutDown ? "terminate after shutdown" : "terminate before shutdown")
        }
        #expect(!coordinator.didShutDown)
        coordinator.quit()
        coordinator.quit()   // a second request waits for the same shutdown
        for _ in 0..<300 where log.entries.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(log.entries == ["terminate after shutdown", "terminate after shutdown"])
        #expect(rig.fakeIPC.stopped && rig.workspace.stopped == 1)   // the controller shut down exactly once
    }
}
