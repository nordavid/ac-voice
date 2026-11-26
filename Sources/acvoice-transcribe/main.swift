import ACVoiceCore
import ACVoiceSpeech
import Foundation

// Dev CLI for ACVoiceSpeech: runs audio files through VoiceSession with a simulated microphone (FileSource) and
// prints what both transcribers heard, the hypotheses, the end of utterance, the latencies and the Interpretation.
// It never opens the microphone. Interpretations are printed as ids only (project names are private data).
//
//   acvoice-transcribe <file...> [--realtime] [--answer] [--projects <tsv|json>] [--alias CODE=a|b]
//                      [--choices <id,id,...>] [--context-limit N] [--no-context] [--no-adaptive]
//
// Every argument is one utterance of one session (one key press); "a.aiff+b.aiff" plays files back to back
// with their silence trimmed and a 120 ms gap.
// --realtime     feed at real-time pace; without it clips go as fast as possible and latencies mean nothing
// --answer       every file after the first answers the list the previous utterance produced
// --choices      treat every file as an answer to this list of project ids
// --projects     project list for interpretation and context (default: Tests/Fixtures/projects.sample.json)
// --alias        spoken alias per code as in config.json, repeatable ("--alias IBN=eben"); added to the
//                aliases of a JSON list, the only aliases of a TSV list
// --no-adaptive  keep the default hangover instead of playing the app's flow on every live partial
//                (Core `HangoverPolicy.standard`: fast for a resolved preview, long for a dangling word or number)

func usage() -> Never {
    print("usage: acvoice-transcribe <file[+file]...> [--realtime] [--answer] [--projects <tsv|json>] [--alias CODE=a|b] [--choices <id,...>] [--context-limit N] [--no-context] [--no-adaptive]")
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var files: [String] = []
var realtime = false, answerMode = false, useContext = true, adaptive = true
var projectsPath: String?
var fixedChoices: [Int]?
var aliases: [String: [String]] = [:]
var contextLimit = ContextBuilder.defaultLimit
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--realtime": realtime = true
    case "--answer": answerMode = true
    case "--no-context": useContext = false
    case "--no-adaptive": adaptive = false
    case "--projects":
        guard !args.isEmpty else { usage() }
        projectsPath = args.removeFirst()
    case "--alias":
        guard !args.isEmpty else { usage() }
        let kv = args.removeFirst().split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { usage() }
        aliases[kv[0], default: []] += kv[1].split(separator: "|").map(String.init)
    case "--choices":
        guard !args.isEmpty else { usage() }
        fixedChoices = args.removeFirst().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    case "--context-limit":
        guard let n = args.first.flatMap({ Int($0) }) else { usage() }
        args.removeFirst(); contextLimit = n
    case "-h", "--help": usage()
    default:
        if a.hasPrefix("--") { usage() }
        files.append(a)
    }
}
guard !files.isEmpty else { usage() }

// Projects: explicit path, else the committed synthetic fixture when run from the repo root.
var projects: [ProjectEntry] = []
var now = Date()
let defaultFixture = "Tests/Fixtures/projects.sample.json"
if let path = projectsPath ?? (FileManager.default.fileExists(atPath: defaultFixture) ? defaultFixture : nil) {
    if path.hasSuffix(".json") {
        guard let catalog = try? ProjectCatalog.load(URL(fileURLWithPath: path)) else { print("cannot read \(path)"); exit(1) }
        now = catalog.referenceDate
        projects = catalog.entries(now: now).map { $0.addingAliases(byCode: aliases) }
    } else {
        guard let tsv = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); exit(1) }
        projects = ProjectCatalog.entries(tsv: tsv).map { $0.addingAliases(byCode: aliases) }
    }
}
let interpreter: Interpreter? = projects.isEmpty ? nil : Interpreter(resolver: Resolver(projects: projects))
let commandContext = useContext ? ContextBuilder.command(projects: projects, now: now, limit: contextLimit) : []
print("projects: \(projects.count), command context: \(commandContext.count) strings, pacing: \(realtime ? "real time" : "fast")")

/// Utterances and other session events, handed from the event task to the main flow.
final class Inbox: @unchecked Sendable {
    enum Item { case utterance(VoiceSession.Utterance), noSpeech, failed(String) }
    private let lock = NSLock()
    private var items: [Item] = []
    private var listening = UtteranceMode.command
    private var list: [Int] = []

    var mode: UtteranceMode {
        get { lock.withLock { listening } }
        set { lock.withLock { listening = newValue } }
    }

    /// Candidates of the visible list in the answer phase.
    var candidates: [Int] {
        get { lock.withLock { list } }
        set { lock.withLock { list = newValue } }
    }

    func push(_ i: Item) { lock.withLock { items.append(i) } }

    func next(timeout: Double) async -> Item? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let i = lock.withLock({ items.isEmpty ? nil : items.removeFirst() }) { return i }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}

func quoted(_ t: TranscriberText) -> String {
    var s = "\"\(t.best)\""
    if !t.alternatives.isEmpty { s += " alts " + t.alternatives.map { "\"\($0)\"" }.joined(separator: ", ") }
    if t.fromVolatile { s += " (volatile)" }
    return s
}

let session = VoiceSession()
do {
    try await session.warmUp(context: commandContext)
} catch {
    print("speech assets unavailable: \(error)")
    exit(1)
}
let source = FileSource(pacing: realtime ? .realTime : .fast)
let inbox = Inbox()
let events: AsyncStream<VoiceSession.Event>
do {
    events = try await session.start(context: commandContext, source: source)
} catch {
    print("start failed: \(error)")
    exit(1)
}
let consumer = Task {
    for await e in events {
        switch e.kind {
        case .partial(let dt, let st):
            // What the app's flow does with partials (VoiceFlow, PLAN 2.3): the hangover follows the live preview.
            if adaptive, let interpreter {
                let hyps = [Hypothesis(dt), Hypothesis(st)].filter { !$0.text.isEmpty }
                let text = EndpointGate.leading(dt, st)
                guard !hyps.isEmpty else { break }
                let policy = HangoverPolicy.standard
                if inbox.mode == .command {
                    session.setHangover(policy.command(text: text, interpretation: interpreter.command(hyps, now: now)))
                } else {
                    let outcome = interpreter.selection(hyps, candidates: inbox.candidates, now: now)
                    session.setHangover(policy.answer(text: text, outcome: outcome, command: { interpreter.command(hyps, now: now) }))
                }
            }
        case .utterance(let u): inbox.push(.utterance(u))
        case .noSpeech: inbox.push(.noSpeech)
        case .failed(let err): inbox.push(.failed(err.message))
        default: break
        }
    }
}

var candidates: [Int] = fixedChoices ?? []
for (i, arg) in files.enumerated() {
    let isAnswer = fixedChoices != nil || (answerMode && i > 0 && !candidates.isEmpty)
    if i > 0 || fixedChoices != nil {
        if isAnswer {
            let titles = candidates.map { id in projects.first { $0.id == id }?.title ?? "" }
            inbox.mode = .answer
            inbox.candidates = candidates
            await session.expectAnswer(context: useContext ? ContextBuilder.answer(titles: titles, limit: contextLimit) : [])
        } else if i > 0 {
            inbox.mode = .command
            await session.expectCommand(context: commandContext)
        }
        try? await Task.sleep(for: .milliseconds(300))   // reaction time after the list appears
    }
    do {
        // Parts lose their file silence and get a natural 120 ms gap (mixed-voice TTS clips).
        let parts = arg.split(separator: "+").map { URL(fileURLWithPath: String($0)) }
        for (n, url) in parts.enumerated() {
            if n > 0 { source.enqueue(silence: 0.12) }
            try source.enqueue(contentsOf: url, trimSilence: parts.count > 1)
        }
        if parts.count > 1 { source.enqueue(silence: 0.3) }
    } catch {
        print("== \(arg): cannot read (\(error))")
        continue
    }
    print("== \(arg) (\(isAnswer ? "answer" : "command"))")
    guard let item = await inbox.next(timeout: 30) else { print("   no utterance within 30 s"); continue }
    guard case .utterance(let u) = item else {
        if case .failed(let m) = item { print("   failed: \(m)") } else { print("   no speech") }
        continue
    }
    print("   DT: \(quoted(u.dictation))")
    print("   ST: \(quoted(u.speech))")
    print("   hypotheses: " + u.hypotheses.map { String(format: "%.1f \"%@\"", $0.weight, $0.text) }.joined(separator: ", "))
    let t = u.timing
    print(String(format: "   end: %@, speech %.2f-%.2f s, endpoint %.0f ms, finalize %.0f ms, speech end -> final %.0f ms%@%@%@",
                 u.endReason.rawValue, t.speechStart, t.speechEnd, t.endpointMs, t.finalizeMs, t.totalMs,
                 t.killed ? ", killed" : "", t.reopens > 0 ? ", reopened \(t.reopens)x" : "", realtime ? "" : " (fast pacing)"))
    guard let interpreter else { continue }
    if isAnswer {
        let outcome = interpreter.selection(u.hypotheses, candidates: candidates, now: now)
        var line = "   selection: \(outcome)"
        if case .pick(let n) = outcome, candidates.indices.contains(n) { line += " -> \(candidates[n])" }
        print(line)
    } else {
        let result = interpreter.command(u.hypotheses, now: now)
        print("   interpretation: \(Regression.describe(result))")
        if case .project(.ambiguous(let list), _) = result { candidates = list.map(\.project.id) }
    }
}
await session.stop()
consumer.cancel()
