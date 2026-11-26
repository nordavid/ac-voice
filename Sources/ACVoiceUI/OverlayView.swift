import SwiftUI
import ACVoiceFlow

/// The overlay card: orb and text on top, the choice list below. Draws exactly one `OverlayViewState`.
struct OverlayView: View {
    var state: OverlayViewState
    var clock: OrbClock
    var background: CardBackground
    /// false while fading out or in snapshots: rows and the close button ignore the mouse.
    var interactive: Bool
    var choicesWindow: Double
    var onChoose: @MainActor (ChoiceRowState) -> Void
    var onDismiss: @MainActor () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.overlayAccessibility) private var a11y
    @State private var hovering = false

    var body: some View {
        let palette = OverlayPalette(scheme: scheme, highContrast: a11y.increaseContrast)
        VStack(alignment: .leading, spacing: 0) {
            header(palette)
            // Always in the tree, also when empty: rows inserted into a live ForEach run their own staggered
            // transitions (a container inserted as a whole would not).
            ChoiceListView(rows: state.rows, footer: state.footer, palette: palette, interactive: interactive,
                           onChoose: onChoose)
        }
        .frame(width: OverlayMetrics.width, alignment: .leading)
        .background(alignment: .topLeading) { ambientGlow(palette) }
        .modifier(CardBackdropModifier(background: background))
        .overlay { CardRim(background: background) }
        .overlay(alignment: .topTrailing) { closeButton }
        .background { CardShadow() }
        .onHover { hovering = interactive && $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OverlayText.overlay)
    }

    // MARK: Header

    private func header(_ palette: OverlayPalette) -> some View {
        HStack(alignment: .center, spacing: 16) {
            OrbView(tone: state.tone, micLive: state.micLive, phaseStart: state.phaseStart, deadline: state.deadline,
                    countdownFrozen: state.countdownFrozen, choicesWindow: choicesWindow, clock: clock)
            VStack(alignment: .leading, spacing: 5) {
                headline(palette)
                ForEach(state.lines) { line in
                    lineView(line, palette)
                        // Removal at once: a fading line would keep its space and hold the card open. Reduce
                        // Motion: a fade without the slide.
                        .transition(.asymmetric(insertion: a11y.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -3)),
                                                removal: .identity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 26)
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.vertical, 16)
        .frame(minHeight: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .modifier(SecondsLeftValue(deadline: state.deadline, frozen: state.countdownFrozen, live: clock.isLive))
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func headline(_ palette: OverlayPalette) -> some View {
        let font = Font.system(size: 20, weight: .medium)
        switch state.headline {
        case let .transcript(stable, volatile):
            Text(Self.transcript(stable: stable, volatile: volatile, tailOpacity: palette.volatileOpacity))
                .font(font)
                // The view state already cut long utterances at the start (newest words matter most).
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case let .placeholder(text, dimmed):
            // Increase Contrast: secondary at most (tertiary falls below 2:1 on light glass).
            Text(text)
                .font(font)
                .foregroundStyle(dimmed && !a11y.increaseContrast ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        case let .title(text):
            Text(text)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Stable part in the primary color, volatile tail dimmed.
    static func transcript(stable: String, volatile: String, tailOpacity: Double) -> AttributedString {
        var out = AttributedString(stable)
        out.foregroundColor = Color.primary
        if !volatile.isEmpty {
            var tail = AttributedString(stable.isEmpty ? volatile : " " + volatile)
            tail.foregroundColor = Color.primary.opacity(tailOpacity)
            out += tail
        }
        return out
    }

    private func lineView(_ line: OverlayLine, _ palette: OverlayPalette) -> some View {
        let style = lineStyle(line.style, palette)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol = line.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .bold))
                    .frame(width: 14)
            }
            Text(line.text)
                .font(.system(size: 14, weight: style.weight))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(style.color)
    }

    private func lineStyle(_ style: OverlayLine.Style, _ palette: OverlayPalette) -> (color: AnyShapeStyle, weight: Font.Weight) {
        let secondary = palette.secondaryText(increaseContrast: a11y.increaseContrast)
        switch style {
        case .preview:
            return (AnyShapeStyle(palette.accent(state.tone == .processing ? .processing : .listening).color), .semibold)
        case .question:
            return (AnyShapeStyle(palette.accent(.choices).color), .semibold)
        case .status:
            return (secondary, .regular)
        case .alert:
            return (AnyShapeStyle(palette.accent(.choices).color), .semibold)
        case .success:
            return (AnyShapeStyle(palette.accent(.success).color), .semibold)
        case .quote:
            return (secondary, .regular)
        }
    }

    // MARK: Decoration

    /// The orb casts its color onto the glass, strongest behind the orb.
    private func ambientGlow(_ palette: OverlayPalette) -> some View {
        let glow = palette.orb(state.tone).glow
        let strength = palette.ambientGlow * (state.tone == .warming ? 0.5 : 1)
        // Orb center: leading padding + half the slot, vertical padding + half the slot.
        let center = UnitPoint(x: (18 + OrbMotion.slot / 2) / OverlayMetrics.width, y: 46 / 300)
        // The 300 pt gradient must not size its frame: with minimums of 0 the outer frame takes the card's size, so
        // the clip keeps the glow inside the card (review U1: a tinted band hung below every compact card).
        return RadialGradient(colors: [glow.opacity(strength), glow.opacity(strength * 0.3), glow.opacity(0)],
                              center: center, startRadius: 0, endRadius: 300)
            .frame(width: OverlayMetrics.width, height: 300)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(OverlayMetrics.shape)
            .allowsHitTesting(false)
    }

    private var closeButton: some View {
        Button(action: { onDismiss() }) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.75 : (a11y.increaseContrast ? 0.7 : 0.55)))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .allowsHitTesting(interactive)
        .accessibilityLabel(OverlayText.close)
        .accessibilityHint(OverlayText.a11yCloseHint)
    }
}
