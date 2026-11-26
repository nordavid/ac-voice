import ACVoiceCore
import Foundation

/// What the session listens for: a command, or an answer while a list is visible. Commands and answers differ in
/// their default hangover, the no-speech timeout and the dangling-word rule (`Parser.looksIncomplete(_:choosing:)`).
public enum UtteranceMode: String, Sendable, Equatable {
    case command, answer
}

/// Why an utterance ended.
public enum EndReason: String, Sendable, Equatable {
    /// Silence for the hangover after the last voiced slice.
    case pause
    /// The live transcript stopped changing while the level stayed high (music, chatter).
    case stableTranscript
    /// `maxUtterance` reached.
    case maxDuration
    /// `VoiceSession.endUtteranceNow()`: press while listening, push-to-talk release.
    case manual
    /// The audio device changed or stopped mid-utterance (REVIEW M7).
    case sourceChanged
}

/// End-of-utterance decision, fed with the RMS level of 20 ms slices (REVIEW M1, m1).
///
/// - Onset only after `onsetVoiced` (120 ms) of voiced slices within `onsetWindow` (300 ms): a key click or a desk
///   knock is not speech.
/// - Slices while an earcon plays (plus `blankPadding`) are ignored: the built-in mic hears the speakers.
/// - Threshold = clamp(noise floor + `floorOffsetDB`, `minThresholdDB` ... `maxThresholdDB`). The floor is seeded
///   with the first slice, follows the level down at once and up at `floorRiseDBPerSecond`, and freezes at onset.
///   Slices below `floorIgnoreBelowDB` (digital silence, a fade-in) do not move it.
/// - The pause budget is `hangover`, in seconds, as the controller sets it (`arm`, `setHangover`). The controller owns
///   the policy (VoiceFlow with Core `HangoverPolicy` on every live partial); the gate adds only two floors of
///   `incompleteHangover`: while a command has no word yet (the transcriber lags the level), and after `resume`
///   until new words arrive.
/// - Fallback: the utterance also ends when the live partial has not changed for `stableTranscript` (0.9 s) while
///   the level stays high (music, colleagues): voiced within the last 200 ms, and the partial does not dangle
///   (`Parser.looksIncomplete`).
///
/// Times are seconds on one monotonic audio clock; `t` is the end time of a slice.
public struct EndpointGate: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        public var sliceDuration = 0.02
        public var onsetVoiced = 0.12
        public var onsetWindow = 0.30
        public var floorOffsetDB: Float = 12
        public var minThresholdDB: Float = -50
        public var maxThresholdDB: Float = -30
        public var floorRiseDBPerSecond: Float = 15
        /// Slices below this level neither seed nor lower the floor. A room is never that quiet; a mic tap that
        /// starts with digital silence would otherwise set the floor near -120 dB, and at 15 dB/s a -45 dBFS
        /// room would count as speech for seconds (review, REVIEW m11).
        public var floorIgnoreBelowDB: Float = -90
        /// Hangover of a command armed without one (standalone use). The app passes every hangover explicitly.
        public var commandHangover = HangoverPolicy.standard.command
        /// Hangover of an answer armed without one (0.40 s, see `HangoverPolicy.answer`).
        public var answerHangover = HangoverPolicy.standard.answer
        /// Floor while a command has no word yet, and after `resume`. The app keeps it at
        /// `FlowTimings.incompleteHangover`.
        public var incompleteHangover = HangoverPolicy.standard.incomplete
        public var stableTranscript = 0.90
        /// Command phase only. The answer phase deadline belongs to the caller (choices window). The app sets
        /// `.infinity`: its flow owns the timeout (it waits for a held key and restarts after a discarded noise onset,
        /// which this clock from `arm` cannot).
        public var noSpeechTimeout = 4.0
        public var maxUtterance = 8.0
        public var blankPadding = 0.10
        /// Command phase: no partial yet after onset waits at least `incompleteHangover` (the transcriber lags the
        /// level).
        public var emptyTranscriptIsIncomplete = true
        /// Chunked audio (taps deliver 100 ms) can only end an utterance at a chunk boundary. true: end at the
        /// boundary nearest to the hangover; false: at the first boundary past it (+0-100 ms, REVIEW m1).
        public var nearestChunkDecision = true
        public init() {}

        /// Default hangover for `mode`.
        public func hangover(for mode: UtteranceMode) -> Double { mode == .answer ? answerHangover : commandHangover }
    }

    public struct Ending: Sendable, Equatable {
        /// End time of the last voiced slice: the speech end.
        public var lastVoiced: Double
        public var decidedAt: Double
        public var reason: EndReason
    }

    public enum Output: Sendable, Equatable {
        case none
        /// Speech started at `speechStart` (first voiced slice of the onset window).
        case onset(speechStart: Double)
        case end(Ending)
        /// Command phase: nothing said within `noSpeechTimeout` after arming.
        case noSpeech
    }

    public enum Phase: Sendable, Equatable {
        /// Not armed, or the utterance ended. Slices are ignored.
        case idle
        /// Armed, waiting for onset. The noise floor adapts.
        case waiting
        /// After onset. The floor is frozen.
        case speaking
    }

    public var config: Config
    /// Language of the voice commands, for the dangling-word rule (`Parser.looksIncomplete`).
    public var language: AppLanguage
    public private(set) var phase = Phase.idle
    public private(set) var mode = UtteranceMode.command
    /// Pause budget from the controller, in seconds.
    public private(set) var hangover = HangoverPolicy.standard.command
    public private(set) var floorDB: Float?
    public private(set) var speechStart = 0.0
    public private(set) var lastVoiced = 0.0
    /// The latest live partial dangles (`Parser.looksIncomplete`): no stable-transcript end.
    public private(set) var transcriptIncomplete = false
    /// After `resume`: `incompleteHangover` applies until the partial shows new words.
    public private(set) var resumed = false
    /// Push-to-talk: while held, pauses and a stable transcript do not end the utterance (REVIEW m4).
    public private(set) var held = false
    public private(set) var blankUntil = -Double.infinity
    private var armedAt = 0.0
    private var voiced: [Double] = []
    private var lastText = ""
    private var resumedKey: String?
    private var hasText = false
    private var lastTextChange = 0.0

    public init(config: Config = .init(), language: AppLanguage = .de) { self.config = config; self.language = language }

    public var thresholdDB: Float {
        min(max((floorDB ?? -60) + config.floorOffsetDB, config.minThresholdDB), config.maxThresholdDB)
    }

    /// Pause budget that applies right now: the controller's `hangover`, at least `incompleteHangover` while a command
    /// has no word yet or after `resume`.
    public var effectiveHangover: Double {
        let noWordYet = !hasText && mode == .command && config.emptyTranscriptIsIncomplete
        return noWordYet || resumed ? max(hangover, config.incompleteHangover) : hangover
    }

    /// Starts listening for one utterance with `hangover` seconds (nil: the mode's default). The noise floor carries
    /// over from earlier utterances.
    public mutating func arm(_ mode: UtteranceMode, at t: Double, hangover: Double? = nil) {
        self.mode = mode
        phase = .waiting
        self.hangover = max(0, hangover ?? config.hangover(for: mode))
        armedAt = t
        resetUtterance(at: t)
    }

    /// Stops listening without an output (session closed, utterance ended elsewhere).
    public mutating func disarm() { phase = .idle }

    /// Back to waiting for onset after an utterance that produced no word (a cough, a knock): the floor adapts
    /// again, and the no-speech timeout still counts from `arm`. Only from `.idle`. The hangover stays.
    public mutating func rewait(at t: Double) {
        guard phase == .idle else { return }
        phase = .waiting
        resetUtterance(at: t)
    }

    private mutating func resetUtterance(at t: Double) {
        voiced = []
        lastText = ""
        resumedKey = nil
        resumed = false
        hasText = false
        lastTextChange = t
        transcriptIncomplete = false
    }

    /// The controller's pause budget for the armed utterance, in seconds; applies from the next slice.
    public mutating func setHangover(_ seconds: Double) { hangover = max(0, seconds) }

    public mutating func setHold(_ held: Bool) { self.held = held }

    /// An earcon starts playing at `t` for `duration` seconds.
    public mutating func blank(from t: Double, duration: Double) {
        blankUntil = max(blankUntil, t + duration + config.blankPadding)
    }

    /// Live partial transcripts of this utterance. Any change restarts the stable-transcript timer; the text with
    /// more words decides whether the partial dangles (ties: DT).
    public mutating func partial(dt: String, st: String, at t: Double) {
        let key = dt + "\u{1F}" + st
        guard key != lastText else { return }
        lastText = key
        lastTextChange = t
        hasText = !dt.isEmpty || !st.isEmpty
        let lead = Self.leading(dt, st)
        // After `resume`, the same words again keep the utterance open.
        if let rk = resumedKey, TextNorm.queryKey(TextNorm.tokenize(lead, language: language)) == rk { return }
        resumedKey = nil
        resumed = false
        transcriptIncomplete = !lead.isEmpty && Parser.looksIncomplete(lead, choosing: mode == .answer, language: language)
    }

    public mutating func partial(_ text: String, at t: Double) { partial(dt: text, st: "", at: t) }

    /// The transcript that has heard more words; DT on a tie.
    public static func leading(_ dt: String, _ st: String) -> String {
        TextNorm.tokenize(st).count > TextNorm.tokenize(dt).count ? st : dt
    }

    /// Takes back an end whose final text turned out to dangle ("Öffne WWT Ticket" before "412"): listening goes
    /// on with the incomplete hangover from the same speech end. Returns false when that budget is used up already.
    public mutating func resume(transcript text: String, at t: Double) -> Bool {
        guard phase == .idle else { return false }
        phase = .speaking
        partial(text, at: t)
        transcriptIncomplete = true
        resumed = true
        resumedKey = TextNorm.queryKey(TextNorm.tokenize(text, language: language))
        if t - lastVoiced >= effectiveHangover - 1e-9 { phase = .idle; return false }
        return true
    }

    /// After the last slice of a chunk lasting `chunkDuration`. With `nearestChunkDecision` the utterance ends now
    /// when waiting for the next chunk would overshoot the pause budget by more than ending now undershoots it.
    public mutating func chunkEnd(at t: Double, chunkDuration: Double) -> Output {
        guard phase == .speaking, config.nearestChunkDecision, !held else { return .none }
        let budget = effectiveHangover, silence = t - lastVoiced
        if silence < budget - 1e-9, silence + chunkDuration / 2 >= budget - 1e-9 { return end(at: t, reason: .pause) }
        return .none
    }

    /// One 20 ms slice with its RMS level in dBFS; `t` is the slice end time.
    public mutating func slice(rmsDB db: Float, at t: Double) -> Output {
        guard phase != .idle else { return .none }
        if t - config.sliceDuration < blankUntil { return .none }
        switch phase {
        case .idle:
            return .none
        case .waiting:
            let tracksFloor = db >= config.floorIgnoreBelowDB
            if tracksFloor, floorDB == nil { floorDB = db }
            let isVoiced = db > thresholdDB
            if tracksFloor, let f = floorDB {
                floorDB = db < f ? db : min(db, f + config.floorRiseDBPerSecond * Float(config.sliceDuration))
            }
            if isVoiced { voiced.append(t) }
            voiced.removeAll { $0 <= t - config.onsetWindow + 1e-9 }
            if Double(voiced.count) * config.sliceDuration >= config.onsetVoiced - 1e-9 {
                phase = .speaking
                speechStart = voiced[0] - config.sliceDuration
                lastVoiced = t
                lastTextChange = t
                return .onset(speechStart: speechStart)
            }
            if mode == .command, t - armedAt >= config.noSpeechTimeout - 1e-9 {
                phase = .idle
                return .noSpeech
            }
            return .none
        case .speaking:
            if db > thresholdDB { lastVoiced = t }
            return evaluate(at: t)
        }
    }

    /// Ends the utterance now (press while listening, push-to-talk release). Ignored before onset: an accidental
    /// double tap must not end an empty utterance (REVIEW m5).
    public mutating func endNow(at t: Double, reason: EndReason = .manual) -> Output {
        guard phase == .speaking else { return .none }
        return end(at: t, reason: reason)
    }

    private mutating func evaluate(at t: Double) -> Output {
        if t - speechStart >= config.maxUtterance - 1e-9 { return end(at: t, reason: .maxDuration) }
        if held { return .none }
        if t - lastVoiced >= effectiveHangover - 1e-9 { return end(at: t, reason: .pause) }
        // Fallback for a level that never drops (music, chatter); a real pause is the hangover's job.
        if hasText, !transcriptIncomplete, t - lastVoiced < 0.2,
           t - lastTextChange >= config.stableTranscript - 1e-9 {
            return end(at: t, reason: .stableTranscript)
        }
        return .none
    }

    private mutating func end(at t: Double, reason: EndReason) -> Output {
        phase = .idle
        return .end(Ending(lastVoiced: lastVoiced, decidedAt: t, reason: reason))
    }
}
