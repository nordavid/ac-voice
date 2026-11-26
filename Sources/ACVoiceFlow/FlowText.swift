import Foundation
import ACVoiceCore

/// The overlay's strings in one language: `FlowText.de`, `FlowText.en` or `FlowText(language)`. Every text sits with
/// both languages side by side; the flow picks the table of `FlowEnv.language`.
///
/// German follows the company style: active voice, short sentences, no participle or noun fragments, no subjunctive,
/// plain hyphen, no colons or dashes inside sentences. The overlay speaks as "ich" ("Ich höre nichts").
/// English: plain, short, active, sentence case, "you" form, no exclamation marks. The overlay speaks as "I".
/// English example phrases use the English command words ("my tasks", "cancel", "more", "number two").
public struct FlowText: Sendable, Equatable {
    public let language: AppLanguage

    public init(_ language: AppLanguage) { self.language = language }

    public static let de = FlowText(.de)
    public static let en = FlowText(.en)

    private func t(_ de: String, _ en: String) -> String { language == .de ? de : en }
    /// Opening and closing quote marks: „…“ in German, “…” in English.
    public func quote(_ s: String) -> String { t("„\(s)“", "“\(s)”") }

    public var loadingModel: String { t("Sprachmodell lädt", "Speech model is loading") }
    public var myTasks: String { t("Meine Aufgaben", "My tasks") }

    // Retry (listening again) and the error after the second failure.
    public var notUnderstoodRetry: String { t("Das verstehe ich nicht. Sag es nochmal.", "I didn’t get that. Say it again.") }
    public var notUnderstood: String { t("Das verstehe ich nicht", "I didn’t get that") }
    public var projectNotRecognizedRetry: String { t("Welches Projekt? Sag es nochmal.", "Which project? Say it again.") }
    public var projectNotRecognized: String { t("Ich finde das Projekt nicht", "I can’t find that project") }
    public var nothingHeardRetry: String { t("Ich höre nichts. Sag es nochmal.", "I can’t hear anything. Say it again.") }
    public var nothingHeard: String { t("Ich höre nichts", "I can’t hear anything") }

    // Choices.
    public var sayNumber: String { t("Sag eine Zahl", "Say a number") }
    public var sayYesOrOne: String { t("Sag ja oder nein", "Say yes or no") }
    public var noMoreChoices: String { t("Mehr Einträge gibt es nicht", "There are no more entries") }
    public var selectionFailed: String { t("Ich verstehe die Auswahl nicht", "I didn’t get your choice") }
    /// An answer that fits no row: "„Hi.“ passt zu keiner Zeile. Sag eine Zahl.", "“Hi.” matches no row. Say a number."
    public func unclearAnswer(_ heard: String) -> String {
        heard.isEmpty ? sayNumber : t("\(quote(heard)) passt zu keiner Zeile. \(sayNumber).",
                                      "\(quote(heard)) matches no row. \(sayNumber).")
    }
    /// An answer that fits some rows: "„Website“ passt zu 2 Zeilen", "“Website” matches 2 rows".
    public func narrowed(_ heard: String, count: Int) -> String {
        let rows = count == 1 ? t("einer Zeile", "one row") : t("\(count) Zeilen", "\(count) rows")
        return heard.isEmpty ? t("Das passt zu \(rows)", "That matches \(rows)") : t("\(quote(heard)) passt zu \(rows)", "\(quote(heard)) matches \(rows)")
    }

    // Tickets.
    public func searchingTicket(_ n: Int) -> String { t("Suche Ticket \(n) …", "Looking for ticket \(n)…") }
    public func ticketNotFound(_ n: Int, code: String? = nil) -> String {
        code.map { t("\($0) hat kein Ticket \(n)", "\($0) has no ticket \(n)") } ?? t("AC kennt kein Ticket \(n)", "AC has no ticket \(n)")
    }
    public var ticketTrashed: String { t("Das Ticket liegt im Papierkorb", "The ticket is in the trash") }
    /// "Ticket 412 · WWT: Website Relaunch" (the same in both languages).
    public func ticketTitle(_ n: Int, project: String?) -> String {
        project.map { "Ticket \(n) · \($0)" } ?? "Ticket \(n)"
    }
    /// Live preview for a list: "4 WWT-Projekte" or "5 Projekte", "4 WWT projects" or "5 projects".
    public func projectCount(_ n: Int, code: String?) -> String {
        code.map { t("\(n) \($0)-Projekte", "\(n) \($0) projects") } ?? t("\(n) Projekte", "\(n) projects")
    }

    // Data, Chrome, speech.
    public var noProjectData: String { t("Die Projektliste fehlt", "The project list is missing") }
    public var acUnreachable: String { t("AC antwortet nicht", "AC is not responding") }
    /// A 401 of AC (German: `ACError.unauthorized.userMessage`, same text).
    public var tokenRejected: String { t("AC lehnt den Token ab", "AC rejects the token") }
    public var openFailed: String { t("Chrome öffnet die Seite nicht", "Chrome does not open the page") }
    public var chromeTimeout: String { t("Chrome reagiert nicht", "Chrome is not responding") }
    /// Success after the NSWorkspace fallback because Automation is denied.
    public var automationHint: String {
        t("AC Voice öffnet einen neuen Tab. Erlaube die Chrome-Steuerung in den Systemeinstellungen.",
          "AC Voice opens a new tab. Allow Chrome control in System Settings.")
    }
    /// Success after the NSWorkspace fallback because Automation was never asked for (once per app run).
    public var automationSetupHint: String {
        t("AC Voice öffnet einen neuen Tab. Erlaube die Chrome-Steuerung in der Einrichtung.",
          "AC Voice opens a new tab. Allow Chrome control in the setup window.")
    }
    public var micDenied: String { t("Erlaube das Mikrofon in der Einrichtung", "Allow the microphone in the setup window") }
    /// No input device, or the device failed or kept changing (`SpeechError.sourceFailed`, `.invalidInputFormat`).
    public var noInput: String { t("Mikrofon fehlt", "No microphone found") }
    /// Speech assets missing or the analyzer could not be prepared (`SpeechError.assetsUnavailable`, `.analyzerFailed`).
    public var modelUnavailable: String { t("Sprachmodell fehlt", "Speech model is missing") }
    /// The utterance ended, but the model did not get ready within `FlowTimings.coldFinalize`.
    public var modelStillLoading: String { t("Sprachmodell lädt noch", "Speech model is still loading") }
    public var speechFailed: String { t("Die Spracherkennung meldet einen Fehler", "Speech recognition reports an error") }
    public var micNotReady: String { t("Mikrofon startet nicht", "Microphone does not start") }

    // Next steps under an error card.
    public var setupIsOpen: String { t("Die Einrichtung ist offen", "The setup window is open") }
    public var tryMyTasks: String { t("Sag zum Beispiel \(quote("Meine Aufgaben"))", "For example, say \(quote("my tasks"))") }
    public var checkNetwork: String { t("Prüfe die Internetverbindung", "Check your internet connection") }
    public var signInAgain: String { t("Melde dich in der Einrichtung neu an", "Sign in again in the setup window") }

    public func failure(_ f: SpeechFailure) -> String {
        switch f {
        case .micDenied: return micDenied
        case .noInput: return noInput
        case .modelUnavailable: return modelUnavailable
        case .engine: return speechFailed
        }
    }

    /// The next step shown under an error card, if the error has one. `message` is an error text of this language.
    public func hint(forError message: String) -> String? {
        switch message {
        case micDenied: return setupIsOpen
        case nothingHeard: return tryMyTasks
        case acUnreachable: return checkNetwork
        case tokenRejected: return signInAgain
        default: return nil
        }
    }

    /// Every fixed string and a sample of each formatted one, for style checks.
    public var all: [String] {
        [loadingModel, myTasks, notUnderstoodRetry, notUnderstood, projectNotRecognizedRetry, projectNotRecognized,
         nothingHeardRetry, nothingHeard, sayNumber, sayYesOrOne, noMoreChoices, selectionFailed, ticketTrashed,
         noProjectData, acUnreachable, tokenRejected, openFailed, chromeTimeout, automationHint, automationSetupHint,
         micDenied, noInput, modelUnavailable, modelStillLoading, speechFailed, micNotReady, setupIsOpen, tryMyTasks,
         checkNetwork, signInAgain,
         searchingTicket(412), ticketNotFound(412), ticketNotFound(412, code: "WWT"),
         ticketTitle(412, project: "WWT: Website Relaunch"), projectCount(4, code: "WWT"), projectCount(5, code: nil),
         unclearAnswer("Hi."), narrowed("Website", count: 2), narrowed("Website", count: 1), narrowed("", count: 2)]
    }
}
