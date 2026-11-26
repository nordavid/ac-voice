import ACVoiceCore
import ACVoiceFlow
import ACVoiceSystem
import Foundation
import os

// MARK: - Serial work

/// Runs speech lifecycle calls strictly in effect order on the main actor. An async job (start, rearm, stop) holds
/// the queue until it returns; a sync job (hangover, hold, end now) runs at once when nothing is queued, else after
/// the jobs before it. So `.startMic` followed by `.suspendEndpointing(true)` holds the new session, not the old one.
@MainActor
final class SerialWork {
    private var jobs: [@MainActor () async -> Void] = []
    private var runner: Task<Void, Never>?

    var isBusy: Bool { runner != nil }

    func perform(_ job: @escaping @MainActor () -> Void) {
        if runner == nil { job() } else { jobs.append { job() } }
    }

    func enqueue(_ job: @escaping @MainActor () async -> Void) {
        jobs.append(job)
        guard runner == nil else { return }
        runner = Task { @MainActor in
            while !self.jobs.isEmpty {
                let next = self.jobs.removeFirst()
                await next()
            }
            self.runner = nil
        }
    }

    /// Returns once every queued job ran.
    func idle() async {
        while let r = runner { await r.value }
    }
}

// MARK: - Clock

/// The app's clock: `Date()` for the reducer, `ContinuousClock` for timers and latencies (monotonic, also across
/// sleep).
@MainActor
public final class SystemClock: RuntimeClock {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: Date { Date() }

    public var uptime: Double {
        let d = ContinuousClock.now - origin
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) -> any TimerToken {
        after(seconds, tolerance: 0.005, action)
    }

    public func after(_ seconds: Double, tolerance: Double, _ action: @escaping @MainActor () -> Void) -> any TimerToken {
        let delay = max(0, seconds.isFinite ? seconds : 0)
        let slack = max(0.001, tolerance.isFinite ? tolerance : 0.005)
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay), tolerance: .seconds(slack), clock: .continuous)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return TaskTimer(task)
    }
}

@MainActor
final class TaskTimer: TimerToken {
    private let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
}

// MARK: - Live transcript

/// Splits a live transcript into a stable part (words the previous partial already had) and a volatile tail, so the
/// overlay draws settled words bright and the newest words dim.
struct TranscriptSplitter: Sendable {
    private var previous: [Substring] = []

    mutating func reset() { previous = [] }

    mutating func next(_ text: String) -> Transcript {
        let words = text.split(whereSeparator: \.isWhitespace)
        var common = 0
        while common < min(words.count, previous.count), Self.same(words[common], previous[common]) { common += 1 }
        // The last word may still grow ("Relau" -> "Relaunch"): a word is stable once the previous partial had it and
        // the text goes on after it.
        let stableCount = min(common, max(0, words.count - 1))
        previous = words
        return Transcript(stable: words.prefix(stableCount).joined(separator: " "),
                          volatile: words.dropFirst(stableCount).joined(separator: " "))
    }

    private static func same(_ a: Substring, _ b: Substring) -> Bool {
        TextNorm.fold(String(a)) == TextNorm.fold(String(b))
    }
}

// MARK: - Latencies

/// What the diagnostics report: press -> mic ready, speech end -> final, final -> Chrome opened.
public enum LatencyMetric: String, CaseIterable, Sendable {
    case pressToMic, speechEndToFinal, finalToOpened
}

/// The last samples of one metric, in milliseconds.
public struct LatencyStats: Sendable, Equatable {
    public static let capacity = 20
    public private(set) var samples: [Double] = []
    public init() {}

    public mutating func add(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        samples.append(ms)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    public var count: Int { samples.count }
    public var last: Double? { samples.last }
    public var median: Double? { quantile(0.5) }
    public var p90: Double? { quantile(0.9) }

    func quantile(_ q: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let i = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[min(max(i, 0), sorted.count - 1)]
    }
}

/// os_signpost intervals for Instruments (M7) plus the same durations for the diagnostics.
/// Intervals: press -> mic ready, speech end -> final, final -> opened.
@MainActor
final class FlowSignposts {
    private let signposter = Log.signposter(.flow)
    private var pressToMic: (state: OSSignpostIntervalState, at: Double, session: Int)?
    private var endToFinal: (state: OSSignpostIntervalState, at: Double, gen: SpeechGen)?
    private var finalToOpened: (state: OSSignpostIntervalState, at: Double)?
    private(set) var stats: [LatencyMetric: LatencyStats] = [:]

    func press(session: Int, at t: Double) {
        if let open = pressToMic { signposter.endInterval("pressToMicReady", open.state, "abandoned") }
        pressToMic = (signposter.beginInterval("pressToMicReady", id: signposter.makeSignpostID()), t, session)
    }

    func micReady(session: Int, at t: Double) {
        guard let open = pressToMic, open.session == session else { return }
        signposter.endInterval("pressToMicReady", open.state)
        pressToMic = nil
        record(.pressToMic, (t - open.at) * 1000)
    }

    func endpoint(_ gen: SpeechGen, at t: Double) {
        // A reopened utterance ends again later: the last end before the final counts.
        if let open = endToFinal { signposter.endInterval("speechEndToFinal", open.state, "reopened") }
        endToFinal = (signposter.beginInterval("speechEndToFinal", id: signposter.makeSignpostID()), t, gen)
    }

    /// `latencyMs`: the speech layer's own measure (speech end -> final), preferred for the statistics.
    func final(_ gen: SpeechGen, at t: Double, latencyMs: Double?) {
        var measured = latencyMs
        if let open = endToFinal, open.gen == gen {
            signposter.endInterval("speechEndToFinal", open.state)
            endToFinal = nil
            if measured == nil { measured = (t - open.at) * 1000 }
        }
        if let measured { record(.speechEndToFinal, measured) }
        if let open = finalToOpened { signposter.endInterval("finalToOpened", open.state, "superseded") }
        finalToOpened = (signposter.beginInterval("finalToOpened", id: signposter.makeSignpostID()), t)
    }

    func opened(at t: Double, ok: Bool) {
        guard let open = finalToOpened else { return }
        signposter.endInterval("finalToOpened", open.state)
        finalToOpened = nil
        if ok { record(.finalToOpened, (t - open.at) * 1000) }
    }

    /// The flow went idle or failed: close what is still open.
    func reset() {
        if let open = pressToMic { signposter.endInterval("pressToMicReady", open.state, "abandoned") }
        if let open = endToFinal { signposter.endInterval("speechEndToFinal", open.state, "abandoned") }
        if let open = finalToOpened { signposter.endInterval("finalToOpened", open.state, "abandoned") }
        pressToMic = nil; endToFinal = nil; finalToOpened = nil
    }

    private func record(_ m: LatencyMetric, _ ms: Double) {
        stats[m, default: LatencyStats()].add(ms)
        Log.event(.flow, "latency", .tag("metric", m), .double("ms", (ms * 10).rounded() / 10))
    }
}

// MARK: - Log tags

/// Event names for the log. FlowEvent, Effect and OverlayModel carry transcripts and names, so they are never logged
/// through their default description; only these tags are.
enum EventTag: String {
    case press, release, choose, cancel, pointer, speechWarm, micReady, speechStarted, voice, partial, speechEnded
    case speechResumed, speechDiscarded, utterance, noSpeech, speechFailed, taskListsRevalidated, archiveFetched, probed
    case opened, openFailed, timer

    init(_ e: FlowEvent) {
        switch e {
        case .press: self = .press
        case .release: self = .release
        case .choose: self = .choose
        case .cancel: self = .cancel
        case .pointer: self = .pointer
        case .speechWarm: self = .speechWarm
        case .micReady: self = .micReady
        case .speechStarted: self = .speechStarted
        case .voice: self = .voice
        case .partial: self = .partial
        case .speechEnded: self = .speechEnded
        case .speechResumed: self = .speechResumed
        case .speechDiscarded: self = .speechDiscarded
        case .utterance: self = .utterance
        case .noSpeech: self = .noSpeech
        case .speechFailed: self = .speechFailed
        case .taskListsRevalidated: self = .taskListsRevalidated
        case .archiveFetched: self = .archiveFetched
        case .probed: self = .probed
        case .opened: self = .opened
        case .openFailed: self = .openFailed
        case .timer: self = .timer
        }
    }

    /// Partials and levels arrive several times per second: logged at debug level only.
    var isFrequent: Bool { self == .partial || self == .voice }
}

/// Speech failure names for the log.
enum FailureTag: String {
    case micDenied, noInput, modelUnavailable, engine
    init(_ f: SpeechFailure) {
        switch f {
        case .micDenied: self = .micDenied
        case .noInput: self = .noInput
        case .modelUnavailable: self = .modelUnavailable
        case .engine: self = .engine
        }
    }
}
