import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

/// Synthetic projects (Tests/Fixtures/projects.sample.json) and a small task index.
enum Fixture {
    static let catalog: ProjectCatalog = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/projects.sample.json")
        do { return try ProjectCatalog.load(url) } catch { fatalError("projects.sample.json: \(error)") }
    }()
    static var now: Date { catalog.referenceDate }
    static let projects = catalog.entries(now: now)
    static let interpreter = Interpreter(resolver: Resolver(projects: projects))
    static let wwt = [628, 314, 315, 693]
    static let base = URL(string: "https://ac.example.com")!

    /// 628 #412 completed, 314 #412 open, 315 #58 open, 2032 #7 (id 47285), own #530 in 628, 63000 trashed.
    /// 693's archive is not indexed yet.
    static var index: TaskIndex {
        var i = TaskIndex()
        i.add(TaskRef(id: 50_000, projectId: 628, number: 412, isCompleted: true))
        i.add(TaskRef(id: 45_000, projectId: 314, number: 412))
        i.add(TaskRef(id: 41_000, projectId: 315, number: 58))
        i.add(TaskRef(id: 47_285, projectId: 2032, number: 7))
        i.archiveComplete = [628, 315, 314]
        i.mine = [TaskRef(id: 61_834, projectId: 628, number: 530)]
        i.trashed = [63_000]
        return i
    }

    static func projectURL(_ id: Int) -> URL { Routes.project(base, id) }
    static func taskURL(_ pid: Int, _ tid: Int) -> URL { Routes.task(base, projectId: pid, taskId: tid) }
}

/// Plays the controller: keeps timers on a fake clock, tracks the mic stamp and records effects.
struct Harness {
    var flow: VoiceFlow
    var env: FlowEnv
    var now: Date
    var timers: [TimerKind: (id: TimerID, due: Date)] = [:]
    /// Effects of the last `send` or `advance`.
    var last: [Effect] = []
    var all: [Effect] = []
    /// Stamp of the latest `.startMic` / `.rearm`.
    var gen: SpeechGen?
    var mode: ListenMode?
    var hangover: Double?
    var micOn = false
    var visible = false
    var suspended = false
    var pendingRequest: Int?
    /// How the fake controller answers `.revalidateTaskLists`: at once with `complete` (true: the lists are current),
    /// or not at all (nil, the test answers itself).
    var autoRevalidate: Bool? = true
    /// Every `.revalidateTaskLists` seen.
    var revalidations: [TaskRequest] = []

    init(warm: Bool = true, config: Config = .init(), index: TaskIndex = Fixture.index,
         timings: FlowTimings = .init(), activeProjectId: Int? = nil) {
        flow = VoiceFlow(timings: timings, speechWarm: warm)
        env = FlowEnv(interpreter: Fixture.interpreter, index: index, config: config, activeProjectId: activeProjectId)
        now = Fixture.now
    }

    var phase: FlowPhase { flow.phase }
    var model: OverlayModel { flow.model }
    var state: IPC.State { flow.model.ipcState() }

    @discardableResult
    mutating func send(_ e: FlowEvent) -> [Effect] {
        var fx = flow.handle(e, now: now, env: env)
        apply(fx)
        // The controller revalidates the task lists of a ticket decision (mostly 304s within ~25 ms).
        for effect in fx {
            guard case let .revalidateTaskLists(task, _, r) = effect else { continue }
            revalidations.append(task)
            guard let complete = autoRevalidate else { continue }
            let more = flow.handle(.taskListsRevalidated(request: r, complete: complete), now: now, env: env)
            apply(more)
            fx += more
        }
        last = fx
        return fx
    }

    mutating func apply(_ fx: [Effect]) {
        all += fx
        for e in fx {
            switch e {
            case let .schedule(id, after): timers[id.kind] = (id, now.addingTimeInterval(after))
            case .cancelTimer(let k): timers[k] = nil
            case let .startMic(g, m, h): gen = g; mode = m; hangover = h; micOn = true
            case let .rearm(g, m, h): gen = g; mode = m; hangover = h
            case .setHangover(let h): hangover = h
            case .stopMic: micOn = false
            case .showOverlay: visible = true
            case .hideOverlay: visible = false
            case .suspendEndpointing(let s): suspended = s
            case let .open(_, r), let .fetchArchive(_, r), let .probeTask(_, r), let .revalidateTaskLists(_, _, r):
                pendingRequest = r
            default: break
            }
        }
    }

    /// Advances the fake clock, firing due timers in order.
    @discardableResult
    mutating func advance(_ dt: Double) -> [Effect] {
        let target = now.addingTimeInterval(dt)
        var out: [Effect] = []
        while let next = timers.values.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = max(now, next.due)
            timers[next.id.kind] = nil
            out += send(.timer(next.id))
        }
        now = target
        last = out
        return out
    }

    /// The wall clock (`now`) steps by `dt` while the controller's timers keep running on a monotonic clock: every
    /// pending timer still fires after its remaining time.
    mutating func jumpWallClock(_ dt: Double) {
        now = now.addingTimeInterval(dt)
        for (k, t) in timers { timers[k] = (t.id, t.due.addingTimeInterval(dt)) }
    }

    /// Silence of `seconds` after speech, as the speech gate sees it: the utterance ends (`.speechEnded`) once the
    /// pause reaches the hangover the flow asked for last. Returns true when it ended.
    @discardableResult
    mutating func pause(_ seconds: Double) -> Bool {
        let budget = hangover ?? 0
        guard seconds >= budget else { advance(seconds); return false }
        advance(budget)
        ended()
        return true
    }

    func due(_ k: TimerKind) -> Double? { timers[k].map { $0.due.timeIntervalSince(now) } }
    func has(_ e: Effect) -> Bool { last.contains(e) }
    var opened: URL? {
        for e in last { if case let .open(url, _) = e { return url } }
        return nil
    }
    /// Every `.recordPick` emitted so far.
    var picks: [Effect] { all.filter { if case .recordPick = $0 { return true }; return false } }
    /// Chrome confirms the pending open.
    @discardableResult
    mutating func confirmOpen(_ result: OpenResult = .reused) -> [Effect] { send(.opened(request: pendingRequest!, result)) }
    var published: OverlayModel? {
        for e in last { if case .publish(let m) = e { return m } }
        return nil
    }

    /// Timer due in `seconds` from now (fake-clock dates are not exact in binary floating point).
    func dueIs(_ k: TimerKind, _ seconds: Double) -> Bool {
        guard let d = due(k) else { return false }
        return abs(d - seconds) < 1e-6
    }
    func dateIs(_ d: Date?, _ secondsAfterStart: Double) -> Bool {
        guard let d else { return false }
        return abs(d.timeIntervalSince(Fixture.now) - secondsAfterStart) < 1e-6
    }

    // MARK: Speech helpers

    @discardableResult
    mutating func press(_ id: String? = "p1", source: TriggerSource = .streamDeck, at: Date? = nil) -> [Effect] {
        send(.press(Press(id: id, source: source, at: at)))
    }
    @discardableResult
    mutating func release(_ id: String? = "p1", heldMs: Int = 120) -> [Effect] { send(.release(pressId: id, heldMs: heldMs)) }
    @discardableResult mutating func micReady() -> [Effect] { send(.micReady(gen!)) }
    @discardableResult mutating func onset() -> [Effect] { send(.speechStarted(gen!)) }
    @discardableResult mutating func voice(_ active: Bool) -> [Effect] { send(.voice(gen!, active: active)) }
    @discardableResult
    mutating func partial(_ text: String) -> [Effect] { send(.partial(gen!, Transcript(volatile: text), [Hypothesis(text)])) }
    @discardableResult mutating func ended() -> [Effect] { send(.speechEnded(gen!)) }
    @discardableResult
    mutating func final(_ texts: String...) -> [Effect] { send(.utterance(gen!, texts.map { Hypothesis($0) })) }

    /// Press, mic ready, release (tap), then one utterance.
    mutating func command(_ text: String) {
        press()
        micReady()
        release()
        say(text)
    }

    /// Onset, a partial, end of utterance and the final.
    mutating func say(_ text: String) {
        onset()
        partial(text)
        ended()
        final(text)
    }
}
