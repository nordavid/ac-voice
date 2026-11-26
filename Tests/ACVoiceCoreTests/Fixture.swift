import Foundation
@testable import ACVoiceCore

/// Synthetic projects from Tests/Fixtures/projects.sample.json: fantasy codes and titles with the collision structure of
/// the real list (see the file's "comment"); the real names stay in the git-ignored Tests/Fixtures/private.
/// Other test targets load the same file with `ProjectCatalog.load` and a path relative to `#filePath`.
enum Fixture {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let catalog: ProjectCatalog = {
        do { return try ProjectCatalog.load(fixturesDir.appendingPathComponent("projects.sample.json")) }
        catch { fatalError("Tests/Fixtures/projects.sample.json: \(error)") }
    }()
    static var now: Date { catalog.referenceDate }
    /// With the catalog's aliases (IBN = "eben").
    static let projects = catalog.entries(now: now)
    static let projectsWithoutAliases = catalog.entries(now: now, aliases: [:])
    static let resolver = Resolver(projects: projects)
    static let interpreter = Interpreter(resolver: resolver)

    /// Id-only outcome, e.g. "unique 628", "choices 628,314,315,693", "task 412 -".
    static func run(_ texts: String..., weights: [Double]? = nil, using i: Interpreter = interpreter, now: Date = now) -> String {
        let hyps = texts.enumerated().map { Hypothesis($0.element, weight: weights?[$0.offset] ?? 1) }
        return Regression.describe(i.command(hyps, now: now))
    }

    static func request(_ texts: String..., using i: Interpreter = interpreter) -> TaskRequest? {
        if case let .task(t) = i.command(texts.map { Hypothesis($0) }, now: now) { return t }
        return nil
    }
}
