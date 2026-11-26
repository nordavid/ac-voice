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

    public init(appVersion: String, build: String, osVersion: String, phase: FlowPhase, status: RuntimeStatus,
                microphone: Permission, speechRecognition: Permission, automation: AutomationStatus?,
                loginItem: LoginItemStatus, hotkey: String, ipcClients: Int, index: IndexSnapshot.Stats?,
                indexFetchedAt: Date?, taskListsFetchedAt: Date?, latencies: [LatencyMetric: LatencyStats],
                config: Config, now: Date) {
        self.appVersion = appVersion; self.build = build; self.osVersion = osVersion; self.phase = phase
        self.status = status; self.microphone = microphone; self.speechRecognition = speechRecognition
        self.automation = automation; self.loginItem = loginItem; self.hotkey = hotkey; self.ipcClients = ipcClients
        self.index = index; self.indexFetchedAt = indexFetchedAt; self.taskListsFetchedAt = taskListsFetchedAt
        self.latencies = latencies; self.config = config; self.now = now
    }
}

public enum Diagnostics {
    public static func text(_ d: DiagnosticsInput) -> String {
        var lines = ["AC Voice \(d.appVersion) (\(d.build)), \(d.osVersion)"]
        func add(_ key: String, _ value: String) { lines.append("\(key): \(value)") }
        add("Phase", d.phase.rawValue)
        add("AC-Token", token(d.status.token))
        add("Index", d.index.map { s in
            "\(s.projects) Projekte, \(s.taskLists) Aufgabenlisten, \(s.openTasks) offene Aufgaben, \(s.taskIds) Aufgaben-IDs, "
                + "\(s.archiveComplete) Archive vollständig"
        } ?? "nicht geladen")
        add("Index-Stand", age(d.indexFetchedAt, d.now) + ", Aufgabenlisten " + age(d.taskListsFetchedAt, d.now))
        if let e = d.status.indexError { add("Index-Fehler", e) }
        add("Sprachmodell", speech(d.status.speech))
        if let c = d.status.selfCheck {
            add("Selbsttest", "\(c.passed ? "bestanden" : "fehlgeschlagen"), \(Int(c.elapsedMs.rounded())) ms")
        }
        add("Mikrofon", d.microphone.rawValue)
        add("Spracherkennung", d.speechRecognition.rawValue)
        add("Chrome-Steuerung", d.automation?.description ?? "Chrome läuft nicht")
        add("Chrome-Aktivierung", d.config.chromeActivation)
        if let t = d.status.chromeTest { add("Chrome-Test", t + (d.status.chromeFront.map { ". " + $0 } ?? "")) }
        add("Tastenkürzel", d.config.hotkey.enabled ? d.hotkey + (d.status.hotkeyError.map { " (\($0))" } ?? "") : "aus")
        add("Stream Deck", (d.ipcClients == 1 ? "1 Verbindung" : "\(d.ipcClients) Verbindungen")
            + (d.status.ipcError.map { " (\($0))" } ?? ""))
        add("Anmeldeobjekt", d.loginItem.rawValue)
        add("Einstellungen", "earcons \(d.config.earcons), fastSelect \(d.config.fastSelect), visibleChoices "
            + "\(d.config.visibleChoices), choicesWindow \(d.config.choicesWindow), contextualStrings "
            + "\(d.config.contextualStringLimit), inputDevice \(d.config.inputDeviceUID == nil ? "Standard" : "fest")")
        for m in LatencyMetric.allCases {
            add("Latenz \(m.rawValue)", latency(d.latencies[m]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func token(_ t: RuntimeStatus.Token) -> String {
        switch t {
        case .unknown: return "unbekannt"
        case .missing: return "fehlt"
        case .present: return "gespeichert"
        case .invalid: return "ungültig"
        case .unreadable: return "nicht lesbar"
        case .needsUserId: return "Benutzer-ID fehlt"
        }
    }

    static func speech(_ s: RuntimeStatus.Speech) -> String {
        switch s {
        case .warming: return "lädt"
        case .ready: return "bereit"
        case .unavailable: return "nicht verfügbar"
        }
    }

    static func age(_ date: Date?, _ now: Date) -> String {
        guard let date else { return "nie" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 120 { return "vor \(Int(s)) s" }
        if s < 7200 { return "vor \(Int(s / 60)) min" }
        return "vor \(Int(s / 3600)) h"
    }

    static func latency(_ s: LatencyStats?) -> String {
        guard let s, let median = s.median, let p90 = s.p90, let last = s.last else { return "keine Messung" }
        return "n=\(s.count), Median \(Int(median.rounded())) ms, p90 \(Int(p90.rounded())) ms, zuletzt \(Int(last.rounded())) ms"
    }
}
