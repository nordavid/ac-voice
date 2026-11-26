import ACVoiceCore
import Foundation

// Dev CLI for the resolver. Prints only ids, counts and timings (project names are private data).
//
//   acvoice-resolve <projects.tsv|projects.json> "<utterance>" ["<second hypothesis>" ...]
//   acvoice-resolve <projects.tsv|projects.json> --cases <regression.tsv>
//
// Options: --alias CODE=spoken[|spoken]  (repeatable), --favorite <id> (repeatable, adds a strong personal signal),
// --lang de|en (language of the utterances, default de; in a case file until its first `@language` line).
// projects.tsv holds "id<TAB>name" lines; projects.json is the ProjectCatalog format of Tests/Fixtures.
// The regression format is documented in ACVoiceCore/Regression.swift.

func usage() -> Never {
    print("usage: acvoice-resolve <projects.tsv|projects.json> [--alias CODE=a|b] [--favorite ID] [--lang de|en] (--cases FILE | utterance [hypothesis ...])")
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }
let source = args.removeFirst()
var aliases: [String: [String]] = [:]
var favorites: [Int] = []
var casesPath: String?
var hyps: [String] = []
var language = AppLanguage.de
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--alias":
        guard !args.isEmpty else { usage() }
        let kv = args.removeFirst().split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { usage() }
        aliases[kv[0], default: []] += kv[1].split(separator: "|").map(String.init)
    case "--favorite":
        guard let id = args.first.flatMap({ Int($0) }) else { usage() }
        args.removeFirst(); favorites.append(id)
    case "--cases":
        guard !args.isEmpty else { usage() }
        casesPath = args.removeFirst()
    case "--lang":
        guard let l = args.first.flatMap(AppLanguage.init(rawValue:)) else { usage() }
        args.removeFirst(); language = l
    default: hyps.append(a)
    }
}

let now = Date()
var projects: [ProjectEntry]
if source.hasSuffix(".json") {
    guard let catalog = try? ProjectCatalog.load(URL(fileURLWithPath: source)) else { print("cannot read \(source)"); exit(1) }
    projects = catalog.entries(now: now, aliases: aliases.isEmpty ? nil : aliases)
} else {
    guard let tsv = try? String(contentsOfFile: source, encoding: .utf8) else { print("cannot read \(source)"); exit(1) }
    projects = ProjectCatalog.entries(tsv: tsv).map { $0.addingAliases(byCode: aliases) }
}
for i in projects.indices where favorites.contains(projects[i].id) {
    projects[i].signals = Signals(favorite: true, timeRecords30d: 11, ownOpenTasks: 1, lastActivity: now)
}

if let casesPath {
    guard let text = try? String(contentsOfFile: casesPath, encoding: .utf8) else { print("cannot read \(casesPath)"); exit(1) }
    let results = Regression.run(Regression.parse(text, now: now, language: language), projects: projects, now: now)
    for r in results {
        let mark = r.passed ? "ok  " : "FAIL"
        print("\(mark) line \(r.testCase.line): \(r.actual)" + (r.passed ? "" : "  (expected \(r.testCase.expected))")
              + String(format: "  %.0fus", r.micros))
    }
    let failed = results.filter { !$0.passed }.count
    let times = results.map(\.micros).sorted()
    let p50 = times.isEmpty ? 0 : times[times.count / 2], maxT = times.last ?? 0
    print("\(results.count - failed)/\(results.count) passed, p50 \(Int(p50))us, max \(Int(maxT))us")
    exit(failed == 0 ? 0 : 1)
}

guard !hyps.isEmpty else { usage() }
let interp = Interpreter(resolver: Resolver(projects: projects), language: language)
let t0 = DispatchTime.now().uptimeNanoseconds
let result = interp.command(hyps.map { Hypothesis($0) }, now: now)
let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
print(Regression.describe(result), String(format: "%.0fus", us))
