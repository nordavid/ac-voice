import Carbon
import CryptoKit
@testable import ACVoiceSystem
import Foundation
import Testing

/// The Chrome script: generation, osacompile syntax check and the REVIEW M4 rules. Nothing here sends an Apple
/// Event to another app; the runner tests execute a local script without any `tell` block in this process.
struct AppleScriptTests {
    static var chromeInstalled: Bool {
        ["/Applications/Google Chrome.app", NSHomeDirectory() + "/Applications/Google Chrome.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Runs a tool with a hard timeout. Returns the exit status and the combined output.
    static func run(_ tool: String, _ args: [String], timeout: Double = 120) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, out)
    }

    @Test func embeddedSourceMatchesResource() throws {
        let data = try Data(contentsOf: Repo.appleScript)
        let file = String(decoding: data, as: UTF8.self)
        func trimmed(_ s: String) -> String {
            var t = s
            while t.hasSuffix("\n") { t.removeLast() }
            return t
        }
        #expect(trimmed(OpenACScript.source) == trimmed(file))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(OpenACScript.sha256 == sha, "run scripts/gen-applescript.sh")
    }

    @Test func generatorCheckPasses() throws {
        let (status, out) = try Self.run("/bin/bash", [Repo.genScript.path, "--check"])
        #expect(status == 0, "\(out)")
        if Self.chromeInstalled { #expect(out.contains("osacompile: ok")) }
        #expect(out.contains("up to date"))
    }

    @Test(.enabled(if: AppleScriptTests.chromeInstalled, "osacompile resolves Chrome terms from Chrome's sdef"))
    func osacompileAcceptsEmbeddedSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acv-osa-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("open-ac.applescript")
        try OpenACScript.source.write(to: src, atomically: true, encoding: .utf8)
        let (status, out) = try Self.run("/usr/bin/osacompile", ["-o", dir.appendingPathComponent("o.scpt").path, src.path])
        #expect(status == 0, "\(out)")
    }

    @Test func scriptFollowsReviewRules() throws {
        let code = OpenACScript.source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            .joined(separator: "\n")
        // Handlers with the argument order ChromeOpener sends.
        let signatures = [
            "on chromestate(secs)",
            "on focustab(winID, tabIndex, targetURL, setURL, setTab, secs, doActivate)",
            "on newtab(winID, targetURL, secs, doActivate)",
            "on newwindow(targetURL, secs, doActivate)",
        ]
        for sig in signatures { #expect(code.contains(sig), "\(sig)") }
        #expect(ChromeOpener.stateHandler == "chromestate")
        #expect(ChromeOpener.focusHandler == "focustab")
        #expect(ChromeOpener.newTabHandler == "newtab")
        #expect(ChromeOpener.newWindowHandler == "newwindow")
        // No loops and no decisions in AppleScript: ChromeTabPlan decides in Swift.
        #expect(!code.contains("repeat"))
        for sig in signatures {
            let name = String(sig.dropFirst(3).prefix { $0 != "(" })
            let body = try #require(code.components(separatedBy: sig).dropFirst().first?
                .components(separatedBy: "end \(name)").first)
            // Never launch Chrome: check that it runs before any tell block, and bound every Apple Event.
            let guardAt = try #require(body.range(of: #"if not (application id "com.google.Chrome" is running) then return "notrunning""#))
            let timeoutAt = try #require(body.range(of: "with timeout of secs seconds"))
            let tellAt = try #require(body.range(of: "tell application"))
            #expect(guardAt.upperBound < timeoutAt.lowerBound)
            #expect(timeoutAt.upperBound < tellAt.lowerBound)
            if name != "chromestate" {
                // Activate last and only on request.
                let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                let at = try #require(lines.firstIndex(of: "if doActivate then activate"), "\(name)")
                #expect(lines[at + 1] == "end tell", "\(name)")
            }
        }
        // The URL changes only on request (no reload of a tab that shows the target), new windows are normal.
        #expect(code.contains("if setURL then set URL of tab tabIndex to targetURL"))
        #expect(code.contains(#"make new window with properties {mode:"normal"}"#))
        #expect(code.contains("tell window id winID"))
        #expect(!code.contains("System Events"))
        #expect(!code.contains("execute javascript"))
    }

    @Test func handlerEventShape() {
        let e = AppleScriptRunner.handlerEvent("OpenAC", [.text("https://ac.example.com/projects/628"), .int(2), .bool(false)])
        #expect(e.eventClass == AEEventClass(kASAppleScriptSuite))
        #expect(e.eventID == AEEventID(kASSubroutineEvent))
        #expect(e.paramDescriptor(forKeyword: AEKeyword(keyASSubroutineName))?.stringValue == "openac")
        let list = e.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        #expect(list?.numberOfItems == 3)
        #expect(list?.atIndex(1)?.stringValue == "https://ac.example.com/projects/628")
        #expect(list?.atIndex(2)?.int32Value == 2)
        #expect(list?.atIndex(3)?.booleanValue == false)
    }
}

/// `AppleScriptRunner` with a local script: no `tell` block, so nothing leaves this process. Only short handlers:
/// long AppleScript loops stall for seconds in the headless test process (environment, not the runner), so the
/// deadline logic is tested on `DeadlineWorker` with plain Swift jobs. Deadlines here are generous for the same reason.
@Suite(.serialized)
struct AppleScriptRunnerTests {
    static let local = """
    property hits : 0

    on echo(a, b, c)
    \treturn (a as text) & "|" & (b as text) & "|" & (c as text)
    end echo

    on hit()
    \tset hits to hits + 1
    \treturn hits as text
    end hit

    on boom()
    \terror "boom" number 4242
    end boom

    on shape()
    \treturn {1, "a", true, {2, missing value}, {}}
    end shape

    on bigids()
    \treturn {{1749650355, 536870911, 536870912}, 2.5}
    end bigids

    on sameid(x)
    \treturn x = 1749650355
    end sameid
    """

    @Test func callsHandlersWithArguments() async {
        let r = AppleScriptRunner(source: Self.local)
        defer { r.shutdown() }
        #expect(await r.prepare())
        #expect(await r.call("echo", [.text("x"), .int(3), .bool(true)], deadline: 30) == .value(.text("x|3|true")))
        #expect(await r.call("ECHO", [.text("ä ö"), .int(-1), .bool(false)], deadline: 30) == .value(.text("ä ö|-1|false")))
        #expect(await r.call("boom", [], deadline: 30) == .failed(code: 4242, message: "boom"))
        #expect(await r.call("hit", [], deadline: 30) == .value(.text("1")))
        #expect(await r.call("hit", [], deadline: 30) == .value(.text("2")))
        // Lists, booleans and missing value come back structured (the shape of chromestate).
        #expect(await r.call("shape", [], deadline: 30)
                == .value(.list([.int(1), .text("a"), .bool(true), .list([.int(2), .missing]), .list([])])))
        // Whole numbers above AppleScript's integer range (Chrome window ids, about 1.7e9) arrive as reals and still
        // read as Int; a fraction does not.
        let big = await r.call("bigids", [], deadline: 30)
        #expect(big == .value(.list([.list([.real(1_749_650_355), .int(536_870_911), .real(536_870_912)]), .real(2.5)])))
        if case .value(let v) = big {
            #expect(v.list?[0].list?.map(\.int) == [1_749_650_355, 536_870_911, 536_870_912])
            #expect(v.list?[1].int == nil)
        }
        // Such an id goes back into the script as the same number (focustab's "window id winID").
        #expect(await r.call("sameid", [.int(1_749_650_355)], deadline: 30) == .value(.bool(true)))
        #expect(!r.isBusy)
    }

    @Test func compileErrorMakesCallsUnavailable() async {
        let r = AppleScriptRunner(source: "on broken(\n")
        defer { r.shutdown() }
        #expect(await r.prepare() == false)
        guard case .unavailable = await r.call("broken", [], deadline: 30) else {
            Issue.record("expected .unavailable")
            return
        }
    }

    @Test func shutDownRunnerAnswersUnavailable() async {
        let r = AppleScriptRunner(source: Self.local)
        r.shutdown()
        #expect(await r.call("hit", [], deadline: 30) == .unavailable(code: -1))
        #expect(await r.prepare() == false)
    }
}

/// The worker behind `AppleScriptRunner`: deadlines, busy state, skipped jobs. Jobs are plain Swift sleeps.
@Suite(.serialized)
struct DeadlineWorkerTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    static func waitIdle(_ w: DeadlineWorker, timeout: Double = 10) async {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while w.isBusy, ProcessInfo.processInfo.systemUptime < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func runsJobsInOrderOnOneThread() async {
        let w = DeadlineWorker(name: "acv-test-worker")
        defer { w.shutdown() }
        var names: [String] = []
        for i in 0..<5 {
            guard case .done(let n) = await w.run(deadline: 5, { "\(i):\(Thread.current.name ?? "")" }) else {
                Issue.record("job \(i) did not run")
                return
            }
            names.append(n)
        }
        #expect(names == (0..<5).map { "\($0):acv-test-worker" })
    }

    @Test func deadlineAnswersAndBusyWorkerRefusesNewJobs() async {
        let w = DeadlineWorker(name: "acv-test-worker")
        defer { w.shutdown() }
        let t0 = ProcessInfo.processInfo.systemUptime
        let r = await w.run(deadline: 0.05) { Thread.sleep(forTimeInterval: 0.6); return 1 }
        guard case .timedOut = r else {
            Issue.record("expected .timedOut")
            return
        }
        #expect(ProcessInfo.processInfo.systemUptime - t0 < 0.4)
        #expect(w.isBusy)
        guard case .busy = await w.run(deadline: 5, { 2 }) else {
            Issue.record("expected .busy")
            return
        }
        await Self.waitIdle(w)
        #expect(!w.isBusy)
        guard case .done(3) = await w.run(deadline: 5, { 3 }) else {
            Issue.record("expected .done(3)")
            return
        }
    }

    @Test func queuedJobPastItsDeadlineNeverRuns() async throws {
        let w = DeadlineWorker(name: "acv-test-worker")
        defer { w.shutdown() }
        let counter = Counter()
        // The long job stays inside its deadline (not busy), so the next job queues behind it.
        async let long = w.run(deadline: 10) { Thread.sleep(forTimeInterval: 0.3); return 1 }
        try await Task.sleep(for: .milliseconds(30))
        guard case .timedOut = await w.run(deadline: 0.02, { counter.bump() }) else {
            Issue.record("expected .timedOut")
            return
        }
        guard case .done(1) = await long else {
            Issue.record("long job failed")
            return
        }
        guard case .done = await w.run(deadline: 5, { counter.bump() }) else {
            Issue.record("next job failed")
            return
        }
        #expect(counter.value == 1)
    }

    @Test func noDeadlineWaits() async {
        let w = DeadlineWorker(name: "acv-test-worker")
        defer { w.shutdown() }
        guard case .done(7) = await w.run(deadline: nil, { Thread.sleep(forTimeInterval: 0.1); return 7 }) else {
            Issue.record("expected .done(7)")
            return
        }
    }

    @Test func shutdownStopsTheWorker() async {
        let w = DeadlineWorker(name: "acv-test-worker")
        let counter = Counter()
        w.enqueue { counter.bump() }
        w.shutdown()
        guard case .stopped = await w.run(deadline: 1, { counter.bump() }) else {
            Issue.record("expected .stopped")
            return
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(counter.value == 1)
    }
}
