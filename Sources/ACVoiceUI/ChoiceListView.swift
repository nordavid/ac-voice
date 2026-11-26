import SwiftUI

/// Numbered choice rows with a footer (hint, page dots, "mehr").
struct ChoiceListView: View {
    var rows: [ChoiceRowState]
    var footer: ChoiceFooterState?
    var palette: OverlayPalette
    var interactive: Bool
    /// The overlay's words in the app language (VoiceOver hints, page label).
    var text: OverlayText = .de
    var onChoose: @MainActor (ChoiceRowState) -> Void

    @Environment(\.overlayAccessibility) private var a11y

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(a11y.increaseContrast ? 0.25 : 0.09))
                    .frame(height: 1)
                    .padding(.horizontal, 18)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    ChoiceRowView(row: row, palette: palette, interactive: interactive, text: text, onChoose: onChoose)
                        .transition(Self.rowTransition(index: row.index, reduceMotion: a11y.reduceMotion))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, rows.isEmpty ? 0 : 8)
            if let footer {
                // Leading 17 = list padding 8 + row padding 9: the icon sits under the numeral pills, the hint
                // under the row titles.
                ChoiceFooterView(footer: footer, palette: palette, text: text)
                    .padding(.leading, 17)
                    .padding(.trailing, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .transition(.asymmetric(
                        insertion: AnyTransition.opacity.animation(
                            a11y.reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.2).delay(Self.stagger(rows.count))),
                        removal: .identity))
            }
        }
    }

    /// Rows enter staggered by 30 ms; Reduce Motion fades without movement. Rows leave at once: a fading row keeps
    /// its layout space, so a page change would briefly stack both pages.
    static func rowTransition(index: Int, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: AnyTransition.opacity.animation(.easeOut(duration: 0.15)), removal: .identity)
        }
        return .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(y: 8))
                .animation(.spring(response: 0.32, dampingFraction: 0.86).delay(Self.stagger(index))),
            removal: .identity)
    }

    nonisolated static func stagger(_ index: Int) -> Double { Double(max(0, index)) * 0.03 }
}

struct ChoiceRowView: View {
    var row: ChoiceRowState
    var palette: OverlayPalette
    var interactive: Bool
    var text: OverlayText = .de
    var onChoose: @MainActor (ChoiceRowState) -> Void

    @Environment(\.overlayAccessibility) private var a11y
    @State private var hover = false

    var body: some View {
        let accent = palette.accent(.choices)
        // The row value (number and seq of the snapshot it was drawn from) goes out as is: never the live model.
        let row = self.row
        Button { onChoose(row) } label: {
            HStack(spacing: 12) {
                NumeralPill(n: row.n, accent: accent, filled: hover, palette: palette)
                // Two lines: long German titles keep their distinguishing tail ("… Phase 2", "… PIM").
                title
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if let badge = row.badge { BadgeView(text: badge) }
                if let ticket = row.ticket {
                    // Neutral: amber belongs to the numeral the user says; the ticket number is information.
                    Text(ticket)
                        .font(.system(size: 12.5, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondaryText(increaseContrast: a11y.increaseContrast))
                        .fixedSize()
                }
                Spacer(minLength: 6)
                if !row.markers.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(row.markers, id: \.self) { MarkerIcon(marker: $0, palette: palette) }
                    }
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hover ? accent.opacity(palette.dark ? 0.16 : 0.12) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(RowPressStyle(reduceMotion: a11y.reduceMotion))
        .allowsHitTesting(interactive)
        .onHover { inside in
            if a11y.reduceMotion { hover = interactive && inside } else {
                withAnimation(.easeOut(duration: 0.12)) { hover = interactive && inside }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(text.a11yOpenRow)
        .accessibilityAddTraits(.isButton)
    }

    private var title: Text {
        var s = AttributedString()
        for run in row.titleRuns {
            var piece = AttributedString(run.text)
            piece.font = .system(size: 15, weight: run.matched ? .bold : .medium)
            piece.foregroundColor = Color.primary
            s += piece
        }
        return Text(s)
    }
}

/// Large rounded numeral: what the user says.
struct NumeralPill: View {
    var n: Int
    var accent: RGB
    var filled: Bool
    var palette: OverlayPalette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let dark = palette.dark
        Text("\(n)")
            .font(.system(size: n >= 10 ? 15 : 17, weight: .bold, design: .rounded))
            .monospacedDigit()
            .tracking(n >= 10 ? -0.4 : 0)
            .foregroundStyle(filled ? Color.white : accent.color)
            .frame(width: 32, height: 30)
            .background {
                if filled {
                    shape.fill(accent.color)
                } else if dark {
                    // Lit from above, like the glass around it.
                    shape.fill(LinearGradient(colors: [accent.opacity(0.26), accent.opacity(0.12)],
                                              startPoint: .top, endPoint: .bottom))
                } else {
                    // Light glass: a bright pill keeps the amber numeral above 4.5:1 (review U3).
                    shape.fill(Color.white.opacity(0.55))
                }
            }
            .overlay {
                shape.strokeBorder(accent.opacity(palette.highContrast ? 0.85 : (dark ? 0.42 : 0.55)), lineWidth: 0.75)
            }
    }
}

/// Code and type ("WWT · AGIL").
struct BadgeView: View {
    var text: String
    @Environment(\.overlayAccessibility) private var a11y
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(a11y.increaseContrast ? AnyShapeStyle(Color.primary)
                             : OverlayPalette(scheme: scheme).secondaryText(increaseContrast: false))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(a11y.increaseContrast ? 0.35 : 0.10), lineWidth: 0.5))
            .fixedSize()
    }
}

struct MarkerIcon: View {
    var marker: RowMarker
    var palette: OverlayPalette

    var body: some View {
        Image(systemName: marker.symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var color: AnyShapeStyle {
        switch marker {
        case .favorite: return AnyShapeStyle(palette.dark ? Color(red: 1.0, green: 0.80, blue: 0.20) : Color(red: 0.86, green: 0.58, blue: 0.0))
        // Completed is information, not "correct": neutral like the other markers.
        case .mine, .recent, .completed: return AnyShapeStyle(.secondary)
        }
    }
}

struct ChoiceFooterView: View {
    var footer: ChoiceFooterState
    var palette: OverlayPalette
    var text: OverlayText = .de
    @Environment(\.overlayAccessibility) private var a11y

    var body: some View {
        let accent = palette.accent(.choices)
        let secondary = palette.secondaryText(increaseContrast: a11y.increaseContrast)
        let hintStyle = footer.hintIsAlert ? AnyShapeStyle(accent.color)
            : footer.hintIsLive ? AnyShapeStyle(Color.primary.opacity(palette.volatileOpacity + 0.1)) : secondary
        HStack(spacing: 8) {
            // The icon in the numeral column (32 pt), the hint in the title column (12 pt gap, as in the rows).
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: footer.hintIsAlert ? "exclamationmark.bubble.fill" : "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(footer.hintIsAlert ? AnyShapeStyle(accent.color) : secondary)
                    .frame(width: 32)
                Text(footer.hint)
                    .font(.system(size: 13, weight: footer.hintIsAlert ? .semibold : .regular))
                    .foregroundStyle(hintStyle)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if footer.pageCount > 1 {
                PageDots(page: footer.page, count: footer.pageCount, accent: accent)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text.a11yPage(footer.page + 1, of: footer.pageCount))
                if let more = footer.moreText {
                    Text(more)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }
}

struct PageDots: View {
    var page: Int
    var count: Int
    var accent: RGB

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<min(count, 6), id: \.self) { i in
                Capsule()
                    .fill(i == page ? AnyShapeStyle(accent.color) : AnyShapeStyle(Color.primary.opacity(0.22)))
                    .frame(width: i == page ? 14 : 6, height: 6)
            }
        }
    }
}

/// Press feedback without the system button chrome.
struct RowPressStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
