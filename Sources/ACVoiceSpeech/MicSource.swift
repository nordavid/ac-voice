import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// An audio input device as CoreAudio reports it.
public struct InputDeviceInfo: Sendable, Equatable {
    public enum Transport: Sendable, Equatable { case builtIn, bluetooth, usb, virtual, aggregate, other }
    public var id: UInt32
    public var uid: String
    public var name: String
    public var transport: Transport
    public var hasInput: Bool

    public init(id: UInt32, uid: String, name: String, transport: Transport, hasInput: Bool = true) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport; self.hasInput = hasInput
    }
}

/// Which microphone to use (REVIEW M7, PLAN risk "Bluetooth HFP mics").
public enum InputDevicePolicy {
    public enum Choice: Sendable, Equatable {
        case systemDefault
        case device(InputDeviceInfo)
    }

    /// 1. `preferredUID` when that device exists and has inputs (`Config.inputDeviceUID`).
    /// 2. With `avoidBluetooth`, the built-in mic when the default input is Bluetooth: HFP lowers the output quality
    ///    for the whole session and starts slowly, so first syllables get lost.
    /// 3. Otherwise the system default.
    public static func choose(devices: [InputDeviceInfo], defaultID: UInt32?, preferredUID: String?,
                              avoidBluetooth: Bool) -> Choice {
        let inputs = devices.filter(\.hasInput)
        if let uid = preferredUID, let d = inputs.first(where: { $0.uid == uid }) { return .device(d) }
        if avoidBluetooth, let def = inputs.first(where: { $0.id == defaultID }), def.transport == .bluetooth,
           let builtIn = inputs.first(where: { $0.transport == .builtIn }) {
            return .device(builtIn)
        }
        return .systemDefault
    }
}

/// The real microphone: AVAudioEngine input tap (PLAN 2.3, REVIEW M7, m1). Each `start()` builds a fresh engine,
/// validates the input format before installing the tap, asks for 100 ms tap buffers (the supported range is
/// 100-400 ms) and reports `AVAudioEngineConfigurationChange` (the engine stops itself on a device change).
///
/// `start` and `stop` may run on different threads: a `stop()` while `start()` still sets up the engine wins, and
/// `start` then tears its new engine down and throws (review: a device-change restart racing `VoiceSession.stop()`
/// left the microphone open).
///
/// Starting it opens the microphone and triggers the TCC prompt on first use. Tests and dev CLIs use `FileSource`.
public final class MicSource: AudioSource, @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        /// CoreAudio device UID (`Config.inputDeviceUID`). nil: system default (see `avoidBluetooth`).
        public var deviceUID: String?
        public var avoidBluetooth = true
        /// Requested tap buffer length; clamped to 0.1 ... 0.4 s.
        public var bufferDuration = 0.1
        public init(deviceUID: String? = nil, avoidBluetooth: Bool = true, bufferDuration: Double = 0.1) {
            self.deviceUID = deviceUID; self.avoidBluetooth = avoidBluetooth; self.bufferDuration = bufferDuration
        }
    }

    public let options: Options
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var deviceName = "default"
    /// Bumped by every `stop()`; a `start()` stores its engine only if no `stop()` ran meanwhile.
    private var generation = 0

    public init(options: Options = .init()) { self.options = options }

    public var name: String { lock.withLock { deviceName } }

    public func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                      event: @escaping @Sendable (AudioSourceEvent) -> Void) throws {
        stop()
        let startedIn = lock.withLock { generation }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let choice = InputDevicePolicy.choose(devices: CoreAudioDevices.inputDevices(), defaultID: CoreAudioDevices.defaultInputID(),
                                              preferredUID: options.deviceUID, avoidBluetooth: options.avoidBluetooth)
        var name = "default"
        if case .device(let d) = choice {
            guard let unit = input.audioUnit else { throw SpeechError.sourceFailed("no input unit") }
            var id = AudioDeviceID(d.id)
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw SpeechError.sourceFailed("device \(status)") }
            name = d.name
        }
        // A zero sample rate or channel count crashes installTap (REVIEW M7).
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.invalidInputFormat }
        let seconds = min(max(options.bufferDuration, 0.1), 0.4)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount((format.sampleRate * seconds).rounded()), format: format) { buffer, _ in
            deliver(buffer)
        }
        let token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                           queue: nil) { _ in event(.configurationChanged) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NotificationCenter.default.removeObserver(token)
            throw SpeechError.sourceFailed(String(describing: error))
        }
        let stored = lock.withLock { () -> Bool in
            guard generation == startedIn else { return false }
            self.engine = engine; observer = token; deviceName = name
            return true
        }
        guard stored else {
            // `stop()` ran while the engine started: nobody would ever stop this one.
            NotificationCenter.default.removeObserver(token)
            input.removeTap(onBus: 0)
            engine.stop()
            throw SpeechError.sourceFailed("stopped while starting")
        }
    }

    public func stop() {
        let (engine, token) = lock.withLock { () -> (AVAudioEngine?, (any NSObjectProtocol)?) in
            generation &+= 1
            defer { self.engine = nil; observer = nil }
            return (self.engine, observer)
        }
        if let token { NotificationCenter.default.removeObserver(token) }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// CoreAudio device queries. Reading device properties opens no audio stream and needs no permission.
enum CoreAudioDevices {
    static func defaultInputID() -> UInt32? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func inputDevices() -> [InputDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            InputDeviceInfo(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "", name: string(id, kAudioObjectPropertyName) ?? "",
                            transport: transport(id), hasInput: hasInputStreams(id))
        }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func transport(_ id: AudioObjectID) -> InputDeviceInfo.Transport {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        default: return .other
        }
    }

    static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
}
