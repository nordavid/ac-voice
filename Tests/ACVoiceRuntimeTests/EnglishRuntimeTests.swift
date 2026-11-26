import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import ACVoiceSystem
import ACVoiceUI
import Foundation
import Testing
@testable import ACVoiceRuntime

/// German left in an English text: umlauts, German quote marks and frequent German words.
private func germanLeftovers(_ s: String) -> [String] {
    var found = s.unicodeScalars.filter { "äöüÄÖÜß„".unicodeScalars.contains($0) }.map { String($0) }
    let words = Set(s.lowercased().split { !$0.isLetter }.map(String.init))
    let german: Set<String> = [
        "der", "die", "das", "und", "nicht", "ich", "du", "dein", "deine", "sag", "einrichtung", "mikrofon",
        "sprachmodell", "spracherkennung", "fehlt", "steuerung", "erlaube", "melde", "anmelden", "einen", "eine", "ist",
        "mit", "von", "noch", "kein", "keine", "bitte", "aufgaben", "meine", "zuhören", "beenden", "diagnose", "prüft",
        "schlüsselbund", "systemeinstellungen", "adresse", "passwort", "speichern", "befehle", "ordner", "fertig",
        "leertaste", "taste", "bereit", "hört", "öffnet", "zeigt", "projekte", "verbindung",
    ]
    found += words.intersection(german).sorted()
    return found
}

/// English style on top of the shared rules (`styleViolations`): no exclamation mark, no "would/could/should",
/// sentence case. A name spelled in lower case ("macOS", "npm") or an example address may start a text.
private func englishViolations(_ s: String) -> [String] {
    var v = styleViolations(s)
    if s.contains("!") { v.append("exclamation mark") }
    if s.contains(" …") { v.append("space before ellipsis") }
    let words = Set(s.lowercased().split { !$0.isLetter }.map(String.init))
    for w in ["would", "could", "should", "might"] where words.contains(w) { v.append(w) }
    let firstWord = s.split(separator: " ").first.map(String.init) ?? ""
    let exempt = ["macOS", "npm"].contains(firstWord) || firstWord.contains("://") || firstWord.contains("@")
    if let first = s.first, first.isLetter, !first.isUppercase, !exempt { v.append("sentence case") }
    return v
}

@Suite struct EnglishAppTextTests {
    @Test func everyEnglishTextIsFilledAndFreeOfGerman() {
        #expect(AppText.en.all.count == AppText.de.all.count)
        for s in AppText.en.all {
            #expect(!s.isEmpty, "\(s)")
            #expect(germanLeftovers(s).isEmpty, "\(s): \(germanLeftovers(s))")
            #expect(englishViolations(s).isEmpty, "\(s): \(englishViolations(s))")
        }
        let en = AppText.en
        for s in [en.listen, en.refreshIndex, en.setup, en.launchAtLogin, en.diagnostics, en.selfTest, en.chromeTest,
                  en.overlayDemo, en.copyDiagnostics, en.quit] {
            #expect(s.count <= 24, "\(s)")
        }
    }

    /// macOS labels: title case for menu items, buttons, links, disclosures, window titles and row headings. The setup
    /// window's switch keeps sentence case.
    @Test func labelsUseTitleCase() {
        let en = AppText.en
        let labels = [en.refreshIndex, en.setup, en.launchAtLogin, en.openLoginItems, en.selfTest, en.overlayDemo,
                      en.copyDiagnostics, en.onboardingTitle, en.signIn, en.signInAgain, en.tokenSignIn, en.micRequest,
                      en.chromeRequest, en.speechTitle, en.speechRecognitionRequest, en.streamDeckCopy]
        #expect(labels == ["Refresh Index", "Set Up…", "Start at Login", "Open Login Items…", "Test Speech Recognition",
                           "Show Overlay Demo", "Copy Diagnostics", "Set Up AC Voice", "Sign In",
                           "Sign In Again or Change the Address", "Sign In with a Token", "Allow Microphone",
                           "Allow Control", "Speech Model", "Allow Speech Recognition", "Copy Commands"])
        #expect(en.speechRun == en.selfTest)
        #expect(en.launchAtLoginSwitch == "Start at login")
        #expect(AppText.de.launchAtLoginSwitch == AppText.de.launchAtLogin)
    }

    /// Every German text has its English counterpart (brand names and fixed terms excepted).
    @Test func englishDiffersFromGerman() {
        let same: Set<String> = ["ActiveCollab", "Chrome", "Stream Deck", "Autostart", AppText.de.addressPlaceholder,
                                 AppText.de.emailPlaceholder]
        for (de, en) in zip(AppText.de.all, AppText.en.all) where !same.contains(de) {
            #expect(de != en, "\(de)")
        }
    }

    /// The English examples use the English command words, and the shortcut gets its English key name.
    @Test func examplesAndShortcutInEnglish() {
        let en = AppText.en
        #expect(en.hotkey(.default) == "⌃⌥Space" && AppText.de.hotkey(.default) == "⌃⌥Leertaste")
        #expect(en.hotkey(Hotkey(keyCode: 0, modifiers: Hotkey.controlKey)) == "⌃Key 0")
        #expect(en.hotkey(Hotkey(keyCode: 200, modifiers: Hotkey.optionKey)) == "⌥Key 200")
        #expect(en.hotkey(Hotkey(keyCode: 116, modifiers: Hotkey.cmdKey)) == "⌘Page Up")
        #expect(en.hotkey(Hotkey(keyCode: 96, modifiers: Hotkey.cmdKey)) == "⌘F5")
        #expect(en.hotkey(Hotkey(keyCode: 115, modifiers: Hotkey.cmdKey)) == "⌘Home")
        #expect(en.tryIt(hotkey: en.hotkey(.default)) == "Press ⌃⌥Space and say “my tasks”.")
        #expect(en.tryIt(hotkey: nil) == "Click Listen in the menu bar and say “my tasks”.")
        #expect(AppText.de.tryIt(hotkey: nil) == "Klicke in der Menüleiste auf Zuhören und sag „Meine Aufgaben“.")
    }

    /// AC's errors in English. A rejected token and an unreachable AC use the overlay's texts, so the overlay finds
    /// the next step for them.
    @Test func acErrorsInEnglish() {
        for e in AppText.sampleACErrors {
            let en = AppText.en.acError(e)
            #expect(AppText.de.acError(e) == e.userMessage)
            #expect(en != e.userMessage && germanLeftovers(en).isEmpty, "\(en)")
            #expect(AppText.en.localized(e.userMessage) == en)
        }
        #expect(AppText.en.acError(.unauthorized) == FlowText.en.tokenRejected)
        #expect(AppText.en.acError(.transport(code: -1009)) == FlowText.en.acUnreachable)
        #expect(AppText.en.loginMessage(ACError.credentialsRejected) == "AC rejects the email or password.")
        #expect(AppText.en.loginOffline == "AC is not responding. Check your internet connection.")
    }

    /// Status texts of the speech layer arrive in German; the English app shows them in English.
    @Test func otherModulesTextsInEnglish() {
        for german in ["Spracherkennung bereit", "Spracherkennung antwortet nicht", "Installiere eine deutsche Systemstimme",
                       SpeechError.assetsUnavailable.message, SpeechError.invalidInputFormat.message] {
            let en = AppText.en.localized(german)
            #expect(en != german && germanLeftovers(en).isEmpty, "\(german) -> \(en)")
            #expect(AppText.de.localized(german) == german)
        }
        #expect(AppText.en.localized("WWT: Website Relaunch") == "WWT: Website Relaunch")
    }

    @Test func systemTextsInEnglish() {
        let errors: [HotkeyError] = [.invalid, .registrationFailed(-9878), .registrationFailed(-1), .handlerInstallFailed(-1)]
        for e in errors {
            let en = e.message(.en)
            #expect(en != e.message(.de) && germanLeftovers(en).isEmpty && englishViolations(en).isEmpty, "\(en)")
        }
        #expect(HotkeyError.registrationFailed(-9878).message(.en) == "Another app uses the shortcut. Change hotkey in config.json.")
        for s in [LoginItemStatus.requiresApproval, .notFound] {
            let en = s.hint(.en) ?? ""
            #expect(!en.isEmpty && en != s.hint(.de) && germanLeftovers(en).isEmpty && englishViolations(en).isEmpty, "\(en)")
        }
        #expect(LoginItemStatus.enabled.hint(.en) == nil)
    }

    @Test func diagnosticsInEnglish() {
        var status = RuntimeStatus()
        status.token = .invalid
        status.selfCheck = SelfCheckResult(passed: true, elapsedMs: 812.4, message: "x")
        var lat = LatencyStats()
        lat.add(600)
        let input = DiagnosticsInput(
            appVersion: "0.1.0", build: "202611241500", osVersion: "Version 26.6", phase: .idle, status: status,
            microphone: .granted, speechRecognition: .notDetermined, automation: nil, loginItem: .disabled,
            hotkey: AppText.en.hotkey(.default), ipcClients: 2, index: Fixture.snapshot().stats,
            indexFetchedAt: Fixture.now.addingTimeInterval(-90), taskListsFetchedAt: nil,
            latencies: [.speechEndToFinal: lat], config: Fixture.config, now: Fixture.now, language: .en)
        let text = Diagnostics.text(input)
        #expect(text.contains("AC token: invalid") && text.contains("Self-test: passed, 812 ms"))
        #expect(text.contains("Index updated: 90 s ago, task lists never"))
        #expect(text.contains("Chrome control: Chrome is not running") && text.contains("Stream Deck: 2 connections"))
        #expect(text.contains("Shortcut: ⌃⌥Space") && text.contains("Language: en (config auto)"))
        #expect(text.contains("Latency speechEndToFinal: n=1, median 600 ms") && text.contains("Latency pressToMic: no samples"))
        #expect(germanLeftovers(text).isEmpty, "\(germanLeftovers(text))")
    }
}

/// The app on an English Mac: the controller resolves English once at launch, and every text follows.
@MainActor
@Suite struct EnglishScenarioTests {
    static func english(token: StoredToken = .present(userId: Fixture.userId), config: Config = Fixture.config) -> Rig {
        Rig(token: token, config: config, preferredLanguages: ["en-US", "de-DE"])
    }

    @Test func nothingHeardShowsEnglishTextsInTheOverlayAndOnTheKey() async throws {
        let rig = Self.english()
        await rig.start()
        #expect(rig.controller.language == .en && rig.controller.env.language == .en)
        await rig.listen()
        #expect(rig.model.language == .en && rig.fakeIPC.states.last?.lang == "en")
        let listening = OverlayViewState(model: try #require(rig.overlay.renders.last))
        #expect(listening.headline == .placeholder("I’m listening", dimmed: false))
        await rig.advance(FlowTimings().noSpeech + 0.1)
        #expect(rig.phase == .error && rig.model.message == "I can’t hear anything")
        #expect(rig.model.hint == "For example, say “my tasks”")
        #expect(rig.fakeIPC.states.last?.message == "I can’t hear anything" && rig.fakeIPC.states.last?.lang == "en")
        let card = OverlayViewState(model: try #require(rig.overlay.renders.last))
        #expect(card.accessibilityLabel == "Error. I can’t hear anything. For example, say “my tasks”")
    }

    @Test func menuAndStatusLinesInEnglish() async {
        let rig = Self.english()
        rig.permissions.microphone = .notDetermined
        await rig.start()
        let state = rig.controller.menuState()
        #expect(state.language == .en)
        #expect(state.statusLines.first == "Ready" && state.statusLines.contains("The microphone needs your permission"))
        #expect(state.statusLines.contains { $0.hasSuffix(" projects in the index") })
        let titles = StatusMenuModel.items(state).map(\.title).filter { !$0.isEmpty }
        for title in ["Listen", "Refresh Index", "Set Up…", "Start at Login", "Diagnostics", "Quit"] {
            #expect(titles.contains(title), "\(title)")
        }
        #expect(rig.controller.menuIcon.language == .en)
        #expect(StatusMenuModel.accessibilityLabel(phase: .idle, attention: true, language: .en) == "AC Voice needs setup")
        rig.controller.diagnosticsCopied()
        #expect(rig.controller.statusLines.contains("The diagnostics are on the clipboard"))
    }

    @Test func setupWindowInEnglish() async {
        let rig = Self.english(token: .missing)
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in })
        #expect(model.text == AppText.en)
        let titles = model.steps.map(\.title)
        #expect(titles == ["ActiveCollab", "Microphone", "Chrome", "Speech Model", "Stream Deck", "Autostart"])
        #expect(model.steps.first { $0.id == .token }?.status == "Sign in with your AC account.")
        #expect(model.tryItText == "Press ⌃⌥Space and say “my tasks”.")
        for step in model.steps {
            #expect(germanLeftovers(step.status).isEmpty, "\(step.status)")
            if let action = step.action { #expect(germanLeftovers(action.title).isEmpty, "\(action.title)") }
        }
        // A failed sign-in explains itself in English.
        rig.tokens.loginResult = .failure(.credentialsRejected)
        model.address = "https://ac.example.test"
        model.email = "max@example.test"
        model.password = "wrong"
        await model.login()
        #expect(model.steps.first { $0.id == .token }?.status == "AC rejects the email or password.")
    }

    /// A rejected token: the card and the menu name the next step in English.
    @Test func rejectedTokenInEnglish() async {
        let rig = Self.english()
        await rig.start()
        rig.index?.probeResult = .failure(.unauthorized)
        await rig.command("Ticket 47285")
        #expect(rig.phase == .error && rig.model.message == "AC rejects the token")
        #expect(rig.model.hint == "Sign in again in the setup window")
        #expect(rig.controller.statusLines.contains("AC rejects the token. Sign in again in the setup window."))
    }

    /// config.json "language" wins over the Mac's language.
    @Test func configLanguageOverridesTheMac() async {
        var config = Fixture.config
        config.language = "de"
        let rig = Self.english(config: config)
        await rig.start()
        #expect(rig.controller.language == .de && rig.controller.statusLines.first == "Bereit")
        await rig.listen()
        #expect(rig.fakeIPC.states.last?.lang == "de")
    }

    /// "my tasks" through the English commands opens the user's tasks with an English title.
    @Test func myTasksInEnglish() async {
        let rig = Self.english()
        await rig.start()
        await rig.command("my tasks")
        #expect(rig.chrome.opened == [Fixture.myTasksURL])
        #expect(rig.phase == .success && rig.model.message == "My tasks")
    }

    /// A greeting in front of a corrected command teaches no alias (review: WWT learned "hello", and "Hello, open the
    /// IT support" opened WWT: Maintenance).
    @Test func greetingBeforeACorrectionIsNoAlias() async {
        let rig = Self.english()
        await rig.start()
        for _ in 0..<2 {
            await rig.command("Hello, website relaunch")
            #expect(rig.phase == .retry)
            await rig.say("website relaunch")
            #expect(rig.phase == .choices)
            await rig.say("number one")
        }
        #expect(rig.chrome.opened == [Fixture.projectURL(628), Fixture.projectURL(628)])
        #expect(rig.controller.history.picks(for: "hello website relaunch") == [628: 2])
        #expect(rig.controller.env.interpreter.resolver.projects.filter { $0.code == "WWT" }.allSatisfy { !$0.aliases.contains("hello") })
        await rig.command("Hello, open the IT support")
        #expect(rig.chrome.opened.last == Fixture.projectURL(2077))
    }

    /// The overlay demo plays its command in English: the list, "number two", the open.
    @Test func demoRunsInEnglish() {
        let overlay = FakeOverlay()
        let clock = ManualClock(now: Fixture.now)
        let demo = OverlayDemo(overlay: overlay, clock: clock, language: .en)
        demo.start(loop: false)
        clock.advance(6.5)
        #expect(overlay.renders.allSatisfy { $0.language == .en })
        let list = overlay.renders.first { $0.phase == .choices }
        #expect(list?.choices.count == 4 && list?.transcript.text == "Open WWT")
        #expect(overlay.renders.contains { $0.phase == .choices && $0.answer.text == "Number two" })
        #expect(overlay.renders.first { $0.phase == .opening }?.preview == list?.choices[1].displayName)
        #expect(demo.scenarios.allSatisfy { $0.model.language == .en })
        demo.stop()
    }
}

/// The macOS permission prompts and AppKit's own texts follow the system language through the bundle's lproj folders
/// (scripts/bundle.sh copies Resources/de.lproj and Resources/en.lproj). English is the development region, so every
/// language other than German gets English, as in the app.
@Suite struct BundleLocalizationTests {
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")
    static let usageKeys = ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription", "NSAppleEventsUsageDescription"]

    static func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func developmentRegionIsEnglishWithBothLocalizations() throws {
        let info = try Self.plist(Self.resources.appendingPathComponent("Info.plist.in"))
        #expect(info["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(Set(info["CFBundleLocalizations"] as? [String] ?? []) == ["de", "en"])
        for key in Self.usageKeys {
            let text = info[key] as? String ?? ""
            #expect(!text.isEmpty && germanLeftovers(text).isEmpty, "\(key): \(text)")
        }
        let script = try String(contentsOf: Self.resources.deletingLastPathComponent().appendingPathComponent("scripts/bundle.sh"),
                                encoding: .utf8)
        #expect(script.contains("LPROJS=(de en)"))
    }

    @Test func everyLprojHasTheUsageDescriptions() throws {
        let info = try Self.plist(Self.resources.appendingPathComponent("Info.plist.in"))
        let en = try Self.plist(Self.resources.appendingPathComponent("en.lproj/InfoPlist.strings"))
        let de = try Self.plist(Self.resources.appendingPathComponent("de.lproj/InfoPlist.strings"))
        for key in Self.usageKeys {
            let english = try #require(en[key] as? String), german = try #require(de[key] as? String)
            #expect(english == info[key] as? String, "\(key)")
            #expect(germanLeftovers(english).isEmpty && englishViolations(english).isEmpty, "\(english)")
            #expect(german != english && styleViolations(german).isEmpty, "\(german)")
        }
    }
}
