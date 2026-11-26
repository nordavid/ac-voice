import ACVoiceCore
import Foundation
import Testing
@testable import ACVoiceAC

/// Token helpers and the Keychain store's renewal decision. The Keychain itself is never exercised in tests.
@Suite("Tokens")
struct TokenProviderTests {
    @Test("tokens that could break a header are rejected; the user id comes from the prefix")
    func sanitize() {
        #expect(ACToken.sanitize(" 538-AbcDefGhi\n") == "538-AbcDefGhi")
        #expect(ACToken.sanitize("short") == nil)
        #expect(ACToken.sanitize("538-abc\r\nX-Evil: 1") == nil)
        #expect(ACToken.sanitize("538-äöüabcdefg") == nil)
        #expect(ACToken.userId(from: "538-AbcDef") == 538)
        #expect(ACToken.userId(from: "AbcDef") == nil)
    }

    @Test("the Keychain account names the host and a non-default port, like Config.sameBase")
    func keychainAccountPerOrigin() {
        func account(_ s: String) -> String { KeychainTokenStore.account(for: URL(string: s)!) }
        #expect(account("https://ac.example.test") == "ac.example.test")
        #expect(account("https://ac.example.test/") == "ac.example.test")
        #expect(account("https://ac.example.test:443") == "ac.example.test")
        #expect(account("https://ac.example.test:8443") == "ac.example.test:8443")
        #expect(KeychainTokenStore(base: URL(string: "https://ac.example.test:8443")!).account == "ac.example.test:8443")
        // Whenever two addresses are different ActiveCollabs, their tokens live apart.
        let bases = ["https://ac.example.test", "https://ac.example.test:8443", "https://ac.example.test:443",
                     "https://ac.example.com", "https://ac.example.com:8443"].map { URL(string: $0)! }
        for a in bases {
            for b in bases where !Config.sameBase(a, b) {
                #expect(KeychainTokenStore.account(for: a) != KeychainTokenStore.account(for: b), "\(a) \(b)")
            }
        }
    }

    @Test("Keychain renewal decision: a token saved meanwhile wins, else there is no new token")
    func keychainRenewalDecision() {
        let old = "7-OldTokenAbcdefghij", fresh = "7-FreshTokenAbcdefgh"
        // A new sign-in or a paste saved another token after the rejection: use it.
        #expect(KeychainTokenStore.renewal(rejected: old, stored: fresh) == fresh)
        // The Keychain still holds the rejected token, or nothing: the user has to sign in again.
        #expect(KeychainTokenStore.renewal(rejected: old, stored: old) == nil)
        #expect(KeychainTokenStore.renewal(rejected: old, stored: nil) == nil)
    }
}
