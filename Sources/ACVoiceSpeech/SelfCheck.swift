import ACVoiceCore
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Onboarding self-check (REVIEW m7): transcribes a short clip without the microphone. If it fails in the signed
/// app, the app requests speech authorization; otherwise only the microphone permission is needed.
@available(macOS 26, *)
public enum SpeechSelfCheck {
    public struct Report: Sendable, Equatable {
        public var passed: Bool
        /// Best text of DictationTranscriber, else SpeechTranscriber.
        public var transcript: String
        public var elapsedMs: Double
        /// Short status line for the onboarding window, in the language of the check.
        public var message: String
    }

    /// The German test phrase (`phrase(_:)`).
    public static let defaultPhrase = "Öffne das Projekt"

    /// The test phrase per language: a command the parser knows, spoken by a system voice of that language.
    public static func phrase(_ language: AppLanguage) -> String {
        language == .de ? defaultPhrase : "Open the project"
    }

    /// Synthesizes `phrase` (nil: `phrase(language)`) with a system voice of `language` into memory (nothing is
    /// played) and transcribes it with `language.speechLocale` (or `locale`). `timeout` bounds the whole call,
    /// synthesis included: a stalled analyzer is killed at the deadline.
    public static func run(phrase: String? = nil, language: AppLanguage = .de, locale: Locale? = nil,
                           timeout: Double = 15) async -> Report {
        let t0 = uptime()
        let text = phrase ?? Self.phrase(language)
        guard let clip = await synthesize(text, language: language.bcp47, timeout: timeout) else {
            return Report(passed: false, transcript: "", elapsedMs: (uptime() - t0) * 1000,
                          message: Status.noVoice.in(language))
        }
        return await run(buffer: clip, expecting: words(text, language), locale: locale ?? language.speechLocale,
                         language: language, timeout: timeout, started: t0)
    }

    /// Transcribes an audio file, e.g. a clip bundled with the app. `expecting` are words the transcript must
    /// contain (at least half of them, compared case- and accent-insensitively). `timeout` bounds the whole call.
    public static func run(clip: URL, expecting: [String], language: AppLanguage = .de, locale: Locale? = nil,
                           timeout: Double = 15) async -> Report {
        let t0 = uptime()
        guard let file = try? AVAudioFile(forReading: clip),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1))),
              (try? file.read(into: buffer)) != nil else {
            return Report(passed: false, transcript: "", elapsedMs: 0, message: SpeechError.invalidAudio("").message(language))
        }
        return await run(buffer: buffer, expecting: expecting.map { TextNorm.fold($0, language: language) },
                         locale: locale ?? language.speechLocale, language: language, timeout: timeout, started: t0)
    }

    static func run(buffer: AVAudioPCMBuffer, expecting: [String], locale: Locale, language: AppLanguage = .de,
                    timeout: Double, started t0: Double) async -> Report {
        let text: String
        do {
            let left = max(0.05, timeout - (uptime() - t0))
            text = try await transcribe(SendableBuffer(buffer), locale: locale, timeout: left)
        } catch let e as SpeechError {
            return Report(passed: false, transcript: "", elapsedMs: (uptime() - t0) * 1000, message: e.message(language))
        } catch {
            return Report(passed: false, transcript: "", elapsedMs: (uptime() - t0) * 1000, message: Status.noAnswer.in(language))
        }
        let heard = Set(words(text, language))
        let hits = expecting.filter(heard.contains).count
        let passed = !text.isEmpty && hits * 2 >= expecting.count
        let message = passed ? Status.ready : (text.isEmpty ? Status.noText : Status.notUnderstood)
        return Report(passed: passed, transcript: text, elapsedMs: (uptime() - t0) * 1000, message: message.in(language))
    }

    /// Status lines of the self-check.
    enum Status {
        case noVoice, noAnswer, ready, noText, notUnderstood

        func `in`(_ language: AppLanguage) -> String {
            let de = language == .de
            switch self {
            case .noVoice: return de ? "Installiere eine deutsche Systemstimme" : "Install an English system voice"
            case .noAnswer: return de ? "Spracherkennung antwortet nicht" : "Speech recognition is not responding"
            case .ready: return de ? "Spracherkennung bereit" : "Speech recognition ready"
            case .noText: return de ? "Spracherkennung liefert keinen Text" : "Speech recognition returns no text"
            case .notUnderstood: return de ? "Spracherkennung versteht den Testsatz nicht" : "Speech recognition does not understand the test phrase"
            }
        }
    }

    /// Folded word keys, as the resolver compares them.
    static func words(_ s: String, _ language: AppLanguage = .de) -> [String] {
        TextNorm.tokenize(s, language: language).map(\.key).filter { !$0.isEmpty }
    }

    /// One analyzer, both transcribers, whole clip with room noise around it, then finish. Returns at the deadline
    /// even when the analyzer stalls (`finalize` ignores task cancellation, REVIEW M2): the analyzer is then
    /// killed with `cancelAndFinishNow()` and its result readers are cancelled.
    static func transcribe(_ clip: SendableBuffer, locale: Locale, timeout: Double) async throws -> String {
        let check = CheckAnalysis()
        let text = try await withDeadline(.milliseconds(Int(max(0, timeout) * 1000))) {
            try await check.run(clip, locale: locale)
        }
        guard let text else {
            Task { await check.kill() }
            throw CancellationError()
        }
        return text
    }

    /// Renders `text` with AVSpeechSynthesizer into one buffer. No audio output, no microphone.
    static func synthesize(_ text: String, language: String, timeout: Double) async -> AVAudioPCMBuffer? {
        guard let voice = AVSpeechSynthesisVoice(language: language) else { return nil }
        let collector = SynthCollector()
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.write(utterance) { buffer in
            if let pcm = buffer as? AVAudioPCMBuffer { collector.add(pcm) }
        }
        let deadline = uptime() + timeout
        while !collector.isDone, uptime() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        withExtendedLifetime(synthesizer) {}
        return collector.isDone ? collector.joined() : nil
    }
}

/// The analysis of one self-check, killable from outside while it runs.
@available(macOS 26, *)
final class CheckAnalysis: @unchecked Sendable {
    private let lock = NSLock()
    private var killed = false
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var readers: [Task<Void, Never>] = []

    func run(_ clip: SendableBuffer, locale: Locale) async throws -> String {
        try await AnalyzerFactory.installAssets(locale)
        guard let format = await AnalyzerFactory.bestFormat(locale) else { throw SpeechError.assetsUnavailable }
        let p = try await AnalyzerFactory.prepare(locale, format: format, context: [])
        let speech = try AudioUtil.convert(clip.buffer, to: format)
        let box = FinalTexts(rate: format.sampleRate)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let dtTask = Task { do { for try await r in p.dt.results where r.isFinal { box.add(dt: r) } } catch {} }
        let stTask = Task { do { for try await r in p.st.results where r.isFinal { box.add(st: r) } } catch {} }
        let adopted = lock.withLock { () -> Bool in
            guard !killed else { return false }
            analyzer = p.analyzer; self.input = input; readers = [dtTask, stTask]
            return true
        }
        guard adopted else {
            // Killed while preparing: nobody else releases this analyzer.
            input.finish()
            await p.analyzer.cancelAndFinishNow()
            dtTask.cancel(); stTask.cancel()
            throw CancellationError()
        }
        try await p.analyzer.start(inputSequence: stream)
        let lead = AVAudioFrameCount(0.3 * format.sampleRate), tail = AVAudioFrameCount(0.7 * format.sampleRate)
        if let b = AudioUtil.noise(format, frames: lead, db: -60) { input.yield(AnalyzerInput(buffer: b)) }
        input.yield(AnalyzerInput(buffer: speech))
        if let b = AudioUtil.noise(format, frames: tail, db: -60) { input.yield(AnalyzerInput(buffer: b)) }
        input.finish()
        try await p.analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await (dtTask.value, stTask.value)
        return box.best
    }

    /// Releases a stalled analysis: `cancelAndFinishNow()` ends a pending finalize and both result streams.
    func kill() async {
        let (a, i, r) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, [Task<Void, Never>]) in
            killed = true
            defer { analyzer = nil; input = nil; readers = [] }
            return (analyzer, input, readers)
        }
        i?.finish()
        for t in r { t.cancel() }
        await a?.cancelAndFinishNow()
    }
}

struct SendableBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ b: AVAudioPCMBuffer) { buffer = b }
}

/// Final results of both transcribers, deduplicated like in a session (DT re-sends finals).
final class FinalTexts: @unchecked Sendable {
    private let lock = NSLock()
    private var dt = ModuleResults(), st = ModuleResults()
    private let rate: Double
    init(rate: Double) { self.rate = rate }
    func add(dt r: DictationTranscriber.Result) { lock.withLock { dt.record(segment(r.range, r.text, r.alternatives), isFinal: true, finalizedThrough: 0) } }
    func add(st r: SpeechTranscriber.Result) { lock.withLock { st.record(segment(r.range, r.text, r.alternatives), isFinal: true, finalizedThrough: 0) } }
    private func segment(_ range: CMTimeRange, _ text: AttributedString, _ alts: [AttributedString]) -> Segment {
        Segment(start: range.start.frames(at: rate), end: range.end.frames(at: rate), texts: [String(text.characters)])
    }
    var best: String {
        lock.withLock {
            let d = dt.transcript(from: 0, through: nil, tolerance: 0, includeVolatile: false).best
            return d.isEmpty ? st.transcript(from: 0, through: nil, tolerance: 0, includeVolatile: false).best : d
        }
    }
}

/// Buffers from `AVSpeechSynthesizer.write`; a zero-length buffer marks the end.
final class SynthCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var done = false

    var isDone: Bool { lock.withLock { done } }

    func add(_ b: AVAudioPCMBuffer) {
        lock.withLock {
            if b.frameLength == 0 { done = true } else if !done { buffers.append(b) }
        }
    }

    /// All buffers in one, in the format of the first.
    func joined() -> AVAudioPCMBuffer? {
        lock.withLock {
            guard let first = buffers.first else { return nil }
            let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
            guard let out = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)) else { return nil }
            var offset = 0
            for b in buffers where b.format == first.format {
                let n = Int(b.frameLength)
                for c in 0..<Int(first.format.channelCount) {
                    if let src = b.floatChannelData, let dst = out.floatChannelData {
                        dst[c].advanced(by: offset).update(from: src[c], count: n)
                    } else if let src = b.int16ChannelData, let dst = out.int16ChannelData {
                        dst[c].advanced(by: offset).update(from: src[c], count: n)
                    }
                }
                offset += n
            }
            out.frameLength = AVAudioFrameCount(offset)
            return out
        }
    }
}
