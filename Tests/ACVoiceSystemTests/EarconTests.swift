import ACVoiceFlow
@testable import ACVoiceSystem
import AVFoundation
import Foundation
import Testing

/// Synthesis only: no engine, no playback.
struct EarconTests {
    static let all: [Earcon] = [.listen, .done, .error]

    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// Dominant frequency estimate from zero crossings (the fundamental dominates every note).
    static func frequency(_ x: ArraySlice<Float>, sampleRate: Double = EarconSynth.sampleRate) -> Double {
        var crossings = 0
        var prev = x.first ?? 0
        for v in x.dropFirst() {
            if (prev < 0) != (v < 0) { crossings += 1 }
            prev = v
        }
        return Double(crossings) / 2 / (Double(x.count) / sampleRate)
    }

    static func slice(_ s: [Float], _ from: Double, _ to: Double) -> ArraySlice<Float> {
        let a = Int(from * EarconSynth.sampleRate), b = min(s.count, Int(to * EarconSynth.sampleRate))
        return s[a..<b]
    }

    @Test(arguments: all)
    func shortQuietAndClickFree(_ e: Earcon) {
        let s = EarconSynth.samples(e)
        let d = EarconSynth.duration(e)
        #expect(d >= 0.08 && d <= 0.2)
        #expect(s.count == Int((d * EarconSynth.sampleRate).rounded()))
        let finite = s.allSatisfy { $0.isFinite }
        #expect(finite)
        let peak = s.map(abs).max() ?? 0
        #expect(abs(peak - EarconSynth.peak(e)) < 0.001)
        #expect(peak <= 0.2, "quiet: peak at most -14 dBFS")
        #expect(peak >= 0.1)
        #expect(abs(s.first ?? 1) < 0.001)
        #expect(abs(s.last ?? 1) < 0.001)
        // No jump between neighbours bigger than a smooth tone allows (clicks).
        let maxStep = zip(s, s.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(maxStep < 0.06)
    }

    @Test func listenRises() {
        let s = EarconSynth.samples(.listen)
        let low = Self.frequency(Self.slice(s, 0.01, 0.055))
        let high = Self.frequency(Self.slice(s, 0.08, 0.13))
        #expect(abs(low - 587) < 60)
        #expect(abs(high - 880) < 80)
    }

    @Test func doneIsBrighterThanListen() {
        let done = EarconSynth.samples(.done)
        let listen = EarconSynth.samples(.listen)
        #expect(Self.frequency(Self.slice(done, 0.06, 0.12)) > Self.frequency(Self.slice(listen, 0.08, 0.13)) * 1.4)
        // Decays: the tail is quieter than the attack.
        #expect(Self.rms(Self.slice(done, 0.11, 0.14)) < Self.rms(Self.slice(done, 0.05, 0.08)))
    }

    @Test func errorIsALowDouble() {
        let s = EarconSynth.samples(.error)
        let first = Self.rms(Self.slice(s, 0.01, 0.055))
        let gap = Self.rms(Self.slice(s, 0.07, 0.095))
        let second = Self.rms(Self.slice(s, 0.11, 0.155))
        #expect(gap < 0.001)
        #expect(first > 0.05 && second > 0.05)
        #expect(Self.frequency(Self.slice(s, 0.01, 0.055)) < 400)
        #expect(Self.frequency(Self.slice(s, 0.11, 0.155)) < Self.frequency(Self.slice(s, 0.01, 0.055)) + 1)
    }

    @Test(arguments: all)
    func pcmBuffer(_ e: Earcon) throws {
        let buf = try #require(EarconSynth.buffer(e))
        let s = EarconSynth.samples(e)
        #expect(buf.format.sampleRate == 48_000)
        #expect(buf.format.channelCount == 1)
        #expect(buf.format.commonFormat == .pcmFormatFloat32)
        #expect(Int(buf.frameLength) == s.count)
        let ch = try #require(buf.floatChannelData?[0])
        #expect(ch[s.count / 2] == s[s.count / 2])
    }

    @Test func durationsDifferPerEarcon() {
        let ds = Self.all.map(EarconSynth.duration)
        #expect(Set(ds).count == 3)
        #expect(EarconSynth.samples(.listen, sampleRate: 16_000).count == 2400)
    }
}
