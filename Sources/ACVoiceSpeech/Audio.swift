@preconcurrency import AVFoundation
import ACVoiceCore
import Foundation

/// Something that delivers microphone-like audio in chunks: `MicSource` (AVAudioEngine tap) or `FileSource`
/// (audio files paced like a tap). Chunks arrive serially on one thread at a time.
public protocol AudioSource: AnyObject, Sendable {
    /// Short name for logs ("Built-in Microphone", "file").
    var name: String { get }
    /// Starts delivering. `deliver` gets every chunk in order; `event` reports device changes and failures.
    func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               event: @escaping @Sendable (AudioSourceEvent) -> Void) throws
    /// Stops delivering. No `deliver` call starts after `stop()` returns.
    func stop()
}

public enum AudioSourceEvent: Sendable, Equatable {
    /// The hardware format or device changed and the engine stopped (`AVAudioEngineConfigurationChange`).
    case configurationChanged
    /// The source cannot deliver audio any more.
    case failed(String)
}

/// RMS level per fixed slice (20 ms) of a mono stream, carrying partial slices across chunks (REVIEW m1).
struct SliceMeter: Sendable {
    let sliceFrames: Int
    private var sum: Double = 0
    private var count = 0

    init(sliceFrames: Int) { self.sliceFrames = max(1, sliceFrames) }

    /// Levels of the slices completed by `samples`, each with the index just past its last sample.
    mutating func feed(_ samples: UnsafeBufferPointer<Int16>) -> [(db: Float, end: Int)] {
        var out: [(Float, Int)] = []
        for i in 0..<samples.count {
            let x = Double(samples[i]) / 32768
            sum += x * x
            count += 1
            if count == sliceFrames { out.append((Self.db(sum / Double(count)), i + 1)); sum = 0; count = 0 }
        }
        return out
    }

    mutating func feed(_ samples: UnsafeBufferPointer<Float>) -> [(db: Float, end: Int)] {
        var out: [(Float, Int)] = []
        for i in 0..<samples.count {
            let x = Double(samples[i])
            sum += x * x
            count += 1
            if count == sliceFrames { out.append((Self.db(sum / Double(count)), i + 1)); sum = 0; count = 0 }
        }
        return out
    }

    /// Mono Int16 or Float32 buffer (first channel).
    mutating func feed(_ buffer: AVAudioPCMBuffer) -> [(db: Float, end: Int)] {
        let n = Int(buffer.frameLength)
        if let p = buffer.int16ChannelData { return feed(UnsafeBufferPointer(start: p[0], count: n)) }
        if let p = buffer.floatChannelData { return feed(UnsafeBufferPointer(start: p[0], count: n)) }
        return []
    }

    static func db(_ meanSquare: Double) -> Float { Float(10 * log10(max(meanSquare, 1e-12))) }
}

/// Level helpers for meters and the Stream Deck key.
public enum LevelMeter {
    /// Maps dBFS to 0...1 (-60 dB and below -> 0, -10 dB and above -> 1).
    public static func unit(_ db: Float) -> Double { Double(min(max((db + 60) / 50, 0), 1)) }
}

enum AudioUtil {
    /// White noise at `db` dBFS RMS in `format` (mono Int16 or Float32).
    static func noise(_ format: AVAudioFormat, frames: AVAudioFrameCount, db: Float) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)) else { return nil }
        b.frameLength = frames
        let amplitude = Double(pow(10, db / 20)) * 3.0.squareRoot()   // uniform noise: rms = a / sqrt(3)
        let channels = Int(format.channelCount)
        if let p = b.int16ChannelData {
            let a = Int16(clamping: Int((amplitude * 32768).rounded()))
            for c in 0..<channels { for i in 0..<Int(frames) { p[c][i] = a > 0 ? Int16.random(in: -a...a) : 0 } }
        } else if let p = b.floatChannelData {
            let a = Float(amplitude)
            for c in 0..<channels { for i in 0..<Int(frames) { p[c][i] = a > 0 ? Float.random(in: -a...a) : 0 } }
        }
        return b
    }

    /// Whole-file read, converted to `format` in one pass.
    static func read(_ url: URL, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1))) else {
            throw SpeechError.invalidAudio(url.lastPathComponent)
        }
        try file.read(into: input)
        return try convert(input, to: format)
    }

    /// One-shot conversion of a complete buffer (end of stream after it).
    static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if input.format == format { return input }
        guard let converter = AVAudioConverter(from: input.format, to: format) else {
            throw SpeechError.invalidAudio("no converter")
        }
        converter.downmix = true
        let capacity = AVAudioFrameCount((Double(input.frameLength) * format.sampleRate / input.format.sampleRate).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw SpeechError.invalidAudio("buffer") }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .endOfStream; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw SpeechError.invalidAudio(error?.localizedDescription ?? "conversion") }
        return out
    }
}

/// Streaming converter from the source format to the analyzer format (16 kHz Int16 mono). Keeps the resampler
/// state across chunks and rebuilds itself when the source format changes (device switch).
final class StreamConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?
    private var input: AVAudioFormat?

    init(output: AVAudioFormat) { self.output = output }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { return nil }
        if input != buffer.format || converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.downmix = true
            input = buffer.format
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return (status == .error || out.frameLength == 0) ? nil : out
    }
}

/// Errors with a short message for the overlay and the self-check (`message(_:)`).
public enum SpeechError: Error, Sendable, Equatable {
    case assetsUnavailable
    case analyzerFailed(String)
    case sourceFailed(String)
    case invalidInputFormat
    case invalidAudio(String)

    /// The German message (`message(.de)`).
    public var message: String { message(.de) }

    public func message(_ language: AppLanguage) -> String {
        let de = language == .de
        switch self {
        case .assetsUnavailable: return de ? "Sprachmodell nicht verfügbar" : "Speech model not available"
        case .analyzerFailed: return de ? "Spracherkennung fehlgeschlagen" : "Speech recognition failed"
        case .sourceFailed: return de ? "Mikrofon nicht verfügbar" : "Microphone not available"
        case .invalidInputFormat: return de ? "Mikrofon liefert kein Audio" : "Microphone delivers no audio"
        case .invalidAudio: return de ? "Audiodatei nicht lesbar" : "Cannot read the audio file"
        }
    }

    /// What the flow shows (`VoiceFlow` `.speechFailed(event.gen, error.failure)`): assets missing or an analyzer
    /// that cannot be prepared or started -> "Sprachmodell nicht verfügbar"; a failed, changing or silent device ->
    /// "Mikrofon nicht verfügbar"; anything else -> "Spracherkennung fehlgeschlagen".
    public var failure: SpeechFailure {
        switch self {
        case .assetsUnavailable, .analyzerFailed: return .modelUnavailable
        case .sourceFailed, .invalidInputFormat: return .noInput
        case .invalidAudio: return .engine
        }
    }

    /// Any error as a `SpeechError` (unknown errors count as a failed source: they come from starting it).
    static func wrap(_ error: any Error) -> SpeechError {
        error as? SpeechError ?? .sourceFailed(String(describing: error))
    }
}

@inline(__always) func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
