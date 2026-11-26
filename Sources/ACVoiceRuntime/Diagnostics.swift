import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSystem
import Foundation

/// Diagnose > Diagnose kopieren: a plain-text report for a bug ticket. States, counts, ages and timings only: no
/// transcript, no project or task name, no token, no ETag, no URL path with ids.
public struct DiagnosticsInput: Sendable {
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var phase: FlowPhase
    public var status: RuntimeStatus
    public var microphone: Permission
    public var speechRecognition: Permission
    /// nil: Chrome is not running, so the status is unknown.
    public var automation: AutomationStatus?
    public var loginItem: LoginItemStatus
    public var hotkey: String
    public var ipcClients: Int
    public var index: IndexSnapshot.Stats?
    public var indexFetchedAt: Date?
    public var taskListsFetchedAt: Date?
    public var latencies: [LatencyMetric: LatencyStats]
    public var config: Config
    public var now: Date
    /// Language of the headings and the values (`Controller.language`).
    public var language: AppLanguage

    public init(appVersion: String, build: String, osVersion: String, phase: FlowPhase, status: RuntimeStatus,
                microphone: Permission, speechRecognition: Permission, automation: AutomationStatus?,
                loginItem: LoginItemStatus, hotkey: String, ipcClients: Int, index: IndexSnapshot.Stats?,
                indexFetchedAt: Date?, taskListsFetchedAt: Date?, latencies: [LatencyMetric: LatencyStats],
                config: Config, now: Date, language: AppLanguage = .de) {
        self.appVersion = appVersion; self.build = build; self.osVersion = osVersion; self.phase = phase
        self.status = status; self.microphone = microphone; self.speechRecognition = speechRecognition
        self.automation = automation; self.loginItem = loginItem; self.hotkey = hotkey; self.ipcClients = ipcClients
        self.index = index; self.indexFetchedAt = indexFetchedAt; self.taskListsFetchedAt = taskListsFetchedAt
        self.latencies = latencies; self.config = config; self.now = now; self.language = language
    }
}

/// Diagnose > Diagnose kopieren in the app language. Keys and enum values (phase, permissions, settings) stay as they
/// are: they name code.
public enum Diagnostics {
    public static func text(_ d: DiagnosticsInput) -> String {
        let de = d.language == .de
        func t(_ g: String, _ e: String) -> String { de ? g : e }
        var lines = ["AC Voice \(d.appVersion) (\(d.build)), \(d.osVersion)"]
        func add(_ key: String, _ value: String) { lines.append("\(key): \(value)") }
        add("Phase", d.phase.rawValue)
        add(t("AC-Token", "AC token"), token(d.status.token, d.language))
        add("Index", d.index.map { s in
            t("\(s.projects) Projekte, \(s.taskLists) Aufgabenlisten, \(s.openTasks) offene Aufgaben, \(s.taskIds) Aufgaben-IDs, "
                + "\(s.archiveComplete) Archive vollständig",
              "\(s.projects) projects, \(s.taskLists) task lists, \(s.openTasks) open tasks, \(s.taskIds) task IDs, "
                + "\(s.archiveComplete) archives complete")
        } ?? t("nicht geladen", "not loaded"))
        add(t("Index-Stand", "Index updated"), age(d.indexFetchedAt, d.now, d.language) + t(", Aufgabenlisten ", ", task lists ")
            + age(d.taskListsFetchedAt, d.now, d.language))
        if let e = d.status.indexError { add(t("Index-Fehler", "Index error"), e) }
        add(t("Sprachmodell", "Speech model"), speech(d.status.speech, d.language))
        if let c = d.status.selfCheck {
            add(t("Selbsttest", "Self-test"),
                "\(c.passed ? t("bestanden", "passed") : t("fehlgeschlagen", "failed")), \(Int(c.elapsedMs.rounded())) ms")
        }
        add(t("Mikrofon", "Microphone"), d.microphone.rawValue)
        add(t("Spracherkennung", "Speech recognition"), d.speechRecognition.rawValue)
        add(t("Chrome-Steuerung", "Chrome control"), d.automation?.description ?? t("Chrome läuft nicht", "Chrome is not running"))
        add(t("Chrome-Aktivierung", "Chrome activation"), d.config.chromeActivation)
        if let c = d.status.chromeTest {
            add(t("Chrome-Test", "Chrome test"), c + (d.status.chromeFront.map { ". " + $0 } ?? ""))
        }
        add(t("Tastenkürzel", "Shortcut"),
            d.config.hotkey.enabled ? d.hotkey + (d.status.hotkeyError.map { " (\($0))" } ?? "") : t("aus", "off"))
        let connections = d.ipcClients == 1 ? t("1 Verbindung", "1 connection") : t("\(d.ipcClients) Verbindungen", "\(d.ipcClients) connections")
        add("Stream Deck", connections + (d.status.ipcError.map { " (\($0))" } ?? ""))
        add(t("Anmeldeobjekt", "Login item"), d.loginItem.rawValue)
        add(t("Sprache", "Language"), "\(d.language.rawValue) (config \(d.config.language))")
        add(t("Einstellungen", "Settings"), "earcons \(d.config.earcons), fastSelect \(d.config.fastSelect), visibleChoices "
            + "\(d.config.visibleChoices), choicesWindow \(d.config.choicesWindow), contextualStrings "
            + "\(d.config.contextualStringLimit), inputDevice \(d.config.inputDeviceUID == nil ? t("Standard", "default") : t("fest", "fixed"))")
        for m in LatencyMetric.allCases {
            add(t("Latenz", "Latency") + " \(m.rawValue)", latency(d.latencies[m], d.language))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func token(_ t: RuntimeStatus.Token, _ language: AppLanguage) -> String {
        let de = language == .de
        switch t {
        case .unknown: return de ? "unbekannt" : "unknown"
        case .missing: return de ? "fehlt" : "missing"
        case .present: return de ? "gespeichert" : "stored"
        case .invalid: return de ? "ungültig" : "invalid"
        case .unreadable: return de ? "nicht lesbar" : "unreadable"
        case .needsUserId: return de ? "Benutzer-ID fehlt" : "user ID missing"
        }
    }

    static func speech(_ s: RuntimeStatus.Speech, _ language: AppLanguage) -> String {
        let de = language == .de
        switch s {
        case .warming: return de ? "lädt" : "loading"
        case .ready: return de ? "bereit" : "ready"
        case .unavailable: return de ? "nicht verfügbar" : "not available"
        }
    }

    static func age(_ date: Date?, _ now: Date, _ language: AppLanguage) -> String {
        let de = language == .de
        guard let date else { return de ? "nie" : "never" }
        let s = max(0, now.timeIntervalSince(date))
        let amount = s < 120 ? "\(Int(s)) s" : s < 7200 ? "\(Int(s / 60)) min" : "\(Int(s / 3600)) h"
        return de ? "vor \(amount)" : "\(amount) ago"
    }

    static func latency(_ s: LatencyStats?, _ language: AppLanguage) -> String {
        let de = language == .de
        guard let s, let median = s.median, let p90 = s.p90, let last = s.last else { return de ? "keine Messung" : "no samples" }
        return "n=\(s.count), " + (de ? "Median" : "median") + " \(Int(median.rounded())) ms, p90 \(Int(p90.rounded())) ms, "
            + (de ? "zuletzt" : "last") + " \(Int(last.rounded())) ms"
    }
}
