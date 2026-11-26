import AppKit
import SwiftUI

/// Borderless, non-activating floating panel. Shows above other apps and full-screen spaces without taking focus,
/// so Chrome stays frontmost. Created once, then only ordered in and out.
public final class OverlayPanel: NSPanel {
    public init() {
        // `.nonactivatingPanel` must be part of the initial style mask; toggling it later is unreliable.
        // `defer: true`: no window server window until the first order-in.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 648, height: 170),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The shadow is drawn in SwiftUI (CardShadow): a window shadow is cached from the content alpha and lags
        // behind the spring height animation.
        hasShadow = false
        // The app is never active; the default would hide the panel at once.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        // The controller fades the panel itself.
        animationBehavior = .none
        // `ignoresMouseEvents` stays unset on purpose: set explicitly (even to false) the whole window takes clicks,
        // also its transparent shadow margin beside and below the card. Unset, fully transparent pixels let clicks
        // through to Chrome (review U19, a manual check).
        acceptsMouseMovedEvents = true
    }

    // Never take keyboard focus from the frontmost app: voice is the input channel.
    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}

/// Hosting view that takes the first click: rows react to a click while the app is inactive, without activating
/// it (REVIEW m12). It also reports whether the pointer rests on the card: an `.activeAlways` tracking area works
/// in this never-key panel of a never-active app. Only a mouse move counts, so a card that appears under a resting
/// pointer is not held.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    /// The card in this view's coordinates (flipped, origin top left).
    var cardFrame: @MainActor () -> CGRect = { .zero }
    var onPointer: @MainActor (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer(cardFrame().contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer(false)
    }
}

/// What the controller needs from the window. The live surface wraps `OverlayPanel`; tests use a fake, so no
/// window is ever created there.
@MainActor
protocol OverlaySurface: AnyObject {
    func attach(_ root: OverlayRootView)
    var screens: [ScreenInfo] { get }
    var mouseLocation: CGPoint { get }
    /// nil until the first placement.
    var frame: CGRect? { get }
    func setFrame(_ frame: CGRect)
    /// Runs pending SwiftUI layout, so the card reports its size before the first frame.
    func layoutNow()
    /// Orders the panel in without activating the app (if needed) and fades it to full opacity.
    func fadeIn(duration: Double)
    /// Fades to zero. `completion` runs on the main actor once the fade ended or was interrupted.
    func fadeOut(duration: Double, completion: @escaping @MainActor @Sendable () -> Void)
    func orderOut()
    /// Asks VoiceOver to read `text` (the panel never gets focus, so VoiceOver would say nothing by itself).
    func announce(_ text: String)
}

@MainActor
final class PanelSurface: OverlaySurface {
    let panel = OverlayPanel()
    private var hosting: FirstMouseHostingView<OverlayRootView>?
    private var placed = false
    private var pendingFrame: CGRect?

    func attach(_ root: OverlayRootView) {
        let view = FirstMouseHostingView(rootView: root)
        // The controller sizes the panel from the card size; the view only fills it.
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]
        view.cardFrame = { root.actions.cardFrame() }
        view.onPointer = { root.actions.pointer($0) }
        panel.contentView = view
        hosting = view
    }

    var screens: [ScreenInfo] {
        NSScreen.screens.map { ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    var mouseLocation: CGPoint { NSEvent.mouseLocation }

    var frame: CGRect? { placed ? (pendingFrame ?? panel.frame) : nil }

    func setFrame(_ frame: CGRect) {
        if !placed || !panel.isVisible {
            placed = true
            pendingFrame = nil
            panel.setFrame(frame, display: false)
            return
        }
        // Size reports arrive inside a SwiftUI update; resize on the next turn of the run loop, coalesced.
        let scheduled = pendingFrame != nil
        pendingFrame = frame
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let next = self.pendingFrame else { return }
            self.pendingFrame = nil
            self.panel.setFrame(next, display: true)
        }
    }

    func layoutNow() {
        hosting?.layoutSubtreeIfNeeded()
    }

    func fadeIn(duration: Double) {
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func fadeOut(duration: Double, completion: @escaping @MainActor @Sendable () -> Void) {
        guard panel.isVisible, duration > 0 else {
            panel.alphaValue = 0
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in completion() }
        })
    }

    func orderOut() {
        panel.orderOut(nil)
        panel.alphaValue = 0
    }

    func announce(_ text: String) {
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Callbacks from the view tree into the controller.
struct OverlayActions {
    var choose: @MainActor (ChoiceRowState) -> Void
    var dismiss: @MainActor () -> Void
    var cardSize: @MainActor (CGSize) -> Void
    /// The pointer moved onto the card (true) or off it.
    var pointer: @MainActor (Bool) -> Void = { _ in }
    /// The card inside the panel's content view (flipped coordinates).
    var cardFrame: @MainActor () -> CGRect = { .zero }
}

/// Observable state of the live overlay. `OverlayViewState` changes once per model snapshot; the level lives in
/// `LevelMeter`, so 15 Hz level updates only redraw the orb.
@MainActor
@Observable
final class OverlayStore {
    var state = OverlayViewState.initial
    /// Rows and the close button take clicks (false while hidden or fading out).
    var interactive = false
    /// Animation timelines run (false while hidden: no idle CPU).
    var running = false
    var backdrop = OverlayBackdrop.liquidGlass
    var choicesWindow = 6.0
}

/// Root of the panel: the card, top-aligned inside the panel's transparent shadow margin.
struct OverlayRootView: View {
    var store: OverlayStore
    var meter: LevelMeter
    var actions: OverlayActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        OverlayView(state: store.state, clock: .live(meter: meter, running: store.running),
                    background: .live(store.backdrop), interactive: store.interactive,
                    choicesWindow: store.choicesWindow, onChoose: actions.choose, onDismiss: actions.dismiss)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                actions.cardSize(size)
            }
            .environment(\.overlayAccessibility, OverlayAccessibility(
                reduceMotion: reduceMotion, increaseContrast: contrast == .increased,
                reduceTransparency: reduceTransparency))
            .padding(OverlayMetrics.insets)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
