import ACVoiceCore
import AppKit
import Carbon.HIToolbox

/// A hotkey edge as the flow needs it: press, and release with the hold time (push-to-talk).
public enum HotkeyEvent: Sendable, Equatable {
    case pressed
    case released(heldMs: Int)
}

public enum HotkeyError: Error, Equatable {
    /// The hotkey is disabled or the combination is not allowed (`CarbonHotkey.init`).
    case invalid
    case handlerInstallFailed(Int32)
    /// `eventHotKeyExistsErr` (-9878): another app owns the combination.
    case registrationFailed(Int32)

    /// German text for the menu.
    public var message: String {
        switch self {
        case .invalid: return "Das Tastenkürzel passt nicht. Ändere hotkey in config.json."
        case .registrationFailed(let s) where s == Int32(eventHotKeyExistsErr):
            return "Eine andere App nutzt das Tastenkürzel. Ändere hotkey in config.json."
        case .handlerInstallFailed, .registrationFailed: return "macOS meldet das Tastenkürzel nicht an"
        }
    }
}

/// Carbon `RegisterEventHotKey` arguments for a Core `Hotkey`. Pure, so the mapping is testable.
public struct CarbonHotkey: Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    /// Modifier bits Carbon hotkeys accept.
    public static let allowedModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)
    /// F1 to F20: the only keys allowed without a modifier (anything else would swallow normal typing).
    public static let functionKeys: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4), UInt32(kVK_F5), UInt32(kVK_F6),
        UInt32(kVK_F7), UInt32(kVK_F8), UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16), UInt32(kVK_F17), UInt32(kVK_F18),
        UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    /// Esc without a modifier. Never valid as the configured hotkey (it would swallow Esc in every app); the runtime
    /// registers it only while the overlay shows, to close it.
    public static let escape = CarbonHotkey(keyCode: UInt32(kVK_Escape), modifiers: 0)

    /// Esc while the configured hotkey's modifiers are held (push-to-talk with ⌃⌥Space held, then Esc): Carbon matches
    /// the exact modifier set, so plain `escape` never sees ⌃⌥Esc. nil without a modifier, or with ⌘, so ⌥⌘Esc
    /// (Force Quit) and other ⌘ combinations stay with macOS.
    public static func escape(heldWith modifiers: UInt32) -> CarbonHotkey? {
        let mods = modifiers & allowedModifiers
        guard mods != 0, mods & UInt32(cmdKey) == 0 else { return nil }
        return CarbonHotkey(keyCode: UInt32(kVK_Escape), modifiers: mods)
    }

    private init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// nil when the hotkey is disabled, the key code is out of range, or a non-function key has no modifier.
    /// Unknown modifier bits are dropped.
    public init?(_ hotkey: Hotkey) {
        guard hotkey.enabled, hotkey.keyCode < 128 else { return nil }
        let mods = hotkey.modifiers & Self.allowedModifiers
        if mods == 0, !Self.functionKeys.contains(hotkey.keyCode) { return nil }
        keyCode = hotkey.keyCode
        modifiers = mods
    }

    /// Carbon modifier mask from AppKit flags (a settings field that records a key combination).
    public static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    public static func flags(from modifiers: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }
}

/// Turns raw Carbon edges into `HotkeyEvent`s: drops a repeated press while the key is down and a release without
/// a press, and measures the hold time.
public struct HotkeyEdgeFilter: Sendable {
    private var downAt: Double?

    public init() {}

    public var isDown: Bool { downAt != nil }

    /// `pressed`: Carbon `kEventHotKeyPressed`, else released. `t` in seconds (monotonic).
    public mutating func accept(pressed: Bool, at t: Double) -> HotkeyEvent? {
        if pressed {
            guard downAt == nil else { return nil }
            downAt = t
            return .pressed
        }
        guard let start = downAt else { return nil }
        downAt = nil
        return .released(heldMs: max(0, Int(((t - start) * 1000).rounded())))
    }

    /// Carbon event kind to edge: true for pressed, false for released, nil for other kinds.
    public static func isPressed(eventKind: UInt32) -> Bool? {
        switch eventKind {
        case UInt32(kEventHotKeyPressed): return true
        case UInt32(kEventHotKeyReleased): return false
        default: return nil
        }
    }
}

/// Global hotkey registration. The runtime talks to this protocol, tests use fakes.
@MainActor
public protocol HotkeyRegistering: AnyObject {
    /// Replaces any previous registration.
    func register(_ hotkey: Hotkey, handler: @escaping @MainActor (HotkeyEvent) -> Void) throws
    func unregister()
}

/// Carbon hotkey (default ⌃⌥Space): system-wide, consumes the combination, needs no Accessibility or Input
/// Monitoring permission. Delivers press and release, like the Stream Deck key. Needs a running NSApplication
/// event loop (the app's main thread). Never registered in tests.
@MainActor
public final class GlobalHotkey: HotkeyRegistering {
    /// "ACVC"
    nonisolated static let signature: OSType = 0x4143_5643

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var box: Unmanaged<HandlerBox>?
    /// Shared by all instances: every handler sees every hotkey event of the app and answers only its own id, so
    /// two instances (the configured hotkey and Esc) must never hand out the same id.
    private static var nextId: UInt32 = 1

    public init() {}

    /// The next hotkey id, unique across all instances (see `nextId`).
    static func allocateId() -> UInt32 {
        defer { nextId &+= 1 }
        return nextId
    }

    public private(set) var registered: CarbonHotkey?

    public func register(_ hotkey: Hotkey, handler: @escaping @MainActor (HotkeyEvent) -> Void) throws {
        unregister()
        guard let spec = CarbonHotkey(hotkey) else { throw HotkeyError.invalid }
        try register(spec, handler: handler)
    }

    /// Registers a checked combination as it is (`CarbonHotkey.escape`). Replaces any previous registration.
    /// Several `GlobalHotkey` instances can live side by side: each handler answers only its own hotkey id.
    public func register(_ spec: CarbonHotkey, handler: @escaping @MainActor (HotkeyEvent) -> Void) throws {
        unregister()
        let id = Self.allocateId()
        // Retained until `unregister`: Carbon keeps a raw pointer to it.
        let box = Unmanaged.passRetained(HandlerBox(id: id, handler: handler))
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var handlerRef: EventHandlerRef?
        var status = InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, types.count, &types,
                                         box.toOpaque(), &handlerRef)
        guard status == noErr else {
            box.release()
            throw HotkeyError.handlerInstallFailed(status)
        }
        var ref: EventHotKeyRef?
        status = RegisterEventHotKey(spec.keyCode, spec.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            box.release()
            Log.event(.hotkey, "hotkey.register.failed", .int("status", status), level: .error)
            throw HotkeyError.registrationFailed(status)
        }
        self.hotKeyRef = ref
        self.handlerRef = handlerRef
        self.box = box
        registered = spec
        Log.event(.hotkey, "hotkey.registered", .int("keyCode", spec.keyCode), .int("modifiers", spec.modifiers))
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        box?.release()
        hotKeyRef = nil
        handlerRef = nil
        box = nil
        registered = nil
    }
}

/// The Carbon handler's context. Carbon calls on the main thread (application event target), and `filter` is only
/// touched there, inside `MainActor.assumeIsolated`.
private final class HandlerBox: @unchecked Sendable {
    let id: UInt32
    let handler: @MainActor (HotkeyEvent) -> Void
    var filter = HotkeyEdgeFilter()

    init(id: UInt32, handler: @escaping @MainActor (HotkeyEvent) -> Void) {
        self.id = id
        self.handler = handler
    }
}

private func hotkeyCallback(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hkID = EventHotKeyID()
    let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                               MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    let box = Unmanaged<HandlerBox>.fromOpaque(userData).takeUnretainedValue()
    guard st == noErr, hkID.signature == GlobalHotkey.signature, hkID.id == box.id,
          let pressed = HotkeyEdgeFilter.isPressed(eventKind: GetEventKind(event))
    else { return OSStatus(eventNotHandledErr) }
    let t = ProcessInfo.processInfo.systemUptime
    MainActor.assumeIsolated {
        if let e = box.filter.accept(pressed: pressed, at: t) { box.handler(e) }
    }
    return noErr
}
