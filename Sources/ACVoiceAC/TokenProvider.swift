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

/// A fixed token (tests, the dev CLI with `AC_TOKEN`).
public struct StaticTokenProvider: TokenProvider {
    private let value: String
    public init(_ token: String) { value = token }
    public func token() async throws -> String { value }
    public func refreshedToken(rejected: String) async throws -> String? { nil }
}

/// Token helpers shared by the Keychain store, the sign-in and the dev CLI. Never log what they get.
public enum ACToken {
    /// "538-AbC…" -> 538 [V format; A that every token carries the user id].
    public static func userId(from token: String) -> Int? {
        guard let dash = token.firstIndex(of: "-") else { return nil }
        return Int(token[..<dash])
    }

    /// Rejects empty values and anything that could break a header (whitespace, control characters, non-ASCII).
    public static func sanitize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8, t.count <= 512,
              t.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        return t
    }
}

/// The app's token store: login Keychain, `kSecClassGenericPassword`, service "io.github.nordavid.acvoice".
/// No data-protection keychain (needs an entitlement and a provisioning profile, REVIEW m6).
/// Dev CLIs and tests never use this type: unsigned rebuilds trigger Keychain ACL prompts.
/// After a rejection it re-reads the Keychain: a token saved meanwhile (a new sign-in or a pasted token) wins,
/// otherwise there is no new token and the app asks the user to sign in again. `token()` and `refreshedToken` run
/// the Keychain calls on a private serial queue, never on the cooperative pool: an ACL prompt after a re-sign blocks
/// that queue only.
public struct KeychainTokenStore: TokenProvider {
    public static let service = "io.github.nordavid.acvoice"
    /// The AC host, e.g. "ac.example.com", with the port when it is not 443 ("ac.example.test:8443").
    public let account: String

    public init(account: String) {
        self.account = account
    }

    /// The token store of an AC address (`account(for:)`).
    public init(base: URL) {
        self.init(account: Self.account(for: base))
    }

    /// The Keychain account of an AC address: its host as written, plus the port when it is not the https default.
    /// Two addresses that are different ActiveCollabs for `Config.sameBase` (another host or another port) never
    /// share an account, so a token never travels to an origin it was not issued for.
    public static func account(for base: URL) -> String {
        let host = base.host ?? "ac.example.com"
        guard let port = base.port, port != 443 else { return host }
        return "\(host):\(port)"
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
        return String(data: data, encoding: .utf8).flatMap(ACToken.sanitize)
    }

    public func save(_ token: String) throws {
        guard let clean = ACToken.sanitize(token) else { throw ACError.noToken }
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
        try await offPool { Self.renewal(rejected: rejected, stored: try? load()) }
    }

    /// Renewal decision, testable without the Keychain: a stored token that differs from the rejected one (saved
    /// meanwhile by a sign-in or a paste) wins. Otherwise nil: the token stays rejected until the user signs in.
    static func renewal(rejected: String, stored: String?) -> String? {
        guard let stored, stored != rejected else { return nil }
        return stored
    }

    private static let queue = DispatchQueue(label: "io.github.nordavid.acvoice.keychain")

    private func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
