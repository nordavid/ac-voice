import Foundation
import ACVoiceCore
import ACVoiceUI

// Renders every overlay state to PNG at 2x, offscreen (ImageRenderer, no window):
//   acvoice-overlay-snapshots <outDir> [--only <name>[,<name>...]] [--variants] [--lang de|en]
// Writes <outDir>/<state>-<light|dark>.png. --variants also writes -contrast (Increase Contrast),
// -solid (Reduce Transparency) and -still (Reduce Motion) renders. --lang picks the gallery's language
// (texts and spoken commands; default de). Use another <outDir> per language.

let usage = "usage: acvoice-overlay-snapshots <outDir> [--only <name>[,<name>...]] [--variants] [--lang de|en]"
var args = Array(CommandLine.arguments.dropFirst())
var only: Set<String>?
var variants = false
var language = AppLanguage.de
var outDir: String?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--only":
        guard !args.isEmpty else { print(usage); exit(2) }
        only = Set(args.removeFirst().split(separator: ",").map(String.init))
    case "--variants":
        variants = true
    case "--lang":
        guard !args.isEmpty, let l = AppLanguage(rawValue: args.removeFirst().lowercased()) else { print(usage); exit(2) }
        language = l
    case "-h", "--help":
        print(usage); exit(0)
    default:
        if a.hasPrefix("-") || outDir != nil { print(usage); exit(2) }
        outDir = a
    }
}
guard let outDir else { print(usage); exit(2) }

let dir = URL(fileURLWithPath: outDir, isDirectory: true)
var scenarios = OverlayGallery.scenarios(language: language)
if let only {
    scenarios = scenarios.filter { only.contains($0.name) }
    let unknown = only.subtracting(scenarios.map(\.name))
    if !unknown.isEmpty {
        print("unknown state(s): \(unknown.sorted().joined(separator: ", "))")
        print("states: \(OverlayGallery.scenarios(language: language).map(\.name).joined(separator: ", "))")
        exit(2)
    }
}

let started = Date()
do {
    var written = try OverlaySnapshot.renderAll(to: dir, scenarios: scenarios)
    if variants {
        written += try OverlaySnapshot.renderAll(to: dir, scenarios: scenarios,
                                                 accessibility: OverlayAccessibility(increaseContrast: true),
                                                 suffix: "-contrast")
        written += try OverlaySnapshot.renderAll(to: dir, scenarios: scenarios,
                                                 accessibility: OverlayAccessibility(reduceTransparency: true),
                                                 suffix: "-solid")
        written += try OverlaySnapshot.renderAll(to: dir, scenarios: scenarios,
                                                 accessibility: OverlayAccessibility(reduceMotion: true),
                                                 suffix: "-still")
    }
    for url in written { print(url.path) }
    print(String(format: "%d PNGs in %.2f s", written.count, Date().timeIntervalSince(started)))
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
