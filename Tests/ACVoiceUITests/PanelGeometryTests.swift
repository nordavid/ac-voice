import CoreGraphics
import Testing
@testable import ACVoiceUI

/// Placement on single and multiple screens. Frames in AppKit global coordinates (y up).
@Suite struct PanelGeometryTests {
    // MacBook Pro 14": 1512 x 982 points, menu bar 38 pt.
    static let laptop = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944))
    // 27" display to the right, its bottom 200 pt lower, Dock at its bottom (70 pt), menu bar 25 pt.
    static let external = ScreenInfo(frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                                     visibleFrame: CGRect(x: 1512, y: -130, width: 2560, height: 1345))
    // A display above the laptop.
    static let above = ScreenInfo(frame: CGRect(x: -200, y: 982, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: -200, y: 982, width: 1920, height: 1055))
    // A display to the left (negative x).
    static let left = ScreenInfo(frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
                                 visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 875))
    static let card = CGSize(width: 560, height: 92)

    @Test func singleScreenCentersWithTopAtAQuarter() {
        let f = PanelGeometry.cardFrame(size: Self.card, visibleFrame: Self.laptop.visibleFrame)
        #expect(f.width == 560 && f.height == 92)
        #expect(f.midX == Self.laptop.visibleFrame.midX)
        let expectedTop: CGFloat = 944 - 236   // 25 % of 944 below the visible top
        #expect(f.maxY == expectedTop)
        #expect(Self.laptop.visibleFrame.contains(f))
    }

    @Test func growsDownwardWithTheTopPinned() {
        let vf = Self.laptop.visibleFrame
        let small = PanelGeometry.cardFrame(size: Self.card, visibleFrame: vf)
        let tall = PanelGeometry.cardFrame(size: CGSize(width: 560, height: 430), visibleFrame: vf)
        #expect(small.maxY == tall.maxY)
        #expect(tall.minY == small.minY - (430 - 92))
        #expect(small.minX == tall.minX)
    }

    @Test func panelFrameAddsTheShadowInsets() {
        let card = CGRect(x: 476, y: 616, width: 560, height: 92)
        let insets = PanelInsets(top: 18, left: 44, bottom: 60, right: 44)
        let panel = PanelGeometry.panelFrame(card: card, insets: insets)
        #expect(panel == CGRect(x: 432, y: 556, width: 648, height: 170))
        #expect(panel.maxY - card.maxY == 18)
        let onScreen = PanelGeometry.panelFrame(cardSize: Self.card, on: Self.laptop, insets: insets)
        #expect(onScreen == PanelGeometry.panelFrame(
            card: PanelGeometry.cardFrame(size: Self.card, visibleFrame: Self.laptop.visibleFrame), insets: insets))
    }

    @Test func tallCardStaysOnScreen() {
        let vf = CGRect(x: 0, y: 0, width: 1280, height: 600)
        let f = PanelGeometry.cardFrame(size: CGSize(width: 560, height: 520), visibleFrame: vf)
        #expect(f.minY >= vf.minY + PanelGeometry.margin)
        #expect(f.maxY <= vf.maxY - PanelGeometry.margin)
        #expect(f.height == 520)
        // Taller than the screen: cut to the visible height, top at the margin.
        let huge = PanelGeometry.cardFrame(size: CGSize(width: 560, height: 900), visibleFrame: vf)
        #expect(huge.height == 600 - 2 * PanelGeometry.margin)
        #expect(huge.maxY == vf.maxY - PanelGeometry.margin)
        #expect(huge.minY == vf.minY + PanelGeometry.margin)
    }

    @Test func picksTheScreenUnderTheMouse() {
        let screens = [Self.laptop, Self.external, Self.above, Self.left]
        #expect(PanelGeometry.screen(containing: CGPoint(x: 700, y: 400), in: screens) == Self.laptop)
        #expect(PanelGeometry.screen(containing: CGPoint(x: 2500, y: -150), in: screens) == Self.external)
        #expect(PanelGeometry.screen(containing: CGPoint(x: 100, y: 1500), in: screens) == Self.above)
        #expect(PanelGeometry.screen(containing: CGPoint(x: -700, y: 300), in: screens) == Self.left)
    }

    @Test func sharedEdgeBelongsToTheScreenItEnters() {
        let screens = [Self.laptop, Self.external]
        #expect(PanelGeometry.screen(containing: CGPoint(x: 1512, y: 500), in: screens) == Self.external)
        #expect(PanelGeometry.screen(containing: CGPoint(x: 1511.5, y: 500), in: screens) == Self.laptop)
        // Bottom edge of the display above is the top edge of the laptop.
        #expect(PanelGeometry.screen(containing: CGPoint(x: 300, y: 982), in: [Self.laptop, Self.above]) == Self.above)
    }

    @Test func pointerOffEveryScreenUsesTheNearest() {
        let screens = [Self.laptop, Self.external]
        // NSEvent.mouseLocation can sit on the outer top edge (y == maxY).
        #expect(PanelGeometry.screen(containing: CGPoint(x: 300, y: 982), in: screens) == Self.laptop)
        #expect(PanelGeometry.screen(containing: CGPoint(x: 4072, y: 600), in: screens) == Self.external)
        #expect(PanelGeometry.screen(containing: .zero, in: []) == nil)
    }

    @Test func secondScreenPlacement() {
        let f = PanelGeometry.cardFrame(size: Self.card, visibleFrame: Self.external.visibleFrame)
        #expect(f.midX == Self.external.visibleFrame.midX)
        #expect(f.maxY == Self.external.visibleFrame.maxY - (1345 * 0.25).rounded())
        #expect(Self.external.visibleFrame.contains(f))
        let l = PanelGeometry.cardFrame(size: Self.card, visibleFrame: Self.left.visibleFrame)
        #expect(l.midX == Self.left.visibleFrame.midX && l.minX < 0)
    }

    @Test func resizeGrowsNowAndShrinksLater() {
        let small = PanelGeometry.panelFrame(cardSize: Self.card, on: Self.laptop)
        let tall = PanelGeometry.panelFrame(cardSize: CGSize(width: 560, height: 400), on: Self.laptop)
        // First placement: at once.
        #expect(PanelGeometry.resizePlan(current: nil, target: small) == (small, nil))
        // Grow: at once, so the spring has room.
        #expect(PanelGeometry.resizePlan(current: small, target: tall) == (tall, nil))
        // Shrink: keep the tall frame until the spring settled.
        let shrink = PanelGeometry.resizePlan(current: tall, target: small)
        #expect(shrink.now == tall && shrink.later == small)
        // Another screen: at once.
        let other = PanelGeometry.panelFrame(cardSize: Self.card, on: Self.external)
        #expect(PanelGeometry.resizePlan(current: tall, target: other) == (other, nil))
        #expect(PanelGeometry.resizePlan(current: small, target: small) == (small, nil))
    }
}
