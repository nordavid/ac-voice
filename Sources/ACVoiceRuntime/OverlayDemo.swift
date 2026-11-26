import ACVoiceCore
import ACVoiceFlow
import ACVoiceUI
import Foundation

/// The overlay demo: `--demo` at launch and Diagnose > Overlay vorführen. No microphone, no AC, no Chrome, no sound.
///
/// 1. A scripted command through the real `VoiceFlow` reducer with its real timings and synthetic speech events
///    (`script`): press, the live transcript, the list, the answer "die zweite", opening, success and the fade. This
///    shows the timing feel: 120 ms fade-in, spring growth, staggered rows, 0.7 s success, 0.2 s fade.
/// 2. Every overlay state of `OverlayGallery` (invented names from projects.sample.json), `step` seconds each, with
///    their dates moved to the present so the countdown ring runs.
@MainActor
public final class OverlayDemo {
    public let scenarios: [OverlayScenario]
    /// Seconds per gallery state.
    public var step = 2.6
    /// Level updates per second while a state listens (the IPC rate).
    public static let levelRate = 15.0
    /// Pause between the scripted command and the gallery.
    public static let interlude = 0.8

    public private(set) var isRunning = false
    /// Index of the gallery state on screen; -1 while the scripted command runs.
    public private(set) var position = 0

    private let overlay: any OverlayPresenting
    private let clock: any RuntimeClock
    private let scripted: Bool
    private var loop = false
    private var seq = 0
    private var stepTimer: (any TimerToken)?
    private var levelTimer: (any TimerToken)?
    private var completion: (@MainActor () -> Void)?
    private var level = 0.0
    private var listening = false
    private var run: ScriptRun?

    /// `scripted`: run the scripted command before the gallery.
    public init(overlay: any OverlayPresenting, clock: any RuntimeClock,
                scenarios: [OverlayScenario] = OverlayGallery.scenarios(), scripted: Bool = true) {
        self.overlay = overlay
        self.clock = clock
        self.scenarios = scenarios
        self.scripted = scripted
    }

    /// Starts with the scripted command (if any), then the gallery. `loop`: start over after the last state (launch
    /// argument); else hide and call `completion` (menu).
    public func start(loop: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard !isRunning, !scenarios.isEmpty || scripted else { return }
        isRunning = true
        self.loop = loop
        self.completion = completion
        if scripted {
            startScript()
        } else {
            startGallery()
        }
        tickLevel()
    }

    /// Hides the overlay at once.
    public func stop() {
        guard isRunning else { return }
        finish(fade: 0)
    }

    // MARK: Scripted command

    /// The scripted command: (seconds from the press, event). Speech events carry the stamp the flow armed.
    static let script: [(at: Double, event: ScriptEvent)] = [
        (0.00, .press),
        (0.15, .micReady),
        (0.70, .speechStarted),
        (0.90, .partial("Öffne")),
        (1.20, .partial("Öffne das")),
        (1.55, .partial("Öffne das WWT")),
        (1.90, .partial("Öffne das WWT-Projekt")),
        (2.60, .final("Öffne das WWT-Projekt")),
        (4.30, .speechStarted),
        (4.50, .partial("Die")),
        (4.80, .partial("Die zweite")),
        (5.30, .final("Die zweite")),
        (5.36, .opened),
    ]

    enum ScriptEvent: Equatable {
        case press, micReady, speechStarted, partial(String), final(String), opened
    }

    /// The projects the scripted command resolves against: the WWT group of projects.sample.json.
    static var projects: [ProjectEntry] {
        [(628, "WWT: Website Relaunch [AGIL]"), (315, "WWT: TYPO3 Website maintenance [AGIL]"),
         (314, "WWT: Maintenance [SLA]"), (693, "WWT: Grand Navigation [AGIL]"), (2071, "QZ: CRM [INT]")]
            .map { ProjectEntry(id: $0.0, name: $0.1) }
    }

    private func startScript() {
        position = -1
        var config = Config()
        config.earcons = false
        let env = FlowEnv(interpreter: Interpreter(projects: Self.projects, config: config, history: History()),
                          config: config)
        let r = ScriptRun(flow: VoiceFlow(timings: FlowTimings(), speechWarm: true), env: env)
        run = r
        for (at, event) in Self.script where at > 0 {
            r.steps.append(clock.after(at) { [weak self] in self?.play(event) })
        }
        for (at, event) in Self.script where at <= 0 { play(event) }   // the press shows the card at once
    }

    private func play(_ e: ScriptEvent) {
        guard isRunning, let r = run else { return }
        let gen = r.flow.armed
        let event: FlowEvent?
        switch e {
        case .press: event = .press(Press(source: .menu))
        case .micReady: event = r.flow.armed.map { .micReady($0) }
        case .speechStarted:
            event = gen.map { .speechStarted($0) }
            level = 0.6
        case .partial(let text):
            // Settled words bright, the newest dim, as the live controller splits them.
            let shown = r.splitter.next(text)
            event = gen.map { .partial($0, shown, [Hypothesis(text)]) }
        case .final(let text):
            r.splitter.reset()
            event = gen.map { .utterance($0, [Hypothesis(text)]) }
            level = 0.08
        case .opened: event = r.openRequest.map { .opened(request: $0, .reused) }
        }
        if let event { send(event) }
    }

    private func send(_ event: FlowEvent) {
        guard let r = run else { return }
        let fx = r.flow.handle(event, now: clock.now, env: r.env)
        for effect in fx {
            switch effect {
            case .publish(var m):
                seq += 1
                m.seq = seq
                listening = [.listening, .retry, .choices].contains(m.phase)
                overlay.render(m)
            case .showOverlay:
                overlay.show()
            case .hideOverlay(let fade):
                overlay.hide(fade: fade)
                scriptEnded()
            case let .schedule(id, after):
                r.timers[id.kind]?.cancel()
                r.timers[id.kind] = clock.after(after) { [weak self] in
                    guard let self, self.run === r else { return }
                    r.timers[id.kind] = nil
                    self.send(.timer(id))
                }
            case .cancelTimer(let kind):
                r.timers.removeValue(forKey: kind)?.cancel()
            case let .open(_, request):
                r.openRequest = request
            default:
                break   // no microphone, no AC, no Chrome, no sound
            }
        }
    }

    /// The scripted command faded out: the gallery follows (or the demo ends without one).
    private func scriptEnded() {
        endScript()
        listening = false
        guard !scenarios.isEmpty else {
            if loop {
                stepTimer = clock.after(Self.interlude) { [weak self] in self?.startScript() }
            } else {
                finish(fade: 0)
            }
            return
        }
        stepTimer?.cancel()
        stepTimer = clock.after(Self.interlude) { [weak self] in
            guard let self, self.isRunning else { return }
            self.startGallery()
        }
    }

    private func endScript() {
        guard let r = run else { return }
        for t in r.steps { t.cancel() }
        for t in r.timers.values { t.cancel() }
        run = nil
    }

    // MARK: Gallery

    /// The model the overlay gets for `scenarios[i]`: dates moved so the scenario's render time is now, a fresh seq.
    static func model(_ s: OverlayScenario, now: Date, seq: Int) -> OverlayModel {
        var m = s.model
        let shift = now.timeIntervalSince(s.now)
        m.since = m.since.addingTimeInterval(shift)
        m.deadline = m.deadline?.addingTimeInterval(shift)
        m.seq = seq
        m.visible = true
        return m
    }

    private func startGallery() {
        position = 0
        present(first: true)
    }

    private func present(first: Bool) {
        let s = scenarios[position]
        seq += 1
        let m = Self.model(s, now: clock.now, seq: seq)
        overlay.render(m)
        if first { overlay.show() }
        level = s.level
        listening = [.listening, .retry, .choices].contains(m.phase)
        stepTimer?.cancel()
        stepTimer = clock.after(step) { [weak self] in self?.advance() }
    }

    private func advance() {
        guard isRunning else { return }
        position += 1
        if position >= scenarios.count {
            guard loop else {
                finish(fade: 0.2)
                return
            }
            if scripted {
                overlay.hide(fade: 0.2)
                listening = false
                stepTimer = clock.after(Self.interlude) { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.startScript()
                }
                return
            }
            position = 0
        }
        present(first: false)
    }

    private func tickLevel() {
        guard isRunning else { return }
        if listening {
            let t = clock.uptime
            overlay.setLevel(min(1, max(0, level * (0.55 + 0.45 * sin(2 * .pi * 1.3 * t)))))
        }
        levelTimer = clock.after(1 / Self.levelRate) { [weak self] in self?.tickLevel() }
    }

    private func finish(fade: Double) {
        isRunning = false
        endScript()
        stepTimer?.cancel()
        levelTimer?.cancel()
        stepTimer = nil
        levelTimer = nil
        overlay.hide(fade: fade)
        let done = completion
        completion = nil
        done?()
    }
}

/// State of one scripted command run.
@MainActor
private final class ScriptRun {
    var flow: VoiceFlow
    let env: FlowEnv
    var steps: [any TimerToken] = []
    var timers: [TimerKind: any TimerToken] = [:]
    var openRequest: Int?
    var splitter = TranscriptSplitter()

    init(flow: VoiceFlow, env: FlowEnv) {
        self.flow = flow
        self.env = env
    }
}
