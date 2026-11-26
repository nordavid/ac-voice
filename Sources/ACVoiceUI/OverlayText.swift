import Foundation
import ACVoiceCore

/// The strings the overlay adds on top of `FlowText`, in one language: `OverlayText.de`, `OverlayText.en` or
/// `OverlayText(language)`. German follows the company style (short, active, no subjunctive, plain hyphen); English
/// is plain, short, active and in sentence case. English example phrases use the English command word "more".
public struct OverlayText: Sendable, Equatable {
    public let language: AppLanguage

    public init(_ language: AppLanguage) { self.language = language }

    public static let de = OverlayText(.de)
    public static let en = OverlayText(.en)

    private func t(_ de: String, _ en: String) -> String { language == .de ? de : en }

    public var listening: String { t("Ich höre zu", "I’m listening") }
    /// The engine starts (press -> first audio): speaking now loses the first syllables.
    public var micStarting: String { t("Mikrofon startet …", "Microphone is starting…") }
    public var working: String { t("Einen Moment", "One moment") }
    /// Opening: the target is the headline, this the line under it.
    public var openingInChrome: String { t("Öffne in Chrome …", "Opening in Chrome…") }
    public var opened: String { t("Chrome zeigt die Seite", "Chrome shows the page") }
    public var defaultChoiceHint: String { t("Sag eine Zahl oder einen Namen", "Say a number or a name") }
    public var close: String { t("Schließen", "Close") }
    public var overlay: String { "AC Voice" }

    /// Question above a list: "Welches der 4 Projekte?", "Dieses Ticket?", "Which of the 4 projects?".
    public func question(count: Int, tickets: Bool) -> String {
        if count <= 1 { return tickets ? t("Dieses Ticket?", "This ticket?") : t("Dieses Projekt?", "This project?") }
        return tickets ? t("Welches der \(count) Tickets?", "Which of the \(count) tickets?")
            : t("Welches der \(count) Projekte?", "Which of the \(count) projects?")
    }

    /// Question above a ticket list whose rows share one number: "Ticket 412 in welchem der 3 Projekte?".
    public func ticketQuestion(_ number: Int, count: Int) -> String {
        count <= 1 ? t("Ticket \(number) in diesem Projekt?", "Ticket \(number) in this project?")
            : t("Ticket \(number) in welchem der \(count) Projekte?", "Ticket \(number) in which of the \(count) projects?")
    }

    /// Footer when another page follows: "„mehr“ zeigt 6 weitere Projekte", "“more” shows one more ticket".
    public func more(_ next: Int, tickets: Bool) -> String {
        if next == 1 {
            return tickets ? t("„mehr“ zeigt ein weiteres Ticket", "“more” shows one more ticket")
                : t("„mehr“ zeigt ein weiteres Projekt", "“more” shows one more project")
        }
        return tickets ? t("„mehr“ zeigt \(next) weitere Tickets", "“more” shows \(next) more tickets")
            : t("„mehr“ zeigt \(next) weitere Projekte", "“more” shows \(next) more projects")
    }

    /// Footer on the last page: "mehr" wraps around.
    public var moreFromStart: String { t("„mehr“ zeigt wieder Seite 1", "“more” shows page 1 again") }

    /// What the speech layer heard, quoted.
    public func quoted(_ text: String) -> String { t("„\(text)“", "“\(text)”") }

    public func ticketNumber(_ n: Int) -> String { "#\(n)" }

    // MARK: Accessibility (VoiceOver)

    public var a11yListening: String { t("Hört zu", "Listening") }
    public var a11yWarming: String { t("Sprachmodell lädt", "Speech model is loading") }
    public var a11yProcessing: String { t("Arbeitet", "Working") }
    public var a11yChoices: String { t("Auswahl offen", "Waiting for your choice") }
    public var a11ySuccess: String { t("Fertig", "Done") }
    public var a11yError: String { t("Fehler", "Error") }
    public var a11yFavorite: String { t("Favorit", "Favorite") }
    public var a11yRecent: String { t("Zuletzt genutzt", "Recently used") }
    public var a11yMine: String { t("Mir zugewiesen", "Assigned to me") }
    public var a11yCompleted: String { t("Erledigt", "Completed") }
    public var a11yOpenRow: String { t("Öffnet den Eintrag in Chrome", "Opens the entry in Chrome") }
    public var a11yCloseHint: String { t("Schließt das Fenster und bricht ab", "Closes the window and cancels") }
    public func a11yTicket(_ n: Int) -> String { "Ticket \(n)" }
    public func a11yPage(_ page: Int, of count: Int) -> String { t("Seite \(page) von \(count)", "Page \(page) of \(count)") }
    public func a11ySecondsLeft(_ s: Int) -> String {
        s == 1 ? t("Noch 1 Sekunde", "1 second left") : t("Noch \(s) Sekunden", "\(s) seconds left")
    }

    /// Every fixed string and a sample of each formatted one, for style checks.
    public var all: [String] {
        [listening, micStarting, working, openingInChrome, opened, defaultChoiceHint, close, overlay, moreFromStart,
         more(6, tickets: false), more(1, tickets: false), more(3, tickets: true), more(1, tickets: true),
         question(count: 4, tickets: false), question(count: 3, tickets: true), question(count: 1, tickets: false),
         question(count: 1, tickets: true), ticketQuestion(412, count: 3), ticketQuestion(412, count: 1),
         quoted(language == .de ? "Öffne WWT Ticket 412" : "Open WWT ticket 412"), ticketNumber(412),
         a11yListening, a11yWarming, a11yProcessing, a11yChoices, a11ySuccess, a11yError, a11yFavorite, a11yRecent,
         a11yMine, a11yCompleted, a11yOpenRow, a11yCloseHint, a11yTicket(412), a11yPage(1, of: 2), a11ySecondsLeft(1),
         a11ySecondsLeft(5)]
    }
}
