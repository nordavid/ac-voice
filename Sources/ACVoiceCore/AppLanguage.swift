import Foundation

/// The language AC Voice runs in: UI texts, voice commands and the speech recognition locale.
/// `Config.language` picks it ("auto", "de", "en"); "auto" follows the first macOS language.
public enum AppLanguage: String, Sendable, CaseIterable, Codable {
    case de, en

    /// `setting`: the `Config.language` value. `preferred`: `Locale.preferredLanguages`, first is the user's choice.
    /// "auto" (and any unknown value) gives German when the first preferred language is German, else English.
    public init(setting: String, preferred: [String]) {
        switch setting.trimmingCharacters(in: .whitespaces).lowercased() {
        case "de": self = .de
        case "en": self = .en
        default:
            let first = preferred.first?.lowercased() ?? "en"
            self = first == "de" || first.hasPrefix("de-") || first.hasPrefix("de_") ? .de : .en
        }
    }

    /// Locale for the speech recognition (German de_DE, English en_US).
    public var speechLocale: Locale { Locale(identifier: self == .de ? "de_DE" : "en_US") }

    /// BCP 47 code for `say` and Apple's speech APIs ("de-DE", "en-US").
    public var bcp47: String { self == .de ? "de-DE" : "en-US" }
}
