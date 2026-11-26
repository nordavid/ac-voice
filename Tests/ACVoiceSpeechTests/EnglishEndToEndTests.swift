import ACVoiceCore
import AVFoundation
@testable import ACVoiceSpeech
import Foundation
import Testing

/// Opt-in English end-to-end tests: English TTS clip -> FileSource (real time) -> VoiceSession (en_US) -> Interpreter
/// (`AppLanguage.en`). Same structure and budgets as `SpeechEndToEndTests`; both suites run one after another.
///
///     scripts/make-tts-fixtures.sh --lang en
///     ACVOICE_SPEECH_TESTS=1 swift test --filter SpeechEndToEndTests
///
/// The clips use the fantasy codes of Tests/Fixtures/projects.sample.json; codes and German title words stay as they
/// are (AC names). ACVOICE_TTS_EN_DIR sets the clip folder (relative to the repository root); ACVOICE_E2E_PRIVATE=1
/// reads Tests/Fixtures/private/tts-en (`make-tts-fixtures.sh --lang en --private`) with the private project list.
enum E2EEn {
    static let ttsDir = E2E.path(E2E.env["ACVOICE_TTS_EN_DIR"])
        ?? Fixture.dir.appendingPathComponent(E2E.isPrivate ? "private/tts-en" : "tts-en")
    static var projects: [ProjectEntry] { E2E.projects }
    static var now: Date { E2E.now }
    static let interpreter = Interpreter(resolver: Resolver(projects: E2E.list.projects), language: .en)
    static let locale = AppLanguage.en.speechLocale
    /// German title words in an English voice ("Touren Planer", "Betreuung", "Pilzdatenbank"): an English voice
    /// says them with English sounds, so the transcribers may not write the title. Reported, not asserted.
    static let lenient: Set<String> = ["c04", "c14", "c15"]

    static func clips() throws -> [E2E.Clip] {
        try E2E.clips(in: ttsDir, hint: " --lang en" + (E2E.isPrivate ? " --private" : ""))
    }

    static func expectedCommand(_ text: String) -> String {
        Regression.describe(interpreter.command([Hypothesis(text)], now: now))
    }

    static func describe(_ u: VoiceSession.Utterance) -> String {
        Regression.describe(interpreter.command(u.hypotheses, now: now))
    }

    /// Ground truth ends in a number: the flow asks for `HangoverPolicy.trailingNumber` by design (REVIEW M1).
    static func endsInNumber(_ c: E2E.Clip) -> Bool { Parser.endsInNumeral(c.text, language: .en) }

    /// Code keys the ground truth names exactly, read with English letter names ("S and K" -> "sk").
    static func codeKeys(_ text: String) -> Set<String> {
        let codes = Set(projects.compactMap { $0.code.map(ProjectEntry.codeKey) })
        return Set(TextNorm.tokenize(text, language: .en).map(\.key).filter(codes.contains))
    }

    static func session(tuning: VoiceSession.Tuning = .init()) -> VoiceSession { VoiceSession(tuning: tuning, locale: locale) }

    static func pump(_ events: AsyncStream<VoiceSession.Event>, _ session: VoiceSession, adaptive: Bool = true,
                     candidates: [Int] = []) -> Pump {
        Pump(events, session: session, adaptive: adaptive, candidates: candidates, interpreter: interpreter, now: now)
    }
}

extension SpeechEndToEnd {
    @Suite("English speech end to end (ACVOICE_SPEECH_TESTS=1)", .serialized)
    struct EnglishSpeechEndToEndTests {
        let commandContext = ContextBuilder.command(projects: E2EEn.projects, now: E2EEn.now, limit: E2E.contextLimit,
                                                    language: .en)

        /// One key press: start, play the clip after 0.3 s of room noise, wait for the utterance, stop.
        func runCommand(_ session: VoiceSession, _ clip: E2E.Clip, context: [String]) async throws -> Row {
            let source = FileSource(pacing: .realTime)
            let pump = E2EEn.pump(try await session.start(context: context, source: source), session)
            try E2E.play(clip, on: source)
            let event = await pump.next()
            await session.stop()
            await pump.finish()
            let u = event?.utteranceValue
            return Row(clip: clip, expected: E2EEn.expectedCommand(clip.text), actual: u.map(E2EEn.describe) ?? "no utterance",
                       utterance: u, resumes: pump.kinds.filter { $0 == "resumed" }.count)
        }

        /// Every command clip once; a strict clip that misses gets one more press (as in the German suite).
        func commandRows(limit: Int, retry: Bool = false) async throws -> (rows: [Row], attempts: [Row]) {
            let clips = try E2EEn.clips().filter { $0.kind == .command }
            let context = ContextBuilder.command(projects: E2EEn.projects, now: E2EEn.now, limit: limit, language: .en)
            let session = E2EEn.session()
            try await session.warmUp(context: context)
            var rows: [Row] = [], attempts: [Row] = []
            for clip in clips {
                var row = try await runCommand(session, clip, context: context)
                attempts.append(row)
                try await Task.sleep(for: .milliseconds(500))
                if retry, !row.passed, !E2EEn.lenient.contains(clip.id) {
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
            print("== English command clips (context \(E2E.contextLimit) strings, \(E2E.projectsFile?.lastPathComponent ?? "projects.sample.json"), \(E2EEn.ttsDir.path))")
            for r in rows { print(r.line) }
            for r in rows where !E2EEn.lenient.contains(r.clip.id) {
                #expect(r.passed, "\(r.clip.id): \(r.actual), expected \(r.expected)")
            }
            // A 700 ms pause after a dangling word must not split the utterance (REVIEW M1).
            for r in rows where ["s03", "s04", "s05"].contains(r.clip.id) {
                let u = try #require(r.utterance, "\(r.clip.id)")
                #expect(u.timing.speechEnd - u.timing.speechStart > 1.2, "\(r.clip.id) was cut at the pause")
            }
            let regular = attempts.filter { !E2EEn.endsInNumber($0.clip) && $0.utterance?.endReason == .pause }
                .compactMap { $0.utterance?.timing.totalMs }
            let numbers = attempts.filter { E2EEn.endsInNumber($0.clip) }.compactMap { $0.utterance?.timing.totalMs }
            let numberEndpoints = attempts.filter { E2EEn.endsInNumber($0.clip) && $0.utterance?.endReason == .pause }
                .compactMap { $0.utterance?.timing.endpointMs }
            for r in attempts where ["c05", "c06"].contains(r.clip.id) {
                #expect(r.utterance?.timing.reopens == 0, "\(r.clip.id) reopened")
            }
            for r in attempts {
                if let u = r.utterance { #expect(r.resumes == u.timing.reopens, "\(r.clip.id): resumed \(r.resumes)x, reopened \(u.timing.reopens)x") }
            }
            let strict = rows.filter { !E2EEn.lenient.contains($0.clip.id) }
            print("English commands: \(rows.filter(\.passed).count)/\(rows.count) as expected (strict: \(strict.filter(\.passed).count)/\(strict.count), retries: \(rows.filter(\.retried).count))")
            let coded = rows.compactMap { r -> (Set<String>, VoiceSession.Utterance)? in
                let keys = E2EEn.codeKeys(r.clip.text)
                guard !keys.isEmpty, let u = r.utterance else { return nil }
                return (keys, u)
            }
            let heard = { (text: String, keys: Set<String>) in keys.isSubset(of: Set(TextNorm.tokenize(text, language: .en).map(\.key))) }
            print("code heard exactly: DT \(coded.filter { heard($0.1.dictation.best, $0.0) }.count)/\(coded.count), "
                  + "ST \(coded.filter { heard($0.1.speech.best, $0.0) }.count)/\(coded.count)")
            print("speech end -> final, English commands: " + E2E.stats(regular))
            print("speech end -> final, English commands ending in a number (incomplete hangover): " + E2E.stats(numbers))
            print("speech end -> decision, English commands ending in a number: " + E2E.stats(numberEndpoints))
            // Lenient clips count here too: lenient covers the title words, not the timing. A mangled title whose live
            // partial ends in a dangling word (c15 "BDG pills and") waits the incomplete hangover, as it would for a
            // user. The p90 allows one such press.
            #expect(E2E.p(regular, 0.9) <= 750)
            #expect(E2E.p(numbers, 0.9) <= (HangoverPolicy.standard.trailingNumber + 0.25) * 1000)
            #expect(attempts.allSatisfy { $0.utterance?.timing.killed == false })
        }

        @Test func answerClips() async throws {
            let clips = try E2EEn.clips()
            let command = try #require(clips.first { $0.id == "c01" })
            let answers = clips.filter { $0.kind == .answer }
            let candidates = E2E.choiceIds(E2EEn.expectedCommand(command.text))
            if E2E.projectsFile == nil { #expect(candidates == Fixture.wwtList) }
            try #require(candidates.count >= 2, "c01 must show a list: \(E2EEn.expectedCommand(command.text))")
            let answerContext = ContextBuilder.answer(choices: candidates.map(E2E.project), limit: E2E.contextLimit, language: .en)
            let session = E2EEn.session()
            try await session.warmUp(context: commandContext)
            var latencies: [Double] = []
            var failures = 0
            print("== English answers after \"\(command.text)\"")
            for (i, clip) in answers.enumerated() {
                let gen = SpeechGen(session: 100 + i, utterance: 1)
                let source = FileSource(pacing: .realTime)
                let pump = E2EEn.pump(try await session.start(context: commandContext, source: source, gen: gen,
                                                              hangover: HangoverPolicy.standard.command), session,
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
                let expected = E2EEn.interpreter.selection([Hypothesis(clip.text)], candidates: candidates, now: E2EEn.now)
                guard let second, let u = second.utteranceValue else {
                    Issue.record("\(clip.id): no answer utterance")
                    failures += 1
                    continue
                }
                #expect(second.gen == SpeechGen(session: 100 + i, utterance: 2))
                let actual = E2EEn.interpreter.selection(u.hypotheses, candidates: candidates, now: E2EEn.now)
                if actual != expected { failures += 1 }
                #expect(actual == expected, "\(clip.id): \(actual), expected \(expected)")
                latencies.append(u.timing.totalMs)
                print(String(format: "%@ %@ %@ | %@ | end %@ endpoint %.0f finalize %.0f total %.0f ms | DT \"%@\" ST \"%@\"",
                             clip.id, clip.voice, actual == expected ? "ok  " : "FAIL", "\(actual)", u.endReason.rawValue,
                             u.timing.endpointMs, u.timing.finalizeMs, u.timing.totalMs, u.dictation.best, u.speech.best))
                try await Task.sleep(for: .milliseconds(500))
            }
            print("English answers: \(answers.count - failures)/\(answers.count) as expected")
            print("speech end -> final, English answers: " + E2E.stats(latencies))
            #expect(failures == 0)
            try #require(!answers.isEmpty && latencies.count == answers.count, "every answer clip needs an utterance")
            #expect(E2E.p(latencies, 0.9) <= 550)
        }

        /// REVIEW M2 in English: a killed finalize rebuilds the analyzer for the en_US locale.
        @Test func killedFinalizeRebuildsTheAnalyzer() async throws {
            let myTasks = try #require(try E2EEn.clips().first { $0.id == "c07" })
            let session = E2EEn.session()
            try await session.warmUp(context: commandContext)
            session.killNextFinalize = true
            let source = FileSource(pacing: .realTime)
            let pump = E2EEn.pump(try await session.start(context: commandContext, source: source), session)
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
            #expect(E2EEn.describe(second) == "my")
            #expect(pump.kinds.filter { $0 == "ready" }.count == 2)
            print(String(format: "English killed finalize: second total %.0f ms", second.timing.totalMs))
        }

        /// Press-to-end: the synthetic tail lets finalize return without waiting for audio (REVIEW M2).
        @Test func pressToEndFinalizesAtOnce() async throws {
            let myTasks = try #require(try E2EEn.clips().first { $0.id == "c07" })
            let session = E2EEn.session()
            try await session.warmUp(context: commandContext)
            let source = FileSource(pacing: .realTime)
            let pump = E2EEn.pump(try await session.start(context: commandContext, source: source), session, adaptive: false)
            try E2E.play(myTasks, on: source)
            await source.waitUntilDrained()
            try await Task.sleep(for: .milliseconds(150))
            let pressed = Date()
            #expect(session.endUtteranceNow())
            let u = try #require(await pump.next()?.utteranceValue)
            let ms = Date().timeIntervalSince(pressed) * 1000
            await session.stop()
            await pump.finish()
            #expect(u.endReason == .manual)
            #expect(E2EEn.describe(u) == "my")
            #expect(ms < 400)
            print(String(format: "English press to end -> final %.0f ms (finalize %.0f ms)", ms, u.timing.finalizeMs))
        }

        @Test func selfCheckWithoutMicrophone() async throws {
            let synthesized = await SpeechSelfCheck.run(language: .en)
            print(String(format: "English self-check (synthesized): %@ \"%@\" %.0f ms", synthesized.message, synthesized.transcript,
                         synthesized.elapsedMs))
            #expect(synthesized.passed)
            #expect(synthesized.message == "Speech recognition ready")
            let clip = try #require(try E2EEn.clips().first { $0.id == "c07" })
            let file = await SpeechSelfCheck.run(clip: clip.files[0], expecting: ["show", "my", "tasks"], language: .en)
            print(String(format: "English self-check (clip): %@ \"%@\" %.0f ms", file.message, file.transcript, file.elapsedMs))
            #expect(file.passed)
        }
    }
}
