import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import Foundation

/// The strings of the menu, the setup window and the status lines in one language: `AppText.de`, `AppText.en` or
/// `AppText(language)`. Every text sits with both languages side by side.
///
/// German follows the company style: active voice, short sentences, no participle or noun fragments, no subjunctive,
/// plain hyphen, no colons or dashes inside sentences. English: plain, short, active, "you" form, no exclamation marks,
/// the ellipsis right after the word ("Set Up…", German "Einrichten …"). English uses title case for menu items,
/// buttons, links, disclosure labels, window titles and row headings ("Set Up…"), and sentence case for sentences,
/// status lines, hints, field labels and switch labels. English example phrases use the English command words
/// ("my tasks").
public struct AppText: Sendable, Equatable {
    public let language: AppLanguage

    public init(_ language: AppLanguage) { self.language = language }

    public static let de = AppText(.de)
    public static let en = AppText(.en)

    private func t(_ de: String, _ en: String) -> String { language == .de ? de : en }
    /// The overlay's texts in the same language.
    var flow: FlowText { FlowText(language) }

    // MARK: Menu
    public var listen: String { t("Zuhören", "Listen") }
    public var refreshIndex: String { t("Index aktualisieren", "Refresh Index") }
    public var setup: String { t("Einrichten …", "Set Up…") }
    public var launchAtLogin: String { t("Beim Anmelden starten", "Start at Login") }
    /// The setup window's switch: a control label, so English keeps sentence case.
    public var launchAtLoginSwitch: String { t("Beim Anmelden starten", "Start at login") }
    public var openLoginItems: String { t("Anmeldeobjekte öffnen …", "Open Login Items…") }
    public var diagnostics: String { t("Diagnose", "Diagnostics") }
    public var selfTest: String { t("Spracherkennung testen", "Test Speech Recognition") }
    public var chromeTest: String { t("Chrome testen", "Test Chrome") }
    public var overlayDemo: String { t("Overlay vorführen", "Show Overlay Demo") }
    public var copyDiagnostics: String { t("Diagnose kopieren", "Copy Diagnostics") }
    public var quit: String { t("Beenden", "Quit") }

    /// VoiceOver label and tooltip of the menu bar icon.
    public func iconLabel(phase: FlowPhase, attention: Bool) -> String {
        switch phase {
        case .idle:
            return attention ? t("AC Voice braucht die Einrichtung", "AC Voice needs setup")
                : t("AC Voice ist bereit", "AC Voice is ready")
        case .listening, .retry: return t("AC Voice hört zu", "AC Voice is listening")
        case .processing, .opening: return t("AC Voice verarbeitet den Befehl", "AC Voice is processing the command")
        case .choices: return t("AC Voice wartet auf deine Auswahl", "AC Voice is waiting for your choice")
        case .success: return t("AC Voice hat die Seite geöffnet", "AC Voice opened the page")
        case .error: return t("AC Voice meldet einen Fehler", "AC Voice reports an error")
        }
    }

    // MARK: Status lines
    public var ready: String { t("Bereit", "Ready") }
    public var phaseListening: String { t("Hört zu", "Listening") }
    public var phaseProcessing: String { t("Verarbeitet den Befehl", "Processing the command") }
    public var phaseChoices: String { t("Wartet auf deine Auswahl", "Waiting for your choice") }
    public var phaseOpening: String { t("Öffnet Chrome", "Opening Chrome") }
    public var phaseSuccess: String { t("Hat die Seite geöffnet", "Opened the page") }
    public var phaseError: String { t("Zeigt einen Fehler", "Showing an error") }
    public var tokenMissing: String { t("Melde dich in der Einrichtung bei AC an", "Sign in to AC in the setup window") }
    public var tokenInvalid: String {
        t("AC lehnt den Token ab. Melde dich in der Einrichtung neu an.",
          "AC rejects the token. Sign in again in the setup window.")
    }
    public var tokenUnreadable: String { t("Der Schlüsselbund antwortet nicht", "The keychain is not responding") }
    public var userIdMissing: String { t("AC-Benutzer-ID fehlt", "AC user ID is missing") }
    public var micMissing: String { t("Das Mikrofon braucht deine Freigabe", "The microphone needs your permission") }
    /// Chrome's Automation was never asked for: every open makes a new tab.
    public var chromeAutomationMissing: String {
        t("Erlaube die Chrome-Steuerung in der Einrichtung", "Allow Chrome control in the setup window")
    }
    public var speechWarming: String { flow.loadingModel }
    public var speechUnavailable: String { flow.modelUnavailable }
    public var ipcUnavailable: String { t("Stream Deck erreicht AC Voice nicht", "Stream Deck cannot reach AC Voice") }
    public var indexEmpty: String { t("Der Index ist leer", "The index is empty") }
    public func indexCount(_ n: Int) -> String {
        n == 1 ? t("1 Projekt im Index", "1 project in the index") : t("\(n) Projekte im Index", "\(n) projects in the index")
    }
    public var selfTestRunning: String { t("Prüft die Spracherkennung …", "Checking speech recognition…") }
    public func selfTestPassed(ms: Double) -> String {
        let n = Int(ms.rounded())
        return t("Spracherkennung antwortet in \(n) ms", "Speech recognition responds in \(n) ms")
    }
    public var demoRunning: String { t("Führt das Overlay vor", "Showing the overlay demo") }
    public var loginItemFailed: String { t("macOS ändert das Anmeldeobjekt nicht", "macOS did not change the login item") }
    public var diagnosticsCopied: String {
        t("Die Diagnose liegt in der Zwischenablage", "The diagnostics are on the clipboard")
    }

    // Chrome test.
    public var chromeTestRunning: String { t("Testet Chrome …", "Testing Chrome…") }
    public func chromeTest(_ r: OpenResult) -> String {
        switch r {
        case .reused: return t("Chrome nutzt den vorhandenen AC-Tab", "Chrome uses the open AC tab")
        case .newTab: return t("Chrome öffnet einen neuen Tab", "Chrome opens a new tab")
        case .newWindow: return t("Chrome öffnet ein neues Fenster", "Chrome opens a new window")
        case .launched: return t("Chrome startet mit der Seite", "Chrome starts with the page")
        case .fallback(.denied):
            return t("AC Voice darf Chrome nicht steuern. Erlaube es in den Systemeinstellungen.",
                     "AC Voice is not allowed to control Chrome. Allow it in System Settings.")
        case .fallback(.undetermined):
            return t("AC Voice darf Chrome noch nicht steuern. Erlaube es in der Einrichtung.",
                     "AC Voice is not allowed to control Chrome yet. Allow it in the setup window.")
        case .fallback(.other): return t("Chrome öffnet die Seite ohne Steuerung", "Chrome opens the page without control")
        }
    }
    public var chromeTestFailed: String { flow.openFailed }
    public func chromeFront(_ frontmost: Bool) -> String {
        frontmost ? t("Chrome kam nach vorne", "Chrome came to the front")
            : t("Chrome blieb im Hintergrund", "Chrome stayed in the background")
    }

    // MARK: Onboarding
    public var onboardingTitle: String { t("AC Voice einrichten", "Set Up AC Voice") }
    public var onboardingIntro: String {
        t("AC Voice braucht dein AC-Konto, das Mikrofon und die Chrome-Steuerung. macOS fragt jede Freigabe nur einmal.",
          "AC Voice needs your AC account, the microphone and Chrome control. macOS asks for each permission only once.")
    }
    public var done: String { t("Fertig", "Done") }
    /// Left of "Fertig": how to try it. `hotkey`: the shortcut as `hotkey(_:)` names it.
    public func tryIt(hotkey: String?) -> String {
        let phrase = t("„Meine Aufgaben“", "“my tasks”")
        return hotkey.map { t("Drück \($0) und sag \(phrase).", "Press \($0) and say \(phrase).") }
            ?? t("Klicke in der Menüleiste auf \(listen) und sag \(phrase).",
                 "Click \(listen) in the menu bar and say \(phrase).")
    }

    /// The shortcut as the menu and the setup window name it: "⌃⌥Leertaste", "⌃⌥Space". `Hotkey.display` names the
    /// keys in German; English swaps in the English key names.
    public func hotkey(_ hotkey: Hotkey) -> String {
        let display = hotkey.display
        guard language == .en else { return display }
        for (de, en) in Self.englishKeyNames where display.hasSuffix(de) {
            return String(display.dropLast(de.count)) + en
        }
        // "⌥Taste 80": a key without a layout-independent name.
        if let r = display.range(of: "Taste ") { return display.replacingCharacters(in: r, with: "Key ") }
        return display
    }

    /// German key names of `Hotkey.display` and their English names.
    static let englishKeyNames: [(String, String)] = [
        ("Leertaste", "Space"), ("Pos1", "Home"), ("Ende", "End"), ("Bild auf", "Page Up"), ("Bild ab", "Page Down"),
    ]

    // The ActiveCollab row: address, sign-in, token sign-in.
    public var tokenTitle: String { "ActiveCollab" }
    /// Signed in: names the AC host, so the row shows which ActiveCollab the app uses.
    public func tokenStored(host: String) -> String {
        t("Angemeldet bei \(host). Der Schlüsselbund enthält den Token.",
          "Signed in to \(host). The keychain holds the token.")
    }
    public var tokenNone: String { t("Melde dich mit deinem AC-Konto an.", "Sign in with your AC account.") }
    public var tokenRejected: String { t("AC lehnt den Token ab. Melde dich neu an.", "AC rejects the token. Sign in again.") }
    public var tokenUserId: String {
        t("Der Token enthält keine Benutzer-ID. Trage userId in config.json ein.",
          "The token has no user ID. Add userId to config.json.")
    }
    public var addressLabel: String { t("AC-Adresse", "AC address") }
    public var addressPlaceholder: String { t("https://ac.example.com", "https://ac.example.com") }
    public var emailLabel: String { t("E-Mail", "Email") }
    public var emailPlaceholder: String { t("name@example.com", "name@example.com") }
    public var passwordLabel: String { t("Passwort", "Password") }
    public var signIn: String { t("Anmelden", "Sign In") }
    public var signingIn: String { t("Meldet dich an …", "Signing you in…") }
    public var signInHint: String {
        t("AC stellt einen Token für AC Voice aus. AC Voice speichert dein Passwort nicht.",
          "AC issues a token for AC Voice. AC Voice does not store your password.")
    }
    /// The link that opens the sign-in form again, with the address field.
    public var signInAgain: String { t("Neu anmelden oder Adresse ändern", "Sign In Again or Change the Address") }
    public var tokenSignIn: String { t("Mit Token anmelden", "Sign In with a Token") }
    public var tokenSignInHint: String {
        t("Nutze den Token bei Konten ohne Passwort, zum Beispiel mit Single Sign-on. AC Voice speichert ihn im Schlüsselbund.",
          "For accounts without a password, for example with single sign-on. AC Voice stores the token in the keychain.")
    }
    public var tokenPastePlaceholder: String { t("Token einfügen", "Paste the token") }
    public var tokenSave: String { t("Speichern", "Save") }
    public var tokenSaveFailed: String { t("Der Schlüsselbund speichert den Token nicht.", "The keychain does not save the token.") }
    public var loginRejected: String { t("AC lehnt E-Mail oder Passwort ab.", "AC rejects the email or password.") }
    public var loginOffline: String { flow.acUnreachable + ". " + flow.checkNetwork + "." }
    /// Nothing answers like ActiveCollab at the address: unknown host, refused connection, certificate, 404 or an
    /// answer that is no token.
    public var loginAddress: String {
        t("AC antwortet unter dieser Adresse nicht. Prüfe die AC-Adresse.",
          "AC is not responding at this address. Check the AC address.")
    }
    public var loginFailed: String { t("AC meldet einen Fehler. Versuche es später noch einmal.", "AC reports an error. Try again later.") }
    public var addressInvalid: String { t("Prüfe die AC-Adresse. Sie beginnt mit https.", "Check the AC address. It must start with https.") }
    public var addressMissing: String { t("Trage die Adresse deines AC ein.", "Enter the address of your AC.") }

    /// The token row's message after a failed sign-in. Never shows the password, the token or the answer of AC.
    /// A wrong address is the most likely first failure, so errors that point to it say so.
    public func loginMessage(_ error: any Error) -> String {
        switch error as? ACError {
        case .credentialsRejected?: return loginRejected
        case .transport(let code)?: return Self.addressTransportCodes.contains(code) ? loginAddress : loginOffline
        case .http(status: 404, _)?, .http(status: 405, _)?, .unexpectedRedirect?, .decoding?: return loginAddress
        case .insecureBaseURL?: return addressInvalid
        case .keychain?, .noToken?: return tokenSaveFailed
        default: return loginFailed
        }
    }

    /// URLError codes of a host that does not exist, refuses the connection or shows a certificate that does not fit.
    /// Offline, a lost connection and a timeout keep `loginOffline`.
    static let addressTransportCodes: Set<Int> = Set([
        URLError.Code.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed,
        .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected, .badURL, .unsupportedURL,
    ].map(\.rawValue))

    public var micTitle: String { t("Mikrofon", "Microphone") }
    public var micGranted: String { t("Erlaubt", "Allowed") }
    public var micNotDetermined: String { t("Noch nicht erlaubt", "Not allowed yet") }
    public var micDenied: String {
        t("Du hast das Mikrofon abgelehnt. Erlaube es in den Systemeinstellungen.",
          "You denied the microphone. Allow it in System Settings.")
    }
    public var micRequest: String { t("Mikrofon erlauben", "Allow Microphone") }

    public var chromeTitle: String { "Chrome" }
    public var chromeGranted: String { t("Steuerung erlaubt", "Control allowed") }
    public var chromeNotDetermined: String {
        t("Steuerung noch nicht erlaubt. Ohne sie öffnet AC Voice jede Seite in einem neuen Tab.",
          "Control is not allowed yet. Without it AC Voice opens every page in a new tab.")
    }
    public var chromeDenied: String {
        t("Du hast die Steuerung abgelehnt. AC Voice öffnet deshalb jede Seite in einem neuen Tab.",
          "You denied control. So AC Voice opens every page in a new tab.")
    }
    public var chromeNotRunning: String { t("Starte Chrome für diesen Schritt.", "Start Chrome for this step.") }
    public var chromeUnknown: String { t("AC Voice kennt den Status nicht", "AC Voice does not know the status") }
    public var chromeRequest: String { t("Steuerung erlauben", "Allow Control") }

    public var speechTitle: String { t("Sprachmodell", "Speech Model") }
    public var speechReady: String { t("Bereit", "Ready") }
    public var speechRun: String { selfTest }
    public var speechRecognitionRequest: String { t("Spracherkennung erlauben", "Allow Speech Recognition") }

    public var streamDeckTitle: String { "Stream Deck" }
    public var streamDeckConnected: String { t("Das Plugin ist verbunden", "The plugin is connected") }
    public func streamDeckMissing(folder: String) -> String {
        t("Das Plugin fehlt. Installiere es mit npm install, npm run build und npm run link im Ordner \(folder).",
          "The plugin is missing. Install it with npm install, npm run build and npm run link in the folder \(folder).")
    }
    public var streamDeckCopy: String { t("Befehle kopieren", "Copy Commands") }
    /// A release build has no source folder: the plugin file comes from the GitHub release.
    public var streamDeckMissingRelease: String {
        t("Das Plugin fehlt. Lade die Plugin-Datei aus dem GitHub-Release und öffne sie mit einem Doppelklick.",
          "The plugin is missing. Download the plugin file from the GitHub release and double-click it.")
    }
    public var streamDeckOpenRelease: String { t("Release-Seite öffnen", "Open Release Page") }
    /// The repository's list of all releases.
    public static let releasesURL = URL(string: "https://github.com/nordavid/ac-voice/releases")!
    /// The release of `version` (tag vX.Y.Z) with the app and the plugin file of the same version. The setup window of
    /// a release build opens it, so an older app never gets a newer plugin. Without a version of three numbers (a
    /// bare `swift run` has no Info.plist), the list of all releases.
    public static func releasePageURL(version: String?) -> URL {
        let parts = version?.split(separator: ".", omittingEmptySubsequences: false) ?? []
        guard let version, parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }) else { return releasesURL }
        return URL(string: "https://github.com/nordavid/ac-voice/releases/tag/v\(version)")!
    }
    /// The Info.plist key bundle.sh writes the source folder to (the folder with Package.swift). Only a source build
    /// has it: a release build leaves it out (bundle.sh with EMBED_SOURCE_ROOT=0).
    public static let sourceRootKey = "ACVoiceSourceRoot"
    /// The plugin's folder in the source folder.
    public static func streamDeckFolder(sourceRoot: String) -> String {
        (sourceRoot as NSString).appendingPathComponent("streamdeck")
    }
    /// The commands "Befehle kopieren" puts on the pasteboard in a source build.
    public static func streamDeckCommands(sourceRoot: String) -> String {
        "cd \"\(streamDeckFolder(sourceRoot: sourceRoot))\" && npm install && npm run build && npm run link"
    }

    public var autostartTitle: String { "Autostart" }
    public var autostartOff: String { t("Startet nicht beim Anmelden", "Does not start at login") }

    public var openSettings: String { t("Systemeinstellungen öffnen", "Open System Settings") }
    public var checking: String { t("Prüft …", "Checking…") }

    // MARK: Texts of other modules

    /// `ACError.userMessage` in this language. German is `userMessage` itself; the English texts of a rejected token
    /// and an unreachable AC are the overlay's (`FlowText`), so the overlay finds their next step.
    public func acError(_ error: ACError) -> String {
        guard language == .en else { return error.userMessage }
        switch error {
        case .noToken: return "AC token is missing"
        case .unauthorized: return flow.tokenRejected
        case .credentialsRejected: return "AC rejects the email or password"
        case .notFound: return "AC does not know this page"
        case .transport: return flow.acUnreachable
        case .decoding: return "I don’t understand the answer from AC"
        case .keychain: return "The keychain is not responding"
        case .insecureBaseURL: return "The AC address needs https"
        case .endpointMissing, .http, .unexpectedRedirect, .invalidPath: return "AC reports an error"
        }
    }

    /// A German status text of another module (`ACError.userMessage`, the speech self-test, `SpeechError.message`)
    /// in this language. Unknown texts stay as they are.
    public func localized(_ german: String) -> String {
        guard language == .en else { return german }
        return Self.englishOfGerman[german] ?? german
    }

    /// Every `ACError.userMessage`, the speech self-test's messages and `SpeechError.message`, German to English.
    static let englishOfGerman: [String: String] = {
        var map: [String: String] = [:]
        for e in sampleACErrors { map[e.userMessage] = AppText.en.acError(e) }
        let speech: [SpeechError] = [.assetsUnavailable, .analyzerFailed(""), .sourceFailed(""), .invalidInputFormat,
                                     .invalidAudio("")]
        for e in speech { map[e.message(.de)] = e.message(.en) }
        // The German self-test (`SpeechSelfCheck`) reports these.
        map["Installiere eine deutsche Systemstimme"] = "Install a German system voice"
        map["Spracherkennung antwortet nicht"] = "Speech recognition is not responding"
        map["Spracherkennung bereit"] = "Speech recognition ready"
        map["Spracherkennung liefert keinen Text"] = "Speech recognition returns no text"
        map["Spracherkennung versteht den Testsatz nicht"] = "Speech recognition does not understand the test phrase"
        return map
    }()

    /// One value of every `ACError` case, for `englishOfGerman` and the tests.
    static let sampleACErrors: [ACError] = [
        .noToken, .unauthorized, .credentialsRejected, .notFound(path: "/x"), .endpointMissing(path: "/x"),
        .http(status: 500, path: "/x"), .unexpectedRedirect(path: "/x"), .decoding(path: "/x", detail: "x"),
        .transport(code: -1009), .invalidPath("/x"), .keychain(status: -25300), .insecureBaseURL,
    ]

    /// Every fixed string and a sample of each formatted one, for style checks.
    public var all: [String] {
        [listen, refreshIndex, setup, launchAtLogin, openLoginItems, diagnostics, selfTest, chromeTest, overlayDemo,
         copyDiagnostics, quit, ready, phaseListening, phaseProcessing, phaseChoices, phaseOpening, phaseSuccess,
         phaseError, tokenMissing, tokenInvalid, tokenUnreadable, userIdMissing, micMissing, chromeAutomationMissing,
         speechWarming, speechUnavailable, ipcUnavailable, indexEmpty, indexCount(1), indexCount(42), selfTestRunning,
         selfTestPassed(ms: 812), demoRunning, loginItemFailed, diagnosticsCopied, chromeTestRunning,
         chromeTest(.reused), chromeTest(.newTab), chromeTest(.newWindow), chromeTest(.launched),
         chromeTest(.fallback(.denied)), chromeTest(.fallback(.undetermined)), chromeTest(.fallback(.other)),
         chromeTestFailed, chromeFront(true), chromeFront(false), onboardingTitle, onboardingIntro, done,
         tryIt(hotkey: hotkey(.default)), tryIt(hotkey: nil), launchAtLoginSwitch,
         tokenTitle, tokenStored(host: "ac.example.test"), tokenNone, tokenRejected, tokenUserId, addressLabel,
         addressPlaceholder, emailLabel, emailPlaceholder, passwordLabel, signIn, signingIn, signInHint, signInAgain,
         tokenSignIn, tokenSignInHint, tokenPastePlaceholder, tokenSave, tokenSaveFailed, loginRejected, loginOffline,
         loginAddress, loginFailed, addressInvalid, addressMissing, micTitle, micGranted, micNotDetermined, micDenied,
         micRequest, chromeTitle, chromeGranted, chromeNotDetermined, chromeDenied, chromeNotRunning,
         chromeUnknown, chromeRequest, speechTitle, speechReady, speechRun, speechRecognitionRequest, streamDeckTitle,
         streamDeckConnected, streamDeckMissing(folder: "ac-voice/streamdeck"), streamDeckCopy,
         streamDeckMissingRelease, streamDeckOpenRelease, autostartTitle, autostartOff, openSettings, checking]
            + FlowPhase.allCases.flatMap { [iconLabel(phase: $0, attention: false), iconLabel(phase: $0, attention: true)] }
            + Self.sampleACErrors.map(acError)
    }
}
