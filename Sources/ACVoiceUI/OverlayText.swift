import Foundation

/// German strings the overlay adds on top of `FlowText` (company style: short, active, no subjunctive, plain hyphen).
public enum OverlayText {
    public static let listening = "Ich höre zu"
    /// The engine starts (press -> first audio): speaking now loses the first syllables.
    public static let micStarting = "Mikrofon startet …"
    public static let working = "Einen Moment"
    /// Opening: the target is the headline, this the line under it.
    public static let openingInChrome = "Öffne in Chrome …"
    public static let opened = "Chrome zeigt die Seite"
    public static let defaultChoiceHint = "Sag eine Zahl oder einen Namen"
    public static let close = "Schließen"
    public static let overlay = "AC Voice"

    /// Question above a list: "Welches der 4 Projekte?", "Dieses Ticket?".
    public static func question(count: Int, tickets: Bool) -> String {
        if count <= 1 { return tickets ? "Dieses Ticket?" : "Dieses Projekt?" }
        return tickets ? "Welches der \(count) Tickets?" : "Welches der \(count) Projekte?"
    }

    /// Question above a ticket list whose rows share one number: "Ticket 412 in welchem der 3 Projekte?".
    public static func ticketQuestion(_ number: Int, count: Int) -> String {
        count <= 1 ? "Ticket \(number) in diesem Projekt?" : "Ticket \(number) in welchem der \(count) Projekte?"
    }

    /// Footer when another page follows: "„mehr“ zeigt 6 weitere Projekte", "„mehr“ zeigt ein weiteres Ticket".
    public static func more(_ next: Int, tickets: Bool) -> String {
        if next == 1 { return tickets ? "„mehr“ zeigt ein weiteres Ticket" : "„mehr“ zeigt ein weiteres Projekt" }
        return "„mehr“ zeigt \(next) weitere \(tickets ? "Tickets" : "Projekte")"
    }

    /// Footer on the last page: "mehr" wraps around.
    public static let moreFromStart = "„mehr“ zeigt wieder Seite 1"

    /// What the speech layer heard, quoted.
    public static func quoted(_ text: String) -> String { "„\(text)“" }

    public static func ticketNumber(_ n: Int) -> String { "#\(n)" }

    // MARK: Accessibility (VoiceOver)

    public static let a11yListening = "Hört zu"
    public static let a11yWarming = "Sprachmodell lädt"
    public static let a11yProcessing = "Arbeitet"
    public static let a11yChoices = "Auswahl offen"
    public static let a11ySuccess = "Fertig"
    public static let a11yError = "Fehler"
    public static let a11yFavorite = "Favorit"
    public static let a11yRecent = "Zuletzt genutzt"
    public static let a11yMine = "Mir zugewiesen"
    public static let a11yCompleted = "Erledigt"
    public static let a11yOpenRow = "Öffnet den Eintrag in Chrome"
    public static let a11yCloseHint = "Schließt das Fenster und bricht ab"
    public static func a11yTicket(_ n: Int) -> String { "Ticket \(n)" }
    public static func a11yPage(_ page: Int, of count: Int) -> String { "Seite \(page) von \(count)" }
    public static func a11ySecondsLeft(_ s: Int) -> String { s == 1 ? "Noch 1 Sekunde" : "Noch \(s) Sekunden" }

    /// Every fixed string and a sample of each formatted one, for style checks.
    public static var all: [String] {
        [listening, micStarting, working, openingInChrome, opened, defaultChoiceHint, close, overlay, moreFromStart,
         more(6, tickets: false), more(1, tickets: false), more(3, tickets: true), more(1, tickets: true),
         question(count: 4, tickets: false), question(count: 3, tickets: true), question(count: 1, tickets: false),
         question(count: 1, tickets: true), ticketQuestion(412, count: 3), ticketQuestion(412, count: 1), quoted("Öffne WWT Ticket 412"), ticketNumber(412),
         a11yListening, a11yWarming, a11yProcessing, a11yChoices, a11ySuccess, a11yError, a11yFavorite, a11yRecent,
         a11yMine, a11yCompleted, a11yOpenRow, a11yCloseHint, a11yTicket(412), a11yPage(1, of: 2), a11ySecondsLeft(1),
         a11ySecondsLeft(5)]
    }
}
