import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import ACVoiceSystem
import Foundation
@testable import ACVoiceRuntime

// Fakes for every service. None of them touches the microphone, the speakers, Chrome, the Keychain, the window
// server or the network.

// MARK: - Clock

@MainActor
final class ManualTimer: TimerToken {
    var cancelled = false
    func cancel() { cancelled = true }
}

/// A fake clock: timers fire only in `advance`, in due order, on the main actor.
@MainActor
final class ManualClock: RuntimeClock {
    private let start: Date
    private(set) var uptime: Double = 0
    private var entries: [(seq: Int, due: Double, timer: ManualTimer, action: @MainActor () -> Void)] = []
    private var seq = 0
    /// (delay, tolerance) of every timer that asked for a tolerance.
    private(set) var tolerances: [(delay: Double, tolerance: Double)] = []

    init(now: Date) { start = now }

    var now: Date { start.addingTimeInterval(uptime) }

    func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) -> any TimerToken {
        seq += 1
        let t = ManualTimer()
        entries.append((seq, uptime + max(0, seconds), t, action))
        return t
    }

    func after(_ seconds: Double, tolerance: Double, _ action: @escaping @MainActor () -> Void) -> any TimerToken {
        tolerances.append((seconds, tolerance))
        return after(seconds, action)
    }

    /// Pending, not cancelled timers.
    var pending: Int { entries.filter { !$0.timer.cancelled }.count }

    func advance(_ dt: Double) {
        let target = uptime + dt
        while true {
            entries.removeAll { $0.timer.cancelled }
            guard let next = entries.filter({ $0.due <= target + 1e-9 }).min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) })
            else { break }
            entries.removeAll { $0.seq == next.seq }
            uptime = max(uptime, next.due)
            next.action()
        }
        uptime = target
    }
}

// MARK: - Speech

@MainActor
final class FakeSpeech: SpeechServing {
    var onEvent: (@MainActor (SpeechEvent) -> Void)?
    var calls: [String] = []
    var starts: [(gen: SpeechGen, mode: UtteranceMode, hangover: Double, context: [String])] = []
    var rearms: [(gen: SpeechGen, mode: UtteranceMode, hangover: Double, context: [String]?)] = []
    /// Stamp of the latest start or rearm.
    var gen: SpeechGen?
    var hangover: Double?
    var held = false
    var running = false
    var earconBlanks: [Double] = []
    var startError: SpeechError?
    var warmUpError: (any Error)?
    var warmUpContext: [String]?
    var endNowResult = true
    var selfCheckResult = SelfCheckResult(passed: true, elapsedMs: 812, message: "Spracherkennung bereit")

    func warmUp(context: [String]) async throws {
        calls.append("warmUp")
        warmUpContext = context
        if let warmUpError { throw warmUpError }
    }

    func start(context: [String], mode: UtteranceMode, gen: SpeechGen, hangover: Double) async throws {
        calls.append("start")
        if let startError { throw startError }
        starts.append((gen, mode, hangover, context))
        self.gen = gen
        self.hangover = hangover
        running = true
    }

    func rearm(_ mode: UtteranceMode, context: [String]?, gen: SpeechGen, hangover: Double) async {
        calls.append("rearm")
        rearms.append((gen, mode, hangover, context))
        self.gen = gen
        self.hangover = hangover
    }

    func setHangover(_ seconds: Double) { hangover = seconds }
    func setHold(_ held: Bool) { self.held = held; calls.append("hold \(held)") }
    func noteEarcon(duration: Double) { earconBlanks.append(duration) }

    func endUtteranceNow() -> Bool {
        calls.append("endNow")
        return endNowResult
    }

    func stop() async {
        calls.append("stop")
        running = false
    }

    func selfCheck() async -> SelfCheckResult {
        calls.append("selfCheck")
        return selfCheckResult
    }

    /// Delivers a signal stamped with the latest start or rearm (or `gen`).
    func emit(_ signal: SpeechSignal, gen: SpeechGen? = nil) {
        onEvent?(SpeechEvent(gen ?? self.gen!, signal))
    }

    var stops: Int { calls.filter { $0 == "stop" }.count }
    var endNows: Int { calls.filter { $0 == "endNow" }.count }
}

// MARK: - Index and token

@MainActor
final class FakeIndex: IndexServing {
    let userId: Int
    var snapshot: IndexSnapshot
    var calls: [String] = []
    var fastReport = FakeIndex.report(notModified: 4)
    var listsReport = FakeIndex.report(notModified: 63)
    var revalidateCheck = IndexCheck()
    var revalidations: [(number: Int, activeProjectId: Int?)] = []
    /// Runs on `checkArchives`: may change the snapshot (pages arrived), returns the check.
    var onCheckArchives: (@MainActor (inout IndexSnapshot, [Int]) -> IndexCheck)?
    var archiveRequests: [[Int]] = []
    /// `checkArchives` waits until `releaseArchives()`.
    var holdArchives = false
    private var heldArchives: [CheckedContinuation<Void, Never>] = []
    var probeResult: Result<TaskRef?, ACError> = .success(nil)
    /// Runs on `refreshFast` before the report returns (new projects, renamed ones).
    var onRefreshFast: (@MainActor (inout IndexSnapshot) -> Void)?
    var resets = 0

    init(userId: Int, snapshot: IndexSnapshot) {
        self.userId = userId
        self.snapshot = snapshot
    }

    static func report(fresh: Int = 0, notModified: Int = 0, errors: [ACError] = []) -> RefreshReport {
        var r = RefreshReport()
        r.fresh = fresh
        r.notModified = notModified
        r.failed = errors.count
        r.errors = errors
        return r
    }

    var latest: IndexSnapshot? { snapshot }

    func loadFromDisk() async { calls.append("loadFromDisk") }

    func refreshFast() async -> RefreshReport {
        calls.append("refreshFast")
        onRefreshFast?(&snapshot)
        snapshot.rebuildTasks()
        return fastReport
    }

    func refreshTaskLists() async -> RefreshReport {
        calls.append("refreshTaskLists")
        return listsReport
    }

    func extendArchives(priority: [Int]) async -> RefreshReport {
        calls.append("extendArchives")
        return RefreshReport()
    }

    func revalidateTaskLists(for request: TaskRequest, activeProjectId: Int?) async -> IndexCheck {
        calls.append("revalidate")
        revalidations.append((request.number, activeProjectId))
        return revalidateCheck
    }

    func checkArchives(_ projectIds: [Int]) async -> IndexCheck {
        calls.append("checkArchives")
        archiveRequests.append(projectIds)
        if holdArchives { await withCheckedContinuation { heldArchives.append($0) } }
        let check = onCheckArchives?(&snapshot, projectIds) ?? IndexCheck()
        snapshot.rebuildTasks()
        return check
    }

    func probe(taskId: Int) async throws -> TaskRef? {
        calls.append("probe \(taskId)")
        return try probeResult.get()
    }

    func releaseArchives() {
        holdArchives = false
        let held = heldArchives
        heldArchives = []
        for c in held { c.resume() }
    }

    func resetToken() async {
        calls.append("resetToken")
        resets += 1
    }

    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }
}

@MainActor
final class FakeTokens: TokenServing {
    var stored: StoredToken
    var importResult: Result<Int?, ACError> = .success(538)
    var imports = 0
    /// Saved token values (test tokens only).
    var saved: [String] = []

    init(_ stored: StoredToken) { self.stored = stored }

    func stored() async -> StoredToken { stored }

    func importFromACMCP() async throws -> Int? {
        imports += 1
        let hint = try importResult.get()
        stored = .present(userId: hint)
        return hint
    }

    func save(_ token: String) async throws -> Int? {
        saved.append(token)
        let hint = ACMCPTokenImporter.userId(fromToken: token)
        stored = .present(userId: hint)
        return hint
    }
}

// MARK: - Permissions, overlay, IPC, Chrome, earcons, hotkey, login, store

@MainActor
final class FakePermissions: PermissionsServing {
    var microphone: Permission
    var speechRecognition: Permission = .notDetermined
    var isChromeRunning = true
    var micRequests = 0
    var speechRequests = 0
    var grantOnRequest = true
    var opened: [SettingsPane] = []

    init(microphone: Permission) { self.microphone = microphone }

    func requestMicrophone() async -> Permission {
        micRequests += 1
        microphone = grantOnRequest ? .granted : .denied
        return microphone
    }

    func requestSpeechRecognition() async -> Permission {
        speechRequests += 1
        speechRecognition = .granted
        return speechRecognition
    }

    func openSettings(_ pane: SettingsPane) { opened.append(pane) }
}

@MainActor
final class FakeOverlay: OverlayPresenting {
    var onChoose: ((_ n: Int, _ seq: Int) -> Void)?
    var onDismiss: (() -> Void)?
    var onPointer: ((_ inside: Bool) -> Void)?
    var choicesWindow = 0.0
    var renders: [OverlayModel] = []
    var shows = 0
    var hides: [Double] = []
    var levels: [Double] = []
    var isShown = false

    func show() { shows += 1; isShown = true }
    func hide(fade: Double) { hides.append(fade); isShown = false }
    func render(_ model: OverlayModel) { renders.append(model) }
    func setLevel(_ rms: Double) { levels.append(rms) }

    var last: OverlayModel? { renders.last }
}

/// Esc while the overlay shows: `fire()` is a press of Esc.
@MainActor
final class FakeEscape: EscapeKeyServing {
    private(set) var handler: (@MainActor () -> Void)?
    private(set) var activations = 0
    var isActive: Bool { handler != nil }

    func activate(_ handler: @escaping @MainActor () -> Void) {
        guard self.handler == nil else { return }
        activations += 1
        self.handler = handler
    }

    func deactivate() { handler = nil }

    /// A press of Esc. Does nothing while inactive, like the unregistered Carbon hotkey.
    func fire() { handler?() }
}

@MainActor
final class FakeIPC: IPCEndpoint {
    var onCommand: (@MainActor (IPC.Command, IPCClient) -> Void)?
    var onClientsChanged: (@MainActor ([IPCClient]) -> Void)?
    var connectedClients: [IPCClient] = []
    var startError: (any Error)?
    var started = false
    var stopped = false
    var states: [IPC.State] = []
    var levels: [Double] = []

    func start() async throws {
        if let startError { throw startError }
        started = true
    }

    func stop() { stopped = true }
    func broadcast(_ state: IPC.State) { states.append(state) }
    func level(_ rms: Double) { levels.append(rms) }

    func command(_ cmd: IPC.Command) { onCommand?(cmd, IPCClient(id: 1, name: "streamdeck", version: "0.1.0")) }

    /// Distinct wire phases in order.
    var phases: [IPC.Phase] {
        states.map(\.phase).reduce(into: [IPC.Phase]()) { if $0.last != $1 { $0.append($1) } }
    }
}

@MainActor
final class FakeChrome: ChromeService {
    var tabURL: URL?
    var results: [Result<OpenResult, ChromeOpenerError>] = []
    var defaultResult: OpenResult = .reused
    var opened: [URL] = []
    var preflights: [Bool] = []
    var automation: AutomationStatus = .granted
    var tabQueries = 0
    var lastActivation: (strategy: ActivationStrategy, frontmost: Bool)?

    func open(_ url: URL) async throws -> OpenResult {
        opened.append(url)
        let r = results.isEmpty ? .success(defaultResult) : results.removeFirst()
        if case .success = r { lastActivation = (.appleScript, true) }
        return try r.get()
    }

    func currentACTabURL() async -> URL? {
        tabQueries += 1
        return tabURL
    }

    func preflight(ask: Bool) async -> AutomationStatus {
        preflights.append(ask)
        if ask, automation == .notDetermined { automation = .granted }
        return automation
    }
}

@MainActor
final class FakeEarcons: EarconPlaying {
    var isEnabled = true
    var onPlaybackStart: (@MainActor (Earcon, Double) -> Void)?
    var played: [Earcon] = []
    var prepared = 0
    var prewarms = 0

    func prepare() { prepared += 1 }
    func prewarm() { if isEnabled { prewarms += 1 } }

    func play(_ earcon: Earcon) -> Double {
        guard isEnabled else { return 0 }
        played.append(earcon)
        onPlaybackStart?(earcon, 0.25)
        return 0.25
    }
}

@MainActor
final class FakeHotkey: HotkeyRegistering {
    var registered: Hotkey?
    var handler: (@MainActor (HotkeyEvent) -> Void)?
    var error: HotkeyError?
    var unregistered = 0

    func register(_ hotkey: Hotkey, handler: @escaping @MainActor (HotkeyEvent) -> Void) throws {
        if let error { throw error }
        registered = hotkey
        self.handler = handler
    }

    func unregister() {
        unregistered += 1
        registered = nil
        handler = nil
    }

    func fire(_ e: HotkeyEvent) { handler?(e) }
}

@MainActor
final class FakeLogin: LoginItemControlling {
    var statusValue: LoginItemStatus = .disabled
    /// Reads of `status` (an XPC call in the app): never on the hot path.
    var statusReads = 0
    var error: (any Error)?
    var settingsOpened = 0
    var calls: [Bool] = []
    /// `setEnabled(true)` ends here (macOS may want an approval first).
    var enabledResult: LoginItemStatus = .enabled

    var status: LoginItemStatus {
        statusReads += 1
        return statusValue
    }

    func setEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if let error { throw error }
        statusValue = enabled ? enabledResult : .disabled
    }

    func openSettings() { settingsOpened += 1 }
}

@MainActor
final class FakeWorkspace: WorkspaceObserving {
    var onEvent: (@MainActor (WorkspaceEvent) -> Void)?
    var started = 0
    var stopped = 0
    func start() { started += 1 }
    func stop() { stopped += 1 }
    func post(_ e: WorkspaceEvent) { onEvent?(e) }
}

@MainActor
final class FakeStore: Persisting {
    var config: Config
    var history: History
    var savedHistories: [History] = []
    var launchAtLogin: [Bool] = []
    var flushes = 0

    init(config: Config, history: History = History()) {
        self.config = config
        self.history = history
    }

    func loadConfig() -> Config { config }
    func loadHistory() -> History { history }
    func save(_ history: History) { savedHistories.append(history) }
    func saveLaunchAtLogin(_ enabled: Bool) { launchAtLogin.append(enabled) }
    func flush() { flushes += 1 }
}

struct TestError: Error {}
