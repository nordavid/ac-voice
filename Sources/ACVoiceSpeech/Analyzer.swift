import AVFoundation
import CoreMedia
import Foundation
import Speech

/// A SpeechAnalyzer with both transcribers, prepared for the analyzer format and not started yet.
@available(macOS 26, *)
final class PreparedAnalyzer: @unchecked Sendable {
    let analyzer: SpeechAnalyzer
    let st: SpeechTranscriber
    let dt: DictationTranscriber
    let format: AVAudioFormat
    let context: [String]

    init(analyzer: SpeechAnalyzer, st: SpeechTranscriber, dt: DictationTranscriber, format: AVAudioFormat, context: [String]) {
        self.analyzer = analyzer; self.st = st; self.dt = dt; self.format = format; self.context = context
    }
}

/// Fixed module configuration (PLAN 2.3, research 8).
@available(macOS 26, *)
enum AnalyzerFactory {
    static func makeST(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults, .alternativeTranscriptions], attributeOptions: [])
    }

    static func makeDT(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [],
                             reportingOptions: [.volatileResults, .alternativeTranscriptions], attributeOptions: [])
    }

    static func analysisContext(_ strings: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = strings
        return context
    }

    /// Installs or subscribes the assets of `locale` (de_DE or en_US, the same way for both). About 0.7 s when they
    /// are on disk already (research 3).
    static func installAssets(_ locale: Locale) async throws {
        let modules: [any SpeechModule] = [makeST(locale), makeDT(locale)]
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        // The first status call in a process may still say `.supported` (research 3); only `.unsupported` is fatal.
        if await AssetInventory.status(forModules: modules) == .unsupported { throw SpeechError.assetsUnavailable }
    }

    /// `installAssets` with a deadline. A first download can take long: at the deadline it goes on in the
    /// background (a later call joins it) and this throws `SpeechError.assetsUnavailable`.
    static func installAssets(_ locale: Locale, timeout: Double) async throws {
        let installed: Bool? = try await withDeadline(.milliseconds(Int(max(0, timeout) * 1000)), cancelOnTimeout: false) {
            try await installAssets(locale)
            return true
        }
        if installed == nil { throw SpeechError.assetsUnavailable }
    }

    /// The format both transcribers accept (16 kHz Int16 mono on macOS 26).
    static func bestFormat(_ locale: Locale) async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeST(locale), makeDT(locale)])
    }

    /// What `bestFormat` returns on macOS 26 (research 3). Used while the assets are not installed yet, so a key
    /// press during warm-up can start the microphone at once (REVIEW m5).
    static func fallbackFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    /// New analyzer with context, prepared for `format`: 180-430 ms cold, so it runs before the key press.
    static func prepare(_ locale: Locale, format: AVAudioFormat, context: [String]) async throws -> PreparedAnalyzer {
        let st = makeST(locale), dt = makeDT(locale)
        let analyzer = SpeechAnalyzer(modules: [st, dt], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if !context.isEmpty { try await analyzer.setContext(analysisContext(context)) }
        try await analyzer.prepareToAnalyze(in: format)
        return PreparedAnalyzer(analyzer: analyzer, st: st, dt: dt, format: format, context: context)
    }
}

@available(macOS 26, *)
extension AnalyzerFactory {
    /// One short throwaway analysis with a finalize (about 1.1-1.6 s). The first finalize in a process otherwise
    /// costs the first command about 110 ms instead of 35-50 ms, and up to 1.1 s right after the analyzer started.
    /// The input goes in 100 ms buffers: a single 1 s buffer left the finalize waiting until the deadline.
    static func prime(_ locale: Locale, format: AVAudioFormat) async {
        guard let p = try? await prepare(locale, format: format, context: []) else { return }
        let readers = [Task { do { for try await _ in p.dt.results {} } catch {} },
                       Task { do { for try await _ in p.st.results {} } catch {} }]
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        guard (try? await p.analyzer.start(inputSequence: stream)) != nil else { return }
        for _ in 0..<10 {
            if let b = AudioUtil.noise(format, frames: AVAudioFrameCount(format.sampleRate / 10), db: -60) { input.yield(AnalyzerInput(buffer: b)) }
        }
        _ = await finalizeOrKill(p.analyzer, through: CMTime(value: Int64(format.sampleRate / 2), timescale: CMTimeScale(format.sampleRate)),
                                 timeout: .seconds(3))
        input.finish()
        await p.analyzer.cancelAndFinishNow()
        for t in readers { await t.value }
    }
}

/// Finalizes with a deadline (REVIEW M2). A `finalize(through:)` that waits for audio which never comes is only
/// released by `cancelAndFinishNow()`; `Task.cancel()` and `cancelAnalysis(before:)` leave it pending.
/// Returns false when the analyzer had to be killed: the caller builds a fresh analyzer and input stream.
@available(macOS 26, *)
func finalizeOrKill(_ analyzer: SpeechAnalyzer, through: CMTime, timeout: Duration) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { (try? await analyzer.finalize(through: through)) != nil }
        group.addTask { try? await Task.sleep(for: timeout); return false }
        let ok = await group.next() ?? false
        if !ok { await analyzer.cancelAndFinishNow() }
        group.cancelAll()
        for await _ in group {}
        return ok
    }
}

extension CMTime {
    /// Frames at `rate`, 0 for invalid or indefinite times.
    func frames(at rate: Double) -> Int64 {
        guard isValid, !isIndefinite, !isNegativeInfinity, !isPositiveInfinity else { return 0 }
        return Int64((seconds * rate).rounded())
    }
}
