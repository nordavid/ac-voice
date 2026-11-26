import Foundation

/// One drawn frame of the orb, in points on an `OrbMotion.canvas` square. Pure data, so the animation math is
/// testable (Reduce Motion, countdown, level) without rendering.
struct OrbFrame: Sendable, Equatable {
    struct Ring: Sendable, Equatable {
        var radius: Double
        var width: Double
        var alpha: Double
        /// Dash pattern (on, off) in points; nil draws a solid ring.
        var dash: [Double]? = nil
        /// Degrees, clockwise from 12 o'clock; moves the dash pattern.
        var rotation: Double = 0
    }

    /// A comet arc: bright head at `start + sweep`, tail fading towards `start`.
    struct Arc: Sendable, Equatable {
        var radius: Double
        /// Degrees, clockwise from 12 o'clock.
        var start: Double
        var sweep: Double
        var width: Double
        var alpha: Double
    }

    /// A thin bright arc inside the core; `radius` is a share of the core radius.
    struct Filament: Sendable, Equatable {
        var radius: Double
        var start: Double
        var sweep: Double
        var alpha: Double
    }

    enum Glyph: Sendable, Equatable {
        /// Check mark drawn up to `progress` (0...1).
        case check(progress: Double)
        case exclamation
    }

    var coreRadius: Double
    /// 0...1 overall strength; < 1 dims the orb (mic not hot, model loading).
    var intensity: Double
    var rings: [Ring] = []
    var arcs: [Arc] = []
    var filaments: [Filament] = []
    /// Remaining share of the choices window (1 = full ring).
    var countdown: Double?
    var glyph: Glyph?
}

/// Orb animation math. `time` is a continuous clock in seconds (rotation, breathing); `elapsed` counts from the
/// phase start (one-shot effects); `level` is the smoothed mic level 0...1.
enum OrbMotion {
    /// Canvas side in points. The layout slot is smaller (`slot`); the glow bleeds into the padding.
    static let canvas = 92.0
    static let slot = 60.0
    /// Radius of the choices countdown ring.
    static let countdownRadius = 24.5

    /// Seconds of the breathing cycle.
    static let breathPeriod = 3.4

    static func frame(tone: OverlayTone, micLive: Bool, time: Double, elapsed: Double, level rawLevel: Double,
                      countdown: Double?, reduceMotion: Bool) -> OrbFrame {
        let level = min(max(rawLevel, 0), 1)
        // Reduce Motion: no time-driven movement at all. Level and countdown still show, as opacity and progress.
        let t = reduceMotion ? 0 : time
        let e = reduceMotion ? 10 : max(0, elapsed)
        let breath = reduceMotion ? 0 : sin(t * 2 * .pi / breathPeriod)
        let grow = reduceMotion ? 0 : level

        switch tone {
        case .listening, .warming:
            let hot = micLive
            let intensity = tone == .warming ? 0.5 : (hot ? 1 : 0.55)
            var f = OrbFrame(coreRadius: 13.5 * (1 + 0.035 * breath + 0.26 * grow), intensity: intensity)
            let react = hot ? 0.45 + 0.55 * level : 0.45
            let base: [(r: Double, a: Double)] = [(19, 0.62), (23.5, 0.38), (28, 0.20)]
            for (i, ring) in base.enumerated() {
                f.rings.append(.init(radius: ring.r + grow * (1.5 + Double(i) * 1.2), width: 1.2, alpha: ring.a * react))
            }
            if hot, !reduceMotion {
                // Sonar ripples: two thin rings travel outwards and fade; louder speech makes them brighter.
                for k in 0..<2 {
                    let p = (t / 2.4 + Double(k) / 2).truncatingRemainder(dividingBy: 1)
                    f.rings.append(.init(radius: 15 + p * 21, width: 1.0, alpha: (1 - p) * (1 - p) * (0.18 + 0.6 * level)))
                }
            }
            if tone == .warming {
                f.rings.append(.init(radius: 32, width: 1.3, alpha: 0.8, dash: [2.5, 4.5], rotation: t * 36))
            }
            f.filaments = filaments(t: t, alpha: hot ? 0.30 + 0.35 * level : 0.22)
            return f

        case .processing:
            var f = OrbFrame(coreRadius: 13 * (1 + 0.045 * sin(t * 2 * .pi / 1.3)), intensity: 1)
            f.rings.append(.init(radius: 22, width: 2, alpha: 0.16))
            f.arcs.append(.init(radius: 22, start: reduceMotion ? 300 : (t * 290).truncatingRemainder(dividingBy: 360),
                                sweep: 130, width: 3, alpha: 1))
            if !reduceMotion {
                f.arcs.append(.init(radius: 27.5, start: (180 - t * 170).truncatingRemainder(dividingBy: 360),
                                    sweep: 70, width: 1.6, alpha: 0.6))
            }
            f.filaments = filaments(t: t * 2.2, alpha: 0.45)
            return f

        case .choices:
            var f = OrbFrame(coreRadius: 13.5 * (1 + 0.03 * breath + 0.18 * grow), intensity: 1)
            f.rings.append(.init(radius: 18.5, width: 1.1, alpha: 0.32 * (0.6 + 0.4 * level)))
            f.rings.append(.init(radius: countdownRadius, width: 3.2, alpha: 0.17))
            f.countdown = countdown.map { min(max($0, 0), 1) }
            f.filaments = filaments(t: t, alpha: 0.25 + 0.3 * level)
            return f

        case .success:
            let pop = reduceMotion ? 0 : sin(min(1, e / 0.32) * .pi) * 0.14
            var f = OrbFrame(coreRadius: 15 * (1 + pop), intensity: 1)
            f.rings.append(.init(radius: 22, width: 1.5, alpha: 0.34))
            let q = min(1, e / 0.7)
            if !reduceMotion, q < 1 {
                f.rings.append(.init(radius: 17 + q * 20, width: 2 * (1 - q) + 0.5, alpha: (1 - q) * 0.7))
            }
            f.glyph = .check(progress: reduceMotion ? 1 : min(1, max(0, (e - 0.05) / 0.3)))
            return f

        case .error:
            var f = OrbFrame(coreRadius: 15 * (1 + 0.025 * sin(t * 2 * .pi / 1.8)), intensity: 1)
            f.rings.append(.init(radius: 22, width: 1.5, alpha: 0.36))
            f.rings.append(.init(radius: 27.5, width: 1, alpha: 0.16))
            f.glyph = .exclamation
            return f
        }
    }

    /// Two thin arcs circling inside the core at different speeds: the "plasma" detail.
    static func filaments(t: Double, alpha: Double) -> [OrbFrame.Filament] {
        [OrbFrame.Filament(radius: 0.66, start: (t * 75).truncatingRemainder(dividingBy: 360), sweep: 95, alpha: alpha),
         OrbFrame.Filament(radius: 0.80, start: (200 - t * 52).truncatingRemainder(dividingBy: 360), sweep: 60,
                           alpha: alpha * 0.7)]
    }

    /// Timeline policy: display rate while something moves; 4 Hz under Reduce Motion while the level or the
    /// countdown changes; paused when the frame is static. The caller also pauses while the panel is hidden.
    static func schedule(tone: OverlayTone, micLive: Bool, hasCountdown: Bool, reduceMotion: Bool)
        -> (paused: Bool, minimumInterval: Double?) {
        guard reduceMotion else { return (false, nil) }
        switch tone {
        case .listening, .warming: return (!micLive, 0.25)
        case .choices: return (!hasCountdown, 0.25)
        case .processing, .success, .error: return (true, nil)
        }
    }

    /// Remaining share of the choices window, on a fixed scale of `window` seconds.
    static func countdown(deadline: Date?, now: Date, window: Double) -> Double? {
        guard let deadline else { return nil }
        let left = deadline.timeIntervalSince(now)
        return min(1, max(0, left / max(window, 0.1)))
    }

    /// Point on a circle; degrees clockwise from 12 o'clock in a y-down space.
    static func point(cx: Double, cy: Double, r: Double, deg: Double) -> (x: Double, y: Double) {
        let a = deg * .pi / 180
        return (cx + r * sin(a), cy - r * cos(a))
    }
}

/// Smoothed mic level. `push` takes ~15 Hz samples; `value(at:)` eases between them, so a display-rate canvas
/// moves smoothly, and decays to zero when samples stop.
@MainActor
@Observable
public final class LevelMeter {
    public private(set) var target = 0.0
    private(set) var from = 0.0
    private(set) var changedAt = 0.0

    /// Ease time from one sample to the next.
    static let ease = 0.09
    /// No sample for this long: decay to zero.
    static let hold = 0.4

    public init() {}

    public func push(_ level: Double, at t: Double) {
        let v = level.isFinite ? min(max(level, 0), 1) : 0
        from = value(at: t)
        target = v
        changedAt = t
    }

    public func reset() {
        target = 0; from = 0; changedAt = 0
    }

    public func value(at t: Double) -> Double {
        let dt = t - changedAt
        guard dt >= 0 else { return from }
        let p = min(1, dt / Self.ease)
        let eased = 1 - pow(1 - p, 3)
        let v = from + (target - from) * eased
        if dt > Self.hold { return v * exp(-(dt - Self.hold) * 5) }
        return v
    }

    /// Maps a dBFS peak (VoiceSession `.level(dB:)`) to 0...1: -60 dBFS and below is 0, -12 dBFS and above is 1.
    public nonisolated static func normalized(dB: Double) -> Double {
        guard dB.isFinite else { return 0 }
        return min(max((dB + 60) / 48, 0), 1)
    }
}
