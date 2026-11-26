import SwiftUI

/// Accessibility settings the overlay honours. Live: read from the system environment. Snapshots and tests: set
/// explicitly (the system keys are read-only in SwiftUI).
public struct OverlayAccessibility: Sendable, Equatable {
    public var reduceMotion: Bool
    public var increaseContrast: Bool
    public var reduceTransparency: Bool

    public init(reduceMotion: Bool = false, increaseContrast: Bool = false, reduceTransparency: Bool = false) {
        self.reduceMotion = reduceMotion; self.increaseContrast = increaseContrast; self.reduceTransparency = reduceTransparency
    }
}

struct OverlayAccessibilityKey: EnvironmentKey {
    static let defaultValue = OverlayAccessibility()
}

extension EnvironmentValues {
    var overlayAccessibility: OverlayAccessibility {
        get { self[OverlayAccessibilityKey.self] }
        set { self[OverlayAccessibilityKey.self] = newValue }
    }
}

/// Plain RGB triple, so colors stay `Sendable` and testable.
struct RGB: Sendable, Equatable {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    var color: Color { Color(red: r, green: g, blue: b) }
    func opacity(_ a: Double) -> Color { Color(red: r, green: g, blue: b).opacity(a) }
}

/// Orb colors for one tone: bright body, deep rim, glow, and the stroke color of rings on dark glass.
struct OrbColors: Sendable, Equatable {
    var body: RGB
    var deep: RGB
    var glow: RGB
    var ring: RGB

    init(body: RGB, deep: RGB, glow: RGB, ring: RGB? = nil) {
        self.body = body; self.deep = deep; self.glow = glow; self.ring = ring ?? body
    }
}

/// Tone colors per color scheme. Dark: luminous neon on dark glass. Light: deeper, more saturated hues so 13-17 pt
/// text keeps at least 4.5:1 (WCAG AA) against light glass (review U3, `ContrastTests`).
struct OverlayPalette: Sendable, Equatable {
    var dark: Bool
    var highContrast: Bool

    init(scheme: ColorScheme, highContrast: Bool = false) {
        dark = scheme == .dark
        self.highContrast = highContrast
    }

    /// Accent for text and lines.
    func accent(_ tone: OverlayTone) -> RGB {
        switch (tone, dark) {
        case (.listening, true), (.warming, true): return highContrast ? RGB(0.55, 0.92, 1.0) : RGB(0.40, 0.86, 1.0)
        case (.listening, false), (.warming, false): return highContrast ? RGB(0.0, 0.32, 0.58) : RGB(0.0, 0.38, 0.66)
        case (.processing, true): return highContrast ? RGB(0.82, 0.72, 1.0) : RGB(0.74, 0.62, 1.0)
        case (.processing, false): return highContrast ? RGB(0.30, 0.14, 0.70) : RGB(0.40, 0.24, 0.84)
        case (.choices, true): return highContrast ? RGB(1.0, 0.84, 0.48) : RGB(1.0, 0.76, 0.32)
        case (.choices, false): return highContrast ? RGB(0.52, 0.27, 0.0) : RGB(0.62, 0.31, 0.0)
        case (.success, true): return highContrast ? RGB(0.55, 1.0, 0.70) : RGB(0.42, 0.92, 0.60)
        case (.success, false): return highContrast ? RGB(0.0, 0.38, 0.16) : RGB(0.0, 0.42, 0.20)
        case (.error, true): return highContrast ? RGB(1.0, 0.62, 0.60) : RGB(1.0, 0.50, 0.47)
        case (.error, false): return highContrast ? RGB(0.62, 0.05, 0.08) : RGB(0.78, 0.13, 0.14)
        }
    }

    func orb(_ tone: OverlayTone) -> OrbColors {
        switch tone {
        case .listening, .warming:
            return OrbColors(body: RGB(0.42, 0.90, 1.0), deep: RGB(0.0, 0.42, 0.86), glow: RGB(0.18, 0.78, 1.0))
        case .processing:
            return OrbColors(body: RGB(0.78, 0.64, 1.0), deep: RGB(0.36, 0.16, 0.86), glow: RGB(0.58, 0.40, 1.0))
        case .choices:
            return OrbColors(body: RGB(1.0, 0.78, 0.34), deep: RGB(0.90, 0.40, 0.0), glow: RGB(1.0, 0.58, 0.10),
                             ring: RGB(1.0, 0.66, 0.20))
        case .success:
            return OrbColors(body: RGB(0.50, 0.95, 0.64), deep: RGB(0.0, 0.56, 0.28), glow: RGB(0.20, 0.86, 0.46))
        case .error:
            return OrbColors(body: RGB(1.0, 0.55, 0.50), deep: RGB(0.80, 0.08, 0.12), glow: RGB(1.0, 0.30, 0.28))
        }
    }

    /// Strength of the tone glow that the orb casts onto the glass.
    var ambientGlow: Double { dark ? 0.20 : 0.12 }

    /// Dim volatile transcript tail.
    var volatileOpacity: Double { highContrast ? 0.68 : (dark ? 0.46 : 0.42) }

    /// Opacity of the primary color for small secondary text (footer, badge, status lines). Light glass needs more
    /// than the system's secondary style for 4.5:1.
    var secondaryOpacity: Double { highContrast ? 0.85 : (dark ? 0.62 : 0.66) }

    /// Small secondary text. Dark keeps the system's vibrant secondary style.
    func secondaryText(increaseContrast: Bool) -> AnyShapeStyle {
        if increaseContrast || !dark { return AnyShapeStyle(Color.primary.opacity(secondaryOpacity)) }
        return AnyShapeStyle(.secondary)
    }
}
