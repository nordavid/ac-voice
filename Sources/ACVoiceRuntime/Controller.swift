import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import ACVoiceSystem
import ACVoiceUI
import Foundation

/// What the menu, the onboarding window and the diagnostics show besides the flow phase.
public struct RuntimeStatus: Sendable, Equatable {
    public enum Token: Sendable, Equatable {
        case unknown, missing, present, invalid, unreadable
        /// A token exists, but neither config.json nor the token prefix names the AC user id.
        case needsUserId
    }
    public enum Speech: Sendable, Equatable { case warming, ready, unavailable }

    public var token: Token = .unknown
    /// Why the last token import or paste failed (German).
    public var tokenMessage: String?
    public var speech: Speech = .warming
    /// The last refresh failed (German, `ACError.userMessage`).
    public var indexError: String?
    public var lastRefresh: Date?
    public var projects = 0
    public var hotkeyError: String?
    public var ipcError: String?
    public var selfCheck: SelfCheckResult?
    public var selfCheckRunning = false
    public var chromeTest: String?
    public var chromeFront: String?
    public var chromeTestRunning = false
    /// Chrome's Automation status as last seen (preflight without a prompt, or an open's result); nil before the
    /// first check. `.notDetermined` puts the badge on the menu icon: every open makes a new tab then.
    public var chromeAutomation: AutomationStatus?
    public var loginMessage: String?
    /// A menu action that needs an idle flow ran while a command was active.
    public var notice: String?
    public init() {}
}

/// Runs the voice flow (PLAN 2.1, 3): owns the `VoiceFlow` state, feeds it every trigger, speech event, async result
/// and fired timer, and runs the effects it returns, in order, against the injected `Services`.
///
/// - Speech lifecycle calls (start, rearm, stop) and the live controls run through one serial queue, so they reach
///   the speech layer in effect order.
/// - Timers run on the injected clock (monotonic in the app). The reducer drops stale timer tokens and stale speech
///   stamps, so a late event never acts on a newer session.
/// - Index calls, Chrome and the active-tab query run as tasks; their results come back as flow events. The task
///   index in `env` is synced from the store right before such an event.
/// - Logging: events and effects only as tags. Transcripts go to the log as private text.
@MainActor
public final class Controller {
    public let services: Services
    public let timings: FlowTimings
    public private(set) var flow: VoiceFlow
    public private(set) var env: FlowEnv
    public private(set) var config: Config
    public private(set) var history: History
    /// The last published overlay snapshot.
    public private(set) var model = OverlayModel()
    public private(set) var status = RuntimeStatus()
    public private(set) var index: (any IndexServing)?
    /// Contextual strings of the command phase (rebuilt with the interpreter).
    public private(set) var commandContext: [String] = []

    /// The flow needs the setup window: no token, or the microphone is not allowed.
    public var onNeedsSetup: (@MainActor () -> Void)?
    /// `IPCServer.start` found a live instance: the app quits.
    public var onSecondInstance: (@MainActor () -> Void)?
    /// Chrome started or quit (the setup window re-reads its Chrome row).
    public var onChromeRunningChanged: (@MainActor (Bool) -> Void)?

    /// Background refresh cadence (PLAN 5): projects, favorites, own tasks every 5 minutes; task lists every 12.
    public static let fastRefreshInterval = 300.0
    public static let listsRefreshInterval = 720.0
    /// A background refresh that finds the flow busy tries again after this.
    public static let busyRetry = 30.0
    /// Background timers may fire this share of their interval late, so the system can coalesce wake-ups (review C7).
    public static let backgroundTolerance = 0.1
    /// After a wake, the first refresh waits this long (the network comes back first).
    public static let wakeDelay = 12.0
    /// Transport errors of refreshes within this long after a wake do not show in the menu.
    public static let wakeGrace = 30.0
    /// history.json is written this long after the last change.
    public static let historySaveDelay = 1.5

    private var observers: [@MainActor () -> Void] = []
    private var queue: [FlowEvent] = []
    private var dispatching = false
    private var lastPhase: FlowPhase = .idle
    private var timers: [TimerKind: (id: TimerID, token: any TimerToken)] = [:]
    private let speechWork = SerialWork()
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var taskCounter = 0
    private var lastEntries: [ProjectEntry]?
    private var lastInputs: EntryInputs?
    private var interpreterDirty = false
    private var historyDirty = false
    private var historySave: (any TimerToken)?
    private var backgroundTimers: [BackgroundJob: any TimerToken] = [:]
    private var fastRefreshRunning = false
    private var listsRefreshRunning = false
    /// Bumped when a new token arrives: refresh results of the old token do not change the token status.
    private var tokenGeneration = 0
    private var hotkeyCounter = 0
    private var heldHotkey: String?
    private var splitter = TranscriptSplitter()
    private var splitterGen: SpeechGen?
    private let signposts = FlowSignposts()
    private var demo: OverlayDemo?
    private var started = false
    /// `shutdown()` ran: triggers and late results are dropped.
    private var stopped = false
    /// The system sleeps (or the screens, or the user switched away): no background refresh.
    private(set) var asleep = false
    /// Uptime of the last wake, for `wakeGrace`.
    private var wokeAt: Double?
    /// The setup window opened once for Chrome's undetermined Automation in this run.
    private var chromeSetupOffered = false
    /// The setup window waits for the flow to finish (an open fell back for undetermined Automation).
    private var chromeSetupPending = false
    /// Login item status, read off the hot path (at launch, after a change, when the menu opens).
    public private(set) var loginStatus: LoginItemStatus = .disabled
    /// The menu icon shows a check for a moment (after "Diagnose kopieren").
    public private(set) var iconFlash: String?

    enum BackgroundJob { case fast, lists }

    public init(services: Services, timings: FlowTimings = .init(), config: Config? = nil, history: History? = nil) {
        self.services = services
        self.timings = timings
        let cfg = config ?? services.store.loadConfig()
        let hist = history ?? services.store.loadHistory()
        self.config = cfg
        self.history = hist
        flow = VoiceFlow(timings: timings, speechWarm: false)
        env = FlowEnv(interpreter: Interpreter(projects: [], config: cfg, history: hist), config: cfg)
        rebuildInterpreter()
        wire()
    }

    // MARK: - Lifecycle

    /// Launch: IPC socket, hotkey, token and index, speech warm-up, background refresh. Returns once the cached index
    /// is loaded; warm-up and network refreshes go on in the background.
    public func start() async {
        guard !started else { return }
        started = true
        do {
            try await services.ipc.start()
            status.ipcError = nil
        } catch IPCServerError.alreadyRunning {
            Log.event(.app, "app.secondInstance", level: .error)
            onSecondInstance?()
            return
        } catch {
            Log.error(.ipc, "ipc.start.failed", error)
            status.ipcError = AppText.ipcUnavailable
        }
        if config.earcons { services.earcons.prepare() }
        registerHotkey()
        services.workspace.onEvent = { [weak self] e in self?.workspaceEvent(e) }
        services.workspace.start()
        refreshLoginStatus()
        await connectAC()
        warmUpSpeech()
        scheduleBackground(.fast, after: Self.fastRefreshInterval)
        isRunning = true
        statusChanged()
        if needsSetup { onNeedsSetup?() }
    }

    /// `start()` finished (false for a second instance, which quits).
    public private(set) var isRunning = false

    /// Quit: microphone off, socket removed, history written. The flow goes idle first, so its `.stopMic` and every
    /// speech job queued before (a press right before the quit) run in order: nothing starts the mic after the stop
    /// (review C5).
    public func shutdown() async {
        guard !stopped else { return }
        stopDemo()
        send(.cancel)
        stopped = true
        for t in timers.values { t.token.cancel() }
        timers = [:]
        for t in backgroundTimers.values { t.cancel() }
        backgroundTimers = [:]
        for t in tasks.values { t.cancel() }
        services.workspace.stop()
        services.hotkey.unregister()
        services.ipc.stop()
        flushHistory()
        services.store.flush()
        let speech = services.speech
        speechWork.enqueue { await speech.stop() }
        await speechWork.idle()
    }

    /// Token missing or unusable, or the microphone is not allowed.
    public var needsSetup: Bool {
        status.token != .present || services.permissions.microphone != .granted
    }

    /// Something in the menu needs the user (badge on the menu bar icon). Undetermined Chrome Automation counts: it
    /// silently turns every open into a new tab (review C2).
    public var needsAttention: Bool {
        needsSetup || status.speech == .unavailable || status.chromeAutomation == .notDetermined
    }

    public func observeStatus(_ observer: @escaping @MainActor () -> Void) { observers.append(observer) }

    // MARK: - Triggers

    /// An external trigger: IPC, hotkey, menu, URL scheme or an overlay click. Stops the overlay demo first.
    public func trigger(_ event: FlowEvent) {
        guard !stopped else { return }
        switch event {
        case .press, .cancel, .choose:
            if isDemoRunning { stopDemo() }
            // A click picks without a new final: the final -> opened interval does not apply.
            if case .choose = event { signposts.reset() }
        default:
            break
        }
        send(event)
    }

    /// Menu "Zuhören".
    public func listen() { trigger(.press(Press(source: .menu))) }

    /// `acvoice://press`, `acvoice://cancel`, `acvoice://setup`. Returns false for anything else.
    @discardableResult
    public func handleURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "acvoice" else { return false }
        switch (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "press": trigger(.press(Press(source: .url)))
        case "cancel": trigger(.cancel)
        case "setup": onNeedsSetup?()
        default: return false
        }
        return true
    }

    func hotkey(_ e: HotkeyEvent) {
        switch e {
        case .pressed:
            hotkeyCounter += 1
            let id = "hk-\(hotkeyCounter)"
            heldHotkey = id
            trigger(.press(Press(id: id, source: .hotkey)))
        case .released(let heldMs):
            guard let id = heldHotkey else { return }
            heldHotkey = nil
            trigger(.release(pressId: id, heldMs: heldMs))
        }
    }

    func ipcCommand(_ cmd: IPC.Command, from client: IPCClient) {
        if case .hello = cmd {
            Log.event(.ipc, "ipc.hello", .int("client", client.id))
            statusChanged()
            return
        }
        guard let event = FlowEvent(cmd, source: .streamDeck) else { return }
        trigger(event)
    }

    // MARK: - Event loop

    /// Feeds one event to the reducer and runs its effects. Effects that send events (a synchronous fake, a refused
    /// microphone) queue them, so every event sees the state after the previous one's effects.
    func send(_ event: FlowEvent) {
        guard !stopped else { return }
        queue.append(event)
        guard !dispatching else { return }
        dispatching = true
        while !queue.isEmpty {
            let e = queue.removeFirst()
            let tag = EventTag(e)
            let fx = flow.handle(e, now: services.clock.now, env: env)
            Log.event(.flow, "flow.event", .tag("event", tag), .tag("phase", flow.phase), .int("effects", fx.count),
                      level: tag.isFrequent ? .debug : .info)
            run(fx)
            if interpreterDirty { rebuildInterpreter() }
            if flow.phase != lastPhase { phaseChanged() }
        }
        dispatching = false
    }

    private func run(_ effects: [Effect]) {
        let speech = services.speech
        for effect in effects {
            switch effect {
            case .publish(let m):
                model = m
                services.overlay.render(m)
                services.ipc.broadcast(m.ipcState())
            case .showOverlay:
                // Start the earcon output now: at micReady the engine start would block the main thread while the
                // first partials arrive (review C8).
                if config.earcons { services.earcons.prewarm() }
                services.overlay.show()
            case .hideOverlay(let fade):
                services.overlay.hide(fade: fade)
            case let .startMic(gen, mode, hangover):
                startMic(gen, mode, hangover)
            case let .rearm(gen, mode, hangover):
                splitter.reset()
                let context = context(for: mode)
                speechWork.enqueue { await speech.rearm(Self.utteranceMode(mode), context: context, gen: gen, hangover: hangover) }
            case .setHangover(let seconds):
                speechWork.perform { speech.setHangover(seconds) }
            case .suspendEndpointing(let held):
                speechWork.perform { speech.setHold(held) }
            case .endUtteranceNow:
                speechWork.perform {
                    if !speech.endUtteranceNow() { Log.event(.speech, "speech.endNow.ignored") }
                }
            case .stopMic:
                speechWork.enqueue { await speech.stop() }
            case .refreshIndex:
                refreshFast()
            case let .open(url, request):
                open(url, request: request)
            case let .revalidateTaskLists(task, activeProjectId, request):
                revalidate(task, activeProjectId: activeProjectId, request: request)
            case let .fetchArchive(projectIds, request):
                fetchArchive(projectIds, request: request)
            case let .probeTask(taskId, request):
                probe(taskId, request: request)
            case let .schedule(id, after):
                schedule(id, after: after)
            case .cancelTimer(let kind):
                timers.removeValue(forKey: kind)?.token.cancel()
            case .earcon(let e):
                services.earcons.play(e)
            case .recordOpen(let pid):
                history.recordOpen(projectId: pid, at: services.clock.now)
                historyChanged()
            case let .recordPick(query, pid):
                history.recordPick(query: query, projectId: pid)
                historyChanged()
            }
        }
    }

    private func phaseChanged() {
        let phase = flow.phase
        lastPhase = phase
        if phase == .idle || phase == .error { signposts.reset() }
        statusChanged()
        if phase == .idle, chromeSetupPending {
            chromeSetupPending = false
            offerChromeSetup()
        }
    }

    private func statusChanged() {
        for o in observers { o() }
    }

    // MARK: - Speech

    static func utteranceMode(_ m: ListenMode) -> UtteranceMode {
        if case .answer = m { return .answer }
        return .command
    }

    func context(for mode: ListenMode) -> [String] {
        switch mode {
        case .command:
            return commandContext
        case let .answer(titles, firstNumber, hasMore):
            return ContextBuilder.answer(titles: titles, hasMore: hasMore, firstNumber: firstNumber,
                                         limit: config.contextualStringLimit)
        }
    }

    private func startMic(_ gen: SpeechGen, _ mode: ListenMode, _ hangover: Double) {
        env.activeProjectId = nil
        splitter.reset()
        signposts.press(session: gen.session, at: services.clock.uptime)
        let mic = services.permissions.microphone
        guard mic == .granted else {
            // The prompt belongs to a click in the onboarding window, never to a key press.
            Log.event(.speech, "speech.micNotGranted", .tag("permission", mic))
            send(.speechFailed(gen, .micDenied))
            onNeedsSetup?()
            return
        }
        syncIndex()
        let speech = services.speech
        let context = context(for: mode)
        speechWork.enqueue { [weak self] in
            do {
                try await speech.start(context: context, mode: Self.utteranceMode(mode), gen: gen, hangover: hangover)
            } catch {
                let failure = (error as? SpeechError)?.failure ?? .engine
                Log.event(.speech, "speech.start.failed", .tag("failure", FailureTag(failure)), level: .error)
                self?.send(.speechFailed(gen, failure))
            }
        }
        queryActiveTab(session: gen.session)
    }

    /// The project of Chrome's active AC tab, the ticket resolver's hint (REVIEW M6). Only when Automation is granted
    /// already: `currentACTabURL` never prompts.
    private func queryActiveTab(session: Int) {
        let chrome = services.chrome
        spawn { [weak self] in
            let url = await chrome.currentACTabURL()
            guard let self, self.flow.session == session else { return }
            self.env.activeProjectId = url.flatMap { Routes.projectId(in: $0, base: self.config.acBaseURL) }
        }
    }

    private func speechEvent(_ e: SpeechEvent) {
        let current = e.gen.session == flow.session
        switch e.signal {
        case .warming:
            if current { send(.speechWarm(false)) }
        case .ready:
            setSpeech(.ready)
            if current { send(.speechWarm(true)) }
        case .micReady:
            signposts.micReady(session: e.gen.session, at: services.clock.uptime)
            send(.micReady(e.gen))
        case .level(let db):
            guard current else { return }
            let v = ACVoiceUI.LevelMeter.normalized(dB: db)
            services.overlay.setLevel(v)
            services.ipc.level(v)
        case .speechStarted:
            send(.speechStarted(e.gen))
        case let .partial(dt, st):
            if splitterGen != e.gen { splitter.reset(); splitterGen = e.gen }
            let shown = dt.trimmingCharacters(in: .whitespaces).isEmpty ? st : dt
            let hyps = [dt, st].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { Hypothesis($0) }
            send(.partial(e.gen, splitter.next(shown), hyps))
        case .endpoint:
            guard e.gen == flow.armed else { return }
            signposts.endpoint(e.gen, at: services.clock.uptime)
            // While the model is not warm the final waits for the analyzer: start the flow's (cold) finalize
            // watchdog now, not at maxUtterance (review C4). Warm, the final follows within ~50 ms; forwarding the
            // end then would only flash "processing" for an utterance that resumes or turns out to be noise.
            if !flow.speechWarm { send(.speechEnded(e.gen)) }
        case .resumed:
            send(.speechResumed(e.gen))
        case .discarded:
            send(.speechDiscarded(e.gen))
        case let .utterance(hyps, latencyMs):
            // A late final of an older utterance must not restart the intervals of the current one.
            if e.gen == flow.armed { signposts.final(e.gen, at: services.clock.uptime, latencyMs: latencyMs) }
            splitter.reset()
            Log.event(.speech, "speech.final", .int("hypotheses", hyps.count), .bool("current", current))
            if let first = hyps.first { Log.transcript(.speech, "speech.final.text", first.text) }
            send(.utterance(e.gen, hyps))
        case .noSpeech:
            send(.noSpeech(e.gen))
        case .sourceRestarted:
            Log.event(.speech, "speech.sourceRestarted")
        case .failed(let failure):
            Log.event(.speech, "speech.failed", .tag("failure", FailureTag(failure)), level: .error)
            send(.speechFailed(e.gen, failure))
            // The overlay says "Die Einrichtung ist offen": keep that promise.
            if failure == .micDenied, current { onNeedsSetup?() }
        }
    }

    private func warmUpSpeech() {
        setSpeech(.warming)
        let speech = services.speech
        let context = commandContext
        spawn { [weak self] in
            do {
                try await speech.warmUp(context: context)
                guard let self else { return }
                self.setSpeech(.ready)
                self.send(.speechWarm(true))
            } catch {
                Log.error(.speech, "speech.warmUp.failed", error)
                self?.setSpeech(.unavailable)
            }
        }
    }

    private func setSpeech(_ s: RuntimeStatus.Speech) {
        guard status.speech != s else { return }
        status.speech = s
        statusChanged()
    }

    // MARK: - Timers

    private func schedule(_ id: TimerID, after: Double) {
        timers.removeValue(forKey: id.kind)?.token.cancel()
        let token = services.clock.after(after) { [weak self] in
            guard let self else { return }
            if self.timers[id.kind]?.id == id { self.timers[id.kind] = nil }
            self.send(.timer(id))
        }
        timers[id.kind] = (id, token)
    }

    // MARK: - Chrome

    private func open(_ url: URL, request: Int) {
        let chrome = services.chrome
        Log.event(.chrome, "flow.open", .int("request", request))
        spawn { [weak self] in
            let event: FlowEvent
            do {
                event = .opened(request: request, try await chrome.open(url))
            } catch {
                event = .openFailed(request: request)
            }
            guard let self else { return }
            if case .opened(_, let result) = event {
                self.signposts.opened(at: self.services.clock.uptime, ok: true)
                self.noteOpen(result)
            }
            self.send(event)
        }
    }

    /// What an open tells about Chrome's Automation status.
    private func noteOpen(_ result: OpenResult) {
        switch result {
        case .reused, .newTab, .newWindow: setAutomation(.granted)
        case .fallback(.denied): setAutomation(.denied)
        case .fallback(.undetermined):
            setAutomation(.notDetermined)
            // The setup window explains the step, once per run, after the success card (a user action started it).
            if !chromeSetupOffered { chromeSetupPending = true }
        case .launched, .fallback(.other): break
        }
    }

    private func setAutomation(_ a: AutomationStatus?) {
        guard status.chromeAutomation != a else { return }
        status.chromeAutomation = a
        statusChanged()
    }

    /// The setup window read Chrome's Automation status (or the user answered the prompt).
    public func recordAutomation(_ a: AutomationStatus) {
        setAutomation(a)
        if a == .notDetermined { chromeSetupOffered = true }   // the window explains it already
    }

    /// Re-reads Chrome's Automation status without a prompt (only while Chrome runs). Never asked for: the setup
    /// window opens, once per app run (launch, Chrome's first start, an open that fell back).
    public func checkChromeAutomation() async {
        guard !stopped, services.permissions.isChromeRunning else { return }
        let s = await services.chrome.preflight(ask: false)
        setAutomation(s)
        if s == .notDetermined { offerChromeSetup() }
    }

    /// Opens the setup window for Chrome once per run, when the flow is idle (else after it).
    private func offerChromeSetup() {
        guard !chromeSetupOffered, !stopped else { return }
        guard flow.phase == .idle else {
            chromeSetupPending = true
            return
        }
        chromeSetupOffered = true
        onNeedsSetup?()
    }

    // MARK: - Workspace

    func workspaceEvent(_ e: WorkspaceEvent) {
        guard !stopped else { return }
        switch e {
        case .chromeLaunched:
            onChromeRunningChanged?(true)
            spawn { [weak self] in await self?.checkChromeAutomation() }
        case .chromeTerminated:
            onChromeRunningChanged?(false)
        case .sleep:
            guard !asleep else { return }
            asleep = true
            for t in backgroundTimers.values { t.cancel() }
            backgroundTimers = [:]
            Log.event(.app, "app.sleep")
        case .wake:
            guard asleep else { return }
            asleep = false
            wokeAt = services.clock.uptime
            Log.event(.app, "app.wake")
            // One refresh shortly after the wake, then the normal cadence (lists only when stale).
            scheduleBackground(.fast, after: Self.wakeDelay)
            if !listsRefreshRunning { scheduleBackground(.lists, after: Self.wakeDelay + 5) }
        }
    }

    // MARK: - Index

    private func revalidate(_ task: TaskRequest, activeProjectId: Int?, request: Int) {
        guard let index else {
            send(.taskListsRevalidated(request: request, complete: false))
            return
        }
        let generation = tokenGeneration
        spawn { [weak self] in
            let check = await index.revalidateTaskLists(for: task, activeProjectId: activeProjectId)
            guard let self else { return }
            self.syncIndex()
            self.note(check.errors, generation: generation)
            Log.event(.index, "index.revalidated", .bool("complete", check.complete), .bool("timedOut", check.timedOut))
            self.send(.taskListsRevalidated(request: request, complete: check.complete))
        }
    }

    private func fetchArchive(_ projectIds: [Int], request: Int) {
        guard let index else {
            send(.archiveFetched(request: request, complete: false, message: ACError.noToken.userMessage))
            return
        }
        let generation = tokenGeneration
        spawn { [weak self] in
            let check = await index.checkArchives(projectIds)
            guard let self else { return }
            self.syncIndex()
            self.note(check.errors, generation: generation)
            Log.event(.index, "index.archives", .int("projects", projectIds.count), .bool("complete", check.complete))
            self.send(.archiveFetched(request: request, complete: check.complete, message: check.error?.userMessage))
        }
    }

    private func probe(_ taskId: Int, request: Int) {
        guard let index else {
            send(.probed(request: request, .failed, message: ACError.noToken.userMessage))
            return
        }
        let generation = tokenGeneration
        spawn { [weak self] in
            let event: FlowEvent
            do {
                let ref = try await index.probe(taskId: taskId)
                event = .probed(request: request, ref.map { .found(projectId: $0.projectId) } ?? .notFound)
            } catch {
                let ac = error as? ACError
                self?.note(ac.map { [$0] } ?? [], generation: generation)
                event = .probed(request: request, .failed, message: ac?.userMessage)
            }
            guard let self else { return }
            self.syncIndex()
            self.send(event)
        }
    }

    /// Mirrors the store's latest snapshot into the flow environment; marks the interpreter for a rebuild when the
    /// projects or their signals changed.
    func syncIndex() {
        guard let s = index?.latest else { return }
        env.index = s.tasks
        status.projects = s.projects.count
        // Entries only change with these inputs; building them tokenizes every name, so skip it otherwise.
        let inputs = EntryInputs(s)
        if inputs != lastInputs {
            lastInputs = inputs
            let entries = s.indexEntries()
            if entries != lastEntries {
                lastEntries = entries
                interpreterDirty = true
            }
        }
        if !dispatching, interpreterDirty { rebuildInterpreter() }
    }

    /// What `IndexSnapshot.indexEntries()` reads.
    struct EntryInputs: Equatable {
        var projects: [ProjectRecord]
        var companies: [Int: CompanyRecord]
        var favorites: [Int]
        var timeRecords: [Int: Int]
        var mine: [TaskRef]
        init(_ s: IndexSnapshot) {
            projects = s.projects; companies = s.companies; favorites = s.favorites
            timeRecords = s.timeRecords30d; mine = s.mine
        }
    }

    /// `config` for the flow: without a `userId` in config.json, the user id of the attached index (the token prefix)
    /// fills it, so "Meine Aufgaben" opens "/users/{me}/tasks". Never written back to config.json.
    var flowConfig: Config {
        var c = config
        if c.userId == nil { c.userId = index?.userId }
        return c
    }

    private func rebuildInterpreter() {
        interpreterDirty = false
        env.interpreter = Interpreter(projects: lastEntries ?? [], config: config, history: history)
        env.config = flowConfig
        commandContext = ContextBuilder.command(projects: env.interpreter.resolver.projects, now: services.clock.now,
                                                limit: config.contextualStringLimit)
    }

    /// An AC error of the ticket path: a rejected token shows in the menu. `generation`: the token generation the
    /// request started under; a request of a replaced token never flips the status back (review C6).
    private func note(_ errors: [ACError], generation: Int) {
        guard generation == tokenGeneration else { return }
        if errors.contains(.unauthorized) { setToken(.invalid) }
    }

    private func setToken(_ t: RuntimeStatus.Token) {
        guard status.token != t else { return }
        status.token = t
        Log.event(.index, "token.status", .text("status", Self.name(t)))
        statusChanged()
    }

    /// `generation`: the token generation the refresh started under. A result for a replaced token only updates the
    /// index, never the token status.
    private func apply(_ r: RefreshReport, generation: Int) {
        syncIndex()
        Log.event(.index, "index.refresh", .int("fresh", r.fresh), .int("notModified", r.notModified),
                  .int("failed", r.failed), .ms("elapsed", seconds: Self.seconds(r.duration)))
        guard generation == tokenGeneration else { return }
        if r.unauthorized {
            setToken(.invalid)
        } else if r.fresh + r.notModified > 0 {
            setToken(.present)
        }
        if r.failed > 0, !r.unauthorized {
            // Right after a wake the network is often still down: no menu error for that (review C7).
            let justWoke = wokeAt.map { services.clock.uptime - $0 < Self.wakeGrace } ?? false
            let transportOnly = r.errors.allSatisfy { if case .transport = $0 { return true }; return false }
            if !(justWoke && transportOnly) {
                status.indexError = r.errors.first?.userMessage ?? FlowText.acUnreachable
            }
        } else if r.failed == 0 {
            status.indexError = nil
        }
        status.lastRefresh = services.clock.now
        statusChanged()
    }

    /// Conditional GETs of projects, favorites, own tasks and time records (press, every 5 minutes). `force`: also
    /// while one runs (a new token).
    private func refreshFast(force: Bool = false) {
        guard let index, force || !fastRefreshRunning else { return }
        fastRefreshRunning = true
        let generation = tokenGeneration
        spawn { [weak self] in
            let report = await index.refreshFast()
            guard let self else { return }
            self.fastRefreshRunning = false
            self.apply(report, generation: generation)
        }
    }

    /// Task lists, then archives in the background (every 12 minutes). `fastFirst`: a fast refresh before (menu,
    /// launch, new token). `onlyWhenStale`: skip the lists when they are younger than the list interval.
    private func refreshLists(fastFirst: Bool = false, onlyWhenStale: Bool = false) {
        guard let index, !listsRefreshRunning else { return }
        listsRefreshRunning = true
        if fastFirst { fastRefreshRunning = true }
        let generation = tokenGeneration
        let clock = services.clock
        spawn { [weak self] in
            var unauthorized = false
            if fastFirst {
                let fast = await index.refreshFast()
                self?.fastRefreshRunning = false
                self?.apply(fast, generation: generation)
                unauthorized = fast.unauthorized
            }
            let snapshot = index.latest
            let age = snapshot?.taskListsFetchedAt.map { clock.now.timeIntervalSince($0) } ?? .infinity
            let stale = (snapshot?.projectTasks.isEmpty ?? true) || age >= Self.listsRefreshInterval
            if !unauthorized, stale || !onlyWhenStale {
                let lists = await index.refreshTaskLists()
                self?.apply(lists, generation: generation)
                if !lists.unauthorized {
                    let archives = await index.extendArchives(priority: index.latest?.favorites ?? [])
                    self?.syncIndex()
                    if archives.unauthorized, generation == self?.tokenGeneration { self?.setToken(.invalid) }
                }
            }
            guard let self else { return }
            self.listsRefreshRunning = false
            let next = stale || !onlyWhenStale ? Self.listsRefreshInterval : max(1, Self.listsRefreshInterval - age)
            self.scheduleBackground(.lists, after: next)
        }
    }

    /// Menu "Index aktualisieren": projects and task lists now.
    public func refreshIndexNow() {
        refreshLists(fastFirst: true)
    }

    private func scheduleBackground(_ job: BackgroundJob, after seconds: Double) {
        backgroundTimers[job]?.cancel()
        backgroundTimers[job] = nil
        // Asleep: nothing runs until the wake reschedules both jobs.
        guard !asleep, !stopped else { return }
        backgroundTimers[job] = services.clock.after(seconds, tolerance: seconds * Self.backgroundTolerance) { [weak self] in
            self?.backgroundTick(job)
        }
    }

    /// Pending background job timers (tests).
    var backgroundJobs: Int { backgroundTimers.count }

    private func backgroundTick(_ job: BackgroundJob) {
        backgroundTimers[job] = nil
        guard !asleep else { return }
        let interval = job == .fast ? Self.fastRefreshInterval : Self.listsRefreshInterval
        guard index != nil else {
            scheduleBackground(job, after: interval)
            return
        }
        guard flow.phase == .idle, !isDemoRunning else {
            scheduleBackground(job, after: Self.busyRetry)
            return
        }
        switch job {
        case .fast:
            refreshFast()
            scheduleBackground(.fast, after: interval)
        case .lists:
            // Reschedules itself when done. Only when stale: a wake runs this early.
            if listsRefreshRunning { scheduleBackground(.lists, after: Self.busyRetry) } else { refreshLists(onlyWhenStale: true) }
        }
    }

    // MARK: - Token

    /// Reads the Keychain once at launch and attaches the index when a token exists.
    private func connectAC() async {
        switch await services.tokens.stored() {
        case .missing:
            setToken(.missing)
        case .unreadable(let message):
            status.tokenMessage = message
            setToken(.unreadable)
        case .present(let hint):
            guard let uid = config.userId ?? hint else {
                setToken(.needsUserId)
                return
            }
            await attachIndex(userId: uid)
            // Unknown until AC answers; `present` keeps the setup window closed meanwhile.
            setToken(.present)
            refreshLists(fastFirst: true, onlyWhenStale: true)
        }
    }

    private func attachIndex(userId: Int) async {
        let idx = services.makeIndex(userId, config)
        index = idx
        env.config = flowConfig
        await idx.loadFromDisk()
        syncIndex()
    }

    /// Onboarding "Aus ac-mcp übernehmen".
    @discardableResult
    public func importToken() async -> Bool {
        do {
            let hint = try await services.tokens.importFromACMCP()
            await tokenChanged(userIdHint: hint)
            return true
        } catch {
            tokenFailed(error)
            return false
        }
    }

    /// Onboarding paste field.
    @discardableResult
    public func saveToken(_ token: String) async -> Bool {
        do {
            let hint = try await services.tokens.save(token)
            await tokenChanged(userIdHint: hint)
            return true
        } catch {
            tokenFailed(error)
            return false
        }
    }

    private func tokenFailed(_ error: any Error) {
        status.tokenMessage = (error as? ACError)?.userMessage ?? AppText.tokenImportFailed
        Log.error(.index, "token.save.failed", error)
        statusChanged()
    }

    /// A new token is in the Keychain: forget the client's token state (or attach the index), then refresh.
    private func tokenChanged(userIdHint: Int?) async {
        status.tokenMessage = nil
        guard let uid = config.userId ?? userIdHint else {
            setToken(.needsUserId)
            return
        }
        tokenGeneration += 1
        if let index, index.userId == uid {
            await index.resetToken()
            setToken(.present)
            refreshFast(force: true)
            if !listsRefreshRunning { refreshLists(onlyWhenStale: true) }
        } else {
            // Another user (or the first token): a fresh index; results of the old one no longer count.
            fastRefreshRunning = false
            listsRefreshRunning = false
            await attachIndex(userId: uid)
            setToken(.present)
            refreshLists(fastFirst: true, onlyWhenStale: true)
        }
        statusChanged()
    }

    // MARK: - History

    private func historyChanged() {
        interpreterDirty = true
        historyDirty = true
        historySave?.cancel()
        historySave = services.clock.after(Self.historySaveDelay) { [weak self] in self?.flushHistory() }
    }

    /// Writes history.json now when it changed.
    public func flushHistory() {
        historySave?.cancel()
        historySave = nil
        guard historyDirty else { return }
        historyDirty = false
        services.store.save(history)
    }

    // MARK: - Hotkey, IPC, overlay, earcons

    private func wire() {
        services.speech.onEvent = { [weak self] e in self?.speechEvent(e) }
        services.overlay.choicesWindow = config.choicesWindow
        services.overlay.onChoose = { [weak self] n, seq in self?.trigger(.choose(n: n, seq: seq)) }
        services.overlay.onDismiss = { [weak self] in self?.dismissOverlay() }
        // The pointer on the card holds a list or an error (review U4). The demo has no flow to hold.
        services.overlay.onPointer = { [weak self] inside in
            guard let self, !self.isDemoRunning else { return }
            self.send(.pointer(inside: inside))
        }
        services.ipc.onCommand = { [weak self] cmd, client in self?.ipcCommand(cmd, from: client) }
        services.ipc.onClientsChanged = { [weak self] _ in self?.statusChanged() }
        services.earcons.isEnabled = config.earcons
        // Blank the speech gate while an earcon plays (REVIEW M1).
        services.earcons.onPlaybackStart = { [weak self] _, seconds in self?.services.speech.noteEarcon(duration: seconds) }
    }

    func registerHotkey() {
        guard config.hotkey.enabled else {
            status.hotkeyError = nil
            return
        }
        do {
            try services.hotkey.register(config.hotkey) { [weak self] e in self?.hotkey(e) }
            status.hotkeyError = nil
        } catch {
            status.hotkeyError = (error as? HotkeyError)?.message ?? HotkeyError.invalid.message
            Log.error(.hotkey, "hotkey.failed", error)
        }
    }

    private func dismissOverlay() {
        if isDemoRunning { stopDemo() } else { trigger(.cancel) }
    }

    // MARK: - Menu actions

    public var isDemoRunning: Bool { demo?.isRunning ?? false }

    /// Diagnose > Overlay vorführen: a scripted command, then every overlay state with synthetic data; no microphone, AC or Chrome.
    public func startDemo(loop: Bool = false) {
        // The menu disables the Diagnose commands while a command runs; this guards the URL scheme and races.
        guard flow.phase == .idle, !isDemoRunning else { return }
        let d = OverlayDemo(overlay: services.overlay, clock: services.clock)
        demo = d
        d.start(loop: loop) { [weak self] in
            self?.demo = nil
            self?.statusChanged()
        }
        statusChanged()
    }

    public func stopDemo() {
        demo?.stop()
        demo = nil
    }

    /// Diagnose > Spracherkennung testen: a synthesized phrase through the transcribers, no microphone.
    public func runSelfTest() {
        guard flow.phase == .idle else { return }
        guard !status.selfCheckRunning else { return }
        status.selfCheckRunning = true
        statusChanged()
        let speech = services.speech
        spawn { [weak self] in
            let result = await speech.selfCheck()
            guard let self else { return }
            self.status.selfCheckRunning = false
            self.status.selfCheck = result
            Log.event(.speech, "speech.selfCheck", .bool("passed", result.passed), .ms("elapsed", seconds: result.elapsedMs / 1000))
            self.statusChanged()
        }
    }

    /// Diagnose > Chrome testen: opens "Meine Aufgaben" through the normal Chrome path and reports the route and
    /// whether Chrome came to the front (REVIEW M4 activation spike).
    public func runChromeTest() {
        guard flow.phase == .idle else { return }
        guard !status.chromeTestRunning else { return }
        status.chromeTestRunning = true
        status.chromeTest = AppText.chromeTestRunning
        status.chromeFront = nil
        statusChanged()
        let chrome = services.chrome
        let url = flowConfig.myWorkURL
        spawn { [weak self] in
            var scripted = false
            let line: String
            do {
                let result = try await chrome.open(url)
                line = AppText.chromeTest(result)
                self?.noteOpen(result)
                switch result {
                case .reused, .newTab, .newWindow: scripted = true
                default: break
                }
            } catch {
                line = AppText.chromeTestFailed
            }
            guard let self else { return }
            self.status.chromeTestRunning = false
            self.status.chromeTest = line
            self.statusChanged()
            guard scripted else { return }
            // ChromeOpener checks the front-most app 0.3 s after the script.
            _ = self.services.clock.after(0.6) { [weak self] in
                guard let self, let check = chrome.lastActivation else { return }
                self.status.chromeFront = AppText.chromeFront(check.frontmost)
                self.statusChanged()
            }
        }
    }

    /// Menu toggle "Beim Anmelden starten". Registers or unregisters the login item, mirrors it in config.json.
    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try services.loginItem.setEnabled(enabled)
            config.launchAtLogin = enabled
            env.config = flowConfig
            services.store.saveLaunchAtLogin(enabled)
            refreshLoginStatus(notify: false)
            status.loginMessage = loginStatus.hint
        } catch {
            Log.error(.login, "login.failed", error)
            refreshLoginStatus(notify: false)
            status.loginMessage = [AppText.loginItemFailed, loginStatus.hint].compactMap { $0 }.joined(separator: ". ")
        }
        statusChanged()
    }

    /// Menu "Beim Anmelden starten": a registered item waiting for approval counts as on, so the click turns it off
    /// (review C9). Never toggles from a stale read: the status is read again first.
    public func toggleLaunchAtLogin() {
        refreshLoginStatus(notify: false)
        setLaunchAtLogin(!loginStatus.isOn)
    }

    /// Reads the login item status (an XPC call): at launch, after a change and when the menu opens, never on every
    /// status change (review C8).
    public func refreshLoginStatus(notify: Bool = true) {
        let s = services.loginItem.status
        guard s != loginStatus else { return }
        loginStatus = s
        if notify { statusChanged() }
    }

    /// "Diagnose kopieren" finished: a check on the menu icon for a moment and a status line.
    public func diagnosticsCopied() {
        notice(AppText.diagnosticsCopied)
        iconFlash = "checkmark.circle"
        statusChanged()
        _ = services.clock.after(1.5) { [weak self] in
            guard let self, self.iconFlash != nil else { return }
            self.iconFlash = nil
            self.statusChanged()
        }
    }

    private func notice(_ text: String) {
        status.notice = text
        statusChanged()
        _ = services.clock.after(4) { [weak self] in
            guard let self, self.status.notice == text else { return }
            self.status.notice = nil
            self.statusChanged()
        }
    }

    // MARK: - Reading state

    /// Latency samples per metric (milliseconds).
    public var latencies: [LatencyMetric: LatencyStats] { signposts.stats }

    /// Input for `Diagnostics.text`. `automation`: Chrome's Automation status, nil while Chrome is not running.
    public func diagnosticsInput(automation: AutomationStatus?, appVersion: String, build: String,
                                 osVersion: String) -> DiagnosticsInput {
        let snapshot = index?.latest
        return DiagnosticsInput(
            appVersion: appVersion, build: build, osVersion: osVersion, phase: flow.phase, status: status,
            microphone: services.permissions.microphone, speechRecognition: services.permissions.speechRecognition,
            automation: automation, loginItem: services.loginItem.status, hotkey: config.hotkey.display,
            ipcClients: services.ipc.connectedClients.count, index: snapshot?.stats, indexFetchedAt: snapshot?.fetchedAt,
            taskListsFetchedAt: snapshot?.taskListsFetchedAt, latencies: latencies, config: config, now: services.clock.now)
    }

    // MARK: - Tasks

    /// Runs `body` on the main actor; tracked so tests can wait for it (`settle`).
    @discardableResult
    private func spawn(_ body: @escaping @MainActor () async -> Void) -> Int {
        taskCounter += 1
        let id = taskCounter
        tasks[id] = Task { @MainActor [weak self] in
            await body()
            self?.tasks[id] = nil
        }
        return id
    }

    /// Tasks still running (tests).
    var pendingTasks: Int { tasks.count }

    /// Waits until at most `leaving` spawned tasks and no speech call are pending (tests; services on the main actor).
    /// Returns false when `timeout` seconds of real time passed first.
    /// With `leaving == 0` it awaits the tasks themselves (no polling); otherwise it polls every millisecond.
    @discardableResult
    func settle(leaving: Int = 0, timeout: Double = 30) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var quiet = 0
        while ContinuousClock.now < deadline {
            if leaving == 0, let t = tasks.values.first {
                await t.value
                quiet = 0
                continue
            }
            if leaving == 0, speechWork.isBusy {
                await speechWork.idle()
                quiet = 0
                continue
            }
            if tasks.count <= leaving, !speechWork.isBusy {
                quiet += 1
                // Several quiet turns in a row: nothing queued behind the last one either.
                if quiet >= 3 { return true }
                await Task.yield()
            } else {
                quiet = 0
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        return false
    }

    // MARK: - Helpers

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func name(_ t: RuntimeStatus.Token) -> StaticString {
        switch t {
        case .unknown: return "unknown"
        case .missing: return "missing"
        case .present: return "present"
        case .invalid: return "invalid"
        case .unreadable: return "unreadable"
        case .needsUserId: return "needsUserId"
        }
    }
}
