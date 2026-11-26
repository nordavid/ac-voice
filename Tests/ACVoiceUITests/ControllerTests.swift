import AppKit
import Foundation
import SwiftUI
import Testing
import ACVoiceCore
import ACVoiceFlow
@testable import ACVoiceUI

/// Records what the controller asks of the window. No window exists in these tests.
@MainActor
final class FakeSurface: OverlaySurface {
    var root: OverlayRootView?
    var screens: [ScreenInfo] = [PanelGeometryTests.laptop, PanelGeometryTests.external]
    var mouseLocation = CGPoint(x: 700, y: 500)
    var frame: CGRect?
    var frames: [CGRect] = []
    var layouts = 0
    var fadeIns: [Double] = []
    var fadeOuts: [Double] = []
    var orderOuts = 0
    var pendingFadeOut: (@MainActor @Sendable () -> Void)?

    func attach(_ root: OverlayRootView) { self.root = root }
    func setFrame(_ f: CGRect) { frame = f; frames.append(f) }
    func layoutNow() { layouts += 1 }
    func fadeIn(duration: Double) { fadeIns.append(duration) }
    func fadeOut(duration: Double, completion: @escaping @MainActor @Sendable () -> Void) {
        fadeOuts.append(duration)
        pendingFadeOut = completion
    }
    func orderOut() { orderOuts += 1 }
    var announcements: [String] = []
    func announce(_ text: String) { announcements.append(text) }

    func finishFade() {
        let c = pendingFadeOut
        pendingFadeOut = nil
        c?()
    }
}

@MainActor
@Suite struct ControllerTests {
    static let t0 = ViewStateTests.t0

    static func make() -> (OverlayController, FakeSurface) {
        let surface = FakeSurface()
        let c = OverlayController(surface: surface)
        c.now = { t0 }
        c.reduceMotion = { false }
        return (c, surface)
    }

    static func list(seq: Int, _ items: [ChoiceItem]) -> OverlayModel {
        ViewStateTests.model(.choices, seq: seq) {
            OverlayGallery.list(&$0, items, page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6))
        }
    }

    @Test func attachesTheRootViewAndStartsIdle() {
        let (c, surface) = Self.make()
        #expect(surface.root != nil)
        #expect(!c.isShown)
        #expect(!c.store.running && !c.store.interactive)
        #expect(surface.frames.isEmpty && surface.fadeIns.isEmpty)
    }

    /// The click reports the seq of the snapshot its row was drawn from, not the live one (REVIEW m4).
    @Test func clickCarriesTheSeqOfTheDrawnRow() {
        let (c, _) = Self.make()
        var picks: [(n: Int, seq: Int)] = []
        c.onChoose = { n, seq in picks.append((n, seq)) }
        c.render(Self.list(seq: 5, ViewStateTests.wwt))
        c.show()
        let drawn = c.viewState.rows[1]   // "2" of the first list, drawn from seq 5
        #expect(drawn.n == 2 && drawn.seq == 5)

        // The list narrows and renumbers (seq 7) before the click lands.
        var kept = [ViewStateTests.wwt[2], ViewStateTests.wwt[3]]
        kept[0].n = 1; kept[1].n = 2
        c.render(Self.list(seq: 7, kept))
        #expect(c.viewState.seq == 7)

        c.choose(drawn)
        #expect(picks.count == 1 && picks[0].n == 2 && picks[0].seq == 5)
        c.choose(c.viewState.rows[0])
        #expect(picks.count == 2 && picks[1].n == 1 && picks[1].seq == 7)
    }

    @Test func deadlineOnlyUpdatesKeepRowsButCarryTheNewSeq() {
        let (c, _) = Self.make()
        c.render(Self.list(seq: 5, ViewStateTests.wwt))
        var later = Self.list(seq: 6, ViewStateTests.wwt)
        later.deadline = Self.t0.addingTimeInterval(8)
        c.render(later)
        #expect(c.viewState.rows.map(\.id) == ["p628-1", "p315-2", "p314-3", "p693-4"])
        #expect(c.viewState.rows.allSatisfy { $0.seq == 6 })
        #expect(c.viewState.deadline == Self.t0.addingTimeInterval(8))
    }

    @Test func clicksNeedAVisibleList() {
        let (c, surface) = Self.make()
        var picks = 0
        c.onChoose = { _, _ in picks += 1 }
        c.render(Self.list(seq: 5, ViewStateTests.wwt))
        let row = c.viewState.rows[0]
        c.choose(row)                       // hidden
        #expect(picks == 0)
        c.show()
        c.choose(row)
        #expect(picks == 1)
        // Idle snapshot before the hide: content stays for the fade, clicks stop.
        c.render(OverlayModel())
        #expect(c.viewState.rows.count == 4)
        c.choose(row)
        #expect(picks == 1)
        c.hide(fade: 0.2)
        c.choose(row)
        #expect(picks == 1)
        surface.finishFade()
        // Not a list any more: no pick even when shown.
        c.render(ViewStateTests.model(.processing, seq: 9))
        c.show()
        c.choose(row)
        #expect(picks == 1)
    }

    @Test func dismissForwardsOnlyWhileShown() {
        let (c, _) = Self.make()
        var dismissed = 0
        c.onDismiss = { dismissed += 1 }
        c.render(ViewStateTests.model(.listening) { $0.micReady = true })
        c.dismiss()
        #expect(dismissed == 0)
        c.show()
        c.dismiss()
        #expect(dismissed == 1)
    }

    @Test func showPlacesThePanelOnTheScreenUnderTheMouse() {
        let (c, surface) = Self.make()
        surface.mouseLocation = CGPoint(x: 2600, y: 400)   // external display
        c.render(ViewStateTests.model(.listening) { $0.micReady = true })
        c.show()
        #expect(c.isShown && c.store.running && c.store.interactive)
        #expect(surface.layouts == 1)
        #expect(surface.fadeIns == [OverlayController.fadeIn])
        let expected = PanelGeometry.panelFrame(cardSize: c.cardSize, on: PanelGeometryTests.external)
        #expect(surface.frame == expected)
        // A second show while shown (press during success): no re-placement, the fade-in restarts.
        surface.mouseLocation = CGPoint(x: 100, y: 100)
        c.show()
        #expect(surface.frames.count == 1)
        #expect(surface.fadeIns.count == 2)
    }

    @Test func cardGrowthResizesDownwardAtOnce() {
        let (c, surface) = Self.make()
        c.render(ViewStateTests.model(.listening) { $0.micReady = true })
        c.show()
        #expect(c.cardSize.height == 92)
        let first = surface.frame!
        c.cardSizeChanged(CGSize(width: 560, height: 420))
        let grown = surface.frame!
        #expect(grown.height == first.height + (420 - 92))
        #expect(grown.maxY == first.maxY)
        #expect(grown.minX == first.minX)
        // Shrinking keeps the tall frame for now (the spring is still running).
        c.cardSizeChanged(CGSize(width: 560, height: 92))
        #expect(surface.frame == grown)
    }

    @Test func sizeReportsWhileHiddenWaitForTheNextShow() {
        let (c, surface) = Self.make()
        c.cardSizeChanged(CGSize(width: 560, height: 300))
        #expect(surface.frames.isEmpty)
        c.show()
        #expect(surface.frame == PanelGeometry.panelFrame(cardSize: CGSize(width: 560, height: 300),
                                                          on: PanelGeometryTests.laptop))
    }

    @Test func hidePausesTimelinesAfterTheFade() {
        let (c, surface) = Self.make()
        c.render(ViewStateTests.model(.success) { $0.message = "WWT: Website Relaunch" })
        c.show()
        c.setLevel(0.8)
        c.render(OverlayModel())
        c.hide(fade: 0.2)
        #expect(!c.isShown)
        #expect(surface.fadeOuts == [0.2])
        #expect(c.store.running)            // still fading
        #expect(c.viewState.tone == .success)
        surface.finishFade()
        #expect(surface.orderOuts == 1)
        #expect(!c.store.running)           // TimelineView paused: no idle CPU
        #expect(c.meter.target == 0)
    }

    @Test func showDuringAFadeCancelsTheOrderOut() {
        let (c, surface) = Self.make()
        c.render(ViewStateTests.model(.error) { $0.message = FlowText.de.nothingHeard })
        c.show()
        c.hide(fade: 0.2)
        c.render(ViewStateTests.model(.listening, seq: 9) { $0.micReady = true })
        c.show()
        surface.finishFade()                // the old fade ends late
        #expect(surface.orderOuts == 0)
        #expect(c.isShown && c.store.running)
        #expect(c.viewState.tone == .listening)
    }

    @Test func levelGoesToTheMeterOnlyWhileShown() {
        let (c, _) = Self.make()
        c.setLevel(0.7)
        #expect(c.meter.target == 0)
        c.show()
        c.setLevel(0.7)
        #expect(c.meter.target == 0.7)
        c.setLevel(3)
        #expect(c.meter.target == 1)
        c.setLevel(.nan)
        #expect(c.meter.target == 0)
    }

    @Test func phaseStartFollowsTheLocalClock() {
        let (c, _) = Self.make()
        var clock = Self.t0.addingTimeInterval(100)
        c.now = { clock }
        c.render(ViewStateTests.model(.listening, seq: 1) { $0.micReady = true })
        #expect(c.viewState.phaseStart == clock)
        let start = clock
        clock = clock.addingTimeInterval(1)
        c.render(ViewStateTests.model(.listening, seq: 2) {
            $0.micReady = true
            $0.transcript = Transcript(stable: "Öffne")
        })
        #expect(c.viewState.phaseStart == start)        // same phase: unchanged
        c.render(ViewStateTests.model(.success, seq: 3) { $0.message = "WWT: Website Relaunch" })
        #expect(c.viewState.phaseStart == clock)        // new phase: now
    }

    @Test func settingsReachTheStore() {
        let (c, _) = Self.make()
        c.choicesWindow = 9
        c.backdrop = .hudMaterial
        #expect(c.store.choicesWindow == 9 && c.store.backdrop == .hudMaterial)
        c.choicesWindow = 0
        #expect(c.choicesWindow == 1)
    }
}

/// The real panel's configuration. The panel is created deferred and never ordered in: no window appears.
@MainActor
@Suite struct PanelConfigurationTests {
    @Test func nonActivatingFloatingPanel() {
        let panel = OverlayPanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless) || panel.styleMask == [.nonactivatingPanel])
        #expect(!panel.styleMask.contains(.titled))
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.isOpaque && panel.backgroundColor == .clear)
        #expect(!panel.isVisible)
    }

    @Test func hostingViewTakesTheFirstClick() {
        let view = FirstMouseHostingView(rootView: Text("1"))
        #expect(view.acceptsFirstMouse(for: nil))
    }

    /// Review U4: the pointer on the card holds a list or an error. Reported only while the card takes clicks, as
    /// changes; a hide or an idle snapshot reports `false`.
    @Test func pointerReportsChangesWhileTheCardTakesClicks() throws {
        let (c, surface) = ControllerTests.make()
        var reports: [Bool] = []
        c.onPointer = { reports.append($0) }
        let root = try #require(surface.root)
        c.render(ControllerTests.list(seq: 5, ViewStateTests.wwt))
        root.actions.pointer(true)            // hidden: nothing
        #expect(reports.isEmpty)
        c.show()
        root.actions.pointer(true)
        root.actions.pointer(true)
        #expect(reports == [true])
        root.actions.pointer(false)
        root.actions.pointer(true)
        #expect(reports == [true, false, true])
        c.render(OverlayModel())              // idle snapshot before the fade: no more clicks, no hold
        #expect(reports == [true, false, true, false])
        root.actions.pointer(true)
        #expect(reports.count == 4)
        c.render(ViewStateTests.model(.error, seq: 8) { $0.message = FlowText.de.nothingHeard })
        root.actions.pointer(true)
        #expect(reports.last == true)
        c.hide(fade: 0.2)
        #expect(reports.last == false && !c.pointerInside)
    }

    /// The tracking area hit-tests against the card, not the panel's shadow margin.
    @Test func cardFrameExcludesTheShadowMargin() throws {
        let (c, surface) = ControllerTests.make()
        let frame = try #require(surface.root).actions.cardFrame()
        #expect(frame.minX == OverlayMetrics.insets.leading && frame.minY == OverlayMetrics.insets.top)
        #expect(frame.size == c.cardSize)
    }

    /// Review U8: the panel never gets focus, so VoiceOver hears phase changes as announcements.
    @Test func phaseChangesAreAnnounced() {
        let (c, surface) = ControllerTests.make()
        c.render(ViewStateTests.model(.listening) { $0.micReady = true })
        c.show()
        #expect(surface.announcements.isEmpty)   // listening speaks for itself (earcon)
        c.render(ControllerTests.list(seq: 5, ViewStateTests.wwt))
        #expect(surface.announcements.count == 1 && surface.announcements[0].hasPrefix(OverlayText.de.a11yChoices))
        c.render(ControllerTests.list(seq: 6, ViewStateTests.wwt))   // same phase: no repeat
        #expect(surface.announcements.count == 1)
        c.render(ViewStateTests.model(.error, seq: 7) { $0.message = FlowText.de.nothingHeard; $0.hint = FlowText.de.tryMyTasks })
        #expect(surface.announcements.last == "Fehler. Ich höre nichts. Sag zum Beispiel „Meine Aufgaben“")
    }
}

/// The live view tree (TimelineView clock, glass backdrop) inside a hosting view that has no window.
@MainActor
@Suite struct LiveTreeTests {
    @Test func liveTreeLaysOutAndReportsTheCardSize() throws {
        for backdrop in OverlayBackdrop.allCases {
            let (c, surface) = ControllerTests.make()
            c.backdrop = backdrop
            c.render(ControllerTests.list(seq: 5, ViewStateTests.wwt))
            let root = try #require(surface.root)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(x: 0, y: 0, width: 648, height: 700)
            host.layoutSubtreeIfNeeded()
            // The card reports its size from layout: full width, taller than a header alone.
            #expect(c.cardSize.width == OverlayMetrics.width, "\(backdrop)")
            #expect(c.cardSize.height > 300, "\(backdrop)")
            // Back to one line: the card shrinks to the header.
            c.render(ViewStateTests.model(.listening, seq: 6) { $0.micReady = true })
            host.layoutSubtreeIfNeeded()
            #expect(c.cardSize.height >= 92 && c.cardSize.height < 120, "\(backdrop)")
        }
    }
}
