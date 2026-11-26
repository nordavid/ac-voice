import ACVoiceCore
import AVFoundation
@testable import ACVoiceSpeech
import Foundation
import Testing

/// Opt-in end-to-end tests: TTS clip -> FileSource (real time) -> VoiceSession -> Interpreter.
///
///     scripts/make-tts-fixtures.sh
///     ACVOICE_SPEECH_TESTS=1 swift test --filter ACVoiceSpeechTests
///
/// No microphone and no speech authorization: buffer input needs neither (research 3). Expectations come from the
/// ground truth text of each clip run through the same Interpreter. Set ACVOICE_CONTEXT_SWEEP=1 to also compare
/// context sizes (REVIEW m10).
///
/// The committed run uses the fantasy codes of Tests/Fixtures/projects.sample.json. The same suite also runs the
/// real-code clips against a private list (both git-ignored, docs/DEVELOPMENT.md "Opt-in speech tests"):
///
///     scripts/make-tts-fixtures.sh --private
///     ACVOICE_SPEECH_TESTS=1 ACVOICE_E2E_PRIVATE=1 swift test --filter SpeechEndToEndTests
///
/// ACVOICE_E2E_PRIVATE=1 reads Tests/Fixtures/private/tts and Tests/Fixtures/private/projects.json.
/// ACVOICE_TTS_DIR and ACVOICE_E2E_PROJECTS (.json or .tsv) set either path directly, relative to the repository root.
enum E2E {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["ACVOICE_SPEECH_TESTS"] == "1"
    static let sweep = env["ACVOICE_CONTEXT_SWEEP"] == "1"
    static let isPrivate = env["ACVOICE_E2E_PRIVATE"] == "1"
    /// Repository root: Tests/Fixtures/../..
    static let root = Fixture.dir.deletingLastPathComponent().deletingLastPathComponent()
    static let ttsDir = path(env["ACVOICE_TTS_DIR"]) ?? Fixture.dir.appendingPathComponent(isPrivate ? "private/tts" : "tts")
    /// nil: the committed fixture.
    static let projectsFile = path(env["ACVOICE_E2E_PROJECTS"]) ?? (isPrivate ? Fixture.dir.appendingPathComponent("private/projects.json") : nil)
    static let contextLimit = env["ACVOICE_CONTEXT_LIMIT"].flatMap(Int.init) ?? ContextBuilder.defaultLimit

    static func path(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        return s.hasPrefix("/") ? URL(fileURLWithPath: s) : root.appendingPathComponent(s)
    }

    /// The list the clips are checked against, with its aliases and signals.
    static let list: (projects: [ProjectEntry], now: Date) = {
        guard let url = projectsFile else { return (Fixture.projects, Fixture.now) }
        if url.pathExtension == "json" {
            guard let catalog = try? ProjectCatalog.load(url) else { fatalError("cannot read \(url.path)") }
            return (catalog.entries(now: catalog.referenceDate), catalog.referenceDate)
        }
        guard let tsv = try? String(contentsOf: url, encoding: .utf8) else { fatalError("cannot read \(url.path)") }
        return (ProjectCatalog.entries(tsv: tsv), Date())
    }()
    static var projects: [ProjectEntry] { list.projects }
    static var now: Date { list.now }
    static let interpreter = projectsFile == nil ? Fixture.interpreter : Interpreter(resolver: Resolver(projects: list.projects))
    static func project(_ id: Int) -> ProjectEntry { projects.first { $0.id == id }! }
    /// Project ids of an expected "choices a,b,c" outcome; empty for any other outcome.
    static func choiceIds(_ expected: String) -> [Int] {
        guard expected.hasPrefix("choices ") else { return [] }
        return expected.dropFirst("choices ".count).split(separator: ",").compactMap { Int($0) }
    }
    /// Code keys the ground truth names exactly ("WWT", "S+K" -> "sk"): the base of the code-hit rate per transcriber.
    static func codeKeys(_ text: String) -> Set<String> {
        let codes = Set(projects.compactMap { $0.code.map(ProjectEntry.codeKey) })
        return Set(TextNorm.tokenize(text).map(\.key).filter(codes.contains))
    }
    /// German TTS garbles the codes and title words of these clips (research 5). Reported, not asserted.
    static let lenient: Set<String> = ["c03", "c04", "m02"]
    /// Ground truth ends in a number: the flow asks for `HangoverPolicy.trailingNumber` by design (REVIEW M1).
    static func endsInNumber(_ c: Clip) -> Bool { Parser.endsInNumeral(c.text) }

    struct Clip: Sendable {
        let id: String
        let voice: String
        let kind: UtteranceMode
        let files: [URL]
        let text: String
    }

    /// The clips of `dir`'s manifest.tsv; `hint` names the script call that renders them.
    static func clips(in dir: URL = ttsDir, hint: String = isPrivate ? " --private" : "") throws -> [Clip] {
        let url = dir.appendingPathComponent("manifest.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Missing(message: "\(url.path) missing: run scripts/make-tts-fixtures.sh\(hint)")
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line -> Clip? in
            guard !line.hasPrefix("#") else { return nil }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { return nil }
            return Clip(id: f[0], voice: f[1], kind: f[2] == "answer" ? .answer : .command,
                        files: f[3].split(separator: "+").map { dir.appendingPathComponent(String($0)) }, text: f[4])
        }
    }

    struct Missing: Error, CustomStringConvertible { let message: String; var description: String { message } }

    /// Queues a clip. Parts of mixed-voice clips lose their TTS silence and get a natural 120 ms gap.
    static func play(_ clip: Clip, on source: FileSource) throws {
        guard clip.files.count > 1 else { try source.enqueue(contentsOf: clip.files[0]); return }
        for (i, f) in clip.files.enumerated() {
            if i > 0 { source.enqueue(silence: 0.12) }
            try source.enqueue(contentsOf: f, trimSilence: true)
        }
        source.enqueue(silence: 0.3)
    }

    static func expectedCommand(_ text: String) -> String {
        Regression.describe(interpreter.command([Hypothesis(text)], now: now))
    }

    /// Quantile; infinity for no values, so a budget check on an empty list fails (review: answers that never
    /// arrived passed the p90 gate).
    static func p(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((q * Double(s.count)).rounded(.up)) - 1))]
    }

    static func stats(_ values: [Double]) -> String {
        String(format: "n=%d p50 %.0f ms, p90 %.0f ms, max %.0f ms", values.count, p(values, 0.5), p(values, 0.9), values.max() ?? 0)
    }
}

/// Consumes a session's events like the app's flow: collects utterances and sends the hangover VoiceFlow sends for
/// every live partial (Core `HangoverPolicy.standard`, PLAN 2.3), in the command and in the answer phase, with the
/// rules of `interpreter`'s language.
final class Pump: @unchecked Sendable {
    private let lock = NSLock()
    private var utterances: [VoiceSession.Event] = []
    private var _kinds: [String] = []
    private var _mode = UtteranceMode.command
    private var task: Task<Void, Never>?
    /// Candidates of the visible list in the answer phase.
    let candidates: [Int]

    init(_ events: AsyncStream<VoiceSession.Event>, session: VoiceSession, adaptive: Bool = true, candidates: [Int] = [],
         interpreter: Interpreter = E2E.interpreter, now: Date = E2E.now) {
        self.candidates = candidates
        task = Task { [self] in
            var last: Double?
            for await e in events {
                lock.withLock { _kinds.append(Self.name(e.kind)) }
                switch e.kind {
                case .partial(let dt, let st):
                    guard adaptive, !dt.isEmpty || !st.isEmpty else { break }
                    let h = mode == .command ? Controller.commandHangover(dt, st, using: interpreter, now: now)
                        : Controller.answerHangover(dt, st, candidates: self.candidates, using: interpreter, now: now)
                    if h != last { session.setHangover(h); last = h }   // the flow sends changes only
                case .utterance, .noSpeech:
                    last = nil
                    lock.withLock { utterances.append(e) }
                default: break
                }
            }
        }
    }

    var mode: UtteranceMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }
    var kinds: [String] { lock.withLock { _kinds } }

    /// Next utterance (or no-speech) event.
    func next(timeout: Double = 15) async -> VoiceSession.Event? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = lock.withLock({ utterances.isEmpty ? nil : utterances.removeFirst() }) { return e }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return nil
    }

    func finish() async { await task?.value }

    static func name(_ k: VoiceSession.Kind) -> String {
        switch k {
        case .warming: "warming"
        case .ready: "ready"
        case .micReady: "micReady"
        case .level: "level"
        case .speechStarted: "speechStarted"
        case .endpoint: "endpoint"
        case .resumed: "resumed"
        case .discarded: "discarded"
        case .partial: "partial"
        case .utterance: "utterance"
        case .noSpeech: "noSpeech"
        case .sourceRestarted: "sourceRestarted"
        case .failed(let e): "failed(\(e.message))"
        }
    }
}

extension VoiceSession.Event {
    var utteranceValue: VoiceSession.Utterance? { if case .utterance(let u) = kind { return u }; return nil }
}

struct Row {
    var clip: E2E.Clip
    var expected: String
    var actual: String
    var utterance: VoiceSession.Utterance?
    /// `.resumed` events of the press: one per reopen of the utterance (the runtime maps them to the flow).
    var resumes = 0
    var retried = false
    var passed: Bool { actual == expected }

    var line: String {
        guard let u = utterance else { return "\(clip.id) \(clip.voice): NO UTTERANCE (expected \(expected))" }
        let t = u.timing
        return String(format: "%@ %@ %@%@ | %@%@ | end %@ endpoint %.0f finalize %.0f total %.0f ms%@%@ | DT \"%@\" ST \"%@\"",
                      clip.id, clip.voice, passed ? "ok  " : "FAIL", retried ? " (2nd try)" : "", actual, passed ? "" : " (expected \(expected))",
                      u.endReason.rawValue, t.endpointMs, t.finalizeMs, t.totalMs, t.killed ? " killed" : "",
                      t.reopens > 0 ? " reopened \(t.reopens)x" : "",
                      u.dictation.best, u.speech.best)
    }
}

/// The German and the English speech suites share the speech assets, the CPU and the real-time clips: they run one
/// after another, never in parallel (`EnglishSpeechEndToEndTests`).
@Suite(.serialized, .enabled(if: E2E.enabled)) enum SpeechEndToEnd {}

extension SpeechEndToEnd {
    @Suite("Speech end to end (ACVOICE_SPEECH_TESTS=1)", .serialized)
    struct SpeechEndToEndTests {
        let commandContext = ContextBuilder.command(projects: E2E.projects, now: E2E.now, limit: E2E.contextLimit)

        /// One key press: start, play the clip after 0.3 s of room noise, wait for the utterance, stop.
        func runCommand(_ session: VoiceSession, _ clip: E2E.Clip, context: [String]) async throws -> Row {
            let source = FileSource(pacing: .realTime)
            let pump = Pump(try await session.start(context: context, source: source), session: session)
            try E2E.play(clip, on: source)
            let event = await pump.next()
            await session.stop()
            await pump.finish()
            let u = event?.utteranceValue
            let actual = u.map { Regression.describe(E2E.interpreter.command($0.hypotheses, now: E2E.now)) } ?? "no utterance"
            return Row(clip: clip, expected: E2E.expectedCommand(clip.text), actual: actual, utterance: u,
                       resumes: pump.kinds.filter { $0 == "resumed" }.count)
        }

        /// Every command clip once. With `retry`, a strict clip that misses gets one more press: the transcribers vary
        /// from run to run (DT sometimes splits a glued title word), a broken pipeline fails both times. `attempts` holds
        /// every press, for the latency numbers.
        func commandRows(limit: Int, retry: Bool = false) async throws -> (rows: [Row], attempts: [Row]) {
            let clips = try E2E.clips().filter { $0.kind == .command }
            let context = ContextBuilder.command(projects: E2E.projects, now: E2E.now, limit: limit)
            let session = VoiceSession()
            try await session.warmUp(context: context)
            var rows: [Row] = [], attempts: [Row] = []
            for clip in clips {
                var row = try await runCommand(session, clip, context: context)
                attempts.append(row)
                try await Task.sleep(for: .milliseconds(500))   // next press; the next analyzer is pre-built meanwhile
                if retry, !row.passed, !E2E.lenient.contains(clip.id) {
                    print("retry " + row.line)
                    row = try await runCommand(session, clip, context: context)
                    row.retried = true
                    attempts.append(row)
                    try await Task.sleep(for: .milliseconds(500))
                }
                rows.append(row)
            }
            return (rows, attempts)
        }

        @Test func commandClips() async throws {
            let (rows, attempts) = try await commandRows(limit: E2E.contextLimit, retry: true)
            print("== command clips (context \(E2E.contextLimit) strings, \(E2E.projectsFile?.lastPathComponent ?? "projects.sample.json"), \(E2E.ttsDir.path))")
            for r in rows { print(r.line) }
            for r in rows where !E2E.lenient.contains(r.clip.id) {
                #expect(r.passed, "\(r.clip.id): \(r.actual), expected \(r.expected)")
            }
            // A 700 ms pause after a dangling word must not split the utterance (REVIEW M1).
            for r in rows where r.clip.id.hasPrefix("s0") && ["s03", "s04", "s05"].contains(r.clip.id) {
                let u = try #require(r.utterance, "\(r.clip.id)")
                #expect(u.timing.speechEnd - u.timing.speechStart > 1.2, "\(r.clip.id) was cut at the pause")
            }
            let regular = attempts.filter { !E2E.endsInNumber($0.clip) && $0.utterance?.endReason == .pause }.compactMap { $0.utterance?.timing.totalMs }
            let numbers = attempts.filter { E2E.endsInNumber($0.clip) }.compactMap { $0.utterance?.timing.totalMs }
            let numberEndpoints = attempts.filter { E2E.endsInNumber($0.clip) && $0.utterance?.endReason == .pause }
                .compactMap { $0.utterance?.timing.endpointMs }
            // Review: a final ending in a number reopened once although the gate had waited the incomplete hangover
            // (+100 ms and a second finalize). The clips without a pause must end without a reopen.
            for r in attempts where ["c05", "c06"].contains(r.clip.id) {
                #expect(r.utterance?.timing.reopens == 0, "\(r.clip.id) reopened")
            }
            // Every reopen tells the runtime (`.resumed`), so a flow that moved to processing at `.endpoint` goes back.
            for r in attempts {
                if let u = r.utterance { #expect(r.resumes == u.timing.reopens, "\(r.clip.id): resumed \(r.resumes)x, reopened \(u.timing.reopens)x") }
            }
            let passed = rows.filter(\.passed).count
            print("commands: \(passed)/\(rows.count) as expected (strict: \(rows.filter { !E2E.lenient.contains($0.clip.id) && $0.passed }.count)/\(rows.filter { !E2E.lenient.contains($0.clip.id) }.count), retries: \(rows.filter(\.retried).count))")
            // How often each transcriber heard the spoken code exactly (no lookalike, no alias, no glued title).
            let coded = rows.compactMap { r -> (Set<String>, VoiceSession.Utterance)? in
                let keys = E2E.codeKeys(r.clip.text)
                guard !keys.isEmpty, let u = r.utterance else { return nil }
                return (keys, u)
            }
            let heard = { (text: String, keys: Set<String>) in keys.isSubset(of: Set(TextNorm.tokenize(text).map(\.key))) }
            print("code heard exactly: DT \(coded.filter { heard($0.1.dictation.best, $0.0) }.count)/\(coded.count), "
                  + "ST \(coded.filter { heard($0.1.speech.best, $0.0) }.count)/\(coded.count)")
            print("speech end -> final, commands: " + E2E.stats(regular))
            print("speech end -> final, commands ending in a number (incomplete hangover): " + E2E.stats(numbers))
            print("speech end -> decision, commands ending in a number: " + E2E.stats(numberEndpoints))
            #expect(E2E.p(regular, 0.9) <= 750)
            #expect(E2E.p(numbers, 0.9) <= (HangoverPolicy.standard.trailingNumber + 0.25) * 1000)
            #expect(attempts.allSatisfy { $0.utterance?.timing.killed == false })
        }

        @Test func answerClips() async throws {
            let clips = try E2E.clips()
            let command = try #require(clips.first { $0.id == "c01" })
            let answers = clips.filter { $0.kind == .answer }
            // The answers pick from the list the c01 command shows.
            let candidates = E2E.choiceIds(E2E.expectedCommand(command.text))
            if E2E.projectsFile == nil { #expect(candidates == Fixture.wwtList) }
            try #require(candidates.count >= 2, "c01 must show a list: \(E2E.expectedCommand(command.text))")
            let answerContext = ContextBuilder.answer(choices: candidates.map(E2E.project), limit: E2E.contextLimit)
            let session = VoiceSession()
            try await session.warmUp(context: commandContext)
            var latencies: [Double] = []
            var failures = 0
            print("== answers after \"\(command.text)\"")
            for (i, clip) in answers.enumerated() {
                // Stamped like the app: the flow's session and utterance numbers, and the flow's hangovers.
                let gen = SpeechGen(session: 100 + i, utterance: 1)
                let source = FileSource(pacing: .realTime)
                let pump = Pump(try await session.start(context: commandContext, source: source, gen: gen,
                                                        hangover: HangoverPolicy.standard.command), session: session,
                                candidates: candidates)
                try E2E.play(command, on: source)
                let first = try #require(await pump.next(), "no command utterance")
                #expect(first.gen == gen)
                pump.mode = .answer
                await session.expectAnswer(context: answerContext, gen: SpeechGen(session: gen.session, utterance: 2),
                                           hangover: HangoverPolicy.standard.answer)
                try await Task.sleep(for: .milliseconds(400))   // reaction time after the list appears
                try E2E.play(clip, on: source)
                let second = await pump.next()
                await session.stop()
                await pump.finish()
                let expected = E2E.interpreter.selection([Hypothesis(clip.text)], candidates: candidates, now: E2E.now)
                guard let second, let u = second.utteranceValue else {
                    Issue.record("\(clip.id): no answer utterance")
                    failures += 1
                    continue
                }
                #expect(second.gen == SpeechGen(session: 100 + i, utterance: 2))
                let actual = E2E.interpreter.selection(u.hypotheses, candidates: candidates, now: E2E.now)
                if actual != expected { failures += 1 }
                #expect(actual == expected, "\(clip.id): \(actual), expected \(expected)")
                latencies.append(u.timing.totalMs)
                print(String(format: "%@ %@ %@ | %@ | end %@ endpoint %.0f finalize %.0f total %.0f ms | DT \"%@\" ST \"%@\"",
                             clip.id, clip.voice, actual == expected ? "ok  " : "FAIL", "\(actual)", u.endReason.rawValue,
                             u.timing.endpointMs, u.timing.finalizeMs, u.timing.totalMs, u.dictation.best, u.speech.best))
                try await Task.sleep(for: .milliseconds(500))
            }
            print("answers: \(answers.count - failures)/\(answers.count) as expected")
            print("speech end -> final, answers: " + E2E.stats(latencies))
            #expect(failures == 0)
            try #require(!answers.isEmpty && latencies.count == answers.count, "every answer clip needs an utterance")
            #expect(E2E.p(latencies, 0.9) <= 550)
        }

        /// REVIEW M2: a finalize that hits its deadline kills the analyzer; the session rebuilds it and the next
        /// utterance in the same session is transcribed normally.
        @Test func killedFinalizeRebuildsTheAnalyzer() async throws {
            let clips = try E2E.clips()
            let myTasks = try #require(clips.first { $0.id == "c07" })
            let session = VoiceSession()
            try await session.warmUp(context: commandContext)
            session.killNextFinalize = true
            let source = FileSource(pacing: .realTime)
            let pump = Pump(try await session.start(context: commandContext, source: source), session: session)
            try E2E.play(myTasks, on: source)
            let first = try #require(await pump.next()?.utteranceValue)
            #expect(first.timing.killed)
            await session.expectCommand()
            try await Task.sleep(for: .milliseconds(300))
            try E2E.play(myTasks, on: source)
            let second = try #require(await pump.next()?.utteranceValue)
            await session.stop()
            await pump.finish()
            #expect(!second.timing.killed)
            #expect(Regression.describe(E2E.interpreter.command(second.hypotheses, now: E2E.now)) == "my")
            #expect(pump.kinds.filter { $0 == "ready" }.count == 2)   // first analyzer, then the rebuilt one
            print(String(format: "killed finalize: first texts from volatile results (\"%@\"), second total %.0f ms",
                         first.dictation.best, second.timing.totalMs))
        }

        /// REVIEW m5 and M3: a press before the analyzer is warm buffers audio; stop and start in quick succession,
        /// even concurrently, leave a working session.
        @Test func coldStartAndLifecycleRaces() async throws {
            let clips = try E2E.clips()
            let myTasks = try #require(clips.first { $0.id == "c07" })
            let session = VoiceSession()   // no warmUp: the first start is cold

            let source = FileSource(pacing: .realTime)
            let pump = Pump(try await session.start(context: commandContext, source: source), session: session)
            try E2E.play(myTasks, on: source)
            let cold = try #require(await pump.next()?.utteranceValue)
            #expect(pump.kinds.prefix(2).contains("warming"))
            #expect(Regression.describe(E2E.interpreter.command(cold.hypotheses, now: E2E.now)) == "my")
            let firstSession = try #require(session.currentSession)

            // "Cancel the list, press again at once": stop, then start while the next analyzer is still being built.
            await session.stop()
            let source2 = FileSource(pacing: .realTime)
            let pump2 = Pump(try await session.start(context: commandContext, source: source2), session: session)
            #expect(session.currentSession == firstSession + 1)
            // Stop and start racing each other: either order must leave the session consistent.
            async let stopped: Void = session.stop()
            async let restarted = session.start(context: commandContext, source: FileSource(pacing: .realTime))
            _ = await stopped
            let raced = try await restarted
            await pump.finish()
            await pump2.finish()
            await session.stop()
            for await _ in raced {}   // the raced stream ends after stop

            // A clean press afterwards works.
            let source3 = FileSource(pacing: .realTime)
            let pump3 = Pump(try await session.start(context: commandContext, source: source3), session: session)
            try E2E.play(myTasks, on: source3)
            let last = try #require(await pump3.next()?.utteranceValue)
            await session.stop()
            await pump3.finish()
            #expect(Regression.describe(E2E.interpreter.command(last.hypotheses, now: E2E.now)) == "my")
            print(String(format: "cold start: speech end -> final %.0f ms; after races: %.0f ms", cold.timing.totalMs, last.timing.totalMs))
        }

        /// Press-to-end: the synthetic tail lets finalize return without waiting for audio (REVIEW M2).
        @Test func pressToEndFinalizesAtOnce() async throws {
            let clips = try E2E.clips()
            let myTasks = try #require(clips.first { $0.id == "c07" })
            let session = VoiceSession()
            try await session.warmUp(context: commandContext)
            let source = FileSource(pacing: .realTime)
            let pump = Pump(try await session.start(context: commandContext, source: source), session: session, adaptive: false)
            #expect(!session.endUtteranceNow())   // before any speech: ignored
            try E2E.play(myTasks, on: source)
            await source.waitUntilDrained()
            try await Task.sleep(for: .milliseconds(150))
            let pressed = Date()
            #expect(session.endUtteranceNow())
            let u = try #require(await pump.next()?.utteranceValue)
            let ms = Date().timeIntervalSince(pressed) * 1000
            await session.stop()
            await pump.finish()
            // The runtime starts its "speech end -> final" signpost on `.endpoint`.
            let kinds = pump.kinds
            let endpoint = try #require(kinds.firstIndex(of: "endpoint")), final = try #require(kinds.firstIndex(of: "utterance"))
            #expect(endpoint < final)
            #expect(u.endReason == .manual)
            #expect(Regression.describe(E2E.interpreter.command(u.hypotheses, now: E2E.now)) == "my")
            #expect(ms < 400)
            print(String(format: "press to end -> final %.0f ms (finalize %.0f ms)", ms, u.timing.finalizeMs))
        }

        /// Review (REVIEW m5): a press while `warmUp` still runs starts the microphone at once instead of waiting
        /// for the whole warm-up; the audio is buffered and transcribed once the analyzer is ready.
        @Test func pressDuringWarmUpStartsTheMicAtOnce() async throws {
            let myTasks = try #require(try E2E.clips().first { $0.id == "c07" })
            let session = VoiceSession()
            let context = commandContext
            let warm = Task { try await session.warmUp(context: context) }
            try await Task.sleep(for: .milliseconds(50))
            let pressed = Date()
            let source = FileSource(pacing: .realTime)
            let pump = Pump(try await session.start(context: commandContext, source: source), session: session)
            let startMs = Date().timeIntervalSince(pressed) * 1000
            try E2E.play(myTasks, on: source)
            let u = try #require(await pump.next()?.utteranceValue)
            try await warm.value
            await session.stop()
            await pump.finish()
            let kinds = pump.kinds
            print(String(format: "press during warm-up: start() %.0f ms, events %@, speech end -> final %.0f ms", startMs,
                         kinds.filter { $0 != "level" && $0 != "partial" }.joined(separator: ","), u.timing.totalMs))
            #expect(startMs < 600)
            #expect(kinds.first == "warming")
            let mic = try #require(kinds.firstIndex(of: "micReady")), ready = try #require(kinds.firstIndex(of: "ready"))
            #expect(mic < ready)   // audio flows while the analyzer still loads
            #expect(Regression.describe(E2E.interpreter.command(u.hypotheses, now: E2E.now)) == "my")
        }

        /// Review: a cough before the command made an utterance without words ("Nicht verstanden") and the command
        /// after it was never heard. Now the session listens on and hears the command.
        @Test func noiseBurstBeforeTheCommandIsIgnored() async throws {
            let myTasks = try #require(try E2E.clips().first { $0.id == "c07" })
            let session = VoiceSession()
            try await session.warmUp(context: commandContext)
            let source = FileSource(pacing: .realTime)
            let pump = Pump(try await session.start(context: commandContext, source: source), session: session)
            let burst = try #require(AudioUtil.noise(source.format, frames: AVAudioFrameCount(0.25 * source.format.sampleRate), db: -22))
            try source.enqueue(burst)
            source.enqueue(silence: 1.5)
            try E2E.play(myTasks, on: source)
            let first = try #require(await pump.next(timeout: 10))
            await session.stop()
            await pump.finish()
            let u = try #require(first.utteranceValue, "expected the command, got \(Pump.name(first.kind))")
            print(String(format: "noise burst, then command: speech %.2f-%.2f s, %@ | DT \"%@\" ST \"%@\"", u.timing.speechStart,
                         u.timing.speechEnd, Regression.describe(E2E.interpreter.command(u.hypotheses, now: E2E.now)),
                         u.dictation.best, u.speech.best))
            #expect(first.utterance == 1)
            #expect(u.timing.speechStart > 1.5)   // the command, not the burst at 0.3 s
            #expect(Regression.describe(E2E.interpreter.command(u.hypotheses, now: E2E.now)) == "my")
            #expect(pump.kinds.filter { $0 == "speechStarted" }.count == 2)
            // The burst's end tells the runtime it was noise (review C1: the flow counts the no-speech time again).
            let events = pump.kinds.filter { ["speechStarted", "endpoint", "discarded", "utterance"].contains($0) }
            #expect(Array(events.prefix(4)) == ["speechStarted", "endpoint", "discarded", "speechStarted"], "\(events)")
        }

        /// Review: the self-check timeout did not bound the call (20 ms -> 710 ms). A killed check leaves later
        /// checks working.
        @Test func selfCheckTimeoutBoundsTheCall() async throws {
            let clip = try #require(try E2E.clips().first { $0.id == "c07" })
            let t0 = Date()
            let r = await SpeechSelfCheck.run(clip: clip.files[0], expecting: ["zeig", "meine", "aufgaben"], timeout: 0.05)
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "self-check with 50 ms timeout: %@ after %.0f ms", r.message, ms))
            #expect(!r.passed)
            #expect(ms < 300)
            let again = await SpeechSelfCheck.run(clip: clip.files[0], expecting: ["zeig", "meine", "aufgaben"])
            #expect(again.passed)
        }

        @Test func noSpeechAfterTimeout() async throws {
            var tuning = VoiceSession.Tuning()
            tuning.gate.noSpeechTimeout = 1.5
            let session = VoiceSession(tuning: tuning)
            try await session.warmUp(context: commandContext)
            let pump = Pump(try await session.start(context: commandContext, source: FileSource(pacing: .realTime)), session: session)
            let e = try #require(await pump.next(timeout: 5))
            await session.stop()
            await pump.finish()
            guard case .noSpeech = e.kind else { Issue.record("expected noSpeech, got \(Pump.name(e.kind))"); return }
            #expect(pump.kinds.contains("micReady"))
            #expect(!pump.kinds.contains("speechStarted"))
        }

        @Test func selfCheckWithoutMicrophone() async throws {
            let synthesized = await SpeechSelfCheck.run()
            print(String(format: "self-check (synthesized): %@ \"%@\" %.0f ms", synthesized.message, synthesized.transcript, synthesized.elapsedMs))
            #expect(synthesized.passed)
            let clip = try #require(try E2E.clips().first { $0.id == "c07" })
            let file = await SpeechSelfCheck.run(clip: clip.files[0], expecting: ["zeig", "meine", "aufgaben"])
            print(String(format: "self-check (clip): %@ \"%@\" %.0f ms", file.message, file.transcript, file.elapsedMs))
            #expect(file.passed)
        }

        /// REVIEW m10: accuracy per context size. Only with ACVOICE_CONTEXT_SWEEP=1 (about 4 x 1 min).
        @Test(.enabled(if: E2E.sweep)) func contextSizeSweep() async throws {
            for limit in [0, 19, 35, 50] {
                let rows = try await commandRows(limit: limit).rows
                let strict = rows.filter { !E2E.lenient.contains($0.clip.id) }
                print("context \(limit): \(rows.filter(\.passed).count)/\(rows.count) as expected, strict \(strict.filter(\.passed).count)/\(strict.count)")
                for r in rows where !r.passed { print("   " + r.line) }
            }
        }
    }
}
