import ACVoiceCore
import Foundation

/// One transcriber's text for an utterance (named apart from `ACVoiceFlow.Transcript`, the overlay's live text).
public struct TranscriberText: Sendable, Equatable {
    public var best: String
    /// Other readings, best first, without `best`. Only filled when the utterance is one final segment.
    public var alternatives: [String]
    /// No final result arrived (finalize was killed, or the transcriber kept an unchanged volatile result):
    /// `best` is the last volatile text.
    public var fromVolatile: Bool

    public init(best: String = "", alternatives: [String] = [], fromVolatile: Bool = false) {
        self.best = best; self.alternatives = alternatives; self.fromVolatile = fromVolatile
    }
}

/// Builds the Interpreter input from both transcribers (PLAN 2.3): DT best 1.0, ST best 1.0, then DT and ST
/// alternatives 0.9. Empty texts are dropped; texts with the same tokens ("Zwei." / "zwei") are kept once.
public enum HypothesisBuilder {
    public static func build(dictation: TranscriberText, speech: TranscriberText, maxAlternatives: Int = 3) -> [Hypothesis] {
        var out: [Hypothesis] = []
        var seen = Set<String>()
        func add(_ text: String, _ weight: Double) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TextNorm.queryKey(TextNorm.tokenize(t))
            guard !t.isEmpty, !key.isEmpty, seen.insert(key).inserted else { return }
            out.append(Hypothesis(t, weight: weight))
        }
        add(dictation.best, 1.0)
        add(speech.best, 1.0)
        for a in dictation.alternatives.prefix(maxAlternatives) { add(a, 0.9) }
        for a in speech.alternatives.prefix(maxAlternatives) { add(a, 0.9) }
        return out
    }
}

/// A transcriber result on the analyzer timeline, in analyzer frames.
struct Segment: Sendable, Equatable {
    var start: Int64
    var end: Int64
    /// Best text first, then alternatives.
    var texts: [String]
    var best: String { (texts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Results of one transcriber module in one analyzer session.
struct ModuleResults: Sendable {
    /// Finals keyed by range start: a re-sent final with the same start replaces the earlier one (DT re-sends
    /// identical finals after a mid-session finalize, research 7).
    private(set) var finals: [Int64: Segment] = [:]
    private(set) var volatile: Segment?
    /// Largest `resultsFinalizationTime` seen, in frames.
    private(set) var finalizedThrough: Int64 = 0

    mutating func record(_ s: Segment, isFinal: Bool, finalizedThrough f: Int64) {
        finalizedThrough = max(finalizedThrough, f)
        if isFinal {
            finals[s.start] = s
            if let v = volatile, v.start < s.end { volatile = nil }
        } else {
            volatile = s
        }
    }

    /// Text of the segments that start inside [from - tolerance, through). `through == nil` is open-ended (live
    /// partial). With `includeVolatile` the current volatile text is appended (live display); otherwise it is only
    /// the fallback when no final exists.
    func transcript(from: Int64, through: Int64?, tolerance: Int64, includeVolatile: Bool) -> TranscriberText {
        let inRange = { (s: Segment) in s.start >= from - tolerance && (through.map { s.start < $0 } ?? true) }
        var kept: [Segment] = []
        for s in finals.values.filter(inRange).sorted(by: { $0.start < $1.start }) where !s.best.isEmpty {
            // Identical overlapping finals are one result sent twice.
            if let prev = kept.last, prev.best == s.best, s.start < prev.end { continue }
            kept.append(s)
        }
        var best = kept.map(\.best).joined(separator: " ")
        let alternatives = kept.count == 1 ? kept[0].texts.dropFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } : []
        let v = volatile.flatMap { inRange($0) && !$0.best.isEmpty ? $0.best : nil }
        if includeVolatile, let v { best = best.isEmpty ? v : best + " " + v }
        if best.isEmpty, let v { return TranscriberText(best: v, alternatives: [], fromVolatile: true) }
        return TranscriberText(best: best, alternatives: alternatives, fromVolatile: false)
    }
}
