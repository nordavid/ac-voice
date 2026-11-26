import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import ACVoiceSystem
import ACVoiceUI
import Foundation

// Every system service the controller talks to sits behind a protocol here. The app passes the live
// implementations (LiveServices.swift); tests pass fakes, so no test starts the microphone, plays a sound, sends an
// Apple Event, shows a window or touches the Keychain.

// MARK: - Speech

/// What the controller hears from the speech layer: `VoiceSession.Event` without the AVFoundation payloads.
public enum SpeechSignal: Sendable, Equatable {
    /// The session's analyzer still loads; audio is buffered meanwhile.
    case warming
    /// The session's analyzer runs.
    case ready
    /// First audio chunk of the session.
    case micReady
    /// Peak slice level of a chunk in dBFS (about 10 Hz).
    case level(dB: Double)
    case speechStarted
    /// Live transcript: DictationTranscriber and SpeechTranscriber.
    case partial(dt: String, st: String)
    /// The gate decided the end of the utterance; a final follows unless the utterance resumes or was noise.
    case endpoint
    /// The utterance after `.endpoint` goes on (its final text dangled).
    case resumed
    /// The onset after `.endpoint` was noise: the gate waits for speech again in the same utterance.
    case discarded
    /// Final hypotheses (DT best, ST best, alternatives) and the speech end -> event latency in ms.
    case utterance([Hypothesis], latencyMs: Double?)
    case noSpeech
    /// The audio device changed and capture restarted.
    case sourceRestarted
    case failed(SpeechFailure)
}

/// A speech signal with the stamp of the session and utterance it belongs to.
public struct SpeechEvent: Sendable, Equatable {
    public var gen: SpeechGen
    public var signal: SpeechSignal
    public init(_ gen: SpeechGen, _ signal: SpeechSignal) { self.gen = gen; self.signal = signal }
}

/// Result of the speech self-test (a synthesized phrase, no microphone).
public struct SelfCheckResult: Sendable, Equatable {
    public var passed: Bool
    public var elapsedMs: Double
    /// German status line.
    public var message: String
    public init(passed: Bool, elapsedMs: Double, message: String) {
        self.passed = passed; self.elapsedMs = elapsedMs; self.message = message
    }
}

/// The microphone and the transcribers (`VoiceSession` + `MicSource` in the app).
@MainActor
public protocol SpeechServing: AnyObject {
    /// Every event of every session. The controller drops stale stamps.
    var onEvent: (@MainActor (SpeechEvent) -> Void)? { get set }
    /// Assets, priming and the first analyzer, in the background at launch.
    func warmUp(context: [String]) async throws
    /// Microphone on. Throws `SpeechError` when the source does not start.
    func start(context: [String], mode: UtteranceMode, gen: SpeechGen, hangover: Double) async throws
    func rearm(_ mode: UtteranceMode, context: [String]?, gen: SpeechGen, hangover: Double) async
    func setHangover(_ seconds: Double)
    func setHold(_ held: Bool)
    func noteEarcon(duration: Double)
    @discardableResult func endUtteranceNow() -> Bool
    /// Microphone off.
    func stop() async
    /// Synthesizes a test phrase in `language` and transcribes it with that language's speech model
    /// (`SpeechSelfCheck`). The controller passes `Controller.language`, the language the sessions listen in.
    func selfCheck(language: AppLanguage) async -> SelfCheckResult
}

// MARK: - AC index and token

/// The AC index (`IndexStore` + `ACClient` in the app). Every call has its own time budget inside.
@MainActor
public protocol IndexServing: AnyObject {
    var userId: Int { get }
    /// The latest snapshot, without waiting.
    var latest: IndexSnapshot? { get }
    func loadFromDisk() async
    func refreshFast() async -> RefreshReport
    func refreshTaskLists() async -> RefreshReport
    func extendArchives(priority: [Int]) async -> RefreshReport
    func revalidateTaskLists(for request: TaskRequest, activeProjectId: Int?) async -> IndexCheck
    func checkArchives(_ projectIds: [Int]) async -> IndexCheck
    func probe(taskId: Int) async throws -> TaskRef?
    /// After a new sign-in or a pasted token: the next request loads the token again.
    func resetToken() async
}

public enum StoredToken: Sendable, Equatable {
    /// A token is in the Keychain. `userId`: the numeric token prefix ("538-…"), if any.
    case present(userId: Int?)
    case missing
    /// The Keychain answered with an error (German text).
    case unreadable(String)
}

/// The AC token in the login Keychain, one item per AC host (`base`). Never logs or returns the token itself.
@MainActor
public protocol TokenServing: AnyObject {
    func stored(for base: URL) async -> StoredToken
    /// Signs in: asks the AC at `base` to issue an API token for AC Voice (`ACTokenIssuer`), saves it in the Keychain
    /// like a pasted token and returns the user id hint from the token prefix. The password lives only as long as this
    /// call; it is never stored, logged or written anywhere. Throws `ACError`.
    func login(base: URL, username: String, password: String) async throws -> Int?
    /// Saves a pasted token. Returns the user id hint.
    func save(_ token: String, for base: URL) async throws -> Int?
}

// MARK: - Permissions and system state

public enum Permission: String, Sendable, Equatable {
    case granted, denied, notDetermined, restricted
}

public enum SettingsPane: String, Sendable, Equatable {
    case microphone, automation, speechRecognition, loginItems
}

/// TCC state and System Settings. Requests run only on a user click (onboarding).
@MainActor
public protocol PermissionsServing: AnyObject {
    var microphone: Permission { get }
    func requestMicrophone() async -> Permission
    var speechRecognition: Permission { get }
    func requestSpeechRecognition() async -> Permission
    var isChromeRunning: Bool { get }
    func openSettings(_ pane: SettingsPane)
}

// MARK: - Overlay, IPC, Chrome

/// The overlay panel (`ACVoiceUI.OverlayController`).
@MainActor
public protocol OverlayPresenting: AnyObject {
    var onChoose: ((_ n: Int, _ seq: Int) -> Void)? { get set }
    var onDismiss: (() -> Void)? { get set }
    /// The pointer moved onto the card or left it (after a mouse move only; a hide reports `false`).
    var onPointer: ((_ inside: Bool) -> Void)? { get set }
    var choicesWindow: Double { get set }
    func show()
    func hide(fade: Double)
    func render(_ model: OverlayModel)
    func setLevel(_ rms: Double)
}

extension OverlayController: OverlayPresenting {}

/// The IPC server plus what the onboarding and the diagnostics read.
@MainActor
public protocol IPCEndpoint: IPCServing {
    var connectedClients: [IPCClient] { get }
    var onClientsChanged: (@MainActor ([IPCClient]) -> Void)? { get set }
}

extension IPCServer: IPCEndpoint {}

/// Chrome plus the activation check of the last open (for the Chrome test and the diagnostics).
@MainActor
public protocol ChromeService: ChromeOpening {
    var lastActivation: (strategy: ActivationStrategy, frontmost: Bool)? { get }
    /// The AC address changed: tabs on this origin count as AC tabs from now on.
    func setACBaseURL(_ url: URL)
}

/// `setACBaseURL` is `ChromeOpener.setACBaseURL` (tested in ACVoiceSystemTests).
extension ChromeOpener: ChromeService {
    public var lastActivation: (strategy: ActivationStrategy, frontmost: Bool)? { lastActivationCheck }
}

// MARK: - Workspace

/// What the system tells the app besides TCC: Chrome starting and quitting, sleep and wake.
public enum WorkspaceEvent: Sendable, Equatable {
    case chromeLaunched, chromeTerminated
    /// The system sleeps, the displays sleep or the user switched away: background work pauses.
    case sleep
    /// All of that ended.
    case wake
}

/// NSWorkspace notifications (`LiveWorkspace` in the app). `start` only registers observers.
@MainActor
public protocol WorkspaceObserving: AnyObject {
    var onEvent: (@MainActor (WorkspaceEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// No workspace events (tests that do not need them, the demo mode).
@MainActor
public final class NoWorkspaceEvents: WorkspaceObserving {
    public var onEvent: (@MainActor (WorkspaceEvent) -> Void)?
    public init() {}
    public func start() {}
    public func stop() {}
}

// MARK: - Clock and persistence

/// A pending timer.
@MainActor
public protocol TimerToken: AnyObject {
    func cancel()
}

/// Wall clock for the reducer, a monotonic clock for latencies, and monotonic timers.
@MainActor
public protocol RuntimeClock: AnyObject {
    /// Wall clock: the reducer's `now`.
    var now: Date { get }
    /// Monotonic seconds.
    var uptime: Double { get }
    /// Runs `action` on the main actor after `seconds` on a monotonic clock, unless cancelled first.
    func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) -> any TimerToken
    /// Same, for background work: the system may fire up to `tolerance` seconds late and coalesce the wake-up with
    /// others (review C7). Flow timers keep the tight default.
    func after(_ seconds: Double, tolerance: Double, _ action: @escaping @MainActor () -> Void) -> any TimerToken
}

extension RuntimeClock {
    public func after(_ seconds: Double, tolerance: Double, _ action: @escaping @MainActor () -> Void) -> any TimerToken {
        after(seconds, action)
    }
}

/// config.json and history.json in Application Support.
@MainActor
public protocol Persisting: AnyObject {
    func loadConfig() -> Config
    func loadHistory() -> History
    func save(_ history: History)
    /// Updates only the `launchAtLogin` key of config.json; other keys, unknown ones included, stay as they are.
    func saveLaunchAtLogin(_ enabled: Bool)
    /// Updates only the `acBaseURL` key of config.json, the same way.
    func saveACBaseURL(_ url: URL)
    /// Waits for pending writes (at quit).
    func flush()
}

// MARK: - Bundle

/// Everything the controller runs against.
@MainActor
public struct Services {
    public var speech: any SpeechServing
    public var tokens: any TokenServing
    /// Creates the index for a user once a token exists.
    public var makeIndex: @MainActor (_ userId: Int, _ config: Config) -> any IndexServing
    public var permissions: any PermissionsServing
    public var overlay: any OverlayPresenting
    public var ipc: any IPCEndpoint
    public var chrome: any ChromeService
    public var earcons: any EarconPlaying
    public var hotkey: any HotkeyRegistering
    public var loginItem: any LoginItemControlling
    public var clock: any RuntimeClock
    public var store: any Persisting
    public var workspace: any WorkspaceObserving
    /// `Locale.preferredLanguages` in the app; tests pass a fixed list so the language never depends on the machine.
    public var preferredLanguages: [String]

    public init(speech: any SpeechServing, tokens: any TokenServing,
                makeIndex: @escaping @MainActor (_ userId: Int, _ config: Config) -> any IndexServing,
                permissions: any PermissionsServing, overlay: any OverlayPresenting, ipc: any IPCEndpoint,
                chrome: any ChromeService, earcons: any EarconPlaying, hotkey: any HotkeyRegistering,
                loginItem: any LoginItemControlling, clock: any RuntimeClock, store: any Persisting,
                workspace: any WorkspaceObserving = NoWorkspaceEvents(),
                preferredLanguages: [String] = Locale.preferredLanguages) {
        self.speech = speech; self.tokens = tokens; self.makeIndex = makeIndex; self.permissions = permissions
        self.overlay = overlay; self.ipc = ipc; self.chrome = chrome; self.earcons = earcons; self.hotkey = hotkey
        self.loginItem = loginItem; self.clock = clock; self.store = store; self.workspace = workspace
        self.preferredLanguages = preferredLanguages
    }
}
