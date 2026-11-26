import AVFoundation
@testable import ACVoiceSpeech
import Foundation
import Testing

/// Audio path pieces without microphone or speech recognition.
@Suite struct AudioTests {
    static let int16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!

    static func constant(_ value: Int16, frames: Int, format: AVAudioFormat = int16k) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { b.int16ChannelData![0][i] = value }
        return b
    }

    static func sine(seconds: Double, rate: Double = 22_050, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let n = Int(seconds * rate)
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { b.floatChannelData![0][i] = amplitude * sin(2 * .pi * 440 * Float(i) / Float(rate)) }
        return b
    }

    static func rmsDB(_ b: AVAudioPCMBuffer) -> Float {
        let n = Int(b.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += b.floatChannelData![0][i] * b.floatChannelData![0][i] }
        return 10 * log10(max(sum / Float(max(n, 1)), 1e-12))
    }

    @Test func slicesAre20msAndCarryAcrossChunks() {
        var meter = SliceMeter(sliceFrames: 320)
        let first = meter.feed(Self.constant(3277, frames: 1000))   // 0.1 of full scale
        #expect(first.map(\.end) == [320, 640, 960])
        #expect(first.allSatisfy { abs($0.db - -20) < 0.05 })
        let second = meter.feed(Self.constant(3277, frames: 280))
        #expect(second.map(\.end) == [280])   // 40 carried + 280
        #expect(meter.feed(Self.constant(0, frames: 320)).first.map { $0.db <= -119 } == true)
    }

    @Test func noiseHasTheRequestedLevel() throws {
        let b = try #require(AudioUtil.noise(Self.int16k, frames: 16_000, db: -60))
        var meter = SliceMeter(sliceFrames: 16_000)
        let db = try #require(meter.feed(b).first?.db)
        #expect(abs(db - -60) < 1)
    }

    @Test func streamConverterResamplesAcrossChunks() throws {
        let mic = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let conv = StreamConverter(output: Self.int16k)
        var frames = 0
        for _ in 0..<10 {
            let b = AVAudioPCMBuffer(pcmFormat: mic, frameCapacity: 4800)!
            b.frameLength = 4800
            frames += Int(try #require(conv.convert(b)).frameLength)
        }
        // One second of 48 kHz stereo becomes about one second of 16 kHz mono; the resampler holds back its
        // filter delay (about 16 ms) until more input arrives.
        #expect(frames <= 16_000 && frames > 15_500)
        // A format change (device switch) rebuilds the converter.
        let other = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 4410)!
        b.frameLength = 4410
        #expect((conv.convert(b)?.frameLength ?? 0) > 1000)
        // Zero-length input is skipped.
        let empty = AVAudioPCMBuffer(pcmFormat: mic, frameCapacity: 16)!
        #expect(conv.convert(empty) == nil)
    }

    @Test func fileSourceDeliversTapSizedChunksAndQueuedAudio() async throws {
        let source = FileSource(pacing: .fast, noiseDB: nil, leadIn: 0)
        try source.enqueue(Self.sine(seconds: 0.25))
        #expect(abs(source.pendingSeconds - 0.25) < 0.001)
        let chunks = Chunks()
        try source.start(deliver: { chunks.add($0) }, event: { _ in })
        let deadline = Date().addingTimeInterval(3)
        while chunks.count < 4, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        source.stop()
        let got = chunks.all
        #expect(got.count >= 4)
        #expect(got.allSatisfy { $0.frameLength == 4800 && $0.format.sampleRate == 48_000 && $0.format.channelCount == 1 })
        let levels = got.prefix(4).map(Self.rmsDB)
        #expect(abs(levels[0] - -9) < 1)   // sine at 0.5: -9 dBFS
        #expect(abs(levels[1] - -9) < 1)
        #expect(abs(levels[2] - -12) < 1)  // half a chunk of sine
        #expect(levels[3] < -100)          // digital silence (no noise floor configured)
        #expect(source.pendingSeconds == 0)
    }

    @Test func fileSourcePacesInRealTimeAndMixesTheFloor() async throws {
        let source = FileSource(pacing: .realTime, noiseDB: -60, leadIn: 0)
        let chunks = Chunks()
        let t0 = Date()
        try source.start(deliver: { chunks.add($0) }, event: { _ in })
        while chunks.count < 6, Date().timeIntervalSince(t0) < 3 { try await Task.sleep(for: .milliseconds(5)) }
        let elapsed = Date().timeIntervalSince(t0)
        source.stop()
        #expect(chunks.count >= 6)
        #expect(elapsed > 0.55 && elapsed < 0.9)
        #expect(abs(Self.rmsDB(chunks.all[0]) - -60) < 1.5)
        // No delivery after stop.
        let n = chunks.count
        try await Task.sleep(for: .milliseconds(250))
        #expect(chunks.count == n)
    }

    @Test func fileSourceRejectsUnreadableFiles() {
        let source = FileSource(pacing: .fast)
        #expect(throws: (any Error).self) { try source.enqueue(contentsOf: URL(fileURLWithPath: "/nonexistent/clip.aiff")) }
    }

    @Test func levelMeterUnit() {
        #expect(LevelMeter.unit(-80) == 0)
        #expect(LevelMeter.unit(-35) == 0.5)
        #expect(LevelMeter.unit(0) == 1)
    }
}

final class Chunks: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    func add(_ b: AVAudioPCMBuffer) { lock.withLock { buffers.append(b) } }
    var count: Int { lock.withLock { buffers.count } }
    var all: [AVAudioPCMBuffer] { lock.withLock { buffers } }
}

@Suite struct InputDevicePolicyTests {
    let builtIn = InputDeviceInfo(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Mikrofon", transport: .builtIn)
    let airpods = InputDeviceInfo(id: 2, uid: "AA-BB:input", name: "AirPods", transport: .bluetooth)
    let usb = InputDeviceInfo(id: 3, uid: "USB-Headset", name: "Headset", transport: .usb)
    let speakers = InputDeviceInfo(id: 4, uid: "Speakers", name: "Lautsprecher", transport: .builtIn, hasInput: false)

    @Test func preferredDeviceWins() {
        let all = [builtIn, airpods, usb]
        #expect(InputDevicePolicy.choose(devices: all, defaultID: 2, preferredUID: "USB-Headset", avoidBluetooth: true) == .device(usb))
    }

    @Test func missingOrOutputOnlyPreferredDeviceFallsThrough() {
        let all = [builtIn, airpods, speakers]
        #expect(InputDevicePolicy.choose(devices: all, defaultID: 1, preferredUID: "gone", avoidBluetooth: true) == .systemDefault)
        #expect(InputDevicePolicy.choose(devices: all, defaultID: 1, preferredUID: "Speakers", avoidBluetooth: true) == .systemDefault)
    }

    @Test func bluetoothDefaultSwitchesToBuiltIn() {
        let all = [airpods, builtIn]
        #expect(InputDevicePolicy.choose(devices: all, defaultID: 2, preferredUID: nil, avoidBluetooth: true) == .device(builtIn))
        #expect(InputDevicePolicy.choose(devices: all, defaultID: 2, preferredUID: nil, avoidBluetooth: false) == .systemDefault)
        #expect(InputDevicePolicy.choose(devices: [airpods], defaultID: 2, preferredUID: nil, avoidBluetooth: true) == .systemDefault)
    }

    @Test func wiredDefaultStays() {
        #expect(InputDevicePolicy.choose(devices: [builtIn, usb], defaultID: 3, preferredUID: nil, avoidBluetooth: true) == .systemDefault)
    }
}

/// REVIEW M3: lifecycle calls run one after another, in the order one actor issued them.
@Suite struct SerialQueueTests {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    @MainActor @Test func keepsCallOrderAndNeverOverlaps() async {
        let queue = SerialQueue()
        let log = Log()
        var tasks: [Task<Void, Never>] = []
        for i in 0..<20 {
            // Fire and forget from the main actor, like the app's effect runner.
            tasks.append(Task { @MainActor in
                await queue.run {
                    log.add("start \(i)")
                    if i % 3 == 0 { try? await Task.sleep(for: .milliseconds(3)) }
                    log.add("end \(i)")
                }
            })
        }
        for t in tasks { await t.value }
        #expect(log.all == (0..<20).flatMap { ["start \($0)", "end \($0)"] })
    }

    @Test func returnsValuesAndErrors() async throws {
        let queue = SerialQueue()
        #expect(try await queue.run { 42 } == 42)
        await #expect(throws: SpeechError.self) { try await queue.run { () async throws -> Int in throw SpeechError.assetsUnavailable } }
        #expect(try await queue.run { "after error" } == "after error")
    }
}
