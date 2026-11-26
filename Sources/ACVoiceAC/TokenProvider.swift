import ACVoiceCore
import Foundation
import Security

/// Source of the AC API token. Implementations never log or print the token.
public protocol TokenProvider: Sendable {
    /// The token to use now. Throws `ACError.noToken` when there is none.
    func token() async throws -> String
    /// Called after AC rejected `rejected`. Returns a different token, or nil when none exists. Concurrent rejections
    /// share one call; after a nil or an error the same token is asked again at most once per
    /// `ACClient.renewalCooldown`.
    func refreshedToken(rejected: String) async throws -> String?
}

/// A fixed token (tests, a token pasted in onboarding).
public struct StaticTokenProvider: TokenProvider {
    private let value: String
    public init(_ token: String) { value = token }
    public func token() async throws -> String { value }
    public func refreshedToken(rejected: String) async throws -> String? { nil }
}

/// Read-only import from an ac-mcp checkout (PLAN 2.2). Reads `.ac-token-cache` (raw token, mode 0600), else
/// `AC_TOKEN` in `.env`, plus `AC_URL` and `AC_USER_ID`. Never writes, never reads any other `.env` key.
/// After a rejection it re-reads both files and offers the first token that differs from the rejected one
/// (ac-mcp itself prefers `AC_TOKEN` and rewrites the cache on its own 401).
public struct ACMCPTokenImporter: TokenProvider {
    public enum Source: String, Sendable { case tokenCache = ".ac-token-cache", envToken = ".env AC_TOKEN" }

    public struct Imported: Sendable, Equatable, CustomStringConvertible {
        public var token: String
        public var source: Source
        /// `AC_URL`, when it is a valid http(s) URL.
        public var baseURL: URL?
        /// `AC_USER_ID`, else the numeric token prefix ("538-…").
        public var userId: Int?
        /// Redacted: never shows the token.
        public var description: String {
            "Imported(source: \(source.rawValue), baseURL: \(baseURL?.absoluteString ?? "nil"), userId: \(userId.map(String.init) ?? "nil"))"
        }
    }

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// `Config.acMcpPath`, else ~/ac-mcp.
    public static func directory(for config: Config) -> URL {
        if let p = config.acMcpPath, !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return AppPaths.home.appendingPathComponent("ac-mcp", isDirectory: true)
    }

    public func load() throws -> Imported {
        let env = readEnv()
        guard let first = candidates(env: env).first else { throw ACError.noToken }
        let url = env["AC_URL"].flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let user = env["AC_USER_ID"].flatMap { Int($0) } ?? Self.userId(fromToken: first.token)
        return Imported(token: first.token, source: first.source, baseURL: url, userId: user)
    }

    /// Valid tokens in import order, without duplicates: cache, then `AC_TOKEN`.
    public func candidates() -> [(token: String, source: Source)] { candidates(env: readEnv()) }

    public func token() async throws -> String { try load().token }

    public func refreshedToken(rejected: String) async throws -> String? {
        candidates().first { $0.token != rejected }?.token
    }

    /// "538-AbC…" -> 538 [V format; A that every token carries the user id].
    public static func userId(fromToken token: String) -> Int? {
        guard let dash = token.firstIndex(of: "-") else { return nil }
        return Int(token[..<dash])
    }

    /// Rejects empty values and anything that could break a header (whitespace, control characters, non-ASCII).
    static func sanitize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8, t.count <= 512,
              t.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        return t
    }

    func candidates(env: [String: String]) -> [(token: String, source: Source)] {
        var out: [(token: String, source: Source)] = []
        let cacheURL = directory.appendingPathComponent(".ac-token-cache")
        if let raw = try? String(contentsOf: cacheURL, encoding: .utf8), let t = Self.sanitize(raw) {
            out.append((t, .tokenCache))
        }
        if let raw = env["AC_TOKEN"], let t = Self.sanitize(raw), !out.contains(where: { $0.token == t }) {
            out.append((t, .envToken))
        }
        return out
    }

    func readEnv() -> [String: String] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(".env"), encoding: .utf8) else { return [:] }
        return Self.parseEnv(text, keys: ["AC_TOKEN", "AC_URL", "AC_USER_ID"])
    }

    /// Minimal dotenv parser for the wanted `keys` only: `KEY=value`, optional `export `, single or double quotes,
    /// `#` comments (whole line, or after whitespace in an unquoted value). Later lines win, as in dotenv.
    static func parseEnv(_ text: String, keys: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard keys.contains(key) else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let q = value.first, q == "\"" || q == "'" {
                let body = value.dropFirst()
                value = body.firstIndex(of: q).map { String(body[..<$0]) } ?? String(body)
            } else if let hash = value.range(of: " #") ?? value.range(of: "\t#") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            out[key] = value
        }
        return out
    }
}

/// The app's token store: login Keychain, `kSecClassGenericPassword`, service "io.github.nordavid.acvoice".
/// No data-protection keychain (needs an entitlement and a provisioning profile, REVIEW m6).
/// Dev CLIs and tests never use this type: unsigned rebuilds trigger Keychain ACL prompts.
/// After a rejection it re-reads the Keychain (a token pasted meanwhile), else re-imports from ac-mcp and stores
/// the new token. `token()` and `refreshedToken` run the Keychain calls on a private serial queue, never on the
/// cooperative pool: an ACL prompt after a re-sign blocks that queue only.
public struct KeychainTokenStore: TokenProvider {
    public static let service = "io.github.nordavid.acvoice"
    /// The AC host, e.g. "ac.example.com".
    public let account: String
    public let reimport: ACMCPTokenImporter?

    public init(account: String, reimport: ACMCPTokenImporter? = nil) {
        self.account = account; self.reimport = reimport
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    /// nil when no item exists.
    public func load() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw ACError.keychain(status: status) }
        return String(data: data, encoding: .utf8).flatMap(ACMCPTokenImporter.sanitize)
    }

    public func save(_ token: String) throws {
        guard let clean = ACMCPTokenImporter.sanitize(token) else { throw ACError.noToken }
        let data = Data(clean.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ACError.keychain(status: update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "AC Voice API-Token"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw ACError.keychain(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ACError.keychain(status: status) }
    }

    public func token() async throws -> String {
        try await offPool {
            guard let t = try load() else { throw ACError.noToken }
            return t
        }
    }

    public func refreshedToken(rejected: String) async throws -> String? {
        try await offPool {
            let stored = try? load()
            let imported = reimport?.candidates().map(\.token) ?? []
            guard let pick = Self.renewal(rejected: rejected, stored: stored, imported: imported) else { return nil }
            // A failed save keeps the new token for this session; the next launch re-imports it again.
            if pick.save { try? save(pick.token) }
            return pick.token
        }
    }

    /// Renewal decision, testable without the Keychain: a stored token that differs from the rejected one (pasted
    /// meanwhile) wins, else the first ac-mcp token that differs, which is then saved.
    static func renewal(rejected: String, stored: String?, imported: [String]) -> (token: String, save: Bool)? {
        if let stored, stored != rejected { return (stored, false) }
        guard let fresh = imported.first(where: { $0 != rejected }) else { return nil }
        return (fresh, true)
    }

    private static let queue = DispatchQueue(label: "io.github.nordavid.acvoice.keychain")

    private func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
