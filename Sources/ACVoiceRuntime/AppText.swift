import ACVoiceFlow
import Foundation

/// German strings of the menu, the onboarding window and the status lines. Company style: active voice, short
/// sentences, no participle or noun fragments, no subjunctive, plain hyphen, no colons or dashes inside sentences.
public enum AppText {
    // MARK: Menu
    public static let listen = "Zuhören"
    public static let refreshIndex = "Index aktualisieren"
    public static let setup = "Einrichten …"
    public static let launchAtLogin = "Beim Anmelden starten"
    public static let openLoginItems = "Anmeldeobjekte öffnen …"
    public static let diagnostics = "Diagnose"
    public static let selfTest = "Spracherkennung testen"
    public static let chromeTest = "Chrome testen"
    public static let overlayDemo = "Overlay vorführen"
    public static let copyDiagnostics = "Diagnose kopieren"
    public static let quit = "Beenden"

    // MARK: Status lines
    public static let ready = "Bereit"
    public static let phaseListening = "Hört zu"
    public static let phaseProcessing = "Verarbeitet den Befehl"
    public static let phaseChoices = "Wartet auf deine Auswahl"
    public static let phaseOpening = "Öffnet Chrome"
    public static let phaseSuccess = "Hat die Seite geöffnet"
    public static let phaseError = "Zeigt einen Fehler"
    public static let tokenMissing = "AC-Token fehlt"
    public static let tokenInvalid = "AC lehnt den Token ab"
    public static let tokenUnreadable = "Der Schlüsselbund antwortet nicht"
    public static let userIdMissing = "AC-Benutzer-ID fehlt"
    public static let micMissing = "Das Mikrofon braucht deine Freigabe"
    /// Chrome's Automation was never asked for: every open makes a new tab.
    public static let chromeAutomationMissing = "Erlaube die Chrome-Steuerung in der Einrichtung"
    public static let speechWarming = FlowText.loadingModel
    public static let speechUnavailable = FlowText.modelUnavailable
    public static let ipcUnavailable = "Stream Deck erreicht AC Voice nicht"
    public static let indexEmpty = "Der Index ist leer"
    public static func indexCount(_ n: Int) -> String { n == 1 ? "1 Projekt im Index" : "\(n) Projekte im Index" }
    public static let selfTestRunning = "Prüft die Spracherkennung …"
    public static func selfTestPassed(ms: Double) -> String { "Spracherkennung antwortet in \(Int(ms.rounded())) ms" }
    public static let demoRunning = "Führt das Overlay vor"
    public static let loginItemFailed = "macOS ändert das Anmeldeobjekt nicht"
    public static let diagnosticsCopied = "Die Diagnose liegt in der Zwischenablage"

    // Chrome test.
    public static let chromeTestRunning = "Testet Chrome …"
    public static func chromeTest(_ r: OpenResult) -> String {
        switch r {
        case .reused: return "Chrome nutzt den vorhandenen AC-Tab"
        case .newTab: return "Chrome öffnet einen neuen Tab"
        case .newWindow: return "Chrome öffnet ein neues Fenster"
        case .launched: return "Chrome startet mit der Seite"
        case .fallback(.denied): return "AC Voice darf Chrome nicht steuern. Erlaube es in den Systemeinstellungen."
        case .fallback(.undetermined): return "AC Voice darf Chrome noch nicht steuern. Erlaube es in der Einrichtung."
        case .fallback(.other): return "Chrome öffnet die Seite ohne Steuerung"
        }
    }
    public static let chromeTestFailed = "Chrome öffnet die Seite nicht"
    public static func chromeFront(_ frontmost: Bool) -> String {
        frontmost ? "Chrome kam nach vorne" : "Chrome blieb im Hintergrund"
    }

    // MARK: Onboarding
    public static let onboardingTitle = "AC Voice einrichten"
    public static let onboardingIntro = "AC Voice braucht einen AC-Token, das Mikrofon und die Chrome-Steuerung. macOS fragt jede Freigabe nur einmal."
    public static let done = "Fertig"
    /// Above "Fertig": how to try it.
    public static func tryIt(hotkey: String?) -> String {
        hotkey.map { "Drück \($0) und sag „Meine Aufgaben“." } ?? "Klicke in der Menüleiste auf Zuhören und sag „Meine Aufgaben“."
    }

    public static let tokenTitle = "AC-Token"
    public static let tokenStored = "Der Schlüsselbund enthält den Token"
    public static let tokenNone = "Der Schlüsselbund enthält keinen Token"
    public static let tokenRejected = "AC lehnt den Token ab. Übernimm einen neuen Token."
    public static let tokenUserId = "Der Token enthält keine Benutzer-ID. Trage userId in config.json ein."
    public static let tokenImport = "Aus ac-mcp übernehmen"
    public static let tokenImportHint = "AC Voice liest .ac-token-cache oder .env im ac-mcp-Ordner und ändert dort nichts."
    public static let tokenPastePlaceholder = "Token einfügen"
    public static let tokenSave = "Speichern"
    public static let tokenReplace = "Anderen Token einfügen"
    public static let tokenImportFailed = "ac-mcp liefert keinen Token"

    public static let micTitle = "Mikrofon"
    public static let micGranted = "Erlaubt"
    public static let micNotDetermined = "Noch nicht erlaubt"
    public static let micDenied = "Du hast das Mikrofon abgelehnt. Erlaube es in den Systemeinstellungen."
    public static let micRequest = "Mikrofon erlauben"

    public static let chromeTitle = "Chrome"
    public static let chromeGranted = "Steuerung erlaubt"
    public static let chromeNotDetermined = "Steuerung noch nicht erlaubt. Ohne sie öffnet AC Voice jede Seite in einem neuen Tab."
    public static let chromeDenied = "Du hast die Steuerung abgelehnt. AC Voice öffnet deshalb jede Seite in einem neuen Tab."
    public static let chromeNotRunning = "Starte Chrome für diesen Schritt."
    public static let chromeUnknown = "AC Voice kennt den Status nicht"
    public static let chromeRequest = "Steuerung erlauben"

    public static let speechTitle = "Sprachmodell"
    public static let speechReady = "Bereit"
    public static let speechRun = "Spracherkennung testen"
    public static let speechRecognitionRequest = "Spracherkennung erlauben"

    public static let streamDeckTitle = "Stream Deck"
    public static let streamDeckConnected = "Das Plugin ist verbunden"
    public static func streamDeckMissing(folder: String) -> String {
        "Das Plugin fehlt. Installiere es mit npm install, npm run build und npm run link im Ordner \(folder)."
    }
    public static let streamDeckCopy = "Befehle kopieren"
    /// The Info.plist key bundle.sh writes the source folder to (the folder with Package.swift).
    public static let sourceRootKey = "ACVoiceSourceRoot"
    /// The plugin's folder: the absolute path when the bundle knows its sources, else a hint.
    public static func streamDeckFolder(sourceRoot: String?) -> String {
        sourceRoot.map { ($0 as NSString).appendingPathComponent("streamdeck") } ?? "ac-voice/streamdeck"
    }
    /// The commands "Befehle kopieren" puts on the pasteboard. Without a known source folder the user runs them in
    /// ac-voice/streamdeck.
    public static func streamDeckCommands(sourceRoot: String?) -> String {
        let build = "npm install && npm run build && npm run link"
        guard let sourceRoot else { return "cd ac-voice/streamdeck && " + build }
        return "cd \"\(streamDeckFolder(sourceRoot: sourceRoot))\" && " + build
    }

    public static let autostartTitle = "Autostart"
    public static let autostartOff = "Startet nicht beim Anmelden"

    public static let openSettings = "Systemeinstellungen öffnen"
    public static let checking = "Prüft …"

    /// Every fixed string, for style checks.
    public static var all: [String] {
        [listen, refreshIndex, setup, launchAtLogin, openLoginItems, diagnostics, selfTest, chromeTest, overlayDemo,
         copyDiagnostics, quit, ready, phaseListening, phaseProcessing, phaseChoices, phaseOpening, phaseSuccess,
         phaseError, tokenMissing, tokenInvalid, tokenUnreadable, userIdMissing, micMissing, chromeAutomationMissing,
         ipcUnavailable, indexEmpty, indexCount(1), indexCount(42), selfTestRunning, selfTestPassed(ms: 812),
         demoRunning, loginItemFailed, diagnosticsCopied, chromeTestRunning, chromeTest(.reused), chromeTest(.newTab),
         chromeTest(.newWindow), chromeTest(.launched), chromeTest(.fallback(.denied)),
         chromeTest(.fallback(.undetermined)), chromeTest(.fallback(.other)), chromeTestFailed, chromeFront(true),
         chromeFront(false), onboardingTitle, onboardingIntro, done, tryIt(hotkey: "⌃⌥Leertaste"), tryIt(hotkey: nil),
         tokenTitle, tokenStored, tokenNone, tokenRejected, tokenUserId, tokenImport, tokenImportHint,
         tokenPastePlaceholder, tokenSave, tokenReplace, tokenImportFailed, micTitle, micGranted, micNotDetermined,
         micDenied, micRequest, chromeTitle, chromeGranted, chromeNotDetermined, chromeDenied, chromeNotRunning,
         chromeUnknown, chromeRequest, speechTitle, speechReady, speechRun, speechRecognitionRequest, streamDeckTitle,
         streamDeckConnected, streamDeckMissing(folder: "ac-voice/streamdeck"), streamDeckCopy, autostartTitle,
         autostartOff, openSettings, checking]
    }
}
