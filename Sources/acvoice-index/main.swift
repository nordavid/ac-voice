import ACVoiceAC
import ACVoiceCore
import Foundation

// Dev CLI for the AC index. GET requests only. Prints ids, counts and timings, never names, tokens or ETags.
//
//   acvoice-index [options] refresh [--full] [--fast] [--stats]
//   acvoice-index [options] resolve "<utterance>" ["<hypothesis>" ...] [--active-project ID] [--url] [--refresh]
//   acvoice-index [options] probe <taskId>
//   acvoice-index [options] stats
//   acvoice-index [options] regress <cases.tsv> [--no-company-aliases]
//
// Options: --cache PATH (default ~/Library/Caches/io.github.nordavid.acvoice/index.json), --config PATH (default the
// app's config.json, read only), --base-url URL (default acBaseURL from the config).
// The token comes from the environment variable AC_TOKEN only; this tool never touches the Keychain and never prints
// the token.
//
// refresh         fast refresh + all task lists (ETag) + missing archive pages; --full starts from an empty cache,
//                 --fast stops after the fast refresh.
// resolve         Core Interpreter + TicketResolver on the cache, as the app does it: the task lists the decision
//                 reads are revalidated first (conditional GET), then archive fetch and 301 probe on a miss; every
//                 network step has a time budget. --url prints only the URL (or the ranked choices as ids).
// regress         the Core regression format against the cached projects (signals reset), to measure the effect
//                 of company aliases.

func usage() -> Never {
    print("""
    usage: AC_TOKEN=<token> acvoice-index [--cache PATH] [--config PATH] [--base-url URL] <command>
      refresh [--full] [--fast] [--stats]
      resolve "<utterance>" ["<hypothesis>" ...] [--active-project ID] [--url] [--refresh]
      probe <taskId>
      stats
      regress <cases.tsv> [--no-company-aliases]
    """)
    exit(2)
}

func ms(_ d: Duration) -> String {
    let c = d.components
    let v = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    return v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v)
}

func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
var cachePath: String?, configPath: String?, baseURLArg: String?
var rest: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--cache": guard !args.isEmpty else { usage() }; cachePath = args.removeFirst()
    case "--base-url": guard !args.isEmpty else { usage() }; baseURLArg = args.removeFirst()
    case "--config": guard !args.isEmpty else { usage() }; configPath = args.removeFirst()
    case "-h", "--help": usage()
    default: rest.append(a)
    }
}
guard !rest.isEmpty else { usage() }
let command = rest.removeFirst()
let flags = Set(rest.filter { $0.hasPrefix("--") })
@MainActor func value(_ flag: String) -> String? {
    guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
    return rest[i + 1]
}
var positional: [String] = []
do {
    var i = 0
    while i < rest.count {
        if rest[i] == "--active-project" { i += 2; continue }
        if !rest[i].hasPrefix("--") { positional.append(rest[i]) }
        i += 1
    }
}

// MARK: - Setup

let config = configPath.map { Config.load(from: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) } ?? Config.load()
let base: URL
if let baseURLArg {
    guard let url = Config.normalizedBaseURL(baseURLArg) else { fail("--base-url needs an https address with a host") }
    base = url
} else {
    guard !config.hasPlaceholderBaseURL else { fail("no AC address: pass --base-url or set acBaseURL in config.json") }
    base = config.acBaseURL
}
guard let rawToken = ProcessInfo.processInfo.environment["AC_TOKEN"], let token = ACToken.sanitize(rawToken) else {
    fail("no AC token: set the environment variable AC_TOKEN")
}
guard let userId = config.userId ?? ACToken.userId(from: token) else { fail("unknown AC user id (config userId or token prefix)") }
let client = ACClient(base: base, userId: userId, tokens: StaticTokenProvider(token))
let cacheURL = cachePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? AppPaths.indexCache
let store = IndexStore(client: client, cacheURL: cacheURL)
let clock = ContinuousClock()

@MainActor func printErrors(_ r: RefreshReport) {
    for e in r.errors { print("  error: \(e)") }
}

@MainActor func printStats(_ s: IndexSnapshot) {
    let st = s.stats
    print("index: projects \(st.projects), companies \(st.companies), favorites \(st.favorites) (\(st.activeFavorites) active)")
    print("personal: own open tasks \(st.ownOpenTasks) in \(st.ownTaskProjects) projects, time records (30 d) \(st.timeRecords) in \(st.timeRecordProjects) projects")
    print("tasks: lists \(st.taskLists), open \(st.openTasks), completed ids \(st.completedIds), trashed \(st.trashedIds), task ids \(st.taskIds)")
    print("archive: tasks with number \(st.archivedTasks), unreachable \(st.unreachable), complete projects \(st.archiveComplete)/\(st.taskLists), probed \(st.probed)")
    let aliases = s.companyAliasMap()
    print("company aliases: \(aliases.values.map(\.count).reduce(0, +)) for \(aliases.count) companies")
    if let size = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.size] as? Int {
        print("cache: \(mb(size))")
    }
}

// MARK: - Commands

switch command {
case "refresh":
    let full = flags.contains("--full"), fastOnly = flags.contains("--fast"), verbose = flags.contains("--stats")
    let t0 = clock.now
    if full { await store.reset() } else if await store.loadFromDisk() != nil { print("cache loaded") }
    let fast = await store.refreshFast()
    print("fast: fresh \(fast.fresh), 304 \(fast.notModified), failed \(fast.failed) in \(ms(fast.duration))")
    printErrors(fast)
    if fast.unauthorized { fail("AC token rejected (401)") }
    if !fastOnly {
        let lists = await store.refreshTaskLists()
        print("task lists: fresh \(lists.fresh), 304 \(lists.notModified), failed \(lists.failed) in \(ms(lists.duration))")
        printErrors(lists)
        let arch = await store.extendArchives()
        print("archives: \(arch.pages) pages, failed \(arch.failed) in \(ms(arch.duration))")
        printErrors(arch)
    }
    let st = client.stats
    print("http: \(st.requests) requests, 304 \(st.notModified), \(mb(st.bytes)), renewals \(st.renewals); total \(ms(clock.now - t0))")
    if verbose { printStats(await store.snapshot) }

case "stats":
    guard await store.loadFromDisk() != nil else { fail("no cache at the given path; run refresh first") }
    printStats(await store.snapshot)

case "probe":
    guard let id = positional.first.flatMap({ Int($0) }) else { usage() }
    let cached = await store.loadFromDisk()
    if cached?.projects.isEmpty ?? true { await store.refreshFast() }
    let t0 = clock.now
    do {
        let before = client.stats.requests
        if let ref = try await store.probe(taskId: id) {
            print("task \(id): project \(ref.projectId), number \(ref.number), completed \(ref.isCompleted), trashed \(ref.isTrashed)"
                  + " (\(client.stats.requests - before) requests, \(ms(clock.now - t0)))")
            print(Routes.task(base, projectId: ref.projectId, taskId: ref.id).absoluteString)
        } else {
            print("task \(id): not found (\(ms(clock.now - t0)))")
            exit(1)
        }
    } catch {
        fail("probe failed: \(error)")
    }

case "resolve":
    guard !positional.isEmpty else { usage() }
    let urlOnly = flags.contains("--url")
    let active = value("--active-project").flatMap { Int($0) }
    guard await store.loadFromDisk() != nil else { fail("no cache at the given path; run refresh first") }
    if flags.contains("--refresh") {
        let r = await store.refreshFast()
        if !urlOnly { print("fast refresh: fresh \(r.fresh), 304 \(r.notModified) in \(ms(r.duration))") }
    }
    let history = History.load()
    var snapshot = await store.snapshot
    let interp = snapshot.interpreter(config: config, history: history)
    let now = Date()
    let t0 = clock.now
    let interpretation = interp.command(positional.map { Hypothesis($0) }, now: now)
    let tInterp = clock.now - t0
    var log: [String] = ["interpretation: \(Regression.describe(interpretation)) (\(ms(tInterp)))"]
    var url: URL?
    var choices: String?

    switch interpretation {
    case .myTasks:
        url = Routes.myWork(base, path: config.myTasksPath, userId: userId)
    case .project(.unique(let s), _):
        url = Routes.project(base, s.project.id)
    case .project(.ambiguous(let list), _):
        choices = list.map { String($0.project.id) }.joined(separator: ",")
    case .project(.none, _), .notUnderstood, .cancel:
        break
    case .task(var req):
        // The same steps as the app's flow (VoiceFlow): revalidate the task lists the decision reads (stale lists:
        // a single hit only asks for confirmation), then archive rounds with `attemptedArchives`, at most
        // `FlowTimings.maxArchiveRounds` (2); an AC error ends the search.
        var outcome: TicketOutcome = .notFound
        var missError: ACError?
        var attempted = Set<Int>()
        var decideNow = false
        var unrecognized = false
        if case .none? = req.projects { unrecognized = true }
        if req.number < TicketResolver.globalIdThreshold, !unrecognized {
            let t = clock.now, before = client.stats
            let check = await store.revalidateTaskLists(for: req, activeProjectId: active)
            let st = client.stats
            log.append("task lists: \(st.requests - before.requests) revalidated (304 \(st.notModified - before.notModified)), "
                       + "\(check.complete ? "current" : "stale") in \(ms(clock.now - t))")
            if let e = check.error { log.append("task lists: \(e)") }
            if !check.complete { req.confident = false }
            snapshot = await store.snapshot
        }
        var rounds = 0
        loop: for _ in 0..<4 {
            outcome = interp.ticket(req, index: snapshot.tasks, activeProjectId: active, archivesFetched: decideNow,
                                    attemptedArchives: attempted, now: now)
            switch outcome {
            case .fetchArchive(let pids):
                guard rounds < 2 else { decideNow = true; continue }
                rounds += 1
                attempted.formUnion(pids)
                let t = clock.now, pages = client.stats.requests
                let check = await store.checkArchives(pids)
                log.append("archive: \(pids.count) projects [\(pids.map(String.init).joined(separator: ","))], "
                           + "\(check.complete ? "complete" : check.timedOut ? "timed out" : "partial"), "
                           + "\(client.stats.requests - pages) requests in \(ms(clock.now - t))")
                missError = check.error
                if missError != nil { decideNow = true }
                snapshot = await store.snapshot
            case .probe(let id):
                let t = clock.now
                do {
                    let ref = try await store.probe(taskId: id)
                    log.append("probe: task \(id) -> \(ref.map { "project \($0.projectId)" } ?? "not found") in \(ms(clock.now - t))")
                    snapshot = await store.snapshot
                    if let ref {
                        outcome = ref.isTrashed ? .trashed(taskId: ref.id) : .open(projectId: ref.projectId, taskId: ref.id)
                    } else {
                        outcome = .notFound
                    }
                } catch {
                    log.append("probe failed: \(error)")
                    missError = error as? ACError
                    outcome = .notFound
                }
                break loop
            default:
                break loop
            }
        }
        switch outcome {
        case .open(let pid, let tid):
            log.append("outcome: open \(pid)/\(tid)")
            url = Routes.task(base, projectId: pid, taskId: tid)
        case .choices(let refs):
            choices = refs.map { "\($0.projectId)/\($0.id)#\($0.number)\($0.isCompleted ? " done" : "")" }.joined(separator: ",")
            log.append("outcome: \(refs.count == 1 ? "confirm" : "choices") \(choices ?? "")")
        case .trashed(let id): log.append("outcome: trashed \(id)")
        case .projectNotRecognized: log.append("outcome: project not recognized")
        case .notFound:
            // The app shows the AC error ("AC-Token ungültig", "AC nicht erreichbar") instead of "nicht gefunden".
            log.append("outcome: " + (missError.map { "error \($0) (\($0.userMessage))" } ?? "not found"))
        case .fetchArchive, .probe: log.append("outcome: unresolved after 4 steps")
        }
    }

    if urlOnly {
        if let url { print(url.absoluteString) } else if let choices { print("choices " + choices) } else { print("none") }
    } else {
        log.forEach { print($0) }
        if let url { print("url: \(url.absoluteString)") } else if let choices, !log.contains(where: { $0.hasPrefix("outcome: c") }) {
            print("choices: \(choices)")
        }
        print("total: \(ms(clock.now - t0))")
    }
    exit(url != nil || choices != nil ? 0 : 1)

case "regress":
    guard let path = positional.first, let text = try? String(contentsOfFile: path, encoding: .utf8) else { usage() }
    guard await store.loadFromDisk() != nil else { fail("no cache at the given path; run refresh first") }
    let snapshot = await store.snapshot
    let now = Date()
    // Signals come from the cases' @signals lines, so start from neutral signals.
    let projects = snapshot.entries(config: Config(), history: History(), companyAliases: !flags.contains("--no-company-aliases"))
        .map { e -> ProjectEntry in var c = e; c.signals = Signals(); return c }
    let results = Regression.run(Regression.parse(text, now: now), projects: projects, now: now)
    for r in results where !r.passed {
        print("FAIL line \(r.testCase.line): \(r.actual)  (expected \(r.testCase.expected))")
    }
    let failed = results.filter { !$0.passed }.count
    print("\(results.count - failed)/\(results.count) passed")
    exit(failed == 0 ? 0 : 1)

default:
    usage()
}
