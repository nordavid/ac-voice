import Foundation

/// Global hotkey as Carbon `RegisterEventHotKey` arguments. Default ⌃⌥Space.
public struct Hotkey: Codable, Sendable, Equatable {
    /// Carbon virtual key code (kVK_Space = 49).
    public var keyCode: UInt32
    /// Carbon modifier mask: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    public var modifiers: UInt32
    public var enabled: Bool

    public static let cmdKey: UInt32 = 0x100, shiftKey: UInt32 = 0x200, optionKey: UInt32 = 0x800, controlKey: UInt32 = 0x1000
    public static let `default` = Hotkey(keyCode: 49, modifiers: controlKey | optionKey, enabled: true)

    public init(keyCode: UInt32, modifiers: UInt32, enabled: Bool = true) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.enabled = enabled
    }

    /// German menu label: "⌃⌥Leertaste", "⌘F5", "⌥Taste 80". Letter keys depend on the keyboard layout
    /// (kVK_ANSI_Y is "Z" on a German keyboard), so they fall back to "Taste <code>"; the app may render them with
    /// UCKeyTranslate instead.
    public var display: String {
        var s = ""
        if modifiers & Self.controlKey != 0 { s += "⌃" }
        if modifiers & Self.optionKey != 0 { s += "⌥" }
        if modifiers & Self.shiftKey != 0 { s += "⇧" }
        if modifiers & Self.cmdKey != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "Taste \(keyCode)")
    }

    /// Layout-independent Carbon key codes (Events.h).
    static let keyNames: [UInt32: String] = [
        49: "Leertaste", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Pos1", 119: "Ende", 116: "Bild auf", 121: "Bild ab",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    enum CodingKeys: String, CodingKey { case keyCode, modifiers, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        keyCode = (try? c.decodeIfPresent(UInt32.self, forKey: .keyCode)) ?? d.keyCode
        modifiers = (try? c.decodeIfPresent(UInt32.self, forKey: .modifiers)) ?? d.modifiers
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
    }
}

/// Non-secret settings in `AppPaths.config` (config.json). Every field has a default; decoding is tolerant:
/// missing keys and values of the wrong type fall back to the default, unknown keys are ignored.
/// The AC token is never part of the config (Keychain, see ACVoiceAC.TokenStore).
public struct Config: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = Config.currentVersion
    /// Web and API root. The API lives at {acBaseURL}/api/v1.
    public var acBaseURL = URL(string: "https://ac.example.com")!
    /// Own AC user id. nil: take it from the token prefix ("538-…").
    public var userId: Int? = nil
    /// Route for "Meine Aufgaben". "{me}" becomes the user id; while it is unknown, "/my-work" opens instead.
    public var myTasksPath = Routes.defaultMyTasksPath
    /// Spoken aliases per code as written in AC: ["IBN": ["eben"], "S+K": ["eska"]].
    public var aliases: [String: [String]] = [:]
    /// Extra spoken words per title word, on top of `ResolverConfig.synonyms`: ["armaturenbrett": ["cockpit"]].
    /// Case and umlauts do not matter (`ResolverConfig(synonyms:)` folds them).
    public var synonyms: [String: [String]] = [:]
    /// Promote repeated picks to aliases (`History.learnedAliases`, REVIEW m9).
    public var learnAliases = true
    public var hotkey = Hotkey.default
    public var earcons = true
    /// CoreAudio device UID of the microphone. nil: system default input.
    public var inputDeviceUID: String? = nil
    /// Use the built-in microphone when the default input is Bluetooth (HFP drops quality and starts slowly, REVIEW M7).
    public var avoidBluetoothInput = true
    /// Commit a spoken pick from stable partials without waiting for the final result (PLAN 3).
    public var fastSelect = true
    /// Maximum contextual strings for the DictationTranscriber (PLAN 2.3, REVIEW m10). 35 is
    /// `ContextBuilder.defaultLimit`, the size the speech end-to-end tests measure.
    public var contextualStringLimit = 35
    /// Choices shown at once; "mehr" pages through the rest.
    public var visibleChoices = 6
    /// Seconds the mic stays open for an answer while a list is visible.
    public var choicesWindow = 6.0
    /// Unclear answers before the list closes with an error.
    public var maxUnclearAnswers = 2
    public var launchAtLogin = false
    /// Debug: keep local recordings of utterances for tuning (M7). Off by default.
    public var saveRecordings = false
    /// ac-mcp checkout for the one-time token import (reads .ac-token-cache or .env, never writes).
    public var acMcpPath: String? = nil
    /// How Chrome comes to the front after a tab change (REVIEW M4 activation test): "appleScript" (default),
    /// "runningApplication" or "workspace" (`ACVoiceSystem.ActivationStrategy` raw values). Unknown values mean the
    /// default.
    public var chromeActivation = "appleScript"
    /// Overlay background (manual glass check): "liquidGlass" (default), "appKitGlass" or "hudMaterial"
    /// (`ACVoiceUI.OverlayBackdrop` raw values). Unknown values mean the default.
    public var overlayBackdrop = "liquidGlass"

    public init() {}

    /// The "Meine Aufgaben" URL for this config. Uses `userId` only; the app fills it from the token prefix
    /// for the flow (`Controller.flowConfig`).
    public var myWorkURL: URL { Routes.myWork(acBaseURL, path: myTasksPath, userId: userId) }

    enum CodingKeys: String, CodingKey {
        case version, acBaseURL, userId, myTasksPath, aliases, synonyms, learnAliases, hotkey, earcons, inputDeviceUID
        case avoidBluetoothInput, fastSelect, contextualStringLimit, visibleChoices, choicesWindow, maxUnclearAnswers
        case launchAtLogin, saveRecordings, acMcpPath, chromeActivation, overlayBackdrop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = Config()
        func get<T: Decodable>(_ k: CodingKeys, _ into: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: k) { into = v }
        }
        func getOptional<T: Decodable>(_ k: CodingKeys, _ into: inout T?) {
            if c.contains(k), (try? c.decodeNil(forKey: k)) == true { into = nil; return }
            if let v = try? c.decodeIfPresent(T.self, forKey: k) { into = v }
        }
        get(.version, &d.version); get(.acBaseURL, &d.acBaseURL); getOptional(.userId, &d.userId)
        get(.myTasksPath, &d.myTasksPath); get(.aliases, &d.aliases); get(.synonyms, &d.synonyms)
        get(.learnAliases, &d.learnAliases)
        get(.hotkey, &d.hotkey); get(.earcons, &d.earcons); getOptional(.inputDeviceUID, &d.inputDeviceUID)
        get(.avoidBluetoothInput, &d.avoidBluetoothInput); get(.fastSelect, &d.fastSelect)
        get(.contextualStringLimit, &d.contextualStringLimit); get(.visibleChoices, &d.visibleChoices)
        get(.choicesWindow, &d.choicesWindow); get(.maxUnclearAnswers, &d.maxUnclearAnswers)
        get(.launchAtLogin, &d.launchAtLogin); get(.saveRecordings, &d.saveRecordings); getOptional(.acMcpPath, &d.acMcpPath)
        get(.chromeActivation, &d.chromeActivation); get(.overlayBackdrop, &d.overlayBackdrop)
        // Clamp values that would break the flow.
        d.visibleChoices = min(max(d.visibleChoices, 1), 9)
        d.contextualStringLimit = min(max(d.contextualStringLimit, 0), 100)
        d.choicesWindow = min(max(d.choicesWindow, 2), 30)
        d.maxUnclearAnswers = min(max(d.maxUnclearAnswers, 0), 5)
        if !Self.isValidBaseURL(d.acBaseURL) { d.acBaseURL = Config().acBaseURL }
        self = d
    }

    /// The AC token travels as a bearer header to this host: https with a host only (no http, no "https://").
    public static func isValidBaseURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    /// Tolerant decode: junk or an empty file gives the defaults.
    public static func decode(_ data: Data) -> Config {
        (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    /// Missing file: defaults.
    public static func load(from url: URL = AppPaths.config) -> Config {
        (try? Data(contentsOf: url)).map(decode) ?? Config()
    }

    public func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("{}".utf8)
    }

    /// Atomic write; creates the directory with mode 0700.
    public func save(to url: URL = AppPaths.config) throws {
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        try encoded().write(to: url, options: .atomic)
    }
}

/// File locations. Nothing here touches the Keychain.
public enum AppPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// ~/Library/Application Support/ac-voice
    public static var support: URL { home.appendingPathComponent("Library/Application Support/ac-voice", isDirectory: true) }
    public static var config: URL { support.appendingPathComponent("config.json") }
    public static var history: URL { support.appendingPathComponent("history.json") }
    /// IPC socket. Under 70 bytes for a typical home path, below the 104-byte sun_path limit.
    public static var socket: URL { support.appendingPathComponent("ipc.sock") }
    /// ~/Library/Caches/io.github.nordavid.acvoice/index.json
    public static var indexCache: URL {
        home.appendingPathComponent("Library/Caches/io.github.nordavid.acvoice/index.json")
    }

    /// Creates `dir` (and parents) with mode 0700 when missing.
    public static func ensureDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
