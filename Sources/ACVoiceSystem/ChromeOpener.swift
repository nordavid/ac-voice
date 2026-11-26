import ACVoiceCore
import ACVoiceFlow
import AppKit
import Carbon // AEDeterminePermissionToAutomateTarget, typeWildCard

/// Automation (TCC "Apple Events") status of ac-voice for a target app.
public enum AutomationStatus: Sendable, Equatable, CustomStringConvertible {
    case granted
    /// -1743: the user denied it. Every call fails until the user allows it in System Settings.
    case denied
    /// -1744: the system has to ask the user first.
    case notDetermined
    /// -600: the target app is not running (the check needs a running target).
    case targetNotRunning
    case other(Int32)

    public init(status: OSStatus) {
        switch status {
        case noErr: self = .granted
        case OSStatus(errAEEventNotPermitted): self = .denied
        case OSStatus(errAEEventWouldRequireUserConsent): self = .notDetermined
        case OSStatus(procNotFound): self = .targetNotRunning
        default: self = .other(status)
        }
    }

    public var description: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .targetNotRunning: return "targetNotRunning"
        case .other(let s): return "other(\(s))"
        }
    }
}

/// How Chrome comes to the front after the script changed the tab.
///
/// Since macOS 14 activation is cooperative: an app activates only when the active app yields. AC Voice is never
/// the active app (non-activating overlay, Stream Deck or hotkey trigger), so whether Chrome follows the
/// AppleScript `activate` is not verified (REVIEW M4). The strategies are selectable so the user can test them.
public enum ActivationStrategy: String, Codable, Sendable, CaseIterable {
    /// `activate` as the last statement of the script (Chrome activates itself on our Apple Event).
    case appleScript
    /// The script skips `activate`; ac-voice calls `NSApp.yieldActivation(to:)` and
    /// `NSRunningApplication.activate(from:options:)`, then `activate(options:)` when that is refused.
    case runningApplication
    /// The script skips `activate`; ac-voice asks LaunchServices to open Chrome with `activates = true`. For a running
    /// app LaunchServices sends a reopen event; Chrome opens a window on it only when it has none, and the script just
    /// made sure one exists.
    case workspace
}

/// Opens AC URLs in Chrome. The runtime talks to this protocol, tests use fakes.
@MainActor
public protocol ChromeOpening: AnyObject {
    /// Opens `url`, reusing an AC tab. Throws `ChromeOpenerError.openFailed` only when the NSWorkspace fallback
    /// failed too (flow event `.openFailed`).
    func open(_ url: URL) async throws -> OpenResult
    /// URL of the active tab of Chrome's front-most normal window when it is an AC page. nil when Chrome is not
    /// running, Automation is not granted (never prompts), the tab is no AC page, or Chrome does not answer within
    /// `Settings.tabQueryDeadline`.
    func currentACTabURL() async -> URL?
    /// Automation status for Chrome. `ask: true` may show the system prompt and waits for the answer; call it from
    /// onboarding while Chrome runs. Runs off the main thread.
    func preflight(ask: Bool) async -> AutomationStatus
}

public enum ChromeOpenerError: Error, Equatable {
    case openFailed
}

/// The system side of `ChromeOpener`: LaunchServices, running apps, TCC and activation. Faked in tests.
@MainActor
public protocol ChromeHost: AnyObject {
    /// nil: Chrome is not installed.
    var chromeAppURL: URL? { get }
    var isChromeRunning: Bool { get }
    var isChromeFrontmost: Bool { get }
    func automationStatus(ask: Bool) async -> AutomationStatus
    /// Opens `url` with the app at `app` (activates it), or with the default browser when `app` is nil.
    func open(_ url: URL, withApplicationAt app: URL?) async throws
    /// Brings Chrome to the front with a strategy other than `.appleScript`.
    func activateChrome(_ strategy: ActivationStrategy)
}

/// Opens AC pages in Google Chrome (PLAN 2.4, REVIEW M4).
///
/// - The AppleScript (Resources/open-ac.applescript) is compiled once and runs on a dedicated thread
///   (`AppleScriptRunner`). The main thread never waits on Chrome.
/// - Two handler calls: `chromestate` reads all windows in 4 Apple Events, `ChromeTabPlan` picks the tab in Swift
///   (normal windows only, exact target first, no reload when the tab shows the target already), then one action
///   handler (`focustab`, `newtab` or `newwindow`) runs it. The script has no loops.
/// - Two timeouts: `with timeout of eventTimeout seconds` inside the script, and a Swift-side `deadline` for both
///   calls together. After the deadline the result is `.fallback(.other)` and the URL opens through
///   NSWorkspace. While the late call still runs, the next `open` skips AppleScript at once (`.busy`).
/// - Chrome not installed: the default browser opens the URL (`.fallback(.other)`).
/// - Chrome not running: LaunchServices launches it with the URL (`.launched`). No Apple Event, no prompt.
/// - Automation denied (-1743): NSWorkspace fallback, `.fallback(.denied)` (the overlay points to System Settings).
/// - Automation not determined: NSWorkspace fallback, `.fallback(.undetermined)` (the overlay points to the setup
///   window). With `askWhenUndetermined` the system prompt is requested once in the background, so the next command
///   can reuse the tab; the app turns that off (the prompt belongs to a setup click).
///
/// Manual activation test (with the user, macOS 14+ cooperative activation, REVIEW M4):
/// 1. Put another app in front (Finder or VS Code), Chrome running with an AC tab in the background.
/// 2. Start `log stream --level info --predicate 'subsystem == "io.github.nordavid.acvoice" AND category == "chrome"'`.
/// 3. Trigger "Öffne WWT Relaunch" with each strategy (`Settings.activation`: appleScript, runningApplication,
///    workspace). Each `open` logs `chrome.activation strategy=… frontmost=true|false` 300 ms after the script.
/// 4. Keep the first strategy that brings Chrome to the front reliably, also from a full-screen app.
@MainActor
public final class ChromeOpener: ChromeOpening {
    public struct Settings: Sendable, Equatable {
        /// Tabs on this origin count as AC tabs ("https://ac.example.com", no trailing slash needed).
        public var acBaseURL: URL
        /// Seconds per Apple Event inside the script (`with timeout`).
        public var eventTimeout: Int = 2
        /// Swift-side deadline for both handler calls of one `open`, seconds. Below the flow's open watchdog (5 s).
        public var deadline: Double = 3.0
        /// Deadline for `currentACTabURL`, seconds (runs at press time, must stay short).
        public var tabQueryDeadline: Double = 0.4
        public var activation: ActivationStrategy = .appleScript
        /// Delay of the frontmost check after a script call, seconds. nil: no check.
        public var verifyActivationAfter: Double? = 0.3
        /// Request the Automation prompt in the background when the status is not determined yet.
        public var askWhenUndetermined = true

        public init(acBaseURL: URL = Config().acBaseURL, activation: ActivationStrategy = .appleScript) {
            self.acBaseURL = acBaseURL
            self.activation = activation
        }
    }

    /// The last activation check, for a debug menu: strategy and whether Chrome was frontmost.
    public private(set) var lastActivationCheck: (strategy: ActivationStrategy, frontmost: Bool)?
    public var settings: Settings

    nonisolated public static let chromeBundleID = "com.google.Chrome"
    nonisolated static let stateHandler = "chromestate"
    nonisolated static let focusHandler = "focustab"
    nonisolated static let newTabHandler = "newtab"
    nonisolated static let newWindowHandler = "newwindow"
    /// Every handler answers this when Chrome is not running.
    nonisolated static let notRunning = ScriptValue.text("notrunning")
    /// The second call always gets at least this much time, seconds.
    nonisolated static let minActionDeadline = 0.25

    private let runner: any AppleScriptRunning
    private let host: any ChromeHost
    private var automationGranted = false
    private var askedThisRun = false
    private let now: @Sendable () -> Double

    /// Production setup: compiles the embedded script on its own thread right away (non-blocking).
    public convenience init(settings: Settings) {
        self.init(settings: settings, runner: AppleScriptRunner(source: OpenACScript.source), host: SystemChromeHost())
    }

    public init(settings: Settings, runner: any AppleScriptRunning, host: any ChromeHost,
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings
        self.runner = runner
        self.host = host
        self.now = now
    }

    /// Waits for the compile step (about 140 ms after launch). false: the script did not compile, every `open` then
    /// uses the NSWorkspace fallback.
    public func prepare() async -> Bool { await runner.prepare() }

    public func open(_ url: URL) async throws -> OpenResult {
        let t0 = now()
        let (result, path) = try await openRouted(url)
        Log.event(.chrome, "chrome.open", .tag("path", path), .ms("elapsed", seconds: now() - t0),
                  .text("result", Self.name(result)), .private("url", url.absoluteString))
        return result
    }

    public func currentACTabURL() async -> URL? {
        guard host.chromeAppURL != nil, host.isChromeRunning, !runner.isBusy else { return nil }
        if !automationGranted {
            guard await host.automationStatus(ask: false) == .granted else { return nil }
            automationGranted = true
        }
        let t0 = now()
        let r = await runner.call(Self.stateHandler, [.int(1)], deadline: settings.tabQueryDeadline)
        var url: URL?
        switch r {
        case .value(Self.notRunning):
            break   // Chrome quit after the isChromeRunning check: no AC tab, and no parse failure to log
        case .value(let v):
            if let s = ChromeWindows(v) {
                url = s.activeACTabURL(base: base).flatMap(URL.init(string:))
            } else {
                Self.logUnreadableState(v)
            }
        case .failed(let code, _):
            if code == Int(errAEEventNotPermitted) { automationGranted = false }
        default:
            break
        }
        Log.event(.chrome, "chrome.activeTab", .ms("elapsed", seconds: now() - t0), .bool("ac", url != nil),
                  .int("projectId", url.flatMap { Routes.projectId(in: $0, base: settings.acBaseURL) } ?? 0))
        return url
    }

    /// Project id of the active AC tab (`Routes.projectId`), the ticket resolver's hint (REVIEW M6).
    public func activeProjectId() async -> Int? {
        guard let url = await currentACTabURL() else { return nil }
        return Routes.projectId(in: url, base: settings.acBaseURL)
    }

    public func preflight(ask: Bool) async -> AutomationStatus {
        let status = await host.automationStatus(ask: ask)
        automationGranted = status == .granted
        Log.event(.chrome, "chrome.preflight", .bool("ask", ask), .text("status", Self.name(status)))
        return status
    }

    // MARK: Routing

    enum Path: String { case script, launch, defaultBrowser, denied, undetermined, busy, timeout, scriptError, notCompiled }

    private func openRouted(_ url: URL) async throws -> (OpenResult, Path) {
        guard let chrome = host.chromeAppURL else {
            try await workspace(url, app: nil)
            return (.fallback(.other), .defaultBrowser)
        }
        guard host.isChromeRunning else {
            try await workspace(url, app: chrome)
            return (.launched, .launch)
        }
        if !automationGranted {
            switch await host.automationStatus(ask: false) {
            case .granted:
                automationGranted = true
            case .denied:
                try await workspace(url, app: chrome)
                return (.fallback(.denied), .denied)
            case .notDetermined:
                try await workspace(url, app: chrome)
                requestPromptInBackground()
                return (.fallback(.undetermined), .undetermined)
            case .targetNotRunning:
                try await workspace(url, app: chrome)
                return (.launched, .launch)
            case .other:
                break // let the Apple Event decide
            }
        }
        if runner.isBusy {
            try await workspace(url, app: chrome)
            return (.fallback(.other), .busy)
        }

        let t0 = now()
        let target = url.absoluteString
        let state: ChromeWindows
        switch await runner.call(Self.stateHandler, [.int(settings.eventTimeout)], deadline: settings.deadline) {
        case .value(Self.notRunning):
            try await workspace(url, app: chrome)
            return (.launched, .launch)
        case .value(let v):
            guard let s = ChromeWindows(v) else {
                Self.logUnreadableState(v)
                try await workspace(url, app: chrome)
                return (.fallback(.other), .scriptError)
            }
            state = s
        case let failure:
            return try await fallback(after: failure, url, chrome)
        }

        let plan = ChromeTabPlan.make(state, target: target, base: base)
        let viaScript = settings.activation == .appleScript
        let secs = ScriptArg.int(settings.eventTimeout)
        let (handler, args, result): (String, [ScriptArg], OpenResult) = switch plan {
        case let .focus(windowId, tab, setURL, setTab):
            (Self.focusHandler, [windowId.arg, .int(tab), .text(target), .bool(setURL), .bool(setTab), secs, .bool(viaScript)],
             .reused)
        case .newTab(let windowId):
            (Self.newTabHandler, [windowId.arg, .text(target), secs, .bool(viaScript)], .newTab)
        case .newWindow:
            (Self.newWindowHandler, [.text(target), secs, .bool(viaScript)], .newWindow)
        }
        let left = max(Self.minActionDeadline, settings.deadline - (now() - t0))
        switch await runner.call(handler, args, deadline: left) {
        case .value(Self.notRunning):
            try await workspace(url, app: chrome)
            return (.launched, .launch)
        case .value:
            if !viaScript { host.activateChrome(settings.activation) }
            scheduleActivationCheck()
            return (result, .script)
        case let failure:
            return try await fallback(after: failure, url, chrome)
        }
    }

    /// NSWorkspace fallback after a failed, late or refused script call.
    private func fallback(after r: ScriptCallResult, _ url: URL, _ chrome: URL) async throws -> (OpenResult, Path) {
        switch r {
        case .value:
            try await workspace(url, app: chrome)
            return (.fallback(.other), .scriptError)
        case .failed(let code, let message):
            Log.event(.chrome, "chrome.script.failed", .int("code", code), .private("message", message ?? ""), level: .error)
            try await workspace(url, app: chrome)
            switch Int32(clamping: code) {
            case Int32(errAEEventNotPermitted):
                automationGranted = false
                return (.fallback(.denied), .denied)
            case Int32(errAEEventWouldRequireUserConsent):
                automationGranted = false
                requestPromptInBackground()
                return (.fallback(.undetermined), .undetermined)
            case Int32(procNotFound):
                return (.launched, .launch)
            case Int32(errAETimeout):
                return (.fallback(.other), .timeout)
            default:
                return (.fallback(.other), .scriptError)
            }
        case .timedOut:
            try await workspace(url, app: chrome)
            return (.fallback(.other), .timeout)
        case .busy:
            try await workspace(url, app: chrome)
            return (.fallback(.other), .busy)
        case .unavailable:
            try await workspace(url, app: chrome)
            return (.fallback(.other), .notCompiled)
        }
    }

    private var base: String { Self.normalizedBase(settings.acBaseURL) }

    private func workspace(_ url: URL, app: URL?) async throws {
        do {
            try await host.open(url, withApplicationAt: app)
        } catch {
            Log.error(.chrome, "chrome.workspace.failed", error)
            throw ChromeOpenerError.openFailed
        }
    }

    private func requestPromptInBackground() {
        guard settings.askWhenUndetermined, !askedThisRun else { return }
        askedThisRun = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.preflight(ask: true)
        }
    }

    private func scheduleActivationCheck() {
        guard let delay = settings.verifyActivationAfter else { return }
        let strategy = settings.activation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            let front = self.host.isChromeFrontmost
            self.lastActivationCheck = (strategy, front)
            Log.event(.chrome, "chrome.activation", .tag("strategy", strategy), .bool("frontmost", front),
                      level: front ? .info : .error)
        }
    }

    // MARK: Pure helpers

    /// A `chromestate` answer that `ChromeWindows` cannot read. Logs only the kinds of its parts, never a URL.
    nonisolated static func logUnreadableState(_ v: ScriptValue) {
        Log.event(.chrome, "chrome.state.unreadable", .shape("shape", v), level: .error)
    }

    /// The base URL as the tab rule compares it: no trailing slash.
    nonisolated static func normalizedBase(_ url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    nonisolated static func name(_ r: OpenResult) -> StaticString {
        switch r {
        case .reused: return "reused"
        case .newTab: return "newTab"
        case .newWindow: return "newWindow"
        case .launched: return "launched"
        case .fallback(.denied): return "fallbackDenied"
        case .fallback(.undetermined): return "fallbackUndetermined"
        case .fallback(.other): return "fallback"
        }
    }

    nonisolated static func name(_ s: AutomationStatus) -> StaticString {
        switch s {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .targetNotRunning: return "targetNotRunning"
        case .other: return "other"
        }
    }
}

/// The real system side of `ChromeOpener`.
@MainActor
public final class SystemChromeHost: ChromeHost {
    private let bundleID: String
    /// TCC calls run here: `ask: true` may wait minutes for the user, so never on the main thread.
    private nonisolated let tccQueue = DispatchQueue(label: "io.github.nordavid.acvoice.automation", qos: .userInitiated)

    public init(bundleID: String = ChromeOpener.chromeBundleID) {
        self.bundleID = bundleID
    }

    public var chromeAppURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    public var isChromeRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    public var isChromeFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }

    public func automationStatus(ask: Bool) async -> AutomationStatus {
        let id = bundleID
        return await withCheckedContinuation { c in
            tccQueue.async {
                c.resume(returning: Self.determine(bundleID: id, ask: ask))
            }
        }
    }

    /// AEDeterminePermissionToAutomateTarget. Sends no Apple Event to the target. With `ask: true` it may show the
    /// consent prompt and block until the user answers.
    nonisolated static func determine(bundleID: String, ask: Bool) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .other(OSStatus(paramErr)) }
        return AutomationStatus(status: AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask))
    }

    public func open(_ url: URL, withApplicationAt app: URL?) async throws {
        guard let app else {
            guard NSWorkspace.shared.open(url) else { throw ChromeOpenerError.openFailed }
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    public func activateChrome(_ strategy: ActivationStrategy) {
        switch strategy {
        case .appleScript:
            return
        case .runningApplication:
            guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
            NSApp?.yieldActivation(to: chrome)
            if !chrome.activate(from: NSRunningApplication.current, options: []) {
                chrome.activate(options: [])
            }
        case .workspace:
            guard let app = chromeAppURL else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, error in
                if let error { Log.error(.chrome, "chrome.activate.failed", error) }
            }
        }
    }
}
