import Foundation

/// German UI strings. Company style: active voice, short sentences, no participle or noun fragments, no subjunctive,
/// plain hyphen, no colons or dashes inside sentences. The overlay speaks as "ich" ("Ich höre nichts").
public enum FlowText {
    public static let loadingModel = "Sprachmodell lädt"
    public static let myTasks = "Meine Aufgaben"

    // Retry (listening again) and the error after the second failure.
    public static let notUnderstoodRetry = "Das verstehe ich nicht. Sag es nochmal."
    public static let notUnderstood = "Das verstehe ich nicht"
    public static let projectNotRecognizedRetry = "Welches Projekt? Sag es nochmal."
    public static let projectNotRecognized = "Ich finde das Projekt nicht"
    public static let nothingHeardRetry = "Ich höre nichts. Sag es nochmal."
    public static let nothingHeard = "Ich höre nichts"

    // Choices.
    public static let sayNumber = "Sag eine Zahl"
    public static let sayYesOrOne = "Sag ja oder nein"
    public static let noMoreChoices = "Mehr Einträge gibt es nicht"
    public static let selectionFailed = "Ich verstehe die Auswahl nicht"
    /// An answer that fits no row: "„Hi.“ passt zu keiner Zeile. Sag eine Zahl."
    public static func unclearAnswer(_ heard: String) -> String {
        heard.isEmpty ? sayNumber : "„\(heard)“ passt zu keiner Zeile. \(sayNumber)."
    }
    /// An answer that fits some rows: "„Website“ passt zu 2 Zeilen".
    public static func narrowed(_ heard: String, count: Int) -> String {
        let rows = count == 1 ? "einer Zeile" : "\(count) Zeilen"
        return heard.isEmpty ? "Das passt zu \(rows)" : "„\(heard)“ passt zu \(rows)"
    }

    // Tickets.
    public static func searchingTicket(_ n: Int) -> String { "Suche Ticket \(n) …" }
    public static func ticketNotFound(_ n: Int, code: String? = nil) -> String {
        code.map { "\($0) hat kein Ticket \(n)" } ?? "AC kennt kein Ticket \(n)"
    }
    public static let ticketTrashed = "Das Ticket liegt im Papierkorb"
    /// "Ticket 412 · WWT: Website Relaunch"
    public static func ticketTitle(_ n: Int, project: String?) -> String {
        project.map { "Ticket \(n) · \($0)" } ?? "Ticket \(n)"
    }
    /// Live preview for a list: "4 WWT-Projekte" or "5 Projekte".
    public static func projectCount(_ n: Int, code: String?) -> String {
        code.map { "\(n) \($0)-Projekte" } ?? "\(n) Projekte"
    }

    // Data, Chrome, speech.
    public static let noProjectData = "Die Projektliste fehlt"
    public static let acUnreachable = "AC antwortet nicht"
    public static let openFailed = "Chrome öffnet die Seite nicht"
    public static let chromeTimeout = "Chrome reagiert nicht"
    /// Success after the NSWorkspace fallback because Automation is denied.
    public static let automationHint = "AC Voice öffnet einen neuen Tab. Erlaube die Chrome-Steuerung in den Systemeinstellungen."
    /// Success after the NSWorkspace fallback because Automation was never asked for (once per app run).
    public static let automationSetupHint = "AC Voice öffnet einen neuen Tab. Erlaube die Chrome-Steuerung in der Einrichtung."
    public static let micDenied = "Erlaube das Mikrofon in der Einrichtung"
    /// No input device, or the device failed or kept changing (`SpeechError.sourceFailed`, `.invalidInputFormat`).
    public static let noInput = "Mikrofon fehlt"
    /// Speech assets missing or the analyzer could not be prepared (`SpeechError.assetsUnavailable`, `.analyzerFailed`).
    public static let modelUnavailable = "Sprachmodell fehlt"
    /// The utterance ended, but the model did not get ready within `FlowTimings.coldFinalize`.
    public static let modelStillLoading = "Sprachmodell lädt noch"
    public static let speechFailed = "Die Spracherkennung meldet einen Fehler"
    public static let micNotReady = "Mikrofon startet nicht"

    // Next steps under an error card.
    public static let setupIsOpen = "Die Einrichtung ist offen"
    public static let tryMyTasks = "Sag zum Beispiel „Meine Aufgaben“"
    public static let checkNetwork = "Prüfe die Internetverbindung"

    public static func failure(_ f: SpeechFailure) -> String {
        switch f {
        case .micDenied: return micDenied
        case .noInput: return noInput
        case .modelUnavailable: return modelUnavailable
        case .engine: return speechFailed
        }
    }

    /// The next step shown under an error card, if the error has one.
    public static func hint(forError message: String) -> String? {
        switch message {
        case micDenied: return setupIsOpen
        case nothingHeard: return tryMyTasks
        case acUnreachable: return checkNetwork
        default: return nil
        }
    }

    /// Every fixed string, for style checks.
    public static var all: [String] {
        [loadingModel, myTasks, notUnderstoodRetry, notUnderstood, projectNotRecognizedRetry, projectNotRecognized,
         nothingHeardRetry, nothingHeard, sayNumber, sayYesOrOne, noMoreChoices, selectionFailed, ticketTrashed,
         noProjectData, acUnreachable, openFailed, chromeTimeout, automationHint, automationSetupHint, micDenied,
         noInput, modelUnavailable, modelStillLoading, speechFailed, micNotReady, setupIsOpen, tryMyTasks, checkNetwork,
         searchingTicket(412), ticketNotFound(412), ticketNotFound(412, code: "WWT"),
         ticketTitle(412, project: "WWT: Website Relaunch"), projectCount(4, code: "WWT"), projectCount(5, code: nil),
         unclearAnswer("Hi."), narrowed("Website", count: 2), narrowed("Website", count: 1)]
    }
}
