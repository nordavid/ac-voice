import AVFoundation
import Foundation

/// A simulated microphone for tests, the dev CLI and the onboarding self-check (REVIEW M7, m1). It never touches
/// audio hardware.
///
/// Delivers fixed chunks (default 100 ms, like an AVAudioEngine tap) in `format` (default 48 kHz Float32 mono,
/// like the built-in mic). Queued clips play back to back; while the queue is empty it delivers room noise in real
/// time, like an open mic, until `stop()`. A low noise floor (`noiseDB`) is mixed into everything so that digital
/// silence in TTS clips looks like a real room.
public final class FileSource: AudioSource, @unchecked Sendable {
    public enum Pacing: Sendable, Equatable {
        /// One chunk per chunk duration: latencies are meaningful.
        case realTime
        /// Clip audio as fast as the consumer takes it; idle noise still in real time.
        case fast
    }

    public let format: AVAudioFormat
    public let chunkFrames: AVAudioFrameCount
    public let pacing: Pacing
    public let noiseDB: Float?
    public var name: String { "file" }

    private let lock = NSLock()
    private var queue: [Float] = []
    private var queueStart = 0
    private var running = false
    private var loop: Task<Void, Never>?
    private var deliveredFrames: Int64 = 0

    /// `leadIn` seconds of room noise are queued before anything else (the user reacts to the earcon).
    public init(format: AVAudioFormat? = nil, chunkDuration: Double = 0.1, pacing: Pacing = .realTime,
                noiseDB: Float? = -60, leadIn: Double = 0.3) {
        let f = format ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        self.format = f
        chunkFrames = AVAudioFrameCount(max(1, (f.sampleRate * chunkDuration).rounded()))
        self.pacing = pacing
        self.noiseDB = noiseDB
        if leadIn > 0 { enqueue(silence: leadIn) }
    }

    /// Queues an audio file (any format AVAudioFile reads), converted to `format`. With `trimSilence`, leading and
    /// trailing audio below -50 dBFS is cut (TTS files carry up to 0.5 s of silence; joined parts sound natural).
    public func enqueue(contentsOf url: URL, trimSilence: Bool = false) throws {
        let mono = try AudioUtil.read(url, as: format)
        append(mono, trim: trimSilence)
    }

    /// Queues a buffer in any PCM format.
    public func enqueue(_ buffer: AVAudioPCMBuffer) throws {
        append(try AudioUtil.convert(buffer, to: format))
    }

    /// Queues digital silence (the noise floor is still mixed in).
    public func enqueue(silence seconds: Double) {
        let n = Int((seconds * format.sampleRate).rounded())
        lock.withLock { queue.append(contentsOf: repeatElement(0, count: max(0, n))) }
    }

    /// Seconds of queued audio not delivered yet.
    public var pendingSeconds: Double {
        lock.withLock { Double(queue.count - queueStart) / format.sampleRate }
    }

    /// Frames delivered since `start`.
    public var delivered: Int64 { lock.withLock { deliveredFrames } }

    /// Waits until every queued frame was delivered.
    public func waitUntilDrained() async {
        while pendingSeconds > 0, isRunning { try? await Task.sleep(for: .milliseconds(5)) }
    }

    public var isRunning: Bool { lock.withLock { running } }

    public func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                      event: @escaping @Sendable (AudioSourceEvent) -> Void) throws {
        try lock.withLock {
            guard !running else { throw SpeechError.sourceFailed("already running") }
            running = true
        }
        let chunkSeconds = Double(chunkFrames) / format.sampleRate
        loop = Task.detached(priority: .userInitiated) { [self] in
            let clock = ContinuousClock()
            var next = clock.now
            while isRunning {
                let hasClip = pendingSeconds > 0
                if pacing == .realTime || !hasClip {
                    next = next.advanced(by: .seconds(chunkSeconds))
                    if next < clock.now - .milliseconds(200) { next = clock.now }   // resync after a stall
                    try? await Task.sleep(until: next, tolerance: .milliseconds(1), clock: clock)
                } else {
                    next = clock.now
                    await Task.yield()
                }
                guard isRunning, let chunk = nextChunk() else { break }
                deliver(chunk)
            }
        }
    }

    public func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            running = false
            defer { loop = nil }
            return loop
        }
        task?.cancel()
    }

    // MARK: Internals

    private func append(_ buffer: AVAudioPCMBuffer, trim: Bool = false) {
        guard let p = buffer.floatChannelData else { return }
        var samples = Array(UnsafeBufferPointer(start: p[0], count: Int(buffer.frameLength)))
        if trim {
            let floor: Float = 0.00316   // -50 dBFS
            let margin = Int(0.03 * format.sampleRate)
            if let first = samples.firstIndex(where: { abs($0) > floor }), let last = samples.lastIndex(where: { abs($0) > floor }) {
                samples = Array(samples[max(0, first - margin)...min(samples.count - 1, last + margin)])
            } else {
                samples = []
            }
        }
        lock.withLock { queue.append(contentsOf: samples) }
    }

    private func nextChunk() -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames), let out = b.floatChannelData else {
            return nil
        }
        let n = Int(chunkFrames)
        b.frameLength = chunkFrames
        lock.withLock {
            let take = min(n, queue.count - queueStart)
            for i in 0..<take { out[0][i] = queue[queueStart + i] }
            for i in take..<n { out[0][i] = 0 }
            queueStart += take
            if queueStart > 480_000 { queue.removeFirst(queueStart); queueStart = 0 }
            deliveredFrames += Int64(n)
        }
        if let noiseDB {
            let a = Float(pow(10, Double(noiseDB) / 20) * 3.0.squareRoot())
            for i in 0..<n { out[0][i] += Float.random(in: -a...a) }
        }
        for c in 1..<Int(format.channelCount) { for i in 0..<n { out[c][i] = out[0][i] } }
        return b
    }
}
