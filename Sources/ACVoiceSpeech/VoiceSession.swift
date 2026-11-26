import ACVoiceCore
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Tap to talk with automatic end of utterance and follow-up answers in the same session (PLAN 2.3).
///
/// Audio source chunks -> AVAudioConverter (16 kHz Int16 mono) -> RMS per 20 ms slice -> `EndpointGate` ->
/// one SpeechAnalyzer with SpeechTranscriber + DictationTranscriber (de_DE). At the end of an utterance a
/// 500 ms synthetic noise-floor tail is appended and `finalize(through: speechEnd + 0.4 s)` runs under
/// `finalizeOrKill`; a killed analyzer is replaced by a fresh analyzer and input stream (REVIEW M2).
///
/// Lifecycle calls (`warmUp`, `start`, `rearm`, `expectAnswer`, `expectCommand`, `stop`) run strictly one after
/// another in call order, so a `start` right after a `stop` waits for it (REVIEW M3). The slow part of `warmUp`
/// (assets, priming, the first analyzer) runs outside that order, so a press during warm-up starts the microphone at
/// once (REVIEW m5). Every session owns its converter, format and analyzer, and every event carries the
/// (session, utterance) generation it belongs to: the caller's `SpeechGen` from `start(gen:)` and `rearm(gen:)`, so
/// the controller passes events, failures included, to `VoiceFlow` as they are (`Event.gen`).
///
/// The end-of-utterance hangover is the caller's (VoiceFlow owns the policy, Core `HangoverPolicy`): pass it with
/// `start` and `rearm`, and every change with `setHangover(_:)`.
@available(macOS 26, *)
public final class VoiceSession: @unchecked Sendable {
    public struct Tuning: Sendable, Equatable {
        public var gate = EndpointGate.Config()
        /// Finalize this long after the speech end. Below ~0.4 s short words get lost (research 5).
        public var finalizeLead = 0.40
        /// Synthetic noise appended at the end of an utterance so `finalize` never waits for real audio.
        public var syntheticTail = 0.50
        /// Deadline for `finalize`; beyond it the analyzer is killed and rebuilt.
        public var finalizeTimeout = 1.2
        /// Wait after `finalize` for the result streams to deliver.
        public var drainTimeout = 0.15
        public var maxAlternatives = 3
        /// Deadline for installing the speech assets in `warmUp`. A first download can take long; it goes on in
        /// the background after the deadline and `warmUp` throws `SpeechError.assetsUnavailable`.
        public var assetInstallTimeout = 120.0
        /// Device changes restart capture at most this often within `sourceRestartWindow`; one more change
        /// stops the microphone and reports `.failed(.sourceFailed)` (REVIEW M7).
        public var maxSourceRestarts = 3
        public var sourceRestartWindow = 5.0
        /// Command phase: an utterance this short (speech start -> end) that DictationTranscriber heard nothing in
        /// and SpeechTranscriber at most one word is noise; SpeechTranscriber alone sometimes makes up a word
        /// ("you") from a cough or a noise burst. An utterance without any word is noise at any length.
        public var noiseMaxDuration = 0.5
        public init() {}
    }

    /// An event of one session, stamped with its generation. Drop events whose `session` or `utterance` do not
    /// match the current ones (REVIEW M3).
    public struct Event: Sendable {
        /// `start(gen:)`'s session, else a counter of this `VoiceSession`.
        public let session: Int
        /// The utterance of `start(gen:)` or of the latest `rearm(gen:)`; without stamps 1 for the first utterance,
        /// incremented by every re-arm.
        public let utterance: Int
        public let kind: Kind
        /// The stamp as `VoiceFlow` expects it: `.speechFailed(event.gen, error.failure)`, `.partial(event.gen, …)`.
        public var gen: SpeechGen { SpeechGen(session: session, utterance: utterance) }
    }

    public enum Kind: Sendable {
        /// The analyzer is still loading. Audio is buffered and transcribed once it is ready (REVIEW m5).
        case warming
        /// The analyzer runs.
        case ready
        /// The first audio chunk arrived (play the earcon now, then call `noteEarcon`).
        case micReady
        /// Peak slice level of a chunk (about 10 Hz) and the current speech threshold, both dBFS.
        case level(dB: Float, thresholdDB: Float)
        case speechStarted
        /// The gate decided the end of the utterance (pause, press or push-to-talk release); finalize runs now. A
        /// `.utterance` follows, unless the final text dangles or holds no word: then the utterance reopens or waits
        /// for speech again, and another `.endpoint` comes later. For latency signposts (speech end -> final).
        case endpoint
        /// The utterance after `.endpoint` goes on: its final text dangled, so the gate listens on with the incomplete
        /// hangover (no `.utterance` for that end). Another `.endpoint` comes later.
        case resumed
        /// The onset of the utterance after `.endpoint` was noise (no word): no `.utterance`, the gate waits for speech
        /// again in the same utterance.
        case discarded
        /// Live transcript of the current utterance: DictationTranscriber drives the overlay, ST is extra.
        case partial(dt: String, st: String)
        case utterance(Utterance)
        /// Command phase: nothing said within `noSpeechTimeout`.
        case noSpeech
        /// The audio device changed; capture restarted on the new device.
        case sourceRestarted
        case failed(SpeechError)
    }

    public struct Utterance: Sendable {
        public var mode: UtteranceMode
        /// Interpreter input: DT best 1.0, ST best 1.0, alternatives 0.9.
        public var hypotheses: [Hypothesis]
        public var dictation: TranscriberText
        public var speech: TranscriberText
        public var endReason: EndReason
        public var timing: Timing
    }

    public struct Timing: Sendable {
        /// Seconds of captured audio since the session started.
        public var speechStart: Double
        public var speechEnd: Double
        /// Speech end -> end-of-utterance decision (hangover plus chunk delivery).
        public var endpointMs: Double
        /// The `finalize(through:)` call, including the wait for a cold analyzer.
        public var finalizeMs: Double
        /// Speech end -> this event (wall clock): the latency budget of PLAN M3.
        public var totalMs: Double
        /// Finalize hit its deadline: the analyzer was rebuilt and the texts are the last volatile results.
        public var killed: Bool
        /// How often a dangling final text reopened this utterance before it ended (REVIEW M1); each reopen costs
        /// at least one chunk and a second finalize.
        public var reopens: Int
    }

    public let locale: Locale
    private let lock = NSLock()
    private var _tuning: Tuning
    private var current: Run?
    private var sessionCounter = 0
    private var prebuild: Prebuild?
    private var format: AVAudioFormat?
    private var commandContext: [String] = []
    private let serial = SerialQueue()
    /// Testing hook: the next finalize behaves as if it timed out.
    var killNextFinalize = false

    public init(tuning: Tuning = .init(), locale: Locale = Locale(identifier: "de_DE")) {
        _tuning = tuning
        self.locale = locale
    }

    /// Applies from the next `start`.
    public var tuning: Tuning {
        get { lock.withLock { _tuning } }
        set { lock.withLock { _tuning = newValue } }
    }

    /// Generation of the running session, nil when stopped.
    public var currentSession: Int? { lock.withLock { current?.id } }

    // MARK: Lifecycle

    /// At app launch (about 2-3 s): installs or subscribes the speech assets (at most `assetInstallTimeout`),
    /// primes the models with a throwaway analysis and pre-builds an analyzer for `context`. Returns when that
    /// analyzer is ready. A `start` meanwhile does not wait: it takes the unfinished analyzer, reports `.warming`
    /// and buffers the audio until it is ready (REVIEW m5).
    nonisolated(nonsending) public func warmUp(context: [String]) async throws {
        let pre = try await serial.run { [self] () -> Prebuild in
            lock.withLock {
                commandContext = context
                let locale = locale, assetTimeout = _tuning.assetInstallTimeout
                let pre = Prebuild { [self] in
                    try await AnalyzerFactory.installAssets(locale, timeout: assetTimeout)
                    let format = await analyzerFormat()
                    await AnalyzerFactory.prime(locale, format: format)
                    return try await AnalyzerFactory.prepare(locale, format: format, context: context)
                }
                prebuild = pre
                return pre
            }
        }
        _ = await pre.task.value
        if let error = pre.error { throw error }
    }

    /// Key press: starts `source` and listens for one utterance. Accepted before the analyzer is warm: audio is
    /// buffered and `.warming` / `.ready` report the state. The returned stream ends after `stop()`.
    /// - Parameters:
    ///   - gen: the stamp for this session's events (`VoiceFlow`'s `.startMic`); nil: an own counter, utterance 1.
    ///   - hangover: pause budget in seconds (`.startMic`'s hangover); nil: `Tuning.gate`'s default for `mode`.
    /// - Throws: `SpeechError` when the source does not start (`.sourceFailed`, `.invalidInputFormat`); map it with
    ///   `SpeechError.failure` and the `gen` passed here. Later failures arrive as `.failed` events with the stamp.
    nonisolated(nonsending) public func start(context: [String], source: any AudioSource, mode: UtteranceMode = .command,
                                              gen: SpeechGen? = nil, hangover: Double? = nil) async throws -> AsyncStream<Event> {
        try await serial.run { [self] in
            if let old = lock.withLock({ () -> Run? in defer { current = nil }; return current }) {
                await old.shutdown()
            }
            let format = await analyzerFormat()
            let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
            let (run, pre) = lock.withLock { () -> (Run, Prebuild?) in
                sessionCounter = max(sessionCounter + 1, gen?.session ?? 0)
                if mode == .command { commandContext = context }
                let pre = prebuild
                prebuild = nil
                let run = Run(id: gen?.session ?? sessionCounter, utterance: gen?.utterance ?? 1, source: source,
                              format: format, tuning: _tuning, locale: locale, events: continuation, context: context,
                              commandContext: commandContext, mode: mode, hangover: hangover,
                              killFirstFinalize: killNextFinalize)
                killNextFinalize = false
                return (run, pre)
            }
            run.begin(prepared: pre)
            lock.withLock { current = run }
            do {
                try run.startSource()
            } catch {
                lock.withLock { current = nil }
                await run.shutdown()
                throw SpeechError.wrap(error)
            }
            return stream
        }
    }

    /// Next utterance in the same session (`VoiceFlow`'s `.rearm`): re-arms end of utterance first, then swaps the
    /// contextual strings when `context` differs (about 110 ms with DT; audio keeps flowing meanwhile).
    /// - Parameters:
    ///   - context: nil keeps the command context of `start` for a command, the current one for an answer.
    ///   - gen: stamp of the new utterance; a stamp of another session is ignored (stale). nil: utterance + 1.
    ///   - hangover: pause budget in seconds; nil: `Tuning.gate`'s default for `mode`.
    nonisolated(nonsending) public func rearm(_ mode: UtteranceMode, context: [String]?, gen: SpeechGen? = nil,
                                              hangover: Double? = nil) async {
        await serial.run { [self] in
            guard let run = currentRun else { return }
            await run.rearm(mode, context: context, gen: gen, hangover: hangover)
        }
    }

    /// A list is visible: `rearm(.answer, …)` (no no-speech timeout; the choices window belongs to the caller).
    nonisolated(nonsending) public func expectAnswer(context: [String], gen: SpeechGen? = nil, hangover: Double? = nil) async {
        await rearm(.answer, context: context, gen: gen, hangover: hangover)
    }

    /// Listen for another command in the same session (retry, or a new command from the list). nil keeps the
    /// command context of `start`.
    nonisolated(nonsending) public func expectCommand(context: [String]? = nil, gen: SpeechGen? = nil, hangover: Double? = nil) async {
        await rearm(.command, context: context, gen: gen, hangover: hangover)
    }

    /// Mic off, analyzer cancelled, event stream finished; then the next analyzer is pre-built in the background.
    nonisolated(nonsending) public func stop() async {
        await serial.run { [self] in
            guard let run = lock.withLock({ () -> Run? in defer { current = nil }; return current }) else { return }
            await run.shutdown()
            schedulePrebuild(format: run.format)
        }
    }

    // MARK: Live controls (any thread)

    /// The controller's pause budget for the armed utterance, in seconds (`VoiceFlow`'s `.setHangover`).
    public func setHangover(_ seconds: Double) { currentRun?.setHangover(seconds) }

    /// Push-to-talk: while held, pauses do not end the utterance (REVIEW m4).
    public func setHold(_ held: Bool) { currentRun?.setHold(held) }

    /// An earcon starts playing now for `duration` seconds: the gate ignores the mic meanwhile (REVIEW M1).
    public func noteEarcon(duration: Double) { currentRun?.noteEarcon(duration: duration) }

    /// Press while listening or push-to-talk release: ends the utterance at once. Ignored before speech started
    /// (accidental double tap) unless `noSpeechIfSilent`, which then reports `.noSpeech`. Returns whether it acted.
    @discardableResult
    public func endUtteranceNow(noSpeechIfSilent: Bool = false) -> Bool {
        currentRun?.endNow(reason: .manual, noSpeechIfSilent: noSpeechIfSilent) ?? false
    }

    // MARK: Internals

    private var currentRun: Run? { lock.withLock { current } }

    /// The analyzer input format. Before the assets are installed `bestAvailableAudioFormat` can be nil or slow:
    /// then the macOS 26 format (16 kHz Int16 mono) without caching it, so a press never waits for the assets
    /// (REVIEW m5). A late answer is still cached; an analyzer prepared for another format is not used.
    private func analyzerFormat() async -> AVAudioFormat {
        if let f = lock.withLock({ format }) { return f }
        let locale = locale
        let found = try? await withDeadline(.milliseconds(500), cancelOnTimeout: false) { [self] () -> SendableFormat? in
            guard let f = await AnalyzerFactory.bestFormat(locale) else { return nil }
            lock.withLock { if format == nil { format = f } }
            return SendableFormat(f)
        }
        if let f = found ?? nil { return f.format }
        return AnalyzerFactory.fallbackFormat()
    }

    private func schedulePrebuild(format runFormat: AVAudioFormat) {
        lock.withLock {
            guard prebuild == nil else { return }
            let context = commandContext, locale = locale
            let f = SendableFormat(format ?? runFormat)
            prebuild = Prebuild { try await AnalyzerFactory.prepare(locale, format: f.format, context: context) }
        }
    }
}

/// An analyzer being prepared in the background. `task` yields it, or nil when preparing failed (`error`).
@available(macOS 26, *)
final class Prebuild: @unchecked Sendable {
    private final class Outcome: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        var analyzer: PreparedAnalyzer?
        var error: SpeechError?
    }

    let task: Task<PreparedAnalyzer?, Never>
    private let outcome: Outcome

    /// Starts `work` at once.
    init(_ work: @escaping @Sendable () async throws -> PreparedAnalyzer) {
        let outcome = Outcome()
        self.outcome = outcome
        task = Task {
            do {
                let p = try await work()
                outcome.lock.withLock { outcome.done = true; outcome.analyzer = p }
                return p
            } catch {
                let e = error as? SpeechError ?? .analyzerFailed(String(describing: error))
                outcome.lock.withLock { outcome.done = true; outcome.error = e }
                return nil
            }
        }
    }

    /// The analyzer once it is prepared, nil while preparing or after a failure.
    var ready: PreparedAnalyzer? { outcome.lock.withLock { outcome.analyzer } }
    var error: SpeechError? { outcome.lock.withLock { outcome.error } }
}

struct SendableFormat: @unchecked Sendable {
    let format: AVAudioFormat
    init(_ f: AVAudioFormat) { format = f }
}

/// Runs async operations strictly one after another, in call order. `run` is `nonisolated(nonsending)`: it enqueues
/// on the caller's executor before its first suspension, so calls made one after another from one actor (the
/// app's main actor) run in that order even when the caller does not await each of them.
final class SerialQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    nonisolated(nonsending) func run<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let task: Task<T, any Error> = lock.withLock {
            let previous = tail
            let t = Task { await previous?.value; return try await op() }
            tail = Task { _ = await t.result }
            return t
        }
        return try await task.value
    }

    nonisolated(nonsending) func run(_ op: @escaping @Sendable () async -> Void) async {
        let task: Task<Void, Never> = lock.withLock {
            let previous = tail
            let t = Task { await previous?.value; await op() }
            tail = t
            return t
        }
        await task.value
    }
}

/// One analyzer instance with its input stream and results. A killed analyzer is replaced by a new epoch.
@available(macOS 26, *)
final class Epoch: @unchecked Sendable {
    enum Module { case dt, st }

    let id: Int
    let stream: AsyncStream<AnalyzerInput>
    let input: AsyncStream<AnalyzerInput>.Continuation
    /// Frames yielded into `input`, guarded by the run lock.
    var fed: Int64 = 0

    private let lock = NSLock()
    private var dt = ModuleResults()
    private var st = ModuleResults()
    private var _analyzer: Task<PreparedAnalyzer?, Never>?
    private var _resultTasks: [Task<Void, Never>] = []

    init(id: Int) {
        self.id = id
        (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    var analyzer: Task<PreparedAnalyzer?, Never>? {
        get { lock.withLock { _analyzer } }
        set { lock.withLock { _analyzer = newValue } }
    }

    var resultTasks: [Task<Void, Never>] {
        get { lock.withLock { _resultTasks } }
        set { lock.withLock { _resultTasks = newValue } }
    }

    func record(_ m: Module, _ s: Segment, isFinal: Bool, finalizedThrough: Int64) {
        lock.withLock {
            switch m {
            case .dt: dt.record(s, isFinal: isFinal, finalizedThrough: finalizedThrough)
            case .st: st.record(s, isFinal: isFinal, finalizedThrough: finalizedThrough)
            }
        }
    }

    func transcript(_ m: Module, from: Int64, through: Int64?, tolerance: Int64, includeVolatile: Bool) -> TranscriberText {
        lock.withLock {
            (m == .dt ? dt : st).transcript(from: from, through: through, tolerance: tolerance, includeVolatile: includeVolatile)
        }
    }

    func finalized(through frame: Int64) -> Bool {
        lock.withLock { dt.finalizedThrough >= frame && st.finalizedThrough >= frame }
    }
}

/// One started session: source, converter, gate and the current analyzer epoch.
@available(macOS 26, *)
final class Run: @unchecked Sendable {
    struct FinalizeJob: @unchecked Sendable {
        var epoch: Epoch
        var utterance: Int
        var mode: UtteranceMode
        var from: Int64
        var through: Int64
        var reason: EndReason
        var speechStart: Double
        var speechEnd: Double
        var lastVoicedWall: Double
        var decidedWall: Double
        /// Pause budget the gate used for this end (`EndpointGate.effectiveHangover`).
        var hangover: Double
        var kill: Bool
        var reopens: Int
    }

    let id: Int
    let source: any AudioSource
    let format: AVAudioFormat
    let rate: Double
    let tuning: VoiceSession.Tuning
    let locale: Locale
    let events: AsyncStream<VoiceSession.Event>.Continuation
    let startWall = uptime()
    static let debug = ProcessInfo.processInfo.environment["ACVOICE_SPEECH_DEBUG"] == "1"

    private let lock = NSLock()
    // Guarded by `lock`.
    private var closed = false
    private var gate: EndpointGate
    private var utterance: Int
    private var mode: UtteranceMode
    private var context: [String]
    let commandContext: [String]
    private var epoch: Epoch
    private var epochCounter = 1
    private var micFrames: Int64 = 0
    private var micReadySent = false
    private var lastChunkWall = 0.0
    private var lastVoicedFrame: Int64 = 0
    private var lastVoicedWall = 0.0
    private var uttStartFrame: Int64 = 0
    private var lastThrough: Int64 = 0
    private var pending: [Task<Void, Never>] = []
    private var lastPartial = ("", "")
    private var reopens = 0
    private var killNext: Bool
    private var restarting = false
    private var restartAgain = false
    private var restartTimes: [Double] = []
    // Used only by `ingest`, which the source calls serially.
    private let converter: StreamConverter
    private var meter: SliceMeter

    /// Pause budget of `start`, applied when `begin` arms the gate.
    private let startHangover: Double?

    init(id: Int, utterance: Int = 1, source: any AudioSource, format: AVAudioFormat, tuning: VoiceSession.Tuning,
         locale: Locale, events: AsyncStream<VoiceSession.Event>.Continuation, context: [String], commandContext: [String],
         mode: UtteranceMode, hangover: Double? = nil, killFirstFinalize: Bool) {
        self.id = id
        self.utterance = utterance
        startHangover = hangover
        self.source = source
        self.format = format
        rate = format.sampleRate
        self.tuning = tuning
        self.locale = locale
        self.events = events
        self.context = context
        self.commandContext = commandContext
        self.mode = mode
        killNext = killFirstFinalize
        gate = EndpointGate(config: tuning.gate)
        epoch = Epoch(id: 1)
        converter = StreamConverter(output: format)
        meter = SliceMeter(sliceFrames: Int((tuning.gate.sliceDuration * format.sampleRate).rounded()))
    }

    private var audioNow: Double { Double(micFrames) / rate }   // call with lock held

    private func event(_ kind: VoiceSession.Kind) -> VoiceSession.Event {   // call with lock held
        VoiceSession.Event(session: id, utterance: utterance, kind: kind)
    }

    private func emit(_ kind: VoiceSession.Kind) {
        if let e = lock.withLock({ closed ? nil : event(kind) }) { events.yield(e) }
    }

    func log(_ s: @autoclosure () -> String) {
        guard Self.debug else { return }
        FileHandle.standardError.write(Data(String(format: "[speech %7.3f] ", uptime() - startWall).appending(s() + "\n").utf8))
    }

    // MARK: Lifecycle

    func begin(prepared: Prebuild?) {
        let (e, ctx) = lock.withLock { () -> (Epoch, [String]) in
            gate.arm(mode, at: 0, hangover: startHangover)
            return (epoch, context)
        }
        if prepared?.ready?.format != format { emit(.warming) }
        launch(e, prepared: prepared, context: ctx)
    }

    func startSource() throws {
        try source.start(deliver: { [self] b in ingest(b) }, event: { [self] e in sourceEvent(e) })
    }

    func shutdown() async {
        let (e, tasks) = lock.withLock { () -> (Epoch, [Task<Void, Never>]) in
            closed = true
            gate.disarm()
            return (epoch, pending)
        }
        source.stop()
        e.input.finish()
        if let p = await e.analyzer?.value { await p.analyzer.cancelAndFinishNow() }
        for t in tasks { await t.value }
        for t in e.resultTasks { await t.value }
        events.finish()
    }

    func rearm(_ mode: UtteranceMode, context newContext: [String]?, gen: SpeechGen? = nil, hangover: Double? = nil) async {
        if let gen, gen.session != id {
            log("rearm for session \(gen.session) ignored (running \(id))")
            return
        }
        let target = newContext ?? (mode == .command ? commandContext : nil)
        let (e, changed) = lock.withLock { () -> (Epoch, Bool) in
            utterance = gen?.utterance ?? utterance + 1
            self.mode = mode
            gate.arm(mode, at: audioNow, hangover: hangover)
            uttStartFrame = lastThrough
            lastPartial = ("", "")
            reopens = 0
            var changed = false
            if let target, target != context { context = target; changed = true }
            return (epoch, changed)
        }
        log("rearm \(mode.rawValue) utterance \(lock.withLock { utterance }) contextChanged=\(changed)")
        guard changed, let target, let p = await e.analyzer?.value else { return }
        let t0 = uptime()
        try? await p.analyzer.setContext(AnalyzerFactory.analysisContext(target))
        log(String(format: "setContext %.0f ms", (uptime() - t0) * 1000))
    }

    /// Starts the analyzer of `e` once it is prepared; audio buffers in `e.stream` meanwhile. A pre-built analyzer
    /// for another format (the fallback format before the assets were installed) is not used.
    private func launch(_ e: Epoch, prepared: Prebuild?, context: [String]) {
        let locale = locale, format = SendableFormat(format)
        e.analyzer = Task { [self] () -> PreparedAnalyzer? in
            let t0 = uptime()
            var p = await prepared?.task.value
            if let q = p, q.format != format.format { p = nil }
            if p == nil {
                do { p = try await AnalyzerFactory.prepare(locale, format: format.format, context: context) }
                catch {
                    // A failed warm-up says why (assets missing, install timeout) better than the retry does.
                    emit(.failed(prepared?.error ?? .analyzerFailed(String(describing: error))))
                    return nil
                }
            }
            guard let p else { return nil }
            if p.context != context { try? await p.analyzer.setContext(AnalyzerFactory.analysisContext(context)) }
            e.resultTasks = [collectDT(p.dt, e), collectST(p.st, e)]
            do {
                try await p.analyzer.start(inputSequence: e.stream)
            } catch {
                emit(.failed(.analyzerFailed(String(describing: error))))
                return nil
            }
            log(String(format: "epoch %d analyzer ready after %.0f ms", e.id, (uptime() - t0) * 1000))
            emit(.ready)
            return p
        }
    }

    private func collectDT(_ dt: DictationTranscriber, _ e: Epoch) -> Task<Void, Never> {
        Task { [self] in
            do {
                for try await r in dt.results {
                    record(.dt, e, r.range, r.isFinal, r.resultsFinalizationTime,
                           [String(r.text.characters)] + r.alternatives.dropFirst().map { String($0.characters) })
                }
            } catch {}
        }
    }

    private func collectST(_ st: SpeechTranscriber, _ e: Epoch) -> Task<Void, Never> {
        Task { [self] in
            do {
                for try await r in st.results {
                    record(.st, e, r.range, r.isFinal, r.resultsFinalizationTime,
                           [String(r.text.characters)] + r.alternatives.dropFirst().map { String($0.characters) })
                }
            } catch {}
        }
    }

    private func record(_ m: Epoch.Module, _ e: Epoch, _ range: CMTimeRange, _ isFinal: Bool, _ finalized: CMTime, _ texts: [String]) {
        let seg = Segment(start: range.start.frames(at: rate), end: range.end.frames(at: rate), texts: texts)
        e.record(m, seg, isFinal: isFinal, finalizedThrough: finalized.frames(at: rate))
        if isFinal { log("\(m) final [\(seg.start)-\(seg.end)] fin=\(finalized.frames(at: rate))") }
        let out = lock.withLock { () -> VoiceSession.Event? in
            guard !closed, e === epoch, gate.phase != .idle else { return nil }
            let tol = Int64(0.05 * rate)
            let dt = e.transcript(.dt, from: uttStartFrame, through: nil, tolerance: tol, includeVolatile: true).best
            let st = e.transcript(.st, from: uttStartFrame, through: nil, tolerance: tol, includeVolatile: true).best
            guard dt != lastPartial.0 || st != lastPartial.1 else { return nil }
            lastPartial = (dt, st)
            gate.partial(dt: dt, st: st, at: audioNow)
            return event(.partial(dt: dt, st: st))
        }
        if let out { events.yield(out) }
    }

    // MARK: Audio path (source thread)

    func ingest(_ buffer: AVAudioPCMBuffer) {
        let wall = uptime()
        guard let out = converter.convert(buffer) else { return }
        let slices = meter.feed(out)
        var emitted: [VoiceSession.Event] = []
        lock.withLock {
            guard !closed else { return }
            if !micReadySent { micReadySent = true; emitted.append(event(.micReady)) }
            let n = Int64(out.frameLength)
            let chunkMic = micFrames, chunkFed = epoch.fed
            var peak: Float = -120
            var ending: EndpointGate.Ending?
            for s in slices {
                let t = Double(chunkMic + Int64(s.end)) / rate
                let before = gate.lastVoiced
                let o = gate.slice(rmsDB: s.db, at: t)
                if gate.lastVoiced != before {
                    lastVoicedFrame = chunkFed + Int64(s.end)
                    lastVoicedWall = wall - Double(n - Int64(s.end)) / rate
                }
                peak = max(peak, s.db)
                switch o {
                case .none: break
                case .onset: emitted.append(event(.speechStarted))
                case .noSpeech: emitted.append(event(.noSpeech))
                case .end(let e): ending = e
                }
            }
            if ending == nil, case .end(let e) = gate.chunkEnd(at: Double(chunkMic + n) / rate, chunkDuration: Double(n) / rate) {
                ending = e
            }
            micFrames += n
            lastChunkWall = wall
            epoch.input.yield(AnalyzerInput(buffer: out))
            epoch.fed += n
            if let ending { emitted.append(beginFinalize(ending, decidedWall: wall)) }
            emitted.append(event(.level(dB: peak, thresholdDB: gate.thresholdDB)))
        }
        for e in emitted { events.yield(e) }
    }

    /// Appends the synthetic tail and starts finalizing (call with lock held). Returns the `.endpoint` event for the
    /// caller to yield once the lock is released.
    private func beginFinalize(_ ending: EndpointGate.Ending, decidedWall: Double) -> VoiceSession.Event {
        let lead = Int64(tuning.finalizeLead * rate)
        var through = max(lastVoicedFrame + lead, uttStartFrame + 1)
        // In 100 ms pieces like the tap: one large buffer can leave a finalize waiting (seen while priming).
        let floor = min(max(gate.floorDB ?? -60, -70), -50)
        var tailLeft = Int64(max(0, tuning.syntheticTail * rate))
        while tailLeft > 0, let piece = AudioUtil.noise(format, frames: AVAudioFrameCount(min(tailLeft, Int64(rate / 10))), db: floor) {
            epoch.input.yield(AnalyzerInput(buffer: piece))
            epoch.fed += Int64(piece.frameLength)
            tailLeft -= Int64(piece.frameLength)
        }
        through = min(through, epoch.fed)
        let job = FinalizeJob(epoch: epoch, utterance: utterance, mode: mode, from: uttStartFrame, through: through,
                              reason: ending.reason, speechStart: gate.speechStart, speechEnd: ending.lastVoiced,
                              lastVoicedWall: lastVoicedWall, decidedWall: decidedWall, hangover: gate.effectiveHangover,
                              kill: killNext, reopens: reopens)
        killNext = false
        lastThrough = through
        log(String(format: "end %@ utterance %d: speechEnd %.2f s, decided after %.0f ms", ending.reason.rawValue,
                   utterance, ending.lastVoiced, (decidedWall - lastVoicedWall) * 1000))
        pending.append(Task { [self] in await finish(job) })
        return event(.endpoint)
    }

    private func finish(_ job: FinalizeJob) async {
        let f0 = uptime()
        var killed = true
        if let p = await job.epoch.analyzer?.value {
            let ok: Bool
            if job.kill {
                await p.analyzer.cancelAndFinishNow()   // testing hook: what a missed deadline does
                ok = false
            } else {
                ok = await finalizeOrKill(p.analyzer, through: CMTime(value: job.through, timescale: CMTimeScale(rate)),
                                          timeout: .milliseconds(Int(tuning.finalizeTimeout * 1000)))
            }
            killed = !ok
            if ok {
                let d0 = uptime(), deadline = d0 + tuning.drainTimeout
                while !job.epoch.finalized(through: job.through), uptime() < deadline { try? await Task.sleep(for: .milliseconds(3)) }
                log(String(format: "finalize %.0f ms, drain %.0f ms%@", (d0 - f0) * 1000, (uptime() - d0) * 1000,
                           job.epoch.finalized(through: job.through) ? "" : " (timeout)"))
            }
        }
        let f1 = uptime()
        let tol = Int64(0.05 * rate)
        let dt = job.epoch.transcript(.dt, from: job.from, through: job.through, tolerance: tol, includeVolatile: false)
        let st = job.epoch.transcript(.st, from: job.from, through: job.through, tolerance: tol, includeVolatile: false)
        let lead = EndpointGate.leading(dt.best, st.best)
        if Self.shouldReopen(after: job, killed: killed, finalText: lead, config: tuning.gate) {
            // The final text shows a dangling last word the live partial did not have yet ("Öffne WWT Ticket"
            // during a pause before "412"): keep listening with the incomplete hangover (REVIEW M1).
            let resumed = lock.withLock { () -> VoiceSession.Event? in
                guard !closed, epoch === job.epoch, utterance == job.utterance, gate.phase == .idle,
                      gate.resume(transcript: lead, at: audioNow) else { return nil }
                reopens = job.reopens + 1
                return event(.resumed)
            }
            if let resumed {
                events.yield(resumed)
                log(String(format: "utterance %d: final text dangles, listening on (finalize %.0f ms)", job.utterance, (f1 - f0) * 1000))
                return
            }
        }
        let hyps = HypothesisBuilder.build(dictation: dt, speech: st, maxAlternatives: tuning.maxAlternatives)
        if Self.isNoise(job, killed: killed, dictation: dt.best, speech: st.best, hypotheses: hyps,
                        maxDuration: tuning.noiseMaxDuration) {
            // A cough or a knock long enough for an onset, but no word: no utterance, wait for speech again. The
            // no-speech timeout still counts from the press (REVIEW M1: noise must not end the listening).
            let rewaited = lock.withLock { () -> VoiceSession.Event? in
                guard !closed, epoch === job.epoch, utterance == job.utterance, gate.phase == .idle else { return nil }
                gate.rewait(at: audioNow)
                uttStartFrame = job.through
                lastPartial = ("", "")
                reopens = 0
                return event(.discarded)
            }
            if let rewaited {
                events.yield(rewaited)
                log(String(format: "utterance %d: no words (speech %.2f-%.2f s), waiting for speech again", job.utterance,
                           job.speechStart, job.speechEnd))
                return
            }
        }
        if killed { rebuild(after: job.epoch) }
        let done = uptime()
        let timing = VoiceSession.Timing(speechStart: job.speechStart, speechEnd: job.speechEnd,
                                         endpointMs: (job.decidedWall - job.lastVoicedWall) * 1000,
                                         finalizeMs: (f1 - f0) * 1000, totalMs: (done - job.lastVoicedWall) * 1000, killed: killed,
                                         reopens: job.reopens)
        log(String(format: "utterance %d: finalize %.0f ms, total %.0f ms, killed %@, hyps %d", job.utterance,
                   timing.finalizeMs, timing.totalMs, killed ? "yes" : "no", hyps.count))
        let u = VoiceSession.Utterance(mode: job.mode, hypotheses: hyps, dictation: dt, speech: st, endReason: job.reason, timing: timing)
        let e = lock.withLock { closed ? nil : VoiceSession.Event(session: id, utterance: job.utterance, kind: .utterance(u)) }
        if let e { events.yield(e) }
    }

    /// Whether a finished utterance whose final text dangles reopens (REVIEW M1): the live partial lagged behind the
    /// final ("Öffne WWT" live, "Öffne WWT Ticket" final), so the controller chose a short hangover. Same rule as the
    /// controller's (`Parser.looksIncomplete`; a trailing numeral dangles in commands only). Not when the gate already
    /// waited the incomplete hangover: the end came at most half a chunk early, so reopening only adds a chunk, a
    /// second synthetic tail and a second finalize (review: every "Ticket 47285" reopened once).
    static func shouldReopen(after job: FinalizeJob, killed: Bool, finalText: String, config: EndpointGate.Config) -> Bool {
        guard !killed, job.reason == .pause, job.reopens < 2, job.hangover < config.incompleteHangover - 1e-9 else { return false }
        guard !TextNorm.tokenize(finalText).isEmpty else { return false }
        return Parser.looksIncomplete(finalText, choosing: job.mode == .answer)
    }

    /// A command utterance that ended on a pause without a word: no hypotheses at all, or a short one where DT
    /// heard nothing and ST at most one word (ST made up "you" from a 250 ms noise burst in 1 of 4 runs).
    /// Answers keep their empty utterance: the flow listens on by itself there. A killed finalize keeps it too:
    /// its words may be lost, not missing.
    static func isNoise(_ job: FinalizeJob, killed: Bool, dictation: String, speech: String, hypotheses: [Hypothesis],
                        maxDuration: Double) -> Bool {
        guard !killed, job.reason == .pause, job.mode == .command else { return false }
        if hypotheses.isEmpty { return true }
        return TextNorm.tokenize(dictation).isEmpty && TextNorm.tokenize(speech).count <= 1
            && job.speechEnd - job.speechStart <= maxDuration + 1e-9
    }

    /// The analyzer of `old` was killed: new analyzer and input stream; audio buffers until it runs.
    private func rebuild(after old: Epoch) {
        let next = lock.withLock { () -> (Epoch, [String])? in
            guard !closed, epoch === old else { return nil }
            epochCounter += 1
            let e = Epoch(id: epochCounter)
            epoch = e
            lastThrough = 0
            uttStartFrame = 0
            return (e, context)
        }
        old.input.finish()
        guard let (e, ctx) = next else { return }
        log("rebuild analyzer, epoch \(e.id)")
        launch(e, prepared: nil, context: ctx)
    }

    // MARK: Live controls

    func setHangover(_ seconds: Double) { lock.withLock { gate.setHangover(seconds) } }

    func setHold(_ held: Bool) { lock.withLock { gate.setHold(held) } }

    func noteEarcon(duration: Double) {
        lock.withLock {
            let now = micReadySent ? audioNow + max(0, uptime() - lastChunkWall) : max(0, uptime() - startWall)
            gate.blank(from: now, duration: duration)
        }
    }

    func endNow(reason: EndReason, noSpeechIfSilent: Bool) -> Bool {
        let result = lock.withLock { () -> (acted: Bool, event: VoiceSession.Event?) in
            guard !closed else { return (false, nil) }
            if case .end(let e) = gate.endNow(at: audioNow, reason: reason) {
                return (true, beginFinalize(e, decidedWall: uptime()))
            }
            if noSpeechIfSilent, gate.phase == .waiting {
                gate.disarm()
                return (true, event(.noSpeech))
            }
            return (false, nil)
        }
        if let e = result.event { events.yield(e) }
        return result.acted
    }

    private func sourceEvent(_ e: AudioSourceEvent) {
        switch e {
        case .configurationChanged:
            // The engine stopped itself: finish the utterance with what was heard, then capture again (REVIEW M7).
            _ = endNow(reason: .sourceChanged, noSpeechIfSilent: false)
            lock.withLock {
                guard !closed else { return }
                if restarting { restartAgain = true; return }
                restarting = true
                pending.append(Task { [self] in await restartSource() })
            }
        case .failed(let message):
            _ = endNow(reason: .sourceChanged, noSpeechIfSilent: false)
            emit(.failed(.sourceFailed(message)))
        }
    }

    /// Restarts capture after a device change, one restart at a time; a change during a restart runs it once
    /// more. `shutdown` awaits this task, and a restart that completes after `shutdown` began stops the source
    /// again: the microphone never stays open after `stop()` (review: restart racing stop). More than
    /// `maxSourceRestarts` within `sourceRestartWindow` stop the microphone and fail the session.
    private func restartSource() async {
        while true {
            enum Step { case closed, tooMany, restart }
            let step = lock.withLock { () -> Step in
                guard !closed else { restarting = false; return .closed }
                let now = uptime()
                restartTimes.removeAll { now - $0 >= tuning.sourceRestartWindow }
                guard restartTimes.count < tuning.maxSourceRestarts else { restarting = false; return .tooMany }
                restartTimes.append(now)
                restartAgain = false
                return .restart
            }
            switch step {
            case .closed:
                return
            case .tooMany:
                source.stop()
                log("capture restarted \(tuning.maxSourceRestarts) times within \(tuning.sourceRestartWindow) s, giving up")
                emit(.failed(.sourceFailed("audio device keeps changing")))
                return
            case .restart:
                break
            }
            source.stop()
            do {
                try startSource()
            } catch {
                lock.withLock { restarting = false }
                emit(.failed(.sourceFailed(String(describing: error))))
                return
            }
            let after = lock.withLock { () -> Step? in
                if closed { restarting = false; return .closed }
                if restartAgain { return .restart }
                restarting = false
                return nil
            }
            switch after {
            case .closed?:
                source.stop()
                return
            case .restart?:
                continue
            default:
                emit(.sourceRestarted)
                return
            }
        }
    }
}
