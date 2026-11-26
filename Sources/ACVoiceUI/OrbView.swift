import SwiftUI

/// Time source of the orb. Live: a `TimelineView` that runs only while the panel is shown. Fixed: one frame for
/// snapshots.
enum OrbClock {
    case live(meter: LevelMeter, running: Bool)
    case fixed(now: Date, level: Double)

    /// The live panel while it is on screen (timelines may run).
    var isLive: Bool {
        if case .live(_, let running) = self { return running }
        return false
    }
}

/// VoiceOver value of the header during choices: the seconds left ("Noch 4 Sekunden"), updated once a second while
/// the panel is on screen. A held list reports its frozen time.
struct SecondsLeftValue: ViewModifier {
    var deadline: Date?
    var frozen: Double?
    var live: Bool
    var text: OverlayText = .de

    func body(content: Content) -> some View {
        if let deadline, live, frozen == nil {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                content.accessibilityValue(Self.text(deadline.timeIntervalSince(ctx.date), text))
            }
        } else if let left = frozen ?? deadline.map({ $0.timeIntervalSinceNow }) {
            content.accessibilityValue(Self.text(left, text))
        } else {
            content
        }
    }

    nonisolated static func text(_ seconds: Double, _ text: OverlayText = .de) -> String {
        text.a11ySecondsLeft(max(0, Int(seconds.rounded(.up))))
    }
}

/// The "Jarvis" orb: a lit sphere with concentric rings, drawn with `Canvas`.
struct OrbView: View {
    var tone: OverlayTone
    var micLive: Bool
    var phaseStart: Date
    var deadline: Date?
    /// The pointer holds the list: the ring stands still with this many seconds left.
    var countdownFrozen: Double? = nil
    var choicesWindow: Double
    var clock: OrbClock

    @Environment(\.colorScheme) private var scheme
    @Environment(\.overlayAccessibility) private var a11y

    var body: some View {
        Group {
            switch clock {
            case let .live(meter, running):
                let policy = OrbMotion.schedule(tone: tone, micLive: micLive, hasCountdown: deadline != nil,
                                                reduceMotion: a11y.reduceMotion)
                TimelineView(.animation(minimumInterval: policy.minimumInterval, paused: !running || policy.paused)) { ctx in
                    canvas(now: ctx.date, level: meter.value(at: ctx.date.timeIntervalSinceReferenceDate))
                }
            case let .fixed(now, level):
                canvas(now: now, level: level)
            }
        }
        .frame(width: OrbMotion.canvas, height: OrbMotion.canvas)
        .padding(-(OrbMotion.canvas - OrbMotion.slot) / 2)
        .frame(width: OrbMotion.slot, height: OrbMotion.slot)
        .accessibilityHidden(true)
    }

    private func canvas(now: Date, level: Double) -> some View {
        let frame = OrbMotion.frame(
            tone: tone, micLive: micLive, time: now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600),
            elapsed: now.timeIntervalSince(phaseStart), level: level,
            countdown: countdownFrozen.map { min(1, max(0, $0 / max(choicesWindow, 0.1))) }
                ?? OrbMotion.countdown(deadline: deadline, now: now, window: choicesWindow),
            reduceMotion: a11y.reduceMotion)
        let palette = OverlayPalette(scheme: scheme, highContrast: a11y.increaseContrast)
        let colors = palette.orb(tone)
        let dark = scheme == .dark
        let contrast = a11y.increaseContrast
        return Canvas { context, size in
            OrbPainter.draw(frame, colors: colors, dark: dark, highContrast: contrast, in: &context, size: size)
        }
    }
}

/// Draws an `OrbFrame`.
enum OrbPainter {
    static func draw(_ f: OrbFrame, colors: OrbColors, dark: Bool, highContrast: Bool, in ctx: inout GraphicsContext,
                     size: CGSize) {
        let k = size.width / OrbMotion.canvas
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let lift = highContrast ? 0.7 : 0.0
        let ringColor = dark ? colors.ring : colors.deep

        // Ambient glow around the sphere.
        do {
            var g = ctx
            if dark { g.blendMode = .plusLighter }
            let r = 44 * k
            let a = (dark ? 0.42 : 0.30) * f.intensity
            g.fill(circle(c, r), with: .radialGradient(
                Gradient(stops: [.init(color: colors.glow.opacity(a), location: 0),
                                 .init(color: colors.glow.opacity(a * 0.35), location: 0.45),
                                 .init(color: colors.glow.opacity(0), location: 1)]),
                center: c, startRadius: 0, endRadius: r))
        }

        // Rings.
        for ring in f.rings {
            var g = ctx
            if dark { g.blendMode = .plusLighter }
            let alpha = min(1, ring.alpha * f.intensity * (highContrast ? 1.5 : 1))
            guard alpha > 0.005 else { continue }
            let path = arc(c, ring.radius * k, from: ring.rotation, sweep: 360)
            var style = StrokeStyle(lineWidth: (ring.width + lift) * k, lineCap: .round)
            if let dash = ring.dash { style.dash = dash.map { $0 * k } }
            g.stroke(path, with: .color(ringColor.opacity(alpha)), style: style)
        }

        // Countdown: the remaining share of the choices window, from 12 o'clock clockwise. Normal blending keeps
        // the amber hue on dark glass (additive blending would turn it yellow).
        if let left = f.countdown, left > 0.002 {
            let r = OrbMotion.countdownRadius * k
            let sweep = 360 * left
            var halo = ctx
            halo.addFilter(.blur(radius: 2.5 * k))
            halo.stroke(arc(c, r, from: 0, sweep: sweep), with: .color(colors.glow.opacity(dark ? 0.55 : 0.35)),
                        style: StrokeStyle(lineWidth: (3.2 + lift) * k, lineCap: .round))
            ctx.stroke(arc(c, r, from: 0, sweep: sweep), with: .color(ringColor.opacity(0.98)),
                       style: StrokeStyle(lineWidth: (3.2 + lift) * k, lineCap: .round))
            let head = OrbMotion.point(cx: c.x, cy: c.y, r: r, deg: sweep)
            ctx.fill(circle(CGPoint(x: head.x, y: head.y), 2.4 * k), with: .color(.white.opacity(0.95)))
        }

        // Comet arcs: segments fading from tail to head.
        for a in f.arcs {
            var g = ctx
            if dark { g.blendMode = .plusLighter }
            let n = 32
            let arcColor = dark ? colors.body : colors.deep
            for i in 0..<n {
                let p0 = Double(i) / Double(n), p1 = Double(i + 1) / Double(n)
                let alpha = a.alpha * pow(p1, 1.25) * f.intensity
                g.stroke(arc(c, a.radius * k, from: a.start + a.sweep * p0, sweep: a.sweep * (p1 - p0) + 0.6),
                         with: .color(arcColor.opacity(alpha)),
                         style: StrokeStyle(lineWidth: (a.width + lift) * k, lineCap: .butt))
            }
            let head = OrbMotion.point(cx: c.x, cy: c.y, r: a.radius * k, deg: a.start + a.sweep)
            var dot = ctx
            dot.addFilter(.shadow(color: colors.glow.opacity(0.9 * a.alpha), radius: 3 * k))
            dot.fill(circle(CGPoint(x: head.x, y: head.y), (a.width * 0.72 + lift / 2) * k),
                     with: .color(.white.opacity(0.95 * a.alpha * f.intensity)))
        }

        // Core: a self-lit plasma sphere. Bloom, a hot center fading to the deep tone, inner filaments.
        let r = f.coreRadius * k
        do {
            var g = ctx
            g.opacity = f.intensity
            g.addFilter(.blur(radius: 6 * k))
            if dark { g.blendMode = .plusLighter }
            g.fill(circle(c, r * 1.25), with: .color(colors.glow.opacity(dark ? 0.75 : 0.5)))
        }
        do {
            var g = ctx
            g.opacity = 0.4 + 0.6 * f.intensity
            let hot = CGPoint(x: c.x - r * 0.12, y: c.y - r * 0.16)
            g.fill(circle(c, r), with: .radialGradient(
                Gradient(stops: [.init(color: .white, location: 0),
                                 .init(color: .white.opacity(0.92), location: 0.12),
                                 .init(color: colors.body.color, location: 0.48),
                                 .init(color: colors.deep.color, location: 0.92),
                                 .init(color: colors.deep.opacity(0.85), location: 1)]),
                center: hot, startRadius: 0, endRadius: r * 1.12))
            // Thin bright rim: the sphere's edge catches its own light.
            g.stroke(circle(c, r - 0.5 * k), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.55), .white.opacity(0.05), colors.body.opacity(0.6)]),
                startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)),
                lineWidth: 0.9 * k)
            for fil in f.filaments {
                g.stroke(arc(c, r * fil.radius, from: fil.start, sweep: fil.sweep),
                         with: .color(.white.opacity(fil.alpha)),
                         style: StrokeStyle(lineWidth: 0.9 * k, lineCap: .round))
            }
        }

        // Glyph.
        switch f.glyph {
        case .check(let progress)?:
            let pts = [CGPoint(x: -0.42, y: 0.02), CGPoint(x: -0.12, y: 0.32), CGPoint(x: 0.44, y: -0.30)]
                .map { CGPoint(x: c.x + $0.x * r, y: c.y + $0.y * r) }
            let path = partial(pts, progress)
            var g = ctx
            g.addFilter(.shadow(color: colors.deep.opacity(0.6), radius: 1.5 * k))
            g.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: max(2.2, r * 0.17), lineCap: .round, lineJoin: .round))
        case .exclamation?:
            var g = ctx
            g.addFilter(.shadow(color: colors.deep.opacity(0.6), radius: 1.5 * k))
            var bar = Path()
            bar.move(to: CGPoint(x: c.x, y: c.y - r * 0.45))
            bar.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.10))
            g.stroke(bar, with: .color(.white), style: StrokeStyle(lineWidth: max(2.2, r * 0.18), lineCap: .round))
            g.fill(circle(CGPoint(x: c.x, y: c.y + r * 0.40), max(1.4, r * 0.11)), with: .color(.white))
        case nil:
            break
        }
    }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    static func ellipse(_ c: CGPoint, w: CGFloat, h: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
    }

    /// Arc as a polyline: degrees clockwise from 12 o'clock, independent of the flipped-y `addArc` convention.
    static func arc(_ c: CGPoint, _ r: CGFloat, from start: Double, sweep: Double) -> Path {
        var p = Path()
        let steps = max(2, Int(abs(sweep) / 2.5))
        for i in 0...steps {
            let pt = OrbMotion.point(cx: c.x, cy: c.y, r: r, deg: start + sweep * Double(i) / Double(steps))
            if i == 0 { p.move(to: CGPoint(x: pt.x, y: pt.y)) } else { p.addLine(to: CGPoint(x: pt.x, y: pt.y)) }
        }
        if abs(sweep) >= 360 { p.closeSubpath() }
        return p
    }

    /// The first `progress` share (by length) of a polyline.
    static func partial(_ pts: [CGPoint], _ progress: Double) -> Path {
        var p = Path()
        guard let first = pts.first, progress > 0 else { return p }
        let lengths = zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var left = lengths.reduce(0, +) * min(1, progress)
        p.move(to: first)
        for (i, len) in lengths.enumerated() {
            let a = pts[i], b = pts[i + 1]
            if left >= len { p.addLine(to: b); left -= len; continue }
            let f = len > 0 ? left / len : 0
            p.addLine(to: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            break
        }
        return p
    }
}
