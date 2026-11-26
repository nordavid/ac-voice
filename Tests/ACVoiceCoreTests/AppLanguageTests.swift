@testable import ACVoiceCore
import Foundation
import Testing

@Suite struct AppLanguageTests {
    @Test func autoFollowsTheFirstMacOSLanguage() {
        #expect(AppLanguage(setting: "auto", preferred: ["de-DE", "en-US"]) == .de)
        #expect(AppLanguage(setting: "auto", preferred: ["de-AT"]) == .de)
        #expect(AppLanguage(setting: "auto", preferred: ["en-GB", "de-DE"]) == .en)
        #expect(AppLanguage(setting: "auto", preferred: ["fr-FR", "de-DE"]) == .en)
        #expect(AppLanguage(setting: "auto", preferred: []) == .en)
    }

    @Test func explicitSettingWinsAndUnknownMeansAuto() {
        #expect(AppLanguage(setting: "en", preferred: ["de-DE"]) == .en)
        #expect(AppLanguage(setting: " DE ", preferred: ["en-US"]) == .de)
        #expect(AppLanguage(setting: "klingon", preferred: ["de-DE"]) == .de)
        #expect(Config.decode(Data(#"{"language":"en"}"#.utf8)).appLanguage(preferred: ["de-DE"]) == .en)
        #expect(Config().language == "auto")
        #expect(AppLanguage.de.speechLocale.identifier == "de_DE" && AppLanguage.en.speechLocale.identifier == "en_US")
    }
}
