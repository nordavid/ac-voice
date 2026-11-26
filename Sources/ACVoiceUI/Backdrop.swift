import AppKit
import SwiftUI

/// How the live card background is drawn.
public enum OverlayBackdrop: String, Sendable, CaseIterable {
    /// macOS 26 Liquid Glass: `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))`. Default.
    case liquidGlass
    /// Liquid Glass through AppKit (`NSGlassEffectView`, the packaging spike's setup). For the case that SwiftUI
    /// glass does not pick up the content behind the panel.
    case appKitGlass
    /// Fallback: `NSVisualEffectView` with the `.hudWindow` material, forced active (the app never is).
    case hudMaterial
}

/// Card background source: the real window backdrop, or a rendered stand-in for offscreen snapshots (glass and
/// visual effect views need the window server and stay empty in `ImageRenderer`).
enum CardBackground: Equatable {
    case live(OverlayBackdrop)
    case rendered(SnapshotWallpaper)

    var isRendered: Bool {
        if case .rendered = self { return true }
        return false
    }
}

enum OverlayMetrics {
    static let width: CGFloat = 560
    static let cornerRadius: CGFloat = 26
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    /// Transparent margin of the panel around the card: room for the shadow. The panel frame is the card frame
    /// grown by these insets.
    static let insets = EdgeInsets(top: 18, leading: 44, bottom: 60, trailing: 44)
}

struct CardBackdropModifier: ViewModifier {
    var background: CardBackground
    @Environment(\.colorScheme) private var scheme
    @Environment(\.overlayAccessibility) private var a11y

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = OverlayMetrics.shape
        if a11y.reduceTransparency {
            // Reduce Transparency: a solid card, glass or not.
            content.background {
                shape.fill(scheme == .dark ? Color(white: 0.13) : Color(white: 0.97))
            }
        } else {
            switch background {
            case .live(.liquidGlass):
                content.glassEffect(.regular, in: shape)
            case .live(.appKitGlass):
                content.background { GlassEffectBackground().clipShape(shape) }
            case .live(.hudMaterial):
                content.background { VisualEffectBackground().clipShape(shape) }
            case .rendered(let wallpaper):
                content.background { RenderedGlass(wallpaper: wallpaper).clipShape(shape) }
            }
        }
    }
}

/// `NSVisualEffectView(.hudWindow)`, behind-window blending, always active.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        // The app is never active: the default `.followsWindowActiveState` would draw the flat inactive look.
        v.state = .active
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// `NSGlassEffectView` behind the card.
struct GlassEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = NSGlassEffectView()
        v.style = .regular
        v.cornerRadius = OverlayMetrics.cornerRadius
        return v
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

/// Rim light along the card edge. Glass draws its own; the material fallback and rendered backgrounds get this one.
struct CardRim: View {
    var background: CardBackground
    @Environment(\.colorScheme) private var scheme
    @Environment(\.overlayAccessibility) private var a11y

    var body: some View {
        let dark = scheme == .dark
        let shape = OverlayMetrics.shape
        ZStack {
            if background == .live(.hudMaterial) || background.isRendered || a11y.reduceTransparency {
                shape.strokeBorder(
                    LinearGradient(stops: [
                        .init(color: .white.opacity(dark ? 0.30 : 0.95), location: 0),
                        .init(color: .white.opacity(dark ? 0.07 : 0.35), location: 0.45),
                        .init(color: .white.opacity(dark ? 0.16 : 0.70), location: 1),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
                shape.strokeBorder(Color.black.opacity(dark ? 0.35 : 0.06), lineWidth: 0.5).padding(-0.5)
            }
            if a11y.increaseContrast {
                shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Drop shadow drawn in SwiftUI, masked to the outside of the card: it follows the spring height animation
/// frame by frame (a window shadow is cached and would lag), and glass never samples it.
struct CardShadow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let shape = OverlayMetrics.shape
        shape.fill(Color.black)
            .shadow(color: .black.opacity(dark ? 0.42 : 0.20), radius: 24, y: 14)
            .shadow(color: .black.opacity(dark ? 0.30 : 0.10), radius: 2.5, y: 1)
            .mask {
                Rectangle().padding(-90)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Offscreen rendering

/// Wallpaper behind snapshot renders: a desktop gradient with a browser window, light or dark.
public enum SnapshotWallpaper: String, Sendable, CaseIterable {
    case light, dark
}

/// Stand-in for glass in offscreen renders: the wallpaper behind the card, blurred and saturated, under a tint.
struct RenderedGlass: View {
    var wallpaper: SnapshotWallpaper
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        GeometryReader { proxy in
            let f = proxy.frame(in: .named(WallpaperView.space))
            WallpaperView(kind: wallpaper)
                .offset(x: -f.minX, y: -f.minY)
                .blur(radius: 26, opaque: true)
                .saturation(1.5)
        }
        .overlay(dark ? Color(red: 0.07, green: 0.075, blue: 0.10).opacity(0.62) : Color.white.opacity(0.60))
        .overlay(
            LinearGradient(colors: [.white.opacity(dark ? 0.06 : 0.25), .clear], startPoint: .top, endPoint: .center)
        )
    }
}

/// Representative desktop: gradient wallpaper with soft color fields and a browser window that reaches under the
/// card, so the snapshot shows the hard case (text over busy content).
struct WallpaperView: View {
    static let space = "acvoice.wallpaper"
    static let size = CGSize(width: 760, height: 1000)
    var kind: SnapshotWallpaper

    var body: some View {
        Canvas { ctx, size in
            let dark = kind == .dark
            let full = CGRect(origin: .zero, size: size)
            ctx.fill(Path(full), with: .linearGradient(
                Gradient(colors: dark
                    ? [Color(red: 0.04, green: 0.07, blue: 0.17), Color(red: 0.11, green: 0.05, blue: 0.20)]
                    : [Color(red: 0.78, green: 0.87, blue: 1.0), Color(red: 0.99, green: 0.86, blue: 0.80)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            let blobs: [(x: Double, y: Double, r: Double, c: Color)] = dark
                ? [(110, 120, 380, Color(red: 0.0, green: 0.50, blue: 0.62).opacity(0.55)),
                   (690, 190, 360, Color(red: 0.55, green: 0.16, blue: 0.70).opacity(0.55)),
                   (420, 760, 460, Color(red: 0.10, green: 0.22, blue: 0.70).opacity(0.50))]
                : [(120, 150, 380, Color(red: 0.72, green: 0.66, blue: 1.0).opacity(0.85)),
                   (660, 110, 320, Color(red: 0.62, green: 0.95, blue: 0.84).opacity(0.85)),
                   (520, 720, 460, Color(red: 1.0, green: 0.70, blue: 0.62).opacity(0.75))]
            for b in blobs {
                let rect = CGRect(x: b.x - b.r, y: b.y - b.r, width: 2 * b.r, height: 2 * b.r)
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [b.c, b.c.opacity(0)]), center: CGPoint(x: b.x, y: b.y), startRadius: 0, endRadius: b.r))
            }
            drawBrowser(&ctx, dark: dark)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// A browser window with a project page: title bar, tabs, address bar, headings, text lines, a card grid.
    private func drawBrowser(_ ctx: inout GraphicsContext, dark: Bool) {
        let win = CGRect(x: 36, y: 210, width: 690, height: 760)
        let bg = dark ? Color(red: 0.12, green: 0.125, blue: 0.15) : Color(white: 0.995)
        let chrome = dark ? Color(red: 0.17, green: 0.17, blue: 0.20) : Color(white: 0.93)
        let line = dark ? Color(white: 0.30) : Color(white: 0.82)
        let strong = dark ? Color(white: 0.78) : Color(white: 0.22)
        var shadowed = ctx
        shadowed.addFilter(.shadow(color: .black.opacity(dark ? 0.6 : 0.18), radius: 22, y: 10))
        shadowed.fill(Path(roundedRect: win, cornerRadius: 12), with: .color(bg))
        ctx.fill(Path(roundedRect: CGRect(x: win.minX, y: win.minY, width: win.width, height: 74), cornerRadius: 12),
                 with: .color(chrome))
        for (i, c) in [Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                       Color(red: 0.16, green: 0.79, blue: 0.25)].enumerated() {
            ctx.fill(Path(ellipseIn: CGRect(x: win.minX + 16 + Double(i) * 20, y: win.minY + 14, width: 12, height: 12)),
                     with: .color(c))
        }
        ctx.fill(Path(roundedRect: CGRect(x: win.minX + 86, y: win.minY + 8, width: 190, height: 26), cornerRadius: 8),
                 with: .color(bg))
        ctx.fill(Path(roundedRect: CGRect(x: win.minX + 284, y: win.minY + 14, width: 120, height: 12), cornerRadius: 6),
                 with: .color(line.opacity(0.7)))
        ctx.fill(Path(roundedRect: CGRect(x: win.minX + 70, y: win.minY + 42, width: 520, height: 24), cornerRadius: 12),
                 with: .color(bg))
        ctx.fill(Path(roundedRect: CGRect(x: win.minX + 92, y: win.minY + 50, width: 210, height: 8), cornerRadius: 4),
                 with: .color(line))
        // Sidebar.
        let side = CGRect(x: win.minX, y: win.minY + 74, width: 150, height: win.height - 74)
        ctx.fill(Path(side), with: .color(dark ? Color(red: 0.10, green: 0.105, blue: 0.13) : Color(white: 0.965)))
        for i in 0..<9 {
            ctx.fill(Path(roundedRect: CGRect(x: side.minX + 18, y: side.minY + 28 + Double(i) * 30,
                                              width: Double([92, 70, 104, 80, 64, 98, 76, 88, 60][i]), height: 9),
                          cornerRadius: 4.5), with: .color(line))
        }
        // Content: heading, text, task cards.
        let x0 = side.maxX + 30
        ctx.fill(Path(roundedRect: CGRect(x: x0, y: side.minY + 26, width: 260, height: 20), cornerRadius: 6),
                 with: .color(strong))
        for i in 0..<5 {
            ctx.fill(Path(roundedRect: CGRect(x: x0, y: side.minY + 66 + Double(i) * 20,
                                              width: Double([470, 440, 482, 300, 410][i]), height: 8), cornerRadius: 4),
                     with: .color(line))
        }
        let accent = Color(red: 0.13, green: 0.47, blue: 0.95)
        ctx.fill(Path(roundedRect: CGRect(x: x0, y: side.minY + 178, width: 120, height: 30), cornerRadius: 8),
                 with: .color(accent))
        for row in 0..<3 {
            for col in 0..<3 {
                let card = CGRect(x: x0 + Double(col) * 160, y: side.minY + 232 + Double(row) * 128, width: 148, height: 116)
                ctx.fill(Path(roundedRect: card, cornerRadius: 10),
                         with: .color(dark ? Color(red: 0.16, green: 0.165, blue: 0.20) : Color(white: 0.955)))
                ctx.fill(Path(roundedRect: CGRect(x: card.minX + 12, y: card.minY + 14, width: 96, height: 9), cornerRadius: 4),
                         with: .color(strong.opacity(0.8)))
                for l in 0..<3 {
                    ctx.fill(Path(roundedRect: CGRect(x: card.minX + 12, y: card.minY + 38 + Double(l) * 16,
                                                      width: Double([118, 100, 70][l]), height: 7), cornerRadius: 3.5),
                             with: .color(line))
                }
                let tag = [Color(red: 0.95, green: 0.55, blue: 0.20), Color(red: 0.30, green: 0.75, blue: 0.45),
                           Color(red: 0.55, green: 0.45, blue: 0.95)][(row + col) % 3]
                ctx.fill(Path(roundedRect: CGRect(x: card.minX + 12, y: card.maxY - 24, width: 42, height: 12), cornerRadius: 6),
                         with: .color(tag.opacity(0.85)))
            }
        }
    }
}
