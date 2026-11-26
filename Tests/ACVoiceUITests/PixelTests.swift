import CoreGraphics
import Foundation
import Testing
import ACVoiceCore
import ACVoiceFlow
@testable import ACVoiceUI

/// Pixel checks on offscreen renders (ImageRenderer only, no window). Scale 1: one pixel per point. The snapshot
/// scene puts the card 48 pt from the left and 40 pt from the top, with 64 pt of wallpaper below it.
@MainActor
@Suite struct PixelTests {
    struct Bitmap {
        let width: Int, height: Int
        let data: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var buf = [UInt8](repeating: 0, count: width * height * 4)
            buf.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            data = buf
        }

        /// RGB 0...255 at `x`, `y` (from the top).
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }

        /// Median color of a square patch, per channel.
        func median(_ x: Int, _ y: Int, radius: Int = 4) -> (Double, Double, Double) {
            var r: [Int] = [], g: [Int] = [], b: [Int] = []
            for yy in (y - radius)...(y + radius) {
                for xx in (x - radius)...(x + radius) {
                    let p = pixel(xx, yy)
                    r.append(p.0); g.append(p.1); b.append(p.2)
                }
            }
            func m(_ v: [Int]) -> Double { Double(v.sorted()[v.count / 2]) / 255 }
            return (m(r), m(g), m(b))
        }
    }

    static func render(_ model: OverlayModel, _ wallpaper: SnapshotWallpaper, now: Date) throws -> Bitmap {
        Bitmap(try #require(OverlaySnapshot.image(model, wallpaper: wallpaper, now: now, scale: 1)))
    }

    static func model(_ phase: FlowPhase, _ edit: (inout OverlayModel) -> Void) -> OverlayModel {
        var m = OverlayModel()
        m.seq = 1
        m.phase = phase
        m.visible = true
        m.since = OverlayGallery.reference
        edit(&m)
        return m
    }

    /// Review U1: the orb's ambient glow (a 300 pt gradient) leaked below every compact card as a tinted band with a
    /// hard left edge. Two compact cards of different tones and the same size must leave the wallpaper below them
    /// alike, while the glow inside the cards differs.
    @Test func ambientGlowStaysInsideTheCard() throws {
        let t = OverlayGallery.reference.addingTimeInterval(0.5)
        let success = Self.model(.success) { $0.message = "WWT: Website Relaunch" }
        let error = Self.model(.error) {
            $0.message = "WWT: Website Relaunch"
            $0.transcript = Transcript(stable: "Öffne WWT")
        }
        for wallpaper in SnapshotWallpaper.allCases {
            let a = try Self.render(success, wallpaper, now: t), b = try Self.render(error, wallpaper, now: t)
            #expect(a.height == b.height, "\(wallpaper): same card size")
            let cardBottom = a.height - 64
            var below = 0
            for y in stride(from: cardBottom + 6, to: a.height - 4, by: 8) {
                for x in [60, 140, 300, 520] {
                    let p = a.pixel(x, y), q = b.pixel(x, y)
                    below = max(below, abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2))
                }
            }
            #expect(below <= 3, "\(wallpaper): tone shows below the card (max channel difference \(below))")
            // Sensitivity: inside the card, next to the orb, the tones differ.
            let p = a.pixel(48 + 110, 40 + 80), q = b.pixel(48 + 110, 40 + 80)
            #expect(max(abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2)) > 8, "\(wallpaper): no glow inside the card")
        }
    }

    // MARK: Contrast

    static func luminance(_ c: (Double, Double, Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    static func ratio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func over(_ fg: (Double, Double, Double), alpha: Double, _ bg: (Double, Double, Double)) -> (Double, Double, Double) {
        (fg.0 * alpha + bg.0 * (1 - alpha), fg.1 * alpha + bg.1 * (1 - alpha), fg.2 * alpha + bg.2 * (1 - alpha))
    }

    /// Review U3: small text (13-17 pt) needs 4.5:1 (WCAG AA). The background is the rendered glass stand-in of the
    /// list card, sampled next to the question line; real Liquid Glass depends on what lies behind it (manual check).
    @Test func smallTextKeepsAAContrastOnTheGlass() throws {
        let s = try #require(OverlayGallery.scenarios().first { $0.name == "choices" })
        for wallpaper in SnapshotWallpaper.allCases {
            let bitmap = try Self.render(s.model, wallpaper, now: s.now)
            let bg = bitmap.median(48 + 470, 40 + 64)
            let dark = wallpaper == .dark
            for contrast in [false, true] {
                let palette = OverlayPalette(scheme: dark ? .dark : .light, highContrast: contrast)
                for tone in OverlayTone.allCases {
                    let c = palette.accent(tone)
                    let r = Self.ratio((c.r, c.g, c.b), bg)
                    #expect(r >= 4.5, "\(wallpaper) \(tone) contrast \(contrast): \(r)")
                }
                // The speakable numeral on its pill: amber on a bright pill (light), on a tinted one (dark).
                let amber = palette.accent(.choices)
                let pill = dark ? Self.over((amber.r, amber.g, amber.b), alpha: 0.26, bg)
                    : Self.over((1, 1, 1), alpha: 0.55, bg)
                #expect(Self.ratio((amber.r, amber.g, amber.b), pill) >= 4.5, "\(wallpaper) numeral pill contrast \(contrast)")
                // Footer, badge and status lines: the primary color at `secondaryOpacity` (light, Increase Contrast).
                if !dark || contrast {
                    let ink: (Double, Double, Double) = dark ? (1, 1, 1) : (0, 0, 0)
                    let text = Self.over(ink, alpha: palette.secondaryOpacity, bg)
                    #expect(Self.ratio(text, bg) >= 4.5, "\(wallpaper) secondary text contrast \(contrast)")
                }
            }
        }
    }
}
