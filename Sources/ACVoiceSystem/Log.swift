import Foundation
import os

/// Unified logging for ac-voice (subsystem `io.github.nordavid.acvoice`).
///
/// The helpers accept no free-form public text: an event is a compile-time constant name plus typed fields.
/// Scalars, ids, durations and enum tags go to the public part. Any `String` field (transcripts, URLs, error
/// messages, client names) goes to the `.private` part and passes `redactSecrets` first, so a token, an ETag
/// or an e-mail address never reaches the log even when a caller passes one by mistake.
///
/// Read the log: `log stream --level info --predicate 'subsystem == "io.github.nordavid.acvoice"'`
/// (add `AND category == "chrome"` to narrow it down).
public enum Log {
    public static let subsystem = "io.github.nordavid.acvoice"

    public enum Category: String, CaseIterable, Sendable {
        case app, flow, speech, index, ipc, chrome, hotkey, earcon, login
    }

    public static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// Signposts for latency measurements (Instruments, M7).
    public static func signposter(_ category: Category) -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: category.rawValue)
    }

    /// One event: `name key=value …` public, followed by the private fields.
    public static func event(_ category: Category, _ name: StaticString, _ fields: LogField..., level: OSLogType = .info) {
        let parts = render(fields)
        let logger = logger(category)
        let title = name.description
        if parts.private.isEmpty {
            logger.log(level: level, "\(title, privacy: .public) \(parts.public, privacy: .public)")
        } else {
            logger.log(level: level,
                       "\(title, privacy: .public) \(parts.public, privacy: .public) \(parts.private, privacy: .private)")
        }
    }

    /// A transcript or any other user speech: always private.
    public static func transcript(_ category: Category, _ label: StaticString, _ text: String) {
        let safe = redactSecrets(text)
        logger(category).info("\(label.description, privacy: .public) \(safe, privacy: .private)")
    }

    /// An error: type and code public, the description private (it may contain URLs or names).
    public static func error(_ category: Category, _ name: StaticString, _ error: any Error) {
        let ns = error as NSError
        event(category, name, .init(key: "domain", value: .tag(ns.domain)), .int("code", ns.code),
              .private("detail", String(describing: error)), level: .error)
    }

    /// Splits fields into the public and the private part. Pure, for tests.
    static func render(_ fields: [LogField]) -> (public: String, private: String) {
        var pub: [String] = []
        var priv: [String] = []
        for f in fields {
            let key = f.key.description
            switch f.value {
            case .int(let v): pub.append("\(key)=\(v)")
            case .double(let v): pub.append("\(key)=\(String(format: "%.3f", v))")
            case .ms(let seconds): pub.append("\(key)=\(String(format: "%.1f", seconds * 1000))ms")
            case .bool(let v): pub.append("\(key)=\(v)")
            case .tag(let v): pub.append("\(key)=\(v)")
            case .privateText(let v): priv.append("\(key)=\(redactSecrets(v))")
            }
        }
        return (pub.joined(separator: " "), priv.joined(separator: " "))
    }

    /// Replaces words that look like secrets: bearer values, long mixed letter-digit runs (API tokens, ETag
    /// hashes, feed tokens) and e-mail addresses. Spoken German text passes unchanged.
    public static func redactSecrets(_ text: String) -> String {
        var out: [Substring] = []
        var redactNext = false
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if redactNext, !word.isEmpty {
                out.append("[redacted]")
                redactNext = false
                continue
            }
            let lower = word.lowercased()
            if lower == "bearer" || lower.hasSuffix("token:") || lower.hasSuffix("token=") || lower == "x-angie-authapitoken:" {
                out.append(word)
                redactNext = true
                continue
            }
            out.append(looksSecret(word) ? "[redacted]" : word)
        }
        return out.joined(separator: " ")
    }

    static func looksSecret(_ word: Substring) -> Bool {
        let core = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]{}<>,;"))
        if core.contains("@"), core.contains("."), core.count >= 5 { return true }
        if let eq = core.firstIndex(of: "="), core.lowercased().contains("token") || core.lowercased().contains("etag") {
            return core.distance(from: eq, to: core.endIndex) > 1
        }
        guard core.count >= 20 else { return false }
        var letters = 0
        var digits = 0
        for ch in core.unicodeScalars {
            if CharacterSet.decimalDigits.contains(ch) { digits += 1 } else if CharacterSet.letters.contains(ch) { letters += 1 }
        }
        return letters > 0 && digits > 0 && !core.contains("/")
    }
}

/// A typed log field. Only `private` takes free text; it lands in the private part.
public struct LogField: Sendable {
    enum Value: Sendable {
        case int(Int64), double(Double), ms(Double), bool(Bool), tag(String), privateText(String)
    }
    let key: StaticString
    let value: Value

    public static func int<I: BinaryInteger>(_ key: StaticString, _ v: I) -> LogField { .init(key: key, value: .int(Int64(v))) }
    public static func double(_ key: StaticString, _ v: Double) -> LogField { .init(key: key, value: .double(v)) }
    /// A duration given in seconds, logged in milliseconds.
    public static func ms(_ key: StaticString, seconds: Double) -> LogField { .init(key: key, value: .ms(seconds)) }
    public static func bool(_ key: StaticString, _ v: Bool) -> LogField { .init(key: key, value: .bool(v)) }
    /// An enum case name: public, because a case name cannot carry user data.
    public static func tag<E: RawRepresentable>(_ key: StaticString, _ v: E) -> LogField where E.RawValue == String {
        .init(key: key, value: .tag(v.rawValue))
    }
    /// A constant string (compile time), public.
    public static func text(_ key: StaticString, _ v: StaticString) -> LogField { .init(key: key, value: .tag(v.description)) }
    /// The kinds of a script result (`ScriptValue.shape`): public, because it holds only kind letters and counts.
    public static func shape(_ key: StaticString, _ v: ScriptValue) -> LogField { .init(key: key, value: .tag(v.shape())) }
    /// Free text: private and redacted.
    public static func `private`(_ key: StaticString, _ v: String) -> LogField { .init(key: key, value: .privateText(v)) }
}
