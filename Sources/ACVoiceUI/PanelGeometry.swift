import CoreGraphics

/// A screen as AppKit reports it (global coordinates, y up, origin at the bottom left of the main screen).
public struct ScreenInfo: Sendable, Equatable {
    public var frame: CGRect
    /// Without menu bar and Dock.
    public var visibleFrame: CGRect
    public init(frame: CGRect, visibleFrame: CGRect) { self.frame = frame; self.visibleFrame = visibleFrame }
}

/// Edge insets in points (AppKit naming: bottom is the lower edge).
public struct PanelInsets: Sendable, Equatable {
    public var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}

/// Where the panel goes. Pure functions on frames, so placement is testable for any screen setup.
public enum PanelGeometry {
    /// The card's top edge sits this share of the visible height below the top of the visible frame.
    public static let topFraction: CGFloat = 0.25
    /// Minimum distance between the card and the visible frame edges when the card is very tall.
    public static let margin: CGFloat = 8
    /// The panel's transparent margin around the card (room for the SwiftUI shadow).
    public static let insets = PanelInsets(top: OverlayMetrics.insets.top, left: OverlayMetrics.insets.leading,
                                           bottom: OverlayMetrics.insets.bottom, right: OverlayMetrics.insets.trailing)

    /// The screen under the mouse. A point on a shared edge belongs to the screen it enters (half-open frames).
    /// Off every screen (pointer on an outer edge): the nearest one. No screens: nil.
    public static func screen(containing p: CGPoint, in screens: [ScreenInfo]) -> ScreenInfo? {
        if let hit = screens.first(where: { p.x >= $0.frame.minX && p.x < $0.frame.maxX && p.y >= $0.frame.minY && p.y < $0.frame.maxY }) {
            return hit
        }
        return screens.min { distance(p, $0.frame) < distance(p, $1.frame) }
    }

    /// Card frame for a card of `size`: horizontally centered on the visible frame, top edge at `topFraction`.
    /// A card too tall for the space below moves up so its bottom stays `margin` inside the visible frame; it never
    /// rises above the visible top and gets cut to the visible height at most.
    public static func cardFrame(size: CGSize, visibleFrame vf: CGRect) -> CGRect {
        let height = min(size.height, max(0, vf.height - 2 * margin))
        var top = vf.maxY - (vf.height * topFraction).rounded()
        if top - height < vf.minY + margin {
            top = min(vf.maxY - margin, vf.minY + margin + height)
        }
        let x = (vf.midX - size.width / 2).rounded()
        return CGRect(x: x, y: (top - height).rounded(), width: size.width, height: height)
    }

    /// Panel frame: the card frame grown by the shadow insets.
    public static func panelFrame(card: CGRect, insets: PanelInsets = insets) -> CGRect {
        CGRect(x: card.minX - insets.left, y: card.minY - insets.bottom,
               width: card.width + insets.left + insets.right, height: card.height + insets.top + insets.bottom)
    }

    /// Panel frame for a card of `size` on `screen`.
    public static func panelFrame(cardSize: CGSize, on screen: ScreenInfo, insets: PanelInsets = insets) -> CGRect {
        panelFrame(card: cardFrame(size: cardSize, visibleFrame: screen.visibleFrame), insets: insets)
    }

    /// How to move from `current` to `target`. Growing (or moving) applies at once, so the spring has room below;
    /// shrinking keeps the current frame and applies `target` later, once the card stopped animating. The top edge
    /// stays put either way.
    public static func resizePlan(current: CGRect?, target: CGRect) -> (now: CGRect, later: CGRect?) {
        guard let current, current != target else { return (target, nil) }
        let sameTop = abs(current.maxY - target.maxY) < 0.5
        let sameX = abs(current.minX - target.minX) < 0.5 && abs(current.width - target.width) < 0.5
        if sameTop, sameX, target.height < current.height { return (current, target) }
        return (target, nil)
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
