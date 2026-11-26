import ACVoiceCore
import AVFoundation
@testable import ACVoiceSpeech
import Foundation
import Testing

/// A source that starts like `MicSource`: `stop()` first, then a blocking setup, then it runs. Never touches audio
/// hardware and delivers no audio.
final class SlowSource: AudioSource, @unchecked Sendable {
    let name = "slow"
    let startDelay: Double
    private let lock = NSLock()
    private var running = false
    private var onEvent: (@Sendable (AudioSourceEvent) -> Void)?
    private var starts = 0

    init(startDelay: Double) { self.startDelay = startDelay }

    var isRunning: Bool { lock.withLock { running } }
    var startCount: Int { lock.withLock { starts } }

    func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               event: @escaping @Sendable (AudioSourceEvent) -> Void) throws {
        stop()
        Thread.sleep(forTimeInterval: startDelay)   // engine.prepare() + engine.start()
        lock.withLock { running = true; onEvent = event; starts += 1 }
    }

    func stop() { lock.withLock { running = false } }

    /// What MicSource's `AVAudioEngineConfigurationChange` observer does.
    func fireConfigurationChange() { lock.withLock { onEvent }?(.configurationChanged) }
}

/// Collects a run's events by kind name.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<VoiceSession.Event>) {
        task = Task { [self] in for await e in stream { lock.withLock { names.append(Pump.name(e.kind)) } } }
    }

    var all: [String] { lock.withLock { names } }
    func count(_ name: String) -> Int { all.filter { $0 == name }.count }

    func wait(until name: String, count n: Int = 1, timeout: Double = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while self.count(name) < n, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func finish() async { await task?.value }
}

/// Device-change restarts of a session (REVIEW M7) without analyzer or microphone: the run is never begun, so no
/// analyzer is prepared and the gate stays idle.
@Suite struct SourceRestartTests {
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!

    func makeRun(_ source: any AudioSource, tuning: VoiceSession.Tuning = .init()) -> (Run, EventLog) {
        let (stream, continuation) = AsyncStream.makeStream(of: VoiceSession.Event.self)
        let run = Run(id: 1, source: source, format: Self.format, tuning: tuning, locale: Locale(identifier: "de_DE"),
                      events: continuation, context: [], commandContext: [], mode: .command, killFirstFinalize: false)
        return (run, EventLog(stream))
    }

    /// Review: the restart after a device change ran after `stop()` and left the microphone open.
    @Test func restartRacingStopLeavesTheSourceStopped() async throws {
        let source = SlowSource(startDelay: 0.15)
        let (run, log) = makeRun(source)
        try run.startSource()
        source.fireConfigurationChange()           // the restart begins
        try await Task.sleep(for: .milliseconds(30))
        await run.shutdown()                       // the flow stops the session while the engine restarts
        #expect(!source.isRunning)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!source.isRunning)
        #expect(source.startCount == 2)
        await log.finish()
        #expect(!log.all.contains("sourceRestarted"))
    }

    @Test func changesDuringARestartAreCoalesced() async throws {
        let source = SlowSource(startDelay: 0.05)
        let (run, log) = makeRun(source)
        try run.startSource()
        for _ in 0..<3 { source.fireConfigurationChange() }
        await log.wait(until: "sourceRestarted")
        try await Task.sleep(for: .milliseconds(150))
        #expect(source.isRunning)
        #expect(log.count("sourceRestarted") == 1)
        #expect((2...3).contains(source.startCount))
        await run.shutdown()
        await log.finish()
        #expect(!source.isRunning)
    }

    @Test func aFlappingDeviceStopsTheMicrophone() async throws {
        var tuning = VoiceSession.Tuning()
        tuning.maxSourceRestarts = 2
        tuning.sourceRestartWindow = 5
        let source = SlowSource(startDelay: 0.01)
        let (run, log) = makeRun(source, tuning: tuning)
        try run.startSource()
        for n in 1...2 {
            source.fireConfigurationChange()
            await log.wait(until: "sourceRestarted", count: n)
        }
        #expect(source.isRunning)
        source.fireConfigurationChange()
        await log.wait(until: "failed(Mikrofon nicht verfügbar)")
        #expect(log.count("failed(Mikrofon nicht verfügbar)") == 1)
        #expect(!source.isRunning)
        #expect(source.startCount == 3)
        await run.shutdown()
        await log.finish()
    }
}

/// When a finished utterance reopens or counts as noise (pure decisions of `Run.finish`).
@Suite struct FinishPolicyTests {
    func job(_ mode: UtteranceMode = .command, reason: EndReason = .pause, hangover: Double, reopens: Int = 0,
             speech: Double = 1) -> Run.FinalizeJob {
        Run.FinalizeJob(epoch: Epoch(id: 1), utterance: 1, mode: mode, from: 0, through: 0, reason: reason, speechStart: 0.3,
                        speechEnd: 0.3 + speech, lastVoicedWall: 0, decidedWall: 0, hangover: hangover, kill: false,
                        reopens: reopens)
    }

    let config = EndpointGate.Config()

    @Test func danglingFinalAfterAShortHangoverReopens() {
        #expect(Run.shouldReopen(after: job(hangover: 0.60), killed: false, finalText: "Öffne WWT Ticket", config: config))
        #expect(Run.shouldReopen(after: job(hangover: 0.45), killed: false, finalText: "Öffne Ticket 47285", config: config))
        #expect(Run.shouldReopen(after: job(.answer, hangover: 0.40), killed: false, finalText: "nein", config: config))
        #expect(!Run.shouldReopen(after: job(.answer, hangover: 0.40), killed: false, finalText: "zwei", config: config))
        #expect(!Run.shouldReopen(after: job(hangover: 0.60), killed: false, finalText: "Öffne WWT Relaunch", config: config))
    }

    /// Review: "Öffne Ticket 47285" waited the incomplete hangover already and still reopened once (+100 ms and a
    /// second finalize on every ticket-by-number command).
    @Test func noReopenAfterTheIncompleteHangover() throws {
        #expect(!Run.shouldReopen(after: job(hangover: 1.10), killed: false, finalText: "Öffne Ticket 47285", config: config))
        #expect(!Run.shouldReopen(after: job(hangover: 1.10), killed: false, finalText: "Öffne WWT Ticket", config: config))
        // The gate state that produced it: decided at the nearest chunk boundary 1.06 s after the speech end.
        var d = GateDriver()
        d.say(1.2, "Öffne Ticket 47285")
        _ = d.run([(-60, 0.4), (-28, 0.9), (-60, 1.06)])
        #expect(try #require(d.gate.chunkEnd(at: 2.36, chunkDuration: 0.1).ending).reason == .pause)
        #expect(d.gate.effectiveHangover == config.incompleteHangover)
    }

    /// The reopen rule is the controller's rule (`Parser.looksIncomplete`): a number completes an answer, a verb at the
    /// end of a German command completes it, and an empty final never reopens.
    @Test func reopenFollowsTheCoreRule() {
        #expect(!Run.shouldReopen(after: job(.answer, hangover: 0.40), killed: false, finalText: "die vier", config: config))
        #expect(Run.shouldReopen(after: job(.answer, hangover: 0.40), killed: false, finalText: "die", config: config))
        #expect(!Run.shouldReopen(after: job(hangover: 0.45), killed: false, finalText: "WWT Relaunch öffnen", config: config))
        #expect(Run.shouldReopen(after: job(hangover: 0.45), killed: false, finalText: "Öffne WWT 41", config: config))
        #expect(!Run.shouldReopen(after: job(hangover: 0.60), killed: false, finalText: "", config: config))
    }

    @Test func otherEndsNeverReopen() {
        #expect(!Run.shouldReopen(after: job(hangover: 0.60), killed: true, finalText: "Öffne WWT Ticket", config: config))
        #expect(!Run.shouldReopen(after: job(reason: .manual, hangover: 0.60), killed: false, finalText: "Öffne WWT Ticket", config: config))
        #expect(!Run.shouldReopen(after: job(hangover: 0.60, reopens: 2), killed: false, finalText: "Öffne WWT Ticket", config: config))
    }

    /// Review: a cough before the command produced an utterance without hypotheses ("Nicht verstanden").
    @Test func wordlessCommandIsNoise() {
        func noise(_ j: Run.FinalizeJob, killed: Bool = false, dt: String = "", st: String = "") -> Bool {
            let hyps = HypothesisBuilder.build(dictation: TranscriberText(best: dt), speech: TranscriberText(best: st))
            return Run.isNoise(j, killed: killed, dictation: dt, speech: st, hypotheses: hyps, maxDuration: 0.5)
        }
        let cough = job(hangover: 1.10, speech: 0.26), long = job(hangover: 1.10, speech: 1.2)
        #expect(noise(cough))
        #expect(noise(long))                       // no word at all: noise at any length
        #expect(noise(cough, st: "you"))           // ST made up one word, DT heard nothing
        #expect(noise(cough, st: "."))
        #expect(!noise(long, st: "you"))           // long enough to be speech DT missed
        #expect(!noise(cough, st: "Meine Aufgaben"))
        #expect(!noise(cough, dt: "WWT"))
        #expect(!noise(job(.answer, hangover: 0.40, speech: 0.26)))   // the flow listens on itself
        #expect(!noise(cough, killed: true))
        #expect(!noise(job(reason: .maxDuration, hangover: 1.10, speech: 8)))
        #expect(!noise(job(reason: .sourceChanged, hangover: 1.10, speech: 0.26)))
    }
}

/// `withDeadline`: the bound the self-check and the format lookup rely on.
@Suite struct DeadlineTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    @Test func returnsTheValueInTime() async throws {
        #expect(try await withDeadline(.seconds(1)) { 42 } == 42)
        await #expect(throws: SpeechError.self) {
            _ = try await withDeadline(.seconds(1)) { () async throws -> Int in throw SpeechError.assetsUnavailable }
        }
    }

    /// Review: a task group with a timer child waited for a child that ignored cancellation (self-check 20 ms
    /// timeout -> 710 ms).
    @Test func returnsAtTheDeadlineWhenTheOperationIgnoresCancellation() async throws {
        let release = Flag(), cancelled = Flag()
        let t0 = Date()
        let value = try await withDeadline(.milliseconds(50)) { () async -> String in
            // Stands in for awaiting an analyzer: an unstructured task does not inherit cancellation.
            let stuck = Task { while !release.isSet { try? await Task.sleep(for: .milliseconds(5)) }; return "late" }
            let v = await stuck.value
            if Task.isCancelled { cancelled.set() }
            return v
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        #expect(value == nil)
        #expect(ms < 400)
        release.set()
        try await Task.sleep(for: .milliseconds(50))
        #expect(cancelled.isSet)   // the operation's task was cancelled at the deadline
    }

    @Test func keepsTheOperationRunningWhenAsked() async throws {
        let finished = Flag()
        let value = try await withDeadline(.milliseconds(20), cancelOnTimeout: false) { () async -> Bool in
            try? await Task.sleep(for: .milliseconds(100))   // not cancelled: sleeps the full time
            finished.set()
            return !Task.isCancelled
        }
        #expect(value == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(finished.isSet)
    }

    @Test func cancellingTheCallerReturnsAtOnce() async throws {
        let t0 = Date()
        let caller = Task { try await withDeadline(.seconds(5)) { () async -> Int in
            let never = Task { try? await Task.sleep(for: .seconds(5)); return 1 }
            return await never.value
        } }
        try await Task.sleep(for: .milliseconds(30))
        caller.cancel()
        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        #expect(Date().timeIntervalSince(t0) < 1)
    }

    @Test func raceSlotKeepsTheFirstResult() async throws {
        let early = RaceSlot<Int>()
        #expect(early.fill(.success(1)))
        #expect(!early.fill(.success(2)))
        #expect(try await early.wait() == 1)
        let late = RaceSlot<Int>()
        Task { try? await Task.sleep(for: .milliseconds(20)); late.fill(.success(3)) }
        #expect(try await late.wait() == 3)
    }
}

/// Every event, failures included, carries the caller's stamp (`start(gen:)`, `rearm(gen:)`), so the controller passes
/// `.failed` on as `VoiceFlow`'s `.speechFailed(event.gen, error.failure)` (REVIEW M3).
@Suite struct StampTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [VoiceSession.Event] = []
        private var task: Task<Void, Never>?
        init(_ stream: AsyncStream<VoiceSession.Event>) {
            task = Task { [self] in for await e in stream { lock.withLock { items.append(e) } } }
        }
        var failures: [(gen: SpeechGen, failure: SpeechFailure)] {
            lock.withLock { items.compactMap { e in if case .failed(let err) = e.kind { return (e.gen, err.failure) }; return nil } }
        }
        func wait(failures n: Int) async {
            let deadline = Date().addingTimeInterval(3)
            while failures.count < n, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func finish() async { await task?.value }
    }

    @Test func failuresCarryTheCallersStamp() async throws {
        var tuning = VoiceSession.Tuning()
        tuning.maxSourceRestarts = 0   // the first device change fails the session
        let source = SlowSource(startDelay: 0.01)
        let (stream, continuation) = AsyncStream.makeStream(of: VoiceSession.Event.self)
        let run = Run(id: 41, utterance: 1, source: source, format: SourceRestartTests.format, tuning: tuning,
                      locale: Locale(identifier: "de_DE"), events: continuation, context: [], commandContext: [],
                      mode: .command, hangover: 0.6, killFirstFinalize: false)
        let events = Events(stream)
        try run.startSource()
        // The flow re-arms for an answer: the next failure carries that utterance.
        await run.rearm(.answer, context: nil, gen: SpeechGen(session: 41, utterance: 2), hangover: 0.4)
        // A re-arm for another session is stale and changes nothing.
        await run.rearm(.command, context: nil, gen: SpeechGen(session: 40, utterance: 9), hangover: 0.6)
        source.fireConfigurationChange()
        await events.wait(failures: 1)
        await run.shutdown()
        await events.finish()
        let f = events.failures
        #expect(f.count == 1)
        #expect(f.first?.gen == SpeechGen(session: 41, utterance: 2))
        #expect(f.first?.failure == .noInput)
    }

    @Test func errorsMapToTheFlowsFailures() {
        #expect(SpeechError.assetsUnavailable.failure == .modelUnavailable)
        #expect(SpeechError.analyzerFailed("x").failure == .modelUnavailable)
        #expect(SpeechError.sourceFailed("x").failure == .noInput)
        #expect(SpeechError.invalidInputFormat.failure == .noInput)
        #expect(SpeechError.invalidAudio("x").failure == .engine)
        #expect(SpeechError.assetsUnavailable.message == "Sprachmodell nicht verfügbar")
        #expect(SpeechError.wrap(SpeechError.invalidInputFormat) == .invalidInputFormat)
        #expect(SpeechError.wrap(CancellationError()).failure == .noInput)
    }

    @Test func eventStampAsGen() {
        let e = VoiceSession.Event(session: 5, utterance: 3, kind: .speechStarted)
        #expect(e.gen == SpeechGen(session: 5, utterance: 3))
    }
}
