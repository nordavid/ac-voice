import ACVoiceCore
import Foundation
import Testing
@testable import ACVoiceAC

/// ac-mcp import against a synthetic checkout in a temp directory. The Keychain store is never exercised in tests.
@Suite("Token import")
struct TokenProviderTests {
    static let cacheToken = "7-CacheTokenAbcdefghij"
    static let envToken = "7-EnvTokenAbcdefghijkl"

    func checkout(cache: String?, env: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acmcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let cache { try cache.write(to: dir.appendingPathComponent(".ac-token-cache"), atomically: true, encoding: .utf8) }
        if let env { try env.write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8) }
        return dir
    }

    let env = """
    # Base URL
    AC_URL="https://ac.example.test"

    AC_EMAIL=someone@example.com
    AC_PASSWORD=not-a-real-password
    # AC_TOKEN=7-CommentedOutTokenXyz
    AC_USER_ID=42 # own id
    export AC_TOKEN='\(TokenProviderTests.envToken)'
    """

    @Test("cache first, then AC_TOKEN; URL and user id from .env")
    func importOrder() async throws {
        let dir = try checkout(cache: "  \(Self.cacheToken)\n", env: env)
        let importer = ACMCPTokenImporter(directory: dir)
        let imported = try importer.load()
        #expect(imported.token == Self.cacheToken)
        #expect(imported.source == .tokenCache)
        #expect(imported.baseURL?.absoluteString == "https://ac.example.test")
        #expect(imported.userId == 42)
        #expect(!imported.description.contains(Self.cacheToken))
        #expect(importer.candidates().map(\.token) == [Self.cacheToken, Self.envToken])
        #expect(try await importer.token() == Self.cacheToken)
        #expect(try await importer.refreshedToken(rejected: Self.cacheToken) == Self.envToken)
        #expect(try await importer.refreshedToken(rejected: Self.envToken) == Self.cacheToken)
    }

    @Test("without a cache the .env token is used; the user id falls back to the token prefix")
    func envOnly() async throws {
        let dir = try checkout(cache: nil, env: "AC_TOKEN=\(Self.envToken)\nAC_URL=ftp://nope\n")
        let imported = try ACMCPTokenImporter(directory: dir).load()
        #expect(imported.token == Self.envToken && imported.source == .envToken)
        #expect(imported.baseURL == nil)
        #expect(imported.userId == 7)
        #expect(try await ACMCPTokenImporter(directory: dir).refreshedToken(rejected: Self.envToken) == nil)
    }

    @Test("a commented-out token, a broken cache or a missing checkout give noToken")
    func noToken() throws {
        let commented = try checkout(cache: "bad token with spaces", env: "# AC_TOKEN=\(Self.envToken)\n")
        #expect(throws: ACError.noToken) { try ACMCPTokenImporter(directory: commented).load() }
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: ACError.noToken) { try ACMCPTokenImporter(directory: missing).load() }
    }

    @Test("dotenv parsing reads only the wanted keys")
    func parseEnv() {
        let parsed = ACMCPTokenImporter.parseEnv(env, keys: ["AC_TOKEN", "AC_URL", "AC_USER_ID"])
        #expect(parsed == ["AC_URL": "https://ac.example.test", "AC_USER_ID": "42", "AC_TOKEN": Self.envToken])
        #expect(ACMCPTokenImporter.parseEnv("AC_URL='a#b'\nAC_URL=c\n", keys: ["AC_URL"]) == ["AC_URL": "c"])
        #expect(ACMCPTokenImporter.parseEnv("AC_URL=\"x # y\"", keys: ["AC_URL"]) == ["AC_URL": "x # y"])
    }

    @Test("tokens that could break a header are rejected")
    func sanitize() {
        #expect(ACMCPTokenImporter.sanitize(" 538-AbcDefGhi\n") == "538-AbcDefGhi")
        #expect(ACMCPTokenImporter.sanitize("short") == nil)
        #expect(ACMCPTokenImporter.sanitize("538-abc\r\nX-Evil: 1") == nil)
        #expect(ACMCPTokenImporter.sanitize("538-äöüabcdefg") == nil)
        #expect(ACMCPTokenImporter.userId(fromToken: "538-AbcDef") == 538)
        #expect(ACMCPTokenImporter.userId(fromToken: "AbcDef") == nil)
    }

    @Test("Keychain renewal decision: a token pasted meanwhile wins, else the first different ac-mcp token is saved")
    func keychainRenewalDecision() {
        let old = "7-OldTokenAbcdefghij", pasted = "7-PastedTokenAbcdefg"
        // Pasted into the Keychain after the rejection: use it, nothing to save.
        let a = KeychainTokenStore.renewal(rejected: old, stored: pasted, imported: [old, Self.envToken])
        #expect(a?.token == pasted && a?.save == false)
        // The Keychain still holds the rejected token: re-import from ac-mcp and save.
        let b = KeychainTokenStore.renewal(rejected: old, stored: old, imported: [old, Self.envToken])
        #expect(b?.token == Self.envToken && b?.save == true)
        // Keychain unreadable or empty: re-import.
        #expect(KeychainTokenStore.renewal(rejected: old, stored: nil, imported: [Self.cacheToken])?.token == Self.cacheToken)
        // Nothing different anywhere.
        #expect(KeychainTokenStore.renewal(rejected: old, stored: old, imported: [old]) == nil)
        #expect(KeychainTokenStore.renewal(rejected: old, stored: nil, imported: []) == nil)
    }

    @Test("checkout directory from the config")
    func directory() {
        var config = Config()
        #expect(ACMCPTokenImporter.directory(for: config).path.hasSuffix("/ac-mcp"))
        config.acMcpPath = "~/elsewhere/ac-mcp"
        let dir = ACMCPTokenImporter.directory(for: config)
        #expect(!dir.path.contains("~") && dir.path.hasSuffix("/elsewhere/ac-mcp"))
    }
}
