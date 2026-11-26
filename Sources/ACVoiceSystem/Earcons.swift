import ACVoiceFlow
import AVFoundation
import Foundation

/// Earcon synthesis: short, quiet sine tones built at runtime, no asset files. Pure, so tests check the samples.
///
/// - listen: soft rising two-tone (D5 to A5), 150 ms. Plays when the mic is hot.
/// - done: bright confirm (C6 to G6, bell-like decay), 140 ms.
/// - error: low double (A3, then G3), 170 ms.
///
/// Peaks stay between -17 and -15 dBFS. Raised-cosine edges keep the first and last sample at zero (no click).
public enum EarconSynth {
    public static let sampleRate: Double = 48_000

    /// Mono Float32, the player's connection format.
    public static var format: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    /// Length in seconds. The speech gate blanks for this long (plus output latency) while an earcon plays.
    public static func duration(_ earcon: Earcon) -> Double {
        spec(earcon).duration
    }

    /// Target peak amplitude (linear, full scale 1.0).
    public static func peak(_ earcon: Earcon) -> Float {
        spec(earcon).peak
    }

    /// The earcon as mono samples at `sampleRate`.
    public static func samples(_ earcon: Earcon, sampleRate: Double = sampleRate) -> [Float] {
        let s = spec(earcon)
        let count = Int((s.duration * sampleRate).rounded())
        var out = [Float](repeating: 0, count: count)
        for note in s.notes {
            render(note, into: &out, sampleRate: sampleRate)
        }
        let maxAbs = out.reduce(Float(0)) { max($0, abs($1)) }
        guard maxAbs > 0 else { return out }
        let gain = s.peak / maxAbs
        for i in out.indices { out[i] *= gain }
        return out
    }

    /// An `AVAudioPCMBuffer` with the samples, in `format` (mono Float32 at `sampleRate`). Touches no audio device.
    public static func buffer(_ earcon: Earcon) -> AVAudioPCMBuffer? {
        let data = samples(earcon)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)),
              let channel = buf.floatChannelData?[0]
        else { return nil }
        data.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: data.count)
        }
        buf.frameLength = AVAudioFrameCount(data.count)
        return buf
    }

    // MARK: Design

    struct Note {
        var start: Double
        var length: Double
        var frequency: Double
        /// Relative level before normalization.
        var level: Double = 1
        var attack = 0.008
        var release = 0.03
        /// (multiple of the fundamental, relative gain)
        var partials: [(Double, Double)] = []
        /// Exponential decay time constant, seconds. nil: flat sustain.
        var decay: Double?
    }

    struct Spec {
        var duration: Double
        var peak: Float
        var notes: [Note]
    }

    static func spec(_ earcon: Earcon) -> Spec {
        switch earcon {
        case .listen:
            return Spec(duration: 0.150, peak: 0.16, notes: [
                Note(start: 0.000, length: 0.075, frequency: 587.33, level: 0.8, attack: 0.010, release: 0.020,
                     partials: [(2, 0.10)]),
                Note(start: 0.060, length: 0.090, frequency: 880.00, level: 1.0, attack: 0.012, release: 0.045,
                     partials: [(2, 0.10)]),
            ])
        case .done:
            return Spec(duration: 0.140, peak: 0.14, notes: [
                Note(start: 0.000, length: 0.055, frequency: 1046.50, level: 0.8, attack: 0.004, release: 0.015,
                     partials: [(2, 0.18), (3, 0.06)], decay: 0.06),
                Note(start: 0.045, length: 0.095, frequency: 1567.98, level: 1.0, attack: 0.004, release: 0.035,
                     partials: [(2, 0.18), (3, 0.06)], decay: 0.05),
            ])
        case .error:
            return Spec(duration: 0.170, peak: 0.18, notes: [
                Note(start: 0.000, length: 0.065, frequency: 220.00, level: 1.0, attack: 0.006, release: 0.020,
                     partials: [(3, 0.22), (5, 0.08)]),
                Note(start: 0.100, length: 0.070, frequency: 196.00, level: 1.0, attack: 0.006, release: 0.025,
                     partials: [(3, 0.22), (5, 0.08)]),
            ])
        }
    }

    private static func render(_ note: Note, into out: inout [Float], sampleRate: Double) {
        let first = Int((note.start * sampleRate).rounded())
        let n = Int((note.length * sampleRate).rounded())
        guard n > 1, first < out.count else { return }
        let attackN = max(1, Int(note.attack * sampleRate))
        let releaseN = max(1, Int(note.release * sampleRate))
        let w = 2 * Double.pi * note.frequency / sampleRate
        for k in 0..<n {
            let idx = first + k
            guard idx < out.count else { break }
            var env = 1.0
            if k < attackN { env *= raisedCosine(Double(k) / Double(attackN)) }
            let fromEnd = n - 1 - k
            if fromEnd < releaseN { env *= raisedCosine(Double(fromEnd) / Double(releaseN)) }
            if let tau = note.decay { env *= exp(-Double(k) / sampleRate / tau) }
            var v = sin(w * Double(k))
            for (mult, gain) in note.partials { v += gain * sin(w * mult * Double(k)) }
            out[idx] += Float(note.level * env * v)
        }
    }

    /// 0 at x = 0, 1 at x = 1, smooth at both ends.
    private static func raisedCosine(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return 0.5 - 0.5 * cos(Double.pi * c)
    }
}

/// Earcon playback. The runtime talks to this protocol, tests use fakes.
@MainActor
public protocol EarconPlaying: AnyObject {
    var isEnabled: Bool { get set }
    /// Called right before an earcon starts: the earcon and the seconds the speech gate has to ignore the mic
    /// (duration plus output latency, REVIEW M1). Wire it to `VoiceSession.noteEarcon(duration:)`.
    var onPlaybackStart: (@MainActor (Earcon, Double) -> Void)? { get set }
    /// Builds the audio graph ahead of the first earcon. Starts nothing.
    func prepare()
    /// Starts the output engine now, ahead of an earcon that follows soon (key press -> mic hot). Starting it blocks
    /// the caller for tens of milliseconds, longer with Bluetooth output: better at the press than when the first
    /// audio arrives (review C8). The engine stops `idleStop` seconds after the last earcon or prewarm.
    func prewarm()
    /// Plays the earcon (replaces one that still plays). Returns the blank duration, 0 when nothing plays.
    @discardableResult func play(_ earcon: Earcon) -> Double
}

/// Output-only player: one `AVAudioEngine` with one `AVAudioPlayerNode`, built lazily. It never touches
/// `inputNode`, so it never opens the microphone. The engine stops after `idleStop` seconds without an earcon,
/// so it does not keep the output device busy.
@MainActor
public final class EarconPlayer: EarconPlaying {
    public var isEnabled = true
    /// Player volume on top of the synthesized level (0...1).
    public var volume: Float = 1 {
        didSet { player?.volume = min(max(volume, 0), 1) }
    }
    public var onPlaybackStart: (@MainActor (Earcon, Double) -> Void)?
    public var idleStop: Double = 5

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffers: [Earcon: AVAudioPCMBuffer] = [:]
    private var stopWork: DispatchWorkItem?
    private var configObserver: (any NSObjectProtocol)?

    public init() {}

    public func prepare() {
        _ = graph()
    }

    public func prewarm() {
        guard isEnabled, let (engine, _) = graph() else { return }
        if !engine.isRunning {
            do { try engine.start() } catch {
                Log.error(.earcon, "earcon.engine.failed", error)
                return
            }
        }
        scheduleIdleStop()
    }

    @discardableResult
    public func play(_ earcon: Earcon) -> Double {
        guard isEnabled, let nodes = graph(), let buffer = buffer(earcon) else { return 0 }
        let (engine, player) = nodes
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Log.error(.earcon, "earcon.engine.failed", error)
            return 0
        }
        let latency = max(0, engine.outputNode.presentationLatency)
        let blank = EarconSynth.duration(earcon) + latency
        onPlaybackStart?(earcon, blank)
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        if !player.isPlaying { player.play() }
        scheduleIdleStop()
        return blank
    }

    private func buffer(_ earcon: Earcon) -> AVAudioPCMBuffer? {
        if let b = buffers[earcon] { return b }
        let b = EarconSynth.buffer(earcon)
        buffers[earcon] = b
        return b
    }

    private func graph() -> (AVAudioEngine, AVAudioPlayerNode)? {
        if let engine, let player { return (engine, player) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // mainMixerNode pulls in outputNode only. inputNode stays untouched.
        engine.connect(player, to: engine.mainMixerNode, format: EarconSynth.format)
        player.volume = min(max(volume, 0), 1)
        engine.prepare()
        // The engine stops itself when the output device changes; the next play starts it again.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in
            Log.event(.earcon, "earcon.configurationChange")
        }
        self.engine = engine
        self.player = player
        return (engine, player)
    }

    private func scheduleIdleStop() {
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine, engine.isRunning else { return }
                self.player?.stop()
                engine.stop()
            }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleStop, execute: work)
    }
}
