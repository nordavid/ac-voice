import ACVoiceCore
@testable import ACVoiceSpeech
import Foundation

/// Synthetic projects from Tests/Fixtures/projects.sample.json (no real names), shared with the core tests.
enum Fixture {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let catalog: ProjectCatalog = {
        do { return try ProjectCatalog.load(dir.appendingPathComponent("projects.sample.json")) }
        catch { fatalError("Tests/Fixtures/projects.sample.json: \(error)") }
    }()
    static var now: Date { catalog.referenceDate }
    static let projects = catalog.entries(now: now)
    static let interpreter = Interpreter(resolver: Resolver(projects: projects))
    static func project(_ id: Int) -> ProjectEntry { projects.first { $0.id == id }! }
    /// "Öffne das WWT-Projekt" lists these, most likely first.
    static let wwtList = [628, 314, 315, 693]
}

/// Drives an `EndpointGate` with 20 ms slices: `segments` are (dBFS, seconds) runs, `at` are actions at times.
struct GateDriver {
    var gate: EndpointGate
    var actions: [(t: Double, act: (inout EndpointGate) -> Void)] = []
    /// Slices fed so far; time continues across `run` calls.
    private(set) var k = 0

    init(_ mode: UtteranceMode = .command, config: EndpointGate.Config = .init(), hangover: Double? = nil) {
        gate = EndpointGate(config: config)
        gate.arm(mode, at: 0, hangover: hangover)
    }

    mutating func at(_ t: Double, _ act: @escaping (inout EndpointGate) -> Void) { actions.append((t, act)) }
    /// A live partial alone: the gate keeps the controller's hangover.
    mutating func partial(_ t: Double, _ text: String) { at(t) { $0.partial(text, at: t) } }
    /// A command partial as the app delivers it: the partial, then the hangover the flow sends for it
    /// (Core `HangoverPolicy`, as VoiceFlow applies it).
    mutating func say(_ t: Double, _ text: String) {
        let h = Controller.commandHangover(text)
        at(t) { $0.partial(text, at: t); $0.setHangover(h) }
    }

    /// Outputs other than `.none` with their slice end times; stops after the first end or no-speech.
    mutating func run(_ segments: [(Float, Double)]) -> [(t: Double, out: EndpointGate.Output)] {
        var out: [(Double, EndpointGate.Output)] = []
        var pending = actions.sorted { $0.t < $1.t }.filter { $0.t > Double(k) * 0.02 + 1e-9 }
        for (db, seconds) in segments {
            for _ in 0..<Int((seconds / 0.02).rounded()) {
                k += 1
                let t = Double(k) * 0.02
                while let a = pending.first, a.t <= t + 1e-9 { a.act(&gate); pending.removeFirst() }
                let o = gate.slice(rmsDB: db, at: t)
                if o != .none { out.append((t, o)) }
                switch o {
                case .end, .noSpeech: return out
                default: break
                }
            }
        }
        return out
    }
}

extension EndpointGate.Output {
    var ending: EndpointGate.Ending? { if case .end(let e) = self { return e }; return nil }
}

func near(_ a: Double, _ b: Double, _ tol: Double = 0.011) -> Bool { abs(a - b) <= tol }

/// Plays the app's flow for the speech layer alone: the hangover VoiceFlow sends for a live partial (Core
/// `HangoverPolicy.standard`, the leading of DT and ST as in the flow).
enum Controller {
    static let policy = HangoverPolicy.standard

    static func commandHangover(_ dt: String, _ st: String = "", using interpreter: Interpreter = Fixture.interpreter,
                                now: Date = Fixture.now) -> Double {
        let hyps = [Hypothesis(dt), Hypothesis(st)].filter { !$0.text.isEmpty }
        return policy.command(text: EndpointGate.leading(dt, st), interpretation: interpreter.command(hyps, now: now))
    }

    static func answerHangover(_ dt: String, _ st: String = "", candidates: [Int], using interpreter: Interpreter = Fixture.interpreter,
                               now: Date = Fixture.now) -> Double {
        let hyps = [Hypothesis(dt), Hypothesis(st)].filter { !$0.text.isEmpty }
        let outcome = interpreter.selection(hyps, candidates: candidates, now: now)
        return policy.answer(text: EndpointGate.leading(dt, st), outcome: outcome,
                             command: { interpreter.command(hyps, now: now) })
    }
}
