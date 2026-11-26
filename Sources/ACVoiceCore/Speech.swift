import Foundation

/// Stamp on every speech event: the mic session (one per listening press) and the utterance inside it
/// (command, retry, each answer). `VoiceFlow` hands it out in `.startMic` / `.rearm`, the speech layer stamps every
/// event with the stamp it was started or re-armed with, and the flow drops every event whose stamp is not the armed
/// one, so a late final of session N never reaches session N+1 (REVIEW M3).
public struct SpeechGen: Sendable, Hashable, CustomStringConvertible {
    public var session: Int
    public var utterance: Int
    public init(session: Int, utterance: Int) { self.session = session; self.utterance = utterance }
    public var description: String { "\(session).\(utterance)" }
}

/// Why a mic session failed. The speech layer maps its errors to it (`SpeechError.failure`); the flow shows
/// `FlowText.failure(_:)`.
public enum SpeechFailure: Sendable, Equatable {
    /// Microphone permission denied (the app checks it before it starts the mic).
    case micDenied
    /// No usable input device, or the device failed or kept changing.
    case noInput
    /// Speech assets missing or the analyzer could not be prepared ("Sprachmodell nicht verfügbar").
    case modelUnavailable
    /// Any other failure of the speech pipeline.
    case engine
}

/// End-of-utterance pause budgets in seconds (PLAN 2.3, REVIEW M1): one rule for every live partial.
///
/// `VoiceFlow` owns the values (`FlowTimings.hangovers`), runs the rule on every live partial and sends the result to
/// the speech layer, which applies it as is (`.startMic`, `.rearm`, `.setHangover`). Dev tools that run the speech
/// layer alone (acvoice-transcribe, the speech end-to-end tests) play the controller with `standard`.
public struct HangoverPolicy: Sendable, Equatable {
    /// Command phase default, and a command partial without a complete intent ("Öffne das WWT-Projekt").
    public var command: Double
    /// Command partial with a complete intent (`Interpretation.isCompleteIntent`).
    public var fast: Double
    /// Answer phase while a list is visible. 0.40 s: the 500 ms synthetic tail always covers
    /// `finalize(through: speechEnd + 0.4 s)`, so PLAN's old floor "lead + 50 ms" no longer applies.
    public var answer: Double
    /// Command partial that ends in a dangling word or holds only fillers (`Parser.looksIncomplete`).
    public var incomplete: Double
    /// Command partial that ends in a numeral: "Ticket 4" may become 412, "47000" may become 47285 (REVIEW M1).
    public var trailingNumber: Double

    public init(command: Double = 0.60, fast: Double = 0.45, answer: Double = 0.40, incomplete: Double = 1.10,
                trailingNumber: Double = 1.10) {
        self.command = command; self.fast = fast; self.answer = answer; self.incomplete = incomplete
        self.trailingNumber = trailingNumber
    }

    public static let standard = HangoverPolicy()

    /// Command phase. A trailing numeral is never fast: the number may still grow. `language`: the language of the
    /// voice commands (`Interpreter.language`), for the dangling words and number words.
    public func command(text: String, interpretation: Interpretation, language: AppLanguage = .de) -> Double {
        guard Parser.looksIncomplete(text, language: language) else { return interpretation.isCompleteIntent ? fast : command }
        return Parser.endsInNumeral(text, language: language) ? trailingNumber : incomplete
    }

    /// Answer phase: `answer`. A new command ("Öffne TKZ", "Ticket 412") follows the command rules; `interpret`
    /// runs only then. A dangling answer word ("die", "nein") does not extend the live budget: DT shows the last word
    /// of a short answer late, so "die zweite" would wait for "zweite". The speech layer reopens an utterance whose
    /// final text dangles instead (`Parser.looksIncomplete(_:choosing:)`).
    public func answer(text: String, outcome: SelectionOutcome, language: AppLanguage = .de,
                       command interpret: () -> Interpretation) -> Double {
        if case .command = outcome { return command(text: text, interpretation: interpret(), language: language) }
        return answer
    }
}
