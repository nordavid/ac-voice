import Foundation
import Testing
@testable import ACVoiceCore

@Suite struct IPCTests {
    func cmd(_ json: String) -> IPC.Command? { IPC.decodeCommand(Data(json.utf8)) }

    @Test func decode() {
        #expect(cmd(#"{"v":1,"t":"press","id":"sd-7","at":1732440000000}"#) == .press(id: "sd-7", at: 1_732_440_000_000))
        #expect(cmd(#"{"v":1,"t":"release","id":"sd-8","pressId":"sd-7","heldMs":812}"#) == .release(id: "sd-8", pressId: "sd-7", heldMs: 812))
        #expect(cmd(#"{"v":1,"t":"choose","id":"sd-9","index":2,"seq":6}"#) == .choose(id: "sd-9", index: 2, seq: 6))
        #expect(cmd(#"{"v":1,"t":"cancel","id":"sd-10"}"#) == .cancel(id: "sd-10"))
        #expect(cmd(#"{"v":1,"t":"ping","id":"sd-11"}"#) == .ping(id: "sd-11"))
        #expect(cmd(#"{"v":1,"t":"hello","client":"streamdeck","version":"0.1.0"}"#) == .hello(client: "streamdeck", version: "0.1.0"))
    }

    @Test func tolerantV1() {
        // Older plugins: no pressId / seq.
        #expect(cmd(#"{"v":1,"t":"release","id":"sd-8","heldMs":812}"#) == .release(id: "sd-8", pressId: nil, heldMs: 812))
        #expect(cmd(#"{"v":1,"t":"choose","id":"sd-9","index":2}"#) == .choose(id: "sd-9", index: 2, seq: nil))
        // JavaScript floats, unknown fields and a wrong type in an unused field.
        #expect(cmd(#"{"v":1.0,"t":"release","id":"a","heldMs":812.6,"extra":{"x":1}}"#) == .release(id: "a", pressId: nil, heldMs: 813))
        #expect(cmd(#"{"v":1,"t":"press","id":"b","at":1732440000000.0,"client":5}"#) == .press(id: "b", at: 1_732_440_000_000))
        // Rejected: other versions, unknown types, missing required fields, junk, oversized lines.
        #expect(cmd(#"{"v":2,"t":"press","id":"x"}"#) == nil)
        #expect(cmd(#"{"v":1,"t":"future","id":"x"}"#) == nil)
        #expect(cmd(#"{"v":1,"t":"press"}"#) == nil)
        #expect(cmd(#"{"v":1,"t":"choose","id":"x"}"#) == nil)
        #expect(cmd("not json") == nil)
        #expect(cmd(#"{"t":"press","id":"x"}"#) == nil)
        #expect(IPC.decodeCommand(Data(repeating: 0x20, count: IPC.maxLineBytes + 1)) == nil)
    }

    /// Review C3: a choice number outside 1...1000 is junk. Int.min used to reach the reducer and trap in `n - 1`.
    @Test func chooseIndexOutOfRange() {
        for bad in ["-9223372036854775808", "0", "-1", "1001", "9223372036854775807"] {
            #expect(cmd(#"{"v":1,"t":"choose","id":"x","index":"# + bad + "}") == nil, "index \(bad)")
        }
        #expect(cmd(#"{"v":1,"t":"choose","id":"x","index":1000}"#) == .choose(id: "x", index: 1000, seq: nil))
        #expect(cmd(#"{"v":1,"t":"choose","id":"x","index":1}"#) == .choose(id: "x", index: 1, seq: nil))
    }

    @Test(arguments: [
        IPC.Command.hello(client: "streamdeck", version: "0.1.0"), .press(id: "p", at: 5), .release(id: "r", pressId: "p", heldMs: 700),
        .release(id: "r", pressId: nil, heldMs: 0), .choose(id: "c", index: 3, seq: 9), .choose(id: "c", index: 1, seq: nil),
        .cancel(id: "x"), .ping(id: "y"),
    ])
    func commandRoundTrip(_ c: IPC.Command) {
        let line = IPC.line(c)
        #expect(line.last == 0x0A)
        #expect(IPC.decodeCommand(line.dropLast()) == c)
    }

    @Test func stateLine() throws {
        let s = IPC.State(seq: 6, phase: .choices, since: 1, transcript: "Öffne das WWT-Projekt", preview: "WWT: Website Relaunch",
                          choices: [.init(n: 1, label: "Relaunch", detail: "WWT: Website Relaunch [AGIL]")], total: 4, deadline: 2)
        let line = String(decoding: IPC.line(s), as: UTF8.self)
        #expect(line.hasSuffix("\n") && line.contains(#""phase":"choices""#) && line.contains(#""t":"state""#))
        #expect(!line.contains("micReady"))   // nil fields are omitted
        #expect(try JSONDecoder().decode(IPC.State.self, from: Data(line.utf8)) == s)
        #expect(String(decoding: IPC.line(IPC.Level(rms: 0.5)), as: UTF8.self) == #"{"rms":0.5,"t":"level","v":1}"# + "\n")
    }
}

@Suite struct RoutesTests {
    let base = URL(string: "https://ac.example.com")!

    @Test func urls() {
        #expect(Routes.project(base, 628).absoluteString == "https://ac.example.com/projects/628")
        #expect(Routes.project(URL(string: "https://ac.example.com/")!, 628).absoluteString == "https://ac.example.com/projects/628")
        #expect(Routes.task(base, projectId: 628, taskId: 61_834).absoluteString == "https://ac.example.com/projects/628/tasks/61834")
        #expect(Routes.myWork(base).absoluteString == "https://ac.example.com/my-work")
        #expect(Routes.myWork(base, path: "my-work").absoluteString == "https://ac.example.com/my-work")
        #expect(Routes.myWork(base, path: "/users/{me}/tasks", userId: 538).absoluteString == "https://ac.example.com/users/538/tasks")
        #expect(Routes.myWork(base, path: "/users/{me}/tasks").absoluteString == "https://ac.example.com/my-work")
        #expect(Routes.myWork(base, path: "https://evil.example/x").absoluteString == "https://ac.example.com/my-work")
    }

    @Test(arguments: [
        ("https://ac.example.com/projects/628", 628), ("https://ac.example.com/projects/628/tasks/123", 628),
        ("https://AC.example.com/projects/315?modal=Task-1-315", 315),
    ])
    func activeTab(url: String, id: Int) { #expect(Routes.projectId(in: URL(string: url)!, base: base) == id) }

    @Test(arguments: ["https://ac.example.com/my-work", "https://example.com/projects/628", "https://ac.example.com/projects/x"])
    func notAProjectTab(_ url: String) { #expect(Routes.projectId(in: URL(string: url)!, base: base) == nil) }
}

@Suite struct ConfigTests {
    @Test func defaults() {
        let c = Config()
        #expect(c.acBaseURL.absoluteString == "https://ac.example.com" && c.userId == nil && c.myTasksPath == "/users/{me}/tasks")
        #expect(c.hotkey == .default && c.hotkey.display == "⌃⌥Leertaste" && c.earcons && c.fastSelect && c.aliases.isEmpty)
        #expect(c.contextualStringLimit == 35 && c.visibleChoices == 6 && c.inputDeviceUID == nil && c.avoidBluetoothInput)
        // "Meine Aufgaben" are the tasks assigned to the user; "/my-work" only while the user id is unknown.
        #expect(c.myWorkURL.absoluteString == "https://ac.example.com/my-work")
        var known = c
        known.userId = 538
        #expect(known.myWorkURL.absoluteString == "https://ac.example.com/users/538/tasks")
        // An explicit path in config.json still wins.
        #expect(Config.decode(Data(#"{"userId":538,"myTasksPath":"/my-work"}"#.utf8)).myWorkURL.absoluteString
                == "https://ac.example.com/my-work")
        #expect(c.chromeActivation == "appleScript" && c.overlayBackdrop == "liquidGlass")
    }

    @Test func chromeActivationRoundTrips() {
        var c = Config()
        c.chromeActivation = "workspace"
        c.overlayBackdrop = "hudMaterial"
        #expect(Config.decode(c.encoded()).chromeActivation == "workspace")
        #expect(Config.decode(c.encoded()).overlayBackdrop == "hudMaterial")
        #expect(Config.decode(Data(#"{"chromeActivation":7}"#.utf8)).chromeActivation == "appleScript")
    }

    @Test func tolerantDecoding() {
        #expect(Config.decode(Data("{}".utf8)) == Config())
        #expect(Config.decode(Data("junk".utf8)) == Config())
        let partial = Config.decode(Data(#"{"earcons":false,"aliases":{"IBN":["eben","imben"]},"future":1,"userId":538}"#.utf8))
        var expected = Config()
        expected.earcons = false; expected.aliases = ["IBN": ["eben", "imben"]]; expected.userId = 538
        #expect(partial == expected)
        // Wrong types fall back to the default, out-of-range values are clamped.
        let odd = Config.decode(Data(#"{"earcons":"yes","visibleChoices":40,"acBaseURL":"ftp://x","hotkey":{"keyCode":"a"}}"#.utf8))
        #expect(odd.earcons && odd.visibleChoices == 9 && odd.acBaseURL == Config().acBaseURL && odd.hotkey == .default)
        #expect(Config.decode(Data(#"{"userId":null,"myTasksPath":"/users/{me}/tasks","userId2":1}"#.utf8)).myWorkURL
                    .absoluteString == "https://ac.example.com/my-work")
    }

    @Test(arguments: ["http://ac.example.com", "https://", "https:///projects", "ftp://ac.example.com", "ac.example.com",
                      "HTTP://ac.example.com", "file:///etc"])
    func baseURLNeedsHTTPSAndHost(_ url: String) {
        // Review: the bearer token must never travel over http or to a host-less URL.
        let json = #"{"acBaseURL":"\#(url)"}"#
        #expect(Config.decode(Data(json.utf8)).acBaseURL == Config().acBaseURL, "\(url)")
    }

    /// The setup window's address field: https only, a host required, path and trailing slash dropped.
    @Test func typedAddressIsNormalized() {
        func n(_ s: String) -> String? { Config.normalizedBaseURL(s)?.absoluteString }
        #expect(n("https://ac.example.test") == "https://ac.example.test")
        #expect(n(" https://AC.Example.test/ \n") == "https://ac.example.test")
        #expect(n("https://ac.example.test/projects/628?x=1#top") == "https://ac.example.test")
        #expect(n("ac.example.test") == "https://ac.example.test")
        #expect(n("https://ac.example.test:8443/") == "https://ac.example.test:8443")
        // The https default port is the same origin as no port.
        #expect(n("https://ac.example.test:443/projects") == "https://ac.example.test")
        for bad in ["", "   ", "http://ac.example.test", "ftp://ac.example.test", "https://", "https:///x",
                    "https://someone:secret@ac.example.test", "https://ac example.test", "file:///etc"] {
            #expect(n(bad) == nil, "\(bad)")
        }
    }

    @Test func placeholderAddress() {
        #expect(Config().hasPlaceholderBaseURL && Config.placeholderBaseURL.absoluteString == "https://ac.example.com")
        #expect(Config.decode(Data(#"{"acBaseURL":"https://ac.example.com/"}"#.utf8)).hasPlaceholderBaseURL)
        #expect(!Config.decode(Data(#"{"acBaseURL":"https://ac.example.test"}"#.utf8)).hasPlaceholderBaseURL)
        #expect(Config.sameBase(URL(string: "https://AC.example.test/")!, URL(string: "https://ac.example.test")!))
        #expect(!Config.sameBase(URL(string: "https://ac.example.test")!, URL(string: "https://ac.example.com")!))
        // Another port is another ActiveCollab, the default port is none.
        #expect(!Config.sameBase(URL(string: "https://ac.example.test:8443")!, URL(string: "https://ac.example.test")!))
        #expect(Config.sameBase(URL(string: "https://ac.example.test:443")!, URL(string: "https://ac.example.test")!))
    }

    /// The token import from a local tool is gone; an old config.json that still names its key decodes as before.
    @Test func oldTokenImportKeyIsIgnored() {
        let c = Config.decode(Data(#"{"tokenImportPath":"~/somewhere","earcons":false,"userId":538}"#.utf8))
        var expected = Config()
        expected.earcons = false
        expected.userId = 538
        #expect(c == expected)
        #expect(!String(decoding: c.encoded(), as: UTF8.self).contains("tokenImportPath"))
    }

    @Test func otherHTTPSHostIsKept() {
        let c = Config.decode(Data(#"{"acBaseURL":"https://ac.example.de/"}"#.utf8))
        #expect(c.acBaseURL.absoluteString == "https://ac.example.de/")
        #expect(Routes.project(c.acBaseURL, 628).absoluteString == "https://ac.example.de/projects/628")
    }

    @Test func hotkeyLabelsAreGerman() {
        #expect(Hotkey.default.display == "⌃⌥Leertaste")
        #expect(Hotkey(keyCode: 80, modifiers: Hotkey.optionKey).display == "⌥F19")
        #expect(Hotkey(keyCode: 96, modifiers: Hotkey.cmdKey | Hotkey.shiftKey).display == "⇧⌘F5")
        #expect(Hotkey(keyCode: 0, modifiers: Hotkey.controlKey).display == "⌃Taste 0")
    }

    @Test func roundTripAndFile() throws {
        var c = Config()
        c.userId = 538; c.aliases = ["S+K": ["eska"]]; c.synonyms = ["armaturenbrett": ["cockpit"]]
        c.hotkey = Hotkey(keyCode: 80, modifiers: Hotkey.optionKey)
        c.inputDeviceUID = "BuiltInMicrophoneDevice"
        #expect(Config.decode(c.encoded()) == c)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acvoice-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/config.json")
        #expect(Config.load(from: url) == Config())   // missing file
        try c.save(to: url)
        #expect(Config.load(from: url) == c)
    }

    @Test func aliasesApplyByCode() {
        let p = ProjectEntry(id: 1, name: "S+K: Leasing Cockpit").addingAliases(byCode: ["s+k": ["eska"], "IBN": ["eben"]])
        #expect(p.aliases == ["eska"])
        // The alias word is also the start of a title word of another project ("Eskalationen").
        let rival = ProjectEntry(id: 2, name: "WKT: Eskalationen Archiv")
        let r = Resolver(projects: [p, rival])
        #expect(r.resolve(TextNorm.tokenize("Eska Leasing Cockpit")) == .unique(r.score(TextNorm.tokenize("Eska Leasing Cockpit")).first { $0.project.id == 1 }!))
        // "Eska" alone: the alias opens the S+K project; without it only the prefix of "Eskalationen" matches, too weak.
        guard case .unique(let hit) = r.resolve(TextNorm.tokenize("Eska")) else { Issue.record("expected unique"); return }
        #expect(hit.project.id == 1 && hit.codeHit == .alias)
        let plain = Resolver(projects: [ProjectEntry(id: 1, name: "S+K: Leasing Cockpit"), rival])
        guard case .none(let best) = plain.resolve(TextNorm.tokenize("Eska")) else { Issue.record("expected none"); return }
        #expect(best?.project.id == 2)
    }

    @Test func configSynonyms() {
        // No default synonym points at one customer's title; config.json adds such words.
        #expect(Set(ResolverConfig().synonyms.values.flatMap { $0 }) == ["maintenance", "website"])
        let c = ResolverConfig(synonyms: ["Armaturenbrett": ["Cockpit"], "wartung": ["service"]])
        #expect(c.synonyms["armaturenbrett"] == ["cockpit"] && c.synonyms["wartung"] == ["maintenance", "service"])
        var config = Config()
        #expect(Fixture.run("Öffne S und K Armaturenbrett") == "choices 2011,2012")
        config.synonyms = ["armaturenbrett": ["cockpit"]]
        let i = Interpreter(projects: Fixture.projects, config: config, history: History())
        #expect(Fixture.run("Öffne S und K Armaturenbrett", using: i) == "unique 2011")
        #expect(Config.decode(Data(#"{"synonyms":{"armaturenbrett":["cockpit"]}}"#.utf8)).synonyms == ["armaturenbrett": ["cockpit"]])
    }
}

@Suite struct HistoryTests {
    typealias F = Fixture

    @Test func opensAndPicks() {
        var h = History()
        for d in 0..<25 { h.recordOpen(projectId: 628, at: F.now.addingTimeInterval(Double(d) * 60)) }
        #expect(h.recentOpens(628).count == History.maxOpensPerProject)
        #expect(h.recentOpens(628).last == F.now.addingTimeInterval(24 * 60))
        h.recordPick(query: "wwt", projectId: 693); h.recordPick(query: "wwt", projectId: 693); h.recordPick(query: "", projectId: 1)
        #expect(h.picks(for: "wwt") == [693: 2] && h.picks.count == 1)
    }

    @Test func codableAndTolerant() {
        var h = History()
        h.recordOpen(projectId: 628, at: F.now)
        h.recordPick(query: "eben betreuung", projectId: 2041)
        #expect(History.decode(h.encoded()) == h)
        #expect(History.decode(Data("junk".utf8)) == History())
        #expect(History.decode(Data(#"{"picks":{"x":{"1":2}},"opens":"bad"}"#.utf8)).picks == ["x": [1: 2]])
    }

    @Test func learnedAliases() {
        let projects = F.projectsWithoutAliases
        func aliases(_ picks: [(String, Int, Int)]) -> [String: [String]] {
            var h = History()
            for (q, id, n) in picks { for _ in 0..<n { h.recordPick(query: q, projectId: id) } }
            return h.learnedAliases(projects: projects)
        }
        #expect(aliases([("eben betreuung", 2041, 2)]) == ["IBN": ["eben"]])
        #expect(aliases([("ebenbetreuung", 2041, 2)]) == ["IBN": ["eben"]])     // glued: prefix of the title word
        #expect(aliases([("imben", 2041, 3)]) == ["IBN": ["imben"]])
        #expect(aliases([("eben betreuung", 2041, 1)]).isEmpty)                 // one pick is not enough
        #expect(aliases([("relaunch", 628, 3)]).isEmpty)                        // fully explained by the title
        #expect(aliases([("wkt relaunch", 628, 2)]).isEmpty)                    // "wkt" is another code
        #expect(aliases([("xyz relaunch", 628, 2), ("xyz relaunch", 2042, 2)]).isEmpty)   // two codes tie
        // An alias that already exists is not proposed again.
        var h = History(); h.recordPick(query: "eben betreuung", projectId: 2041); h.recordPick(query: "eben betreuung", projectId: 2041)
        #expect(h.learnedAliases(projects: F.projects).isEmpty)
    }

    @Test func heardCodeOrParticlesNeverBecomeAliases() {
        // Review: picks from an WWT list for "Öffne WWT bitte schön" taught WWT the alias "schon".
        let projects = F.projectsWithoutAliases
        func aliases(_ q: String, _ id: Int, _ n: Int) -> [String: [String]] {
            var h = History()
            for _ in 0..<n { h.recordPick(query: q, projectId: id) }
            return h.learnedAliases(projects: projects)
        }
        #expect(aliases("wwt schon", 628, 2).isEmpty)
        #expect(aliases("gleich wwt", 628, 3).isEmpty)
        #expect(aliases("aber wwt", 628, 2).isEmpty && aliases("wwt gerade", 628, 2).isEmpty)
        #expect(aliases("ibn plattform kram", 2041, 2).isEmpty)             // the code was heard
        #expect(aliases("schon relaunch", 628, 2).isEmpty)                  // only a particle is left over
        #expect(aliases("halt doch relaunch", 628, 2).isEmpty)
        #expect(aliases("eben betreuung", 2041, 2) == ["IBN": ["eben"]])    // the flagship case still learns
        // The command phase no longer stores particles in the key at all.
        guard case let .project(_, key) = F.interpreter.command([Hypothesis("Öffne WWT bitte schön")], now: F.now) else {
            Issue.record("expected a project list"); return
        }
        #expect(key == "wwt")
    }

    @Test func correctionPickAfterNotUnderstoodLearnsTheAlias() {
        // REVIEW m9 end to end: "Eben Betreuung" is not understood without the alias, so no list ever offers IBN.
        // The Flow records the failed key once the user opens the project another way.
        let plain = Interpreter(resolver: Resolver(projects: F.projectsWithoutAliases))
        let heard = [Hypothesis("Öffne Eben Betreuung")]
        guard case .notUnderstood = plain.command(heard, now: F.now) else { Issue.record("expected notUnderstood"); return }
        let key = plain.correctionKey(heard)
        #expect(key == "eben betreuung")
        #expect(plain.correctionKey([Hypothesis("Ticket 412")]) == nil && plain.correctionKey([Hypothesis("")]) == nil)
        var h = History()
        for _ in 0..<2 { h.recordPick(query: key ?? "", projectId: 2041) }
        let learned = h.learnedAliases(projects: F.projectsWithoutAliases)
        #expect(learned == ["IBN": ["eben"]])
        let healed = Interpreter(resolver: Resolver(projects: F.projectsWithoutAliases.map { $0.addingAliases(byCode: learned) }))
        #expect(F.run("Öffne Eben Betreuung", using: healed) == "unique 2041")
    }

    @Test func evictionKeepsNewQueries() {
        // Review: at 500 queries the new query itself was evicted on every pick and never reached 2 picks.
        var h = History()
        for i in 1000..<1500 { h.recordPick(query: "q\(i)", projectId: 628) }
        h.recordPick(query: "aaa", projectId: 628)
        #expect(h.picks(for: "aaa") == [628: 1] && h.picks.count == History.maxQueries)
        h.recordPick(query: "aaa", projectId: 628)
        #expect(h.picks(for: "aaa") == [628: 2] && h.picks(for: "q1000").isEmpty && h.picks(for: "q1499") == [628: 1])
        // All slots hold repeated picks: the least recently picked query goes, never the new one.
        var full = History()
        for i in 0..<550 { for _ in 0..<2 { full.recordPick(query: "r\(i)", projectId: 628) } }
        #expect(full.picks.count == History.maxQueries && full.picks(for: "r549") == [628: 2])
        #expect(full.picks(for: "r49").isEmpty && full.picks(for: "r50") == [628: 2])
        #expect(full.lastPicked.count == History.maxQueries)
        // Older files without LRU data count as least recent.
        var old = History.decode(Data(#"{"picks":{"zzz":{"628":5}}}"#.utf8))
        #expect(old.lastPicked.isEmpty && old.pickClock == 0)
        for i in 0..<History.maxQueries { old.recordPick(query: "n\(i)", projectId: 1) }
        #expect(old.picks(for: "zzz").isEmpty && old.picks.count == History.maxQueries)
        #expect(History.decode(full.encoded()) == full)
    }

    @Test func learnedAliasFixesTheNextUtterance() {
        var h = History()
        h.recordPick(query: "ebenbetreuung", projectId: 2041); h.recordPick(query: "ebenbetreuung", projectId: 2041)
        let learned = h.learnedAliases(projects: F.projectsWithoutAliases)
        let healed = Interpreter(resolver: Resolver(projects: F.projectsWithoutAliases.map { $0.addingAliases(byCode: learned) }))
        #expect(F.run("Ebenbetreuung", using: healed) == "unique 2041")
    }

    @Test func tierIsCoarseAndStable() {
        let s = Signals(favorite: true, timeRecords30d: 11, ownOpenTasks: 1, lastActivity: F.now)
        #expect(s.tier(now: F.now) == 7)
        #expect(Signals(lastActivity: F.now.addingTimeInterval(-5 * 86_400)).tier(now: F.now) == 0)
        #expect(Signals(lastActivity: F.now.addingTimeInterval(-5 * 86_400)).tier(now: F.now.addingTimeInterval(86_400)) == 0)
        #expect(Signals(lastActivity: F.now.addingTimeInterval(-200 * 86_400)).tier(now: F.now) == -1)
        #expect(Signals(recentOpens: [F.now, F.now, F.now]).tier(now: F.now) == 2)
        #expect(Signals(recentOpens: [F.now]).tier(now: F.now.addingTimeInterval(31 * 86_400)) == 0)
    }
}
