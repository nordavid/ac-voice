import ACVoiceFlow
import ACVoiceSystem
import Foundation

/// Esc as a system-wide key while the overlay shows. The overlay panel never takes the keyboard focus (it must not
/// steal it from Chrome), so it cannot see Esc itself.
@MainActor
public protocol EscapeKeyServing: AnyObject {
    var isActive: Bool { get }
    /// Starts delivering Esc presses to `handler`. A second call while active changes nothing.
    func activate(_ handler: @escaping @MainActor () -> Void)
    func deactivate()
}

/// Esc through Carbon hotkeys: needs no Accessibility or Input Monitoring permission, but consumes Esc in every app
/// while registered. So it is registered only while the overlay shows (`EscapeClosesOverlay`).
///
/// Two combinations: plain Esc, and Esc with the configured hotkey's modifiers (⌃⌥Esc for ⌃⌥Space). Carbon matches
/// the exact modifier set, so without the second one Esc does nothing while the hotkey is held for push-to-talk.
@MainActor
public final class EscapeKey: EscapeKeyServing {
    private let keys: [(hotkey: GlobalHotkey, spec: CarbonHotkey)]
    public private(set) var isActive = false

    /// `holdModifiers`: the configured hotkey's Carbon modifier mask, or 0 when it is disabled.
    public init(holdModifiers: UInt32 = 0) {
        keys = [CarbonHotkey.escape, CarbonHotkey.escape(heldWith: holdModifiers)].compactMap { $0 }
            .map { (GlobalHotkey(), $0) }
    }

    public func activate(_ handler: @escaping @MainActor () -> Void) {
        guard !isActive else { return }
        for key in keys {
            do {
                try key.hotkey.register(key.spec) { e in
                    if e == .pressed { handler() }
                }
                isActive = true
            } catch {
                // Another app owns this combination as a global hotkey: the close button still works.
                Log.error(.hotkey, "escape.register.failed", error)
            }
        }
    }

    public func deactivate() {
        guard isActive else { return }
        for key in keys { key.hotkey.unregister() }
        isActive = false
    }
}

/// The overlay plus Esc: Esc does what the close button does (`onDismiss`: cancel the command or stop the demo).
/// Every show and hide goes through here, the flow's and the overlay demo's alike, so Esc is registered exactly while
/// the overlay is on screen.
@MainActor
public final class EscapeClosesOverlay: OverlayPresenting {
    private let inner: any OverlayPresenting
    private let escape: any EscapeKeyServing

    public init(_ inner: any OverlayPresenting, escape: any EscapeKeyServing) {
        self.inner = inner
        self.escape = escape
    }

    public var onChoose: ((_ n: Int, _ seq: Int) -> Void)? {
        get { inner.onChoose }
        set { inner.onChoose = newValue }
    }

    public var onDismiss: (() -> Void)? {
        get { inner.onDismiss }
        set { inner.onDismiss = newValue }
    }

    public var onPointer: ((_ inside: Bool) -> Void)? {
        get { inner.onPointer }
        set { inner.onPointer = newValue }
    }

    public var choicesWindow: Double {
        get { inner.choicesWindow }
        set { inner.choicesWindow = newValue }
    }

    public func show() {
        inner.show()
        escape.activate { [weak self] in
            Log.event(.app, "escape.pressed")
            self?.inner.onDismiss?()
        }
    }

    public func hide(fade: Double) {
        escape.deactivate()
        inner.hide(fade: fade)
    }

    public func render(_ model: OverlayModel) { inner.render(model) }
    public func setLevel(_ rms: Double) { inner.setLevel(rms) }
}
