#!/usr/bin/env swift
// Draws the AC Voice app icon with CoreGraphics and packs it into Resources/AppIcon.icns via iconutil.
//
// Usage: swift scripts/make-icon.swift [--out PATH] [--iconset DIR] [--preview PNG]
//   --out      .icns destination (default: <package>/Resources/AppIcon.icns)
//   --iconset  keep the generated .iconset at DIR (default: a temporary directory that is removed)
//   --preview  also write a 1024 px PNG to PNG, for looking at the result
//
// Look: a glowing cyan orb with a segmented HUD ring on a dark rounded square. The square follows the macOS
// app icon grid (1024 px canvas, 824 px body with a 100 px margin, continuous corners with radius 185.4 px,
// soft drop shadow), so macOS 26 can show it without an extra plate. Each size is drawn natively: up to 32 px
// without the fine rings, at 16 px with a larger orb and no segmented ring, so the orb stays readable.
// Needs no network, no window and no permission.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Geometry

/// Rounded rect with continuous ("squircle") corners, using the widely published approximation of Apple's
/// continuous corner curve (three cubic segments per corner, the curve starts 1.528665 r from the corner).
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    // Corner, unit vector back along the incoming edge (u), unit vector along the outgoing edge (v).
    let corners: [(c: CGPoint, u: CGVector, v: CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),  // top right
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),   // bottom right
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),    // bottom left
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),   // top left
    ]
    func p(_ k: Int, _ a: CGFloat, _ b: CGFloat) -> CGPoint {
        let (c, u, v) = corners[k]
        return CGPoint(x: c.x + (a * u.dx + b * v.dx) * r, y: c.y + (a * u.dy + b * v.dy) * r)
    }
    let path = CGMutablePath()
    path.move(to: p(3, 0, 1.52866483))
    for k in 0..<4 {
        path.addLine(to: p(k, 1.52866471, 0))
        path.addCurve(to: p(k, 0.63149399, 0.07491100), control1: p(k, 1.08849323, 0), control2: p(k, 0.86840701, 0))
        path.addCurve(to: p(k, 0.07491100, 0.63149399), control1: p(k, 0.37282170, 0.16905899),
                      control2: p(k, 0.16905899, 0.37282170))
        path.addCurve(to: p(k, 0, 1.52866483), control1: p(k, 0, 0.86840701), control2: p(k, 0, 1.08849323))
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

struct Painter {
    let ctx: CGContext
    /// Pixels per design unit (the design canvas is 1024 units).
    let scale: CGFloat
    let space: CGColorSpace

    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a])!
    }

    func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    }

    /// Line width in design units that never drops below `minPixels` device pixels.
    func width(_ units: CGFloat, minPixels: CGFloat) -> CGFloat { max(units, minPixels / scale) }

    func radial(_ g: CGGradient, at c: CGPoint, radius: CGFloat, from start: CGPoint? = nil) {
        ctx.drawRadialGradient(g, startCenter: start ?? c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    }

    func arc(center c: CGPoint, radius: CGFloat, from a0: CGFloat, to a1: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: c, radius: radius, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
        return path
    }
}

func renderIcon(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("cannot create a \(pixels) px bitmap context")
    }
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let p = Painter(ctx: ctx, scale: scale, space: space)
    // Detail levels: up to 32 px without the fine rings, at 16 px without the segmented ring as well.
    let tiny = pixels <= 32
    let micro = pixels <= 16

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = continuousRoundedRect(body, radius: 185.4)
    let center = CGPoint(x: 512, y: 512)
    let cyan = (r: CGFloat(0.20), g: CGFloat(0.86), b: CGFloat(1.0))

    // 1. Drop shadow of the plate (shadow parameters are in device pixels, not design units).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 22 * scale, color: p.color(0, 0, 0, 0.40))
    ctx.addPath(bodyPath)
    ctx.setFillColor(p.color(0.05, 0.06, 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    // Everything else stays inside the plate.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // 2. Plate: deep navy, lighter at the top.
    ctx.drawLinearGradient(
        p.gradient([(0, p.color(0.125, 0.155, 0.245)), (0.55, p.color(0.055, 0.070, 0.120)), (1, p.color(0.020, 0.025, 0.050))]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // 3. Ambient light the orb throws onto the plate.
    p.radial(p.gradient([(0, p.color(cyan.r, cyan.g, cyan.b, 0.30)), (0.5, p.color(0.05, 0.55, 0.95, 0.10)),
                         (1, p.color(0.05, 0.45, 0.90, 0))]),
             at: center, radius: 470)

    // 4. HUD rings: a faint outer ring with ticks at the gap centers, and a bright ring in three segments with
    //    gaps at 90, 210 and 330 degrees.
    let gapCenters: [CGFloat] = [90, 210, 330]
    let gap: CGFloat = 22
    if !tiny {
        ctx.setLineCap(.butt)
        ctx.addPath(p.arc(center: center, radius: 322, from: 0, to: 360))
        ctx.setStrokeColor(p.color(cyan.r, cyan.g, cyan.b, 0.26))
        ctx.setLineWidth(p.width(3, minPixels: 0.75))
        ctx.strokePath()
        for angle in gapCenters {
            let rad = angle * .pi / 180
            ctx.move(to: CGPoint(x: center.x + cos(rad) * 306, y: center.y + sin(rad) * 306))
            ctx.addLine(to: CGPoint(x: center.x + cos(rad) * 338, y: center.y + sin(rad) * 338))
        }
        ctx.setStrokeColor(p.color(cyan.r, cyan.g, cyan.b, 0.60))
        ctx.setLineWidth(p.width(6, minPixels: 1))
        ctx.strokePath()
    }
    // At 16 px the segments merge with the orb into a blob, so the smallest size shows a larger orb only.
    if !micro {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 20 * scale, color: p.color(cyan.r, cyan.g, cyan.b, 0.9))
        ctx.setLineCap(tiny ? .butt : .round)
        for (k, start) in gapCenters.enumerated() {
            let end = gapCenters[(k + 1) % gapCenters.count] + (k == gapCenters.count - 1 ? 360 : 0)
            let inset = gap / 2 + (tiny ? 0 : 4)
            ctx.addPath(p.arc(center: center, radius: 266, from: start + inset, to: end - inset))
        }
        ctx.setStrokeColor(p.color(0.50, 0.93, 1.0, 0.95))
        ctx.setLineWidth(p.width(tiny ? 30 : 16, minPixels: 1.25))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 5. Bloom: light that starts at the rim of the orb and fades towards the ring.
    let orbRadius: CGFloat = micro ? 200 : (tiny ? 158 : 140)
    ctx.drawRadialGradient(
        p.gradient([(0, p.color(0.55, 0.96, 1.0, 0.95)), (0.30, p.color(cyan.r, cyan.g, cyan.b, 0.55)),
                    (0.65, p.color(0.05, 0.62, 1.0, 0.16)), (1, p.color(0.0, 0.55, 1.0, 0))]),
        startCenter: center, startRadius: orbRadius * 0.9, endCenter: center,
        endRadius: micro ? 360 : (tiny ? 300 : 262), options: [])

    // 6. The orb: a white-hot core, saturated cyan in the middle and a brighter rim, like a lit sphere of energy.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - orbRadius, y: center.y - orbRadius, width: orbRadius * 2, height: orbRadius * 2))
    ctx.clip()
    p.radial(p.gradient([(0, p.color(1, 1, 1)), (0.28, p.color(0.82, 0.99, 1.0)), (0.62, p.color(0.30, 0.86, 1.0)),
                         (0.86, p.color(0.16, 0.74, 1.0)), (1, p.color(0.52, 0.94, 1.0))]),
             at: center, radius: orbRadius, from: CGPoint(x: center.x - 16, y: center.y + 22))
    if !tiny {
        // Inner rings, the same motif the overlay orb animates with the voice level.
        for (radius, alpha) in [(orbRadius * 0.58, 0.30), (orbRadius * 0.80, 0.20)] as [(CGFloat, CGFloat)] {
            ctx.addPath(p.arc(center: center, radius: radius, from: 0, to: 360))
            ctx.setStrokeColor(p.color(1, 1, 1, alpha))
            ctx.setLineWidth(p.width(3, minPixels: 0.6))
            ctx.strokePath()
        }
    }
    ctx.restoreGState()

    // 7. Soft specular highlight, top left.
    if !tiny {
        let spot = CGPoint(x: center.x - orbRadius * 0.36, y: center.y + orbRadius * 0.42)
        ctx.saveGState()
        ctx.translateBy(x: spot.x, y: spot.y)
        ctx.scaleBy(x: 1.3, y: 0.9)
        p.radial(p.gradient([(0, p.color(1, 1, 1, 0.45)), (1, p.color(1, 1, 1, 0))]), at: .zero, radius: orbRadius * 0.34)
        ctx.restoreGState()
    }

    ctx.restoreGState()  // plate clip

    // 8. Thin light rim along the top of the plate.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setLineWidth(p.width(4, minPixels: 0.5))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(p.gradient([(0, p.color(1, 1, 1, 0.22)), (0.45, p.color(1, 1, 1, 0.04)), (1, p.color(1, 1, 1, 0))]),
                           start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("cannot render \(pixels) px") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
}

// MARK: - Main

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let scriptURL = URL(fileURLWithPath: #filePath, relativeTo: cwd).standardizedFileURL
let packageRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

var outURL = packageRoot.appendingPathComponent("Resources/AppIcon.icns")
var keepIconset: URL?
var previewURL: URL?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let flag = args.removeFirst()
    func value() -> URL {
        guard !args.isEmpty else { fail("\(flag) needs a value") }
        return URL(fileURLWithPath: args.removeFirst(), relativeTo: cwd).standardizedFileURL
    }
    switch flag {
    case "--out": outURL = value()
    case "--iconset": keepIconset = value()
    case "--preview": previewURL = value()
    case "-h", "--help":
        print("usage: swift scripts/make-icon.swift [--out PATH] [--iconset DIR] [--preview PNG]")
        exit(0)
    default: fail("unknown option \(flag)")
    }
}

let fm = FileManager.default
let iconset: URL
if let keep = keepIconset {
    iconset = keep.pathExtension == "iconset" ? keep : keep.appendingPathComponent("AppIcon.iconset")
} else {
    iconset = fm.temporaryDirectory.appendingPathComponent("acvoice-\(ProcessInfo.processInfo.processIdentifier).iconset")
}
try? fm.removeItem(at: iconset)
do {
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    // iconutil names: icon_<points>x<points>[@2x].png
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
            try writePNG(renderIcon(pixels: points * factor), to: iconset.appendingPathComponent(name))
        }
    }
    if let previewURL {
        try fm.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePNG(renderIcon(pixels: 1024), to: previewURL)
    }
    try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
} catch {
    fail(error.localizedDescription)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", outURL.path, iconset.path]
do { try iconutil.run() } catch { fail("cannot run iconutil: \(error.localizedDescription)") }
iconutil.waitUntilExit()
if keepIconset == nil { try? fm.removeItem(at: iconset) }
guard iconutil.terminationStatus == 0 else { fail("iconutil failed with status \(iconutil.terminationStatus)") }
print("wrote \(outURL.path)")
if keepIconset != nil { print("kept \(iconset.path)") }
if let previewURL { print("preview \(previewURL.path)") }
