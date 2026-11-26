import AppKit
import SwiftUI
import ACVoiceFlow

/// Drives the overlay panel for the runtime. Main actor only.
///
/// - `render(_:)` takes every `OverlayModel` snapshot (`Effect.publish`). An idle snapshot keeps the last visible
///   content, so the panel fades out with it, and stops taking clicks.
/// - `show()` / `hide(fade:)` follow `Effect.showOverlay` / `Effect.hideOverlay`. `show()` cancels a running fade.
/// - `setLevel(_:)` takes the mic level (0...1) at about 15 Hz. Only the orb redraws.
/// - `onChoose(n, seq)`: a row click. `seq` is the seq of the snapshot the clicked row was drawn from, never the
///   live one, so the reducer can drop clicks on a list it renumbered since (`FlowEvent.choose`).
/// - `onDismiss`: the close button. The runtime sends `.cancel`.
/// - `onPointer(inside)`: the pointer moved onto the card or left it (only while the card takes clicks; a hide
///   reports `false`). The runtime sends `.pointer(inside:)`: a list keeps its time, an error stays up.
/// - Phase changes to choices, retry, success and error are announced to VoiceOver.
@MainActor
public final class OverlayController {
    public var onChoose: ((_ n: Int, _ seq: Int) -> Void)?
    public var onDismiss: (() -> Void)?
    public var onPointer: ((_ inside: Bool) -> Void)?

    /// Seconds a full countdown ring stands for (`Config.choicesWindow`).
    public var choicesWindow: Double {
        get { store.choicesWindow }
        set { store.choicesWindow = max(1, newValue) }
    }

    /// Card background. Liquid Glass by default; `.appKitGlass` draws it with `NSGlassEffectView`, `.hudMaterial`
    /// is the NSVisualEffectView fallback.
    public var backdrop: OverlayBackdrop {
        get { store.backdrop }
        set { store.backdrop = newValue }
    }

    /// Between `show()` and `hide(fade:)`.
    public private(set) var isShown = false

    /// What the panel draws now.
    public var viewState: OverlayViewState { store.state }

    /// Fade-in when the panel orders in (PLAN 3: 120 ms).
    public static let fadeIn = 0.12
    /// A shrinking card keeps the taller panel this long, until its spring settled.
    static let shrinkDelay = 0.4

    let store = OverlayStore()
    let meter = LevelMeter()
    private let surface: any OverlaySurface
    /// Wall clock (render times, level samples). Tests pin it.
    var now: () -> Date = Date.init
    /// System Reduce Motion, for the controller's own animations (the views read the environment).
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var screen: ScreenInfo?
    private(set) var cardSize = CGSize(width: OverlayMetrics.width, height: 92)
    private var fadeGeneration = 0
    private var shrinkTask: Task<Void, Never>?
    private var shownPhase: FlowPhase?
    /// What `onPointer` reported last.
    private(set) var pointerInside = false

    /// Creates the panel (deferred: no window server window until the first `show()`).
    public convenience init() {
        self.init(surface: PanelSurface())
    }

    init(surface: any OverlaySurface) {
        self.surface = surface
        surface.attach(OverlayRootView(store: store, meter: meter, actions: OverlayActions(
            choose: { [weak self] row in self?.choose(row) },
            dismiss: { [weak self] in self?.dismiss() },
            cardSize: { [weak self] size in self?.cardSizeChanged(size) },
            pointer: { [weak self] inside in self?.pointerMoved(inside: inside) },
            cardFrame: { [weak self] in self?.cardFrame ?? .zero })))
    }

    // MARK: Runtime API

    public func show() {
        fadeGeneration += 1
        let wasShown = isShown
        isShown = true
        store.running = true
        store.interactive = store.state.phase != .idle
        if !wasShown || screen == nil {
            screen = PanelGeometry.screen(containing: surface.mouseLocation, in: surface.screens)
            surface.layoutNow()
            placePanel(immediately: true)
        }
        surface.fadeIn(duration: Self.fadeIn)
    }

    public func hide(fade: Double) {
        guard isShown else { return }
        isShown = false
        store.interactive = false
        pointerMoved(inside: false)
        shrinkTask?.cancel()
        fadeGeneration += 1
        let generation = fadeGeneration
        surface.fadeOut(duration: max(0, fade)) { [weak self] in
            guard let self, self.fadeGeneration == generation else { return }
            self.surface.orderOut()
            self.store.running = false
            self.meter.reset()
            self.shownPhase = nil
            self.screen = nil
        }
    }

    public func render(_ model: OverlayModel) {
        guard model.visible, model.phase != .idle else {
            // Idle snapshot right before a hide: keep the content while it fades, take no more clicks.
            store.interactive = false
            pointerMoved(inside: false)
            return
        }
        let phaseChanged = model.phase != shownPhase
        let start = phaseChanged ? now() : store.state.phaseStart
        shownPhase = model.phase
        let next = OverlayViewState(model: model, phaseStart: start)
        store.interactive = isShown
        if phaseChanged, Self.announced.contains(model.phase) { surface.announce(next.accessibilityLabel) }
        guard next != store.state else { return }
        if isShown, next.structure != store.state.structure {
            withAnimation(Self.animation(reduceMotion: reduceMotion())) { store.state = next }
        } else {
            store.state = next
        }
    }

    public func setLevel(_ rms: Double) {
        guard isShown else { return }
        meter.push(rms, at: now().timeIntervalSinceReferenceDate)
    }

    // MARK: View callbacks

    /// A row click. Forwards the row's own number and seq.
    func choose(_ row: ChoiceRowState) {
        guard isShown, store.interactive, store.state.phase == .choices else { return }
        onChoose?(row.n, row.seq)
    }

    func dismiss() {
        guard isShown, store.interactive else { return }
        onDismiss?()
    }

    /// Phases VoiceOver hears about: the ones that ask for something or report a result.
    static let announced: Set<FlowPhase> = [.choices, .retry, .success, .error]

    /// The card inside the panel's content view: the panel is the card grown by the insets.
    var cardFrame: CGRect {
        CGRect(x: OverlayMetrics.insets.leading, y: OverlayMetrics.insets.top, width: cardSize.width, height: cardSize.height)
    }

    /// From the tracking area. Reports changes only, and only while the card takes clicks.
    func pointerMoved(inside: Bool) {
        let now = inside && isShown && store.interactive
        guard now != pointerInside else { return }
        pointerInside = now
        onPointer?(now)
    }

    func cardSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != cardSize else { return }
        cardSize = size
        guard isShown else { return }   // placed at the next show()
        placePanel(immediately: false)
    }

    // MARK: Placement

    private func placePanel(immediately: Bool) {
        guard let screen else { return }
        let target = PanelGeometry.panelFrame(cardSize: cardSize, on: screen)
        shrinkTask?.cancel()
        shrinkTask = nil
        let plan = immediately ? (now: target, later: nil) : PanelGeometry.resizePlan(current: surface.frame, target: target)
        if surface.frame != plan.now { surface.setFrame(plan.now) }
        guard let later = plan.later else { return }
        shrinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.shrinkDelay))
            guard !Task.isCancelled, let self, self.isShown else { return }
            self.surface.setFrame(later)
        }
    }

    /// The spring the card grows with (PLAN 3: about 250 ms). Reduce Motion: a short ease.
    nonisolated static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.84)
    }
}
