import Foundation
import Testing
@testable import ACVoiceCore

/// Real-name regression (REVIEW M5/M6, PLAN 4.7). Runs only when the git-ignored files exist:
/// - Tests/Fixtures/private/project_names.tsv: "id<TAB>name" per line (the real projects)
/// - Tests/Fixtures/private/regression.tsv: cases in the `Regression` format (ACVoiceCore/Regression.swift)
/// Failure messages carry line numbers and ids only. Also runnable as
/// `acvoice-resolve Tests/Fixtures/private/project_names.tsv --cases Tests/Fixtures/private/regression.tsv`.
enum PrivateRegression {
    static let dir = Fixture.fixturesDir.appendingPathComponent("private")
    static let names = dir.appendingPathComponent("project_names.tsv")
    static let cases = dir.appendingPathComponent("regression.tsv")
    static var available: Bool {
        FileManager.default.isReadableFile(atPath: names.path) && FileManager.default.isReadableFile(atPath: cases.path)
    }
    /// Fixed clock so signals given in days stay stable.
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
}

@Suite(.enabled(if: PrivateRegression.available, "private fixtures missing (Tests/Fixtures/private)"))
struct PrivateRegressionTests {
    @Test func realProjectNames() throws {
        let projects = ProjectCatalog.entries(tsv: try String(contentsOf: PrivateRegression.names, encoding: .utf8))
        #expect(projects.count >= 60)
        let cases = Regression.parse(try String(contentsOf: PrivateRegression.cases, encoding: .utf8), now: PrivateRegression.now)
        #expect(cases.count >= 60)
        let results = Regression.run(cases, projects: projects, now: PrivateRegression.now)
        for r in results where !r.passed {
            Issue.record("regression.tsv line \(r.testCase.line): got '\(r.actual)', expected '\(r.testCase.expected)'")
        }
    }
}
