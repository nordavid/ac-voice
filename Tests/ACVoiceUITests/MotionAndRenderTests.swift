import CoreGraphics
import Foundation
import Testing
import ACVoiceFlow
@testable import ACVoiceUI

/// Reduce Motion: a static orb (no time-driven change), opacity-only level, slow or paused timelines.
@Suite struct ReduceMotionTests {
    static let tones = OverlayTone.allCases

    @Test func reducedOrbIgnoresTime() {
        for tone in Self.tones {
            for elapsed in [0.0, 0.1, 5] {
                let a = OrbMotion.frame(tone: tone, micLive: true, time: 0, elapsed: elapsed, level: 0.4, countdown: 0.5,
                                        reduceMotion: true)
                let b = OrbMotion.frame(tone: tone, micLive: true, time: 1.7, elapsed: elapsed + 0.9, level: 0.4,
                                        countdown: 0.5, reduceMotion: true)
                #expect(a == b, "\(tone)")
            }
        }
    }

    @Test func reducedOrbShowsLevelOnlyAsOpacity() {
        let quiet = OrbMotion.frame(tone: .listening, micLive: true, time: 3, elapsed: 3, level: 0, countdown: nil, reduceMotion: true)
        let loud = OrbMotion.frame(tone: .listening, micLive: true, time: 3, elapsed: 3, level: 1, countdown: nil, reduceMotion: true)
        #expect(quiet.coreRadius == loud.coreRadius)
        #expect(quiet.rings.map(\.radius) == loud.rings.map(\.radius))
        #expect(zip(quiet.rings, loud.rings).allSatisfy { $0.alpha < $1.alpha })
        // No travelling ripples, no rotating arcs.
        #expect(quiet.rings.count == 3)
        let processing = OrbMotion.frame(tone: .processing, micLive: false, time: 2, elapsed: 2, level: 0, countdown: nil,
                                         reduceMotion: true)
        #expect(processing.arcs.count == 1)
        // The success check is complete at once.
        let success = OrbMotion.frame(tone: .success, micLive: false, time: 0, elapsed: 0, level: 0, countdown: nil,
                                      reduceMotion: true)
        #expect(success.glyph == .check(progress: 1))
    }

    @Test func fullMotionMovesWithTime() {
        for tone in [OverlayTone.listening, .warming, .processing] {
            let a = OrbMotion.frame(tone: tone, micLive: true, time: 0.3, elapsed: 0.3, level: 0.5, countdown: nil, reduceMotion: false)
            let b = OrbMotion.frame(tone: tone, micLive: true, time: 1.1, elapsed: 1.1, level: 0.5, countdown: nil, reduceMotion: false)
            #expect(a != b, "\(tone)")
        }
        let loud = OrbMotion.frame(tone: .listening, micLive: true, time: 0, elapsed: 0, level: 1, countdown: nil, reduceMotion: false)
        let quiet = OrbMotion.frame(tone: .listening, micLive: true, time: 0, elapsed: 0, level: 0, countdown: nil, reduceMotion: false)
        #expect(loud.coreRadius > quiet.coreRadius)
        let drawing = OrbMotion.frame(tone: .success, micLive: false, time: 0, elapsed: 0.1, level: 0, countdown: nil, reduceMotion: false)
        if case .check(let p)? = drawing.glyph { #expect(p > 0 && p < 1) } else { Issue.record("no check") }
    }

    @Test func timelineSchedule() {
        for tone in Self.tones {
            let full = OrbMotion.schedule(tone: tone, micLive: true, hasCountdown: true, reduceMotion: false)
            #expect(!full.paused && full.minimumInterval == nil)
        }
        #expect(OrbMotion.schedule(tone: .processing, micLive: false, hasCountdown: false, reduceMotion: true).paused)
        #expect(OrbMotion.schedule(tone: .success, micLive: false, hasCountdown: false, reduceMotion: true).paused)
        #expect(OrbMotion.schedule(tone: .error, micLive: false, hasCountdown: false, reduceMotion: true).paused)
        let listening = OrbMotion.schedule(tone: .listening, micLive: true, hasCountdown: false, reduceMotion: true)
        #expect(!listening.paused && listening.minimumInterval == 0.25)
        #expect(OrbMotion.schedule(tone: .listening, micLive: false, hasCountdown: false, reduceMotion: true).paused)
        let choices = OrbMotion.schedule(tone: .choices, micLive: true, hasCountdown: true, reduceMotion: true)
        #expect(!choices.paused && choices.minimumInterval == 0.25)
    }

    @Test func rowEntranceStagger() {
        #expect(ChoiceListView.stagger(0) == 0)
        #expect(abs(ChoiceListView.stagger(3) - 0.09) < 1e-9)
        #expect(ChoiceListView.stagger(-1) == 0)
    }

    @Test func countdownShare() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(OrbMotion.countdown(deadline: nil, now: now, window: 6) == nil)
        #expect(OrbMotion.countdown(deadline: now.addingTimeInterval(3), now: now, window: 6) == 0.5)
        #expect(OrbMotion.countdown(deadline: now.addingTimeInterval(9), now: now, window: 6) == 1)
        #expect(OrbMotion.countdown(deadline: now.addingTimeInterval(-1), now: now, window: 6) == 0)
        let f = OrbMotion.frame(tone: .choices, micLive: true, time: 0, elapsed: 0, level: 0, countdown: 0.5, reduceMotion: false)
        #expect(f.countdown == 0.5)
    }

    @MainActor
    @Test func levelMeterEasesAndDecays() {
        let m = LevelMeter()
        m.push(1, at: 10)
        #expect(m.value(at: 10) == 0)
        #expect(m.value(at: 10 + LevelMeter.ease) == 1)
        let mid = m.value(at: 10 + LevelMeter.ease / 2)
        #expect(mid > 0.5 && mid < 1)
        #expect(m.value(at: 12) < 0.01)      // no new samples: decays to silence
        m.push(0.2, at: 10.05)
        #expect(m.target == 0.2)
        #expect(LevelMeter.normalized(dB: -80) == 0)
        #expect(LevelMeter.normalized(dB: -12) == 1)
        #expect(abs(LevelMeter.normalized(dB: -36) - 0.5) < 1e-9)
        #expect(LevelMeter.normalized(dB: -.infinity) == 0)
    }

    @Test func controllerAnimationFollowsReduceMotion() {
        #expect(OverlayController.animation(reduceMotion: true) != OverlayController.animation(reduceMotion: false))
    }
}

/// Offscreen renders of every state (ImageRenderer only, no window).
@MainActor
@Suite struct RendererTests {
    @Test func galleryCoversEveryVisiblePhase() {
        let phases = Set(OverlayGallery.scenarios().map(\.model.phase))
        #expect(phases == Set(FlowPhase.allCases).subtracting([.idle]))
        let names = OverlayGallery.scenarios().map(\.name)
        #expect(Set(names).count == names.count)
        for required in ["listening-cold", "listening-partial", "processing-search", "choices", "choices-page2",
                         "choices-narrowed", "choices-unclear", "choices-confirm", "choices-tickets", "retry",
                         "success", "error"] {
            #expect(names.contains(required), "\(required)")
        }
    }

    @Test func everyStateRendersANonEmptyImage() throws {
        for scenario in OverlayGallery.scenarios() {
            for wallpaper in SnapshotWallpaper.allCases {
                let image = try #require(OverlaySnapshot.image(scenario.model, wallpaper: wallpaper, now: scenario.now,
                                                               level: scenario.level),
                                         "\(scenario.name)-\(wallpaper)")
                #expect(image.width == Int((OverlayMetrics.width + 96) * 2), "\(scenario.name)")
                #expect(image.height >= 2 * (92 + 104), "\(scenario.name)")
                #expect(Self.distinctColors(image) > 50, "\(scenario.name)-\(wallpaper)")
            }
        }
    }

    @Test func listStatesAreTallerThanSingleLineStates() throws {
        let scenarios = Dictionary(uniqueKeysWithValues: OverlayGallery.scenarios().map { ($0.name, $0) })
        func height(_ name: String) throws -> Int {
            let s = try #require(scenarios[name])
            return try #require(OverlaySnapshot.image(s.model, wallpaper: .light, now: s.now, scale: 1)).height
        }
        #expect(try height("choices") > height("listening-partial") + 150)
        #expect(try height("choices-page2") > height("choices"))
    }

    @Test func accessibilityVariantsRender() throws {
        let s = OverlayGallery.scenarios().first { $0.name == "choices" }!
        for a11y in [OverlayAccessibility(increaseContrast: true), OverlayAccessibility(reduceTransparency: true),
                     OverlayAccessibility(reduceMotion: true)] {
            let image = try #require(OverlaySnapshot.image(s.model, wallpaper: .dark, now: s.now, accessibility: a11y, scale: 1))
            #expect(Self.distinctColors(image) > 50)
        }
        let light = try #require(OverlaySnapshot.image(s.model, wallpaper: .light, now: s.now, scale: 1))
        let png = try #require(OverlaySnapshot.png(light))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func renderAllWritesOneFilePerStateAndWallpaper() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acvoice-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scenarios = Array(OverlayGallery.scenarios().prefix(2))
        let urls = try OverlaySnapshot.renderAll(to: dir, scenarios: scenarios, scale: 1)
        #expect(urls.map(\.lastPathComponent) == ["listening-ready-light.png", "listening-ready-dark.png",
                                                   "listening-starting-light.png", "listening-starting-dark.png"])
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// Distinct colors in a coarse sample: a blank or single-color image has very few.
    static func distinctColors(_ image: CGImage) -> Int {
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var seen = Set<UInt32>()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            seen.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
        }
        return seen.count
    }
}
