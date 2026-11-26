import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import ACVoiceSystem
import ACVoiceUI
import AppKit
import AVFoundation
import Speech

// The app's real services. Tests never create these: they open the microphone, read the Keychain, show windows or
// talk to Chrome.

// MARK: - Speech

/// `VoiceSession` on the real microphone (`MicSource`), with the flow's hangovers as the gate defaults.
@MainActor
public final class LiveSpeech: SpeechServing {
    public var onEvent: (@MainActor (SpeechEvent) -> Void)?
    private let session: VoiceSession
    private let source: MicSource
    private var pumps: [Int: Task<Void, Never>] = [:]

    public init(config: Config, timings: FlowTimings) {
        session = VoiceSession(tuning: Self.tuning(timings))
        source = MicSource(options: .init(deviceUID: config.inputDeviceUID, avoidBluetooth: config.avoidBluetoothInput))
    }

    /// The gate settings for the app's flow. The flow sends every hangover explicitly; these are the floors and
    /// defaults (FlowTimings stays the source).
    nonisolated static func tuning(_ timings: FlowTimings) -> VoiceSession.Tuning {
        var tuning = VoiceSession.Tuning()
        tuning.gate.commandHangover = timings.commandHangover
        tuning.gate.answerHangover = timings.answerHangover
        tuning.gate.incompleteHangover = timings.incompleteHangover
        // The flow owns the no-speech timeout (from micReady, waiting for a held key, restarting on release and
        // after a discarded noise onset, retry silence). A second clock in the gate counted from arming and went
        // deaf after 4 s while the flow still listened (review C1: a long push-to-talk hold, a cough).
        tuning.gate.noSpeechTimeout = .infinity
        tuning.gate.maxUtterance = timings.maxUtterance
        return tuning
    }

    public func warmUp(context: [String]) async throws {
        try await session.warmUp(context: context)
    }

    public func start(context: [String], mode: UtteranceMode, gen: SpeechGen, hangover: Double) async throws {
        let stream = try await session.start(context: context, source: source, mode: mode, gen: gen, hangover: hangover)
        let id = gen.session
        pumps[id] = Task { @MainActor [weak self] in
            for await e in stream {
                self?.onEvent?(SpeechEvent(e.gen, Self.signal(e.kind)))
            }
            self?.pumps[id] = nil
        }
    }

    public func rearm(_ mode: UtteranceMode, context: [String]?, gen: SpeechGen, hangover: Double) async {
        await session.rearm(mode, context: context, gen: gen, hangover: hangover)
    }

    public func setHangover(_ seconds: Double) { session.setHangover(seconds) }
    public func setHold(_ held: Bool) { session.setHold(held) }
    public func noteEarcon(duration: Double) { session.noteEarcon(duration: duration) }
    public func endUtteranceNow() -> Bool { session.endUtteranceNow() }
    public func stop() async { await session.stop() }

    public func selfCheck() async -> SelfCheckResult {
        let r = await SpeechSelfCheck.run()
        return SelfCheckResult(passed: r.passed, elapsedMs: r.elapsedMs, message: r.message)
    }

    nonisolated static func signal(_ k: VoiceSession.Kind) -> SpeechSignal {
        switch k {
        case .warming: return .warming
        case .ready: return .ready
        case .micReady: return .micReady
        case .level(let db, _): return .level(dB: Double(db))
        case .speechStarted: return .speechStarted
        case .endpoint: return .endpoint
        case .resumed: return .resumed
        case .discarded: return .discarded
        case let .partial(dt, st): return .partial(dt: dt, st: st)
        case .utterance(let u): return .utterance(u.hypotheses, latencyMs: u.timing.totalMs)
        case .noSpeech: return .noSpeech
        case .sourceRestarted: return .sourceRestarted
        case .failed(let e): return .failed(e.failure)
        }
    }
}

// MARK: - AC

/// `IndexStore` + `ACClient` with the Keychain token (re-import from ac-mcp after a rejection).
@MainActor
public final class LiveIndex: IndexServing {
    public let userId: Int
    private let client: ACClient
    private let store: IndexStore

    public init(config: Config, userId: Int, cacheURL: URL = AppPaths.indexCache) {
        self.userId = userId
        let tokens = KeychainTokenStore(account: LiveTokens.account(config),
                                        reimport: ACMCPTokenImporter(directory: ACMCPTokenImporter.directory(for: config)))
        client = ACClient(base: config.acBaseURL, userId: userId, tokens: tokens)
        store = IndexStore(client: client, cacheURL: cacheURL)
    }

    public var latest: IndexSnapshot? { store.latest }
    public func loadFromDisk() async { _ = await store.loadFromDisk() }
    public func refreshFast() async -> RefreshReport { await store.refreshFast() }
    public func refreshTaskLists() async -> RefreshReport { await store.refreshTaskLists() }
    public func extendArchives(priority: [Int]) async -> RefreshReport { await store.extendArchives(priority: priority) }
    public func revalidateTaskLists(for request: TaskRequest, activeProjectId: Int?) async -> IndexCheck {
        await store.revalidateTaskLists(for: request, activeProjectId: activeProjectId)
    }
    public func checkArchives(_ projectIds: [Int]) async -> IndexCheck { await store.checkArchives(projectIds) }
    public func probe(taskId: Int) async throws -> TaskRef? { try await store.probe(taskId: taskId) }
    public func resetToken() async { await client.resetToken() }
}

/// The login Keychain (service "io.github.nordavid.acvoice", account = AC host) and the read-only ac-mcp import. Keychain
/// calls run on a private serial queue, never on the main thread.
@MainActor
public final class LiveTokens: TokenServing {
    private let keychain: KeychainTokenStore
    private let importer: ACMCPTokenImporter
    private nonisolated static let queue = DispatchQueue(label: "io.github.nordavid.acvoice.tokens", qos: .userInitiated)

    public init(config: Config) {
        keychain = KeychainTokenStore(account: Self.account(config))
        importer = ACMCPTokenImporter(directory: ACMCPTokenImporter.directory(for: config))
    }

    nonisolated static func account(_ config: Config) -> String { config.acBaseURL.host ?? "ac.example.com" }

    public func stored() async -> StoredToken {
        let keychain = keychain
        return await Self.offMain {
            do {
                guard let t = try keychain.load() else { return .missing }
                return .present(userId: ACMCPTokenImporter.userId(fromToken: t))
            } catch {
                return .unreadable((error as? ACError)?.userMessage ?? ACError.keychain(status: 0).userMessage)
            }
        }
    }

    public func importFromACMCP() async throws -> Int? {
        let keychain = keychain, importer = importer
        return try await Self.offMainThrowing {
            let imported = try importer.load()
            try keychain.save(imported.token)
            return imported.userId
        }
    }

    public func save(_ token: String) async throws -> Int? {
        let keychain = keychain
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await Self.offMainThrowing {
            try keychain.save(clean)
            return ACMCPTokenImporter.userId(fromToken: clean)
        }
    }

    private nonisolated static func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in queue.async { c.resume(returning: body()) } }
    }

    private nonisolated static func offMainThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in queue.async { c.resume(with: Result { try body() }) } }
    }
}

// MARK: - Permissions

/// TCC through AVFoundation and Speech; requests only from onboarding clicks.
@MainActor
public final class LivePermissions: PermissionsServing {
    public init() {}

    public var microphone: Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func requestMicrophone() async -> Permission {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone
    }

    public var speechRecognition: Permission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func requestSpeechRecognition() async -> Permission {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
        }
        return speechRecognition
    }

    public var isChromeRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: ChromeOpener.chromeBundleID).contains { !$0.isTerminated }
    }

    public func openSettings(_ pane: SettingsPane) {
        let anchor = switch pane {
        case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .automation: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .speechRecognition: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .loginItems: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        }
        if let url = URL(string: anchor) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Workspace

/// NSWorkspace notifications: Chrome launching and quitting, and sleep and wake (system sleep, display sleep, a
/// fast user switch). Registering observers shows nothing and asks for nothing.
@MainActor
public final class LiveWorkspace: WorkspaceObserving {
    public var onEvent: (@MainActor (WorkspaceEvent) -> Void)?
    private var observers: [any NSObjectProtocol] = []
    /// Reasons the app counts as asleep; `.sleep` when the first arrives, `.wake` when the last ends.
    private var asleep: Set<String> = []

    public init() {}

    public func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        // The handlers get the bundle id of the app the notification is about (nil for sleep and wake).
        func observe(_ name: Notification.Name, _ handle: @escaping @MainActor (String?) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { handle(bundleID) }
            })
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] in
            if $0 == ChromeOpener.chromeBundleID { self?.onEvent?(.chromeLaunched) }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] in
            if $0 == ChromeOpener.chromeBundleID { self?.onEvent?(.chromeTerminated) }
        }
        let pairs: [(String, Notification.Name, Notification.Name)] = [
            ("system", NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            ("screens", NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            ("session", NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for (reason, sleep, wake) in pairs {
            observe(sleep) { [weak self] _ in self?.set(reason, asleep: true) }
            observe(wake) { [weak self] _ in self?.set(reason, asleep: false) }
        }
    }

    public func stop() {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
    }

    private func set(_ reason: String, asleep on: Bool) {
        let was = !asleep.isEmpty
        if on { asleep.insert(reason) } else { asleep.remove(reason) }
        let now = !asleep.isEmpty
        if now != was { onEvent?(now ? .sleep : .wake) }
    }
}

// MARK: - Files

/// config.json and history.json (`AppPaths`). Writes run on a utility queue; `flush` waits for them.
@MainActor
public final class FileStore: Persisting {
    public let configURL: URL
    public let historyURL: URL
    private nonisolated let queue = DispatchQueue(label: "io.github.nordavid.acvoice.store", qos: .utility)

    public init(configURL: URL = AppPaths.config, historyURL: URL = AppPaths.history) {
        self.configURL = configURL
        self.historyURL = historyURL
    }

    public func loadConfig() -> Config { Config.load(from: configURL) }
    public func loadHistory() -> History { History.load(from: historyURL) }

    public func save(_ history: History) {
        let url = historyURL
        queue.async {
            do { try history.save(to: url) } catch { Log.error(.app, "history.save.failed", error) }
        }
    }

    public func saveLaunchAtLogin(_ enabled: Bool) {
        let url = configURL
        queue.async {
            do { try Self.update(url, key: "launchAtLogin", value: enabled) } catch { Log.error(.app, "config.save.failed", error) }
        }
    }

    public func flush() { queue.sync {} }

    /// Sets one key in a JSON object file and keeps every other key (unknown ones too). A missing or broken file
    /// becomes a new object.
    nonisolated static func update(_ url: URL, key: String, value: Bool) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        }
        object[key] = value
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Assembly

extension Services {
    /// The app's services. Creating them shows nothing, registers nothing and opens no microphone; the controller
    /// starts them in `start()`.
    public static func live(config: Config, timings: FlowTimings, store: FileStore) -> Services {
        var chromeSettings = ChromeOpener.Settings(acBaseURL: config.acBaseURL,
                                                   activation: ActivationStrategy(rawValue: config.chromeActivation) ?? .appleScript)
        // The Automation prompt comes from the setup window's button only, never from a voice command.
        chromeSettings.askWhenUndetermined = false
        let chrome = ChromeOpener(settings: chromeSettings)
        let overlay = OverlayController()
        overlay.backdrop = OverlayBackdrop(rawValue: config.overlayBackdrop) ?? .liquidGlass
        return Services(
            speech: LiveSpeech(config: config, timings: timings),
            tokens: LiveTokens(config: config),
            makeIndex: { userId, config in LiveIndex(config: config, userId: userId) },
            permissions: LivePermissions(),
            overlay: EscapeClosesOverlay(overlay, escape: EscapeKey(holdModifiers: config.hotkey.enabled ? config.hotkey.modifiers : 0)),
            ipc: IPCServer(),
            chrome: chrome,
            earcons: EarconPlayer(),
            hotkey: GlobalHotkey(),
            loginItem: LaunchAtLogin(),
            clock: SystemClock(),
            store: store,
            workspace: LiveWorkspace())
    }
}
