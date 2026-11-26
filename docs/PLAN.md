# ac-voice v1: final architecture and implementation plan

This document uses fantasy names for project codes, company names and distinctive project titles, the same ones as `Tests/Fixtures/projects.sample.json`. Its examples and transcripts follow these names. The real names stay in the git-ignored `Tests/Fixtures/private`. Project, task and user ids are invented as well.

`spikes/` holds unpublished research code and is not part of this repository.

Legend: **[V]** = VERIFIED (by a research report, or compiled and run in this pass, marked "V, this pass"). **[A]** = ASSUMED, with a fallback where it matters.

Prototype from this pass: `spikes/architect/proto/`. It is a SwiftPM package with the pure-logic core: tokenizer, parser, resolver, selection, ticket resolver and IPC codec.
- 780 LOC.
- A clean build with Swift 6.4.2 shows 0 warnings.
- `swift test` runs 20 test functions (51 cases) and all pass in 0.05 s, headless **[V, this pass]**.
- `acvoice-resolve` checks the resolver against the real project list (about 60 names). It prints ids only.

Nothing in ac-mcp changed (`git status` there is clean). I read 2 files in ac-mcp. I made no AC calls, touched no microphone or Chrome, and no prompts appeared.

---

## 0. Decisions at a glance

| Topic | Decision |
|---|---|
| Process model | A resident menu-bar app, "AC Voice.app" (LSUIElement, AppKit lifecycle with SwiftUI views). It is signed, unsandboxed and has hardened runtime. Bundle id `io.github.nordavid.acvoice`, installed in `~/Applications`. A warm launch takes 267-280 ms, so the app must stay resident **[V]** |
| Trigger | Stream Deck plugin `io.github.nordavid.acvoice.streamdeck` (SDK v3, Node 24). It sends `press` on **keyDown**. Fallbacks: Carbon hotkey ⌃⌥Space (no TCC permission) **[V registration]**, a menu-bar click, and optionally `acvoice://press` |
| IPC | Unix domain socket with NDJSON at `~/Library/Application Support/ac-voice/ipc.sock` (well below the 104-byte limit with a typical home path). The app owns the state machine. p50 is 0.042 ms **[V]** |
| STT | One `SpeechAnalyzer` session with **SpeechTranscriber + DictationTranscriber**, de_DE, on device. It needs only the microphone permission and no speech authorization **[V for file/buffer input; A for mic buffers]**. No custom LM and no SFSpeechRecognizer |
| End of utterance | App-side RMS gate with an adaptive floor. **VoiceFlow owns the hangover policy** (Core `HangoverPolicy`, one rule on every live partial) and sends seconds; the speech layer applies them as is. 600 ms for commands, 450 ms when the live preview is a complete intent, 1.1 s after a dangling word or a trailing number, **400 ms for answers**. At the end the gate appends a 500 ms synthetic noise tail and calls `finalize(through: lastSpeech + 0.4 s)`. Invariant: hangover - chunk/2 + tail ≥ lead + 50 ms, so finalize never waits for real audio (test `syntheticTailCoversFinalizeForEveryHangover`). Speech end to final text: commands p90 658 ms, answers p90 473 ms **[V, TTS E2E]** |
| Intent parsing | Deterministic rules only. FoundationModels is not in v1: Apple Intelligence is off on this Mac, so `.unavailable(.appleIntelligenceNotEnabled)` **[V]**. The code keeps a protocol seam for a later LLM |
| Matching | Token-level scorer over "CODE: Title [TYPE]". Signals: exact code, spoken-letter collapse, aliases, partial multi-word codes, lookalike code (edit distance 1, never auto-opens), title exact, synonym, prefix, Kölner Phonetik, edit distance, compound suffix and title bigrams. It merges ST and DT hypotheses plus their union. Each interpretation takes 0.08-3 ms on real data **[V, this pass]** |
| Ambiguity | Unique text match → open. Otherwise show numbered choices ranked by personal signals (favorite, own time records, own open tasks, ac-voice history). Auto-opening the dominant candidate is **off** by default (see section 8) |
| Choices UX | Up to 6 visible, numbered absolutely, "mehr" pages. The mic stays open in the same analyzer session with a 6 s window that extends while the user speaks. Selection by voice ("zwei", a name) or by a click on an overlay row. **No Stream Deck choice keys** (user decision). A one-item list is a confirm prompt: "Sag ja oder nein" ("ja" or "eins" opens, "nein" closes it). The pointer resting on the list stops its countdown |
| Chrome | In-process `NSAppleScript` handler, compiled once at launch, called by Apple Event. It reuses an AC tab (sets the URL, focuses it), else opens a new tab or window. If Chrome is not running or Automation is denied, it falls back to `NSWorkspace.open` **[script compiled V, runtime A]** |
| AC data | GET only. A disk cache gives instant resolution. ETag revalidation runs on every key press, in parallel with speech. Resolution never waits on the network, except on a ticket archive miss (0.3-1 s) |
| Secrets/config | Token in the login Keychain. A one-time import from ac-mcp reads `.ac-token-cache`, else `AC_TOKEN` in `.env`. On a 401 the app re-imports once. Non-secret `config.json` lives in Application Support. No runtime dependency on the ac-mcp repo |
| Signing | **Blocker:** the only Apple Development cert is revoked **[V]**. The user renews it in Xcode (preferred). Fallback: a self-signed code-signing cert in the login keychain **[V launches]** |
| Autostart | `SMAppService.mainApp.register()` behind a "Beim Anmelden starten" toggle **[A]** |
| Build | SwiftPM plus `scripts/bundle.sh` (no .xcodeproj), deployment target macOS 26.0. The SDK is 27.2, so 27-only APIs need a `#available` guard **[V]** |

---

## 1. Components and repo layout

### 1.1 Component diagram

```
Stream Deck HW ─USB─> Stream Deck.app ─spawn─> plugin.js (Node 24, SDK v3)
                                               │ keyDown/keyUp → press/release/cancel
                                               │ NDJSON over UDS ~/Library/Application Support/ac-voice/ipc.sock
⌃⌥Space (Carbon RegisterEventHotKey) ─┐        ▼  state/level snapshots back to the key
Menu bar click ───────────────────────┼──> AC Voice.app  (resident, LSUIElement, launched via LaunchServices only)
acvoice://press (optional) ───────────┘  ┌───────────────────────────────────────────────────────────────┐
                                         │ Controller @MainActor: VoiceFlow reducer + effect runner      │
                                         │  ├─ VoiceSession: AVAudioEngine tap → AVAudioConverter         │
                                         │  │    (16 kHz Int16 mono) → SpeechAnalyzer[ST + DT]            │
                                         │  │    → partials, finals, RMS end-of-utterance                 │
                                         │  ├─ Interpreter: Parser + Resolver + TicketResolver (≤3 ms)    │
                                         │  ├─ IndexStore (actor): Caches/index.json + ACClient (GET/ETag)│──HTTPS GET──> ac.example.com/api/v1
                                         │  ├─ OverlayPanel: non-activating NSPanel + SwiftUI glass       │
                                         │  ├─ ChromeOpener: NSAppleScript handler / NSWorkspace fallback │──Apple Events──> Google Chrome
                                         │  ├─ IPCServer: NWListener(.unix) → IPC.State / IPC.Level       │
                                         │  └─ Earcons, StatusMenu, Onboarding, LaunchAtLogin, TokenStore │
                                         └───────────────────────────────────────────────────────────────┘
Persistent state: Keychain (token), App Support/ac-voice/{config.json, history.json, ipc.sock},
                  Caches/io.github.nordavid.acvoice/index.json
```

**Rule:** the plugin never spawns the app binary. It only runs `open -g -b io.github.nordavid.acvoice`. TCC then attributes the microphone and Automation permissions to AC Voice, not to Stream Deck **[A, documented TCC behavior]**.

### 1.2 Repo layout: `ac-voice/`

```
ac-voice/
  Package.swift                    tools 6.2, platforms [.macOS(.v26)], Swift 6 language mode
  Sources/
    ACVoiceCore/                   pure logic, no AppKit/Speech/network (prototype = this pass)
      Text.swift                   Token, TextNorm (fold, tokenize, spelling collapse), GermanNumbers, Fuzzy (OSA, Kölner Phonetik)
      Projects.swift               ProjectEntry (parsed + precompiled), Signals (prior)
      Resolver.swift               ResolverConfig, Resolver (score/merge/decide), Resolution
      Parser.swift                 Command, Selection, Parser (command/selection phase)
      Interpreter.swift            Hypothesis, Interpretation, SelectionOutcome, TaskIndex, TicketResolver
      IPC.swift                    protocol v1 codec
      Routes.swift                 web URLs (project, task, my-work)
      Config.swift                 Config/History Codable models + defaults
      VoiceFlow.swift              state machine reducer (pure, fake-clock testable)
    ACVoiceAC/                     Foundation only
      ACClient.swift               GET-only client, ETag, 301 probe, archive pages
      IndexStore.swift             actor: load/persist/refresh, snapshot stream
      TokenStore.swift             Keychain + ac-mcp import
    ACVoiceSpeech/                 AVFoundation + Speech
      VoiceSession.swift           port of research MicPipeline.swift (+ SIMULATE file source)
      ContextBuilder.swift         contextual strings per phase (≤50)
    ACVoiceUI/                     overlay panel, orb, choice list, snapshot renderer
    ACVoiceSystem/                 ChromeOpener (+ OpenACScript.generated.swift), IPCServer, GlobalHotkey, Earcons,
                                   LaunchAtLogin, Log
    ACVoiceRuntime/                Controller (flow + effect runner), Services (protocols), LiveServices, AppCoordinator,
                                   StatusMenu, Onboarding, OverlayDemo, Diagnostics, AppText
    ACVoiceApp/                    executable "AC Voice": main.swift, AppDelegate.swift
    acvoice/                       dev CLI: resolve | index | transcribe | simulate | open | ipc
  Tests/
    ACVoiceCoreTests/              parser, resolver, selection, tickets, IPC, VoiceFlow (Swift Testing)
    ACVoiceACTests/                decoding of sanitized fixtures, GET-only + ETag via URLProtocol stub
    ACVoiceSpeechTests/            TTS clip → interpretation + latency budget (opt-in ACVOICE_SPEECH_TESTS=1)
    Fixtures/projects.sample.json  synthetic names mirroring the real collision structure
  Resources/
    Info.plist.in, ACVoice.entitlements, AppIcon.icns, earcons/*.caf, open-ac.applescript
  streamdeck/                      port of research plugin, ids renamed
    io.github.nordavid.acvoice.streamdeck.sdPlugin/{manifest.json, imgs/, bin/}
    src/{plugin.ts, app-link.ts, protocol.ts, render.ts}, scripts/build-icons.ts, fake-host/host.mjs
    package.json, rollup.config.mjs, tsconfig.json
  scripts/
    bundle.sh                      from research (revocation precheck, SIGN_ID override for self-signed)
    install.sh                     bundle → ~/Applications, lsregister, open -g
    make-tts-fixtures.sh           say -v Anna / Daniel → Tests/Fixtures/tts (git-ignored)
    gen-applescript.sh             osacompile check + generate OpenACScript.generated.swift
    sd-link.sh                     npm install, build, npx streamdeck link
  .gitignore                       .build, dist, Tests/Fixtures/tts, Tests/Fixtures/recordings, *.p12
```

---

## 2. Module specs

### 2.1 ACVoiceCore (prototype signatures compile [V, this pass])

```swift
public struct Token: Sendable, Equatable { public var text: String; public var isAcronym: Bool; public var key: String }
public enum TextNorm { public static func tokenize(_ raw: String) -> [Token]; public static func fold(_ s: String) -> String }
public enum GermanNumbers { public static func cardinal(_ t: String) -> Int?; public static func ordinal(_ t: String) -> Int? }
public enum Fuzzy { public static func osa(_ a: String, _ b: String, cap: Int = 3) -> Int; public static func cologne(_ s: String) -> String }

public struct Signals: Sendable, Codable, Hashable {
    public var favorite: Bool, timeRecords30d: Int, ownOpenTasks: Int, lastActivity: Date?, recentOpens: [Date]
    public func prior(now: Date) -> Double   // 0.30 fav + 0.30 min(1,tr/10) + 0.15 min(1,ot/3) + 0.15 recentOpens(decay 14 d) + 0.10 exp(-age/30 d)
}
public struct ProjectEntry: Sendable, Hashable, Identifiable {
    public init(id: Int, name: String, signals: Signals = .init(), aliases: [String] = [])  // parses CODE / Title / [TYPE]
}
public struct Resolver: Sendable {
    public func score(_ q: [Token], within: Set<Int>? = nil, now: Date = .now) -> [Scored]
    public static func merge(_ lists: [(weight: Double, scored: [Scored])]) -> [Scored]
    public func decide(_ scored: [Scored], minScore: Double? = nil) -> Resolution     // .unique | .ambiguous([Scored]) | .none(best:)
}
public enum Command: Sendable, Equatable { case openProject(query: [Token]), openTask(query: [Token], number: Int), openMyTasks, cancel, unknown }
public enum Parser { public static func command(_ raw: String) -> Command; public static func selection(_ raw: String, count: Int) -> Selection }
public struct Hypothesis: Sendable { public var text: String; public var weight: Double }
public struct Interpreter: Sendable {
    public func command(_ hyps: [Hypothesis], now: Date = .now) -> Interpretation   // .myTasks | .project(Resolution) | .task(number:, projects:) | .cancel | .notUnderstood(heard:)
    public func selection(_ hyps: [Hypothesis], candidates: [Int], now: Date = .now) -> SelectionOutcome  // .pick(i) | .narrow([i]) | .cancel | .more | .unclear | .command(Command)
}
public struct TaskIndex: Sendable, Codable { byProject: [Int: [Int: TaskRef]]; projectOfTask: [Int: Int]; archiveComplete: Set<Int>; mine: [TaskRef] }
public enum TicketResolver {
    public static func resolve(number: Int, projects: Resolution?, index: TaskIndex, favorites: [Int], allProjects: [Int]) -> TicketOutcome
    // .open(projectId:taskId:) | .choices([TaskRef]) | .fetchArchive(projectIds:) | .probe(taskId:) | .notFound
}
public enum Routes {   // to add (trivial)
    static func project(_ base: URL, _ id: Int) -> URL            // {base}/projects/{id}
    static func task(_ base: URL, _ pid: Int, _ id: Int) -> URL   // {base}/projects/{pid}/tasks/{id}
    static func myWork(_ base: URL, path: String, userId: Int?) -> URL  // default "/users/{me}/tasks", "/my-work" without an id
}
```

**VoiceFlow** (`ACVoiceFlow`) is a pure reducer. The Controller runs its effects in order and feeds results back.
The full API is in `FlowTypes.swift`; the wiring:

| Effect | Controller call | Event back |
|---|---|---|
| `.startMic(gen, mode, hangover)` | `VoiceSession.start(context:source:mode:gen:hangover:)` (context: `ContextBuilder.command`) | every `VoiceSession.Event` as is: `e.gen` is the flow's stamp; `.failed(err)` → `.speechFailed(e.gen, err.failure)`; a throw → `.speechFailed(gen, err.failure)` |
| `.rearm(gen, mode, hangover)` | `VoiceSession.rearm(_:context:gen:hangover:)`; `.answer(titles, firstNumber, hasMore)` → `ContextBuilder.answer(titles:hasMore:firstNumber:)` (visible page only) | |
| `.setHangover(s)` | `VoiceSession.setHangover(s)` | |
| `.revalidateTaskLists(task, activeProjectId, request)` | `IndexStore.revalidateTaskLists(for:activeProjectId:)` | `.taskListsRevalidated(request:, complete: check.complete)` |
| `.fetchArchive(pids, request)` | `IndexStore.checkArchives(pids)` | `.archiveFetched(request:, complete:, message: check.error?.userMessage)` |
| `.probeTask(id, request)` | `IndexStore.probe(taskId:)` | `.probed(request:, .found/.notFound/.failed, message: ACError.userMessage)` |
| `.recordOpen` / `.recordPick` | `History.recordOpen` / `recordPick`, save, rebuild `IndexSnapshot.interpreter(config:history:)` | |

`FlowEnv.interpreter` comes from one call: `IndexSnapshot.interpreter(config:history:)` = Core `Interpreter(projects:config:history:)` (config aliases per code, `History.learnedAliases` when `config.learnAliases`, history opens as signals, learned picks). `FlowEnv.index` is the latest `IndexSnapshot.tasks`.

### 2.2 ACVoiceAC

```swift
public enum Fetch<T: Sendable>: Sendable { case fresh(T, etag: String?), notModified }
public actor ACClient {
    public init(base: URL, token: String, userId: Int)          // base = https://ac.example.com, API = base/api/v1
    func get<T: Decodable & Sendable>(_ path: String, etag: String? = nil) async throws -> Fetch<T>  // only GET exists
    func projects(etag: String?) async throws -> Fetch<[ACProject]>                 // GET /projects [V]
    func projectNames() async throws -> [Int: String]                               // GET /projects/names [V]
    func favorites(etag: String?) async throws -> Fetch<[ACFavorite]>               // GET /favorites [V]
    func myTasks(etag: String?) async throws -> Fetch<ACUserTasks>                  // GET /users/{me}/tasks [V]
    func timeRecords(from: Date, to: Date) async throws -> [ACTimeRecord]           // GET /users/{me}/time-records/filtered-by-date?from=&to= [V]
    func projectTasks(_ pid: Int, etag: String?) async throws -> Fetch<ACProjectTasks>  // GET /projects/{id}/tasks [V]
    func archivePage(_ pid: Int, page: Int) async throws -> [ACTask]                // GET /projects/{id}/tasks/archive?page=N, 30/page [V]
    func probeProject(ofTask id: Int, via pid: Int) async throws -> Int?            // 301 Location parse, 404 → nil [V]
    func companies() async throws -> [Int: String]                                  // from GET /user-session (never persist feed_token) [V fields]
}
public struct IndexSnapshot: Sendable, Codable {
    var projects: [ProjectEntry]; var tasks: TaskIndex; var favorites: [Int]; var etags: [String: String]; var fetchedAt: Date
}
public actor IndexStore {
    public init(client: ACClient, cacheURL: URL, history: HistoryStore)
    public nonisolated var updates: AsyncStream<IndexSnapshot> { get }   // Controller mirrors the latest snapshot on MainActor
    public func loadFromDisk() async -> IndexSnapshot?
    public func refreshFast() async        // projects + favorites + my tasks + time records 30 d, parallel, ETag
    public func refreshTaskLists() async   // /projects/{id}/tasks per project, 8 parallel, ETag
    public func extendArchives(priority: [Int]) async  // background, favorites and time-record projects first
    public func ensureArchive(_ pids: [Int]) async -> Bool  // miss path, parallel pages, budget 2.5 s
}
public enum TokenStore {
    static func load(account: String) -> String?                       // kSecClassGenericPassword, service "io.github.nordavid.acvoice"
    static func save(_ token: String, account: String) throws
    static func importFromACMCP(_ dir: URL) throws -> (token: String, url: URL?, userId: Int?)  // .ac-token-cache, else .env AC_TOKEN, plus AC_URL/AC_USER_ID
}
```

How `.ac-token-cache` works **[V, read in ac-mcp/src/index.ts]**:
- The file is 0600 and holds the raw token.
- ac-mcp prefers `AC_TOKEN` from `.env`. Otherwise it uses the cache, re-issues the token via `issue-token` on a 401 and rewrites the cache.
- ac-voice therefore re-reads the cache once on a 401, then shows "AC-Token ungültig".
- The user id comes from the config, else from the token prefix `538-…` **[V format, A that this holds for every token]**.

### 2.3 ACVoiceSpeech (port of research `MicPipeline.swift`, which compiles warning-free [V])

```swift
@available(macOS 26, *)
public final class VoiceSession: @unchecked Sendable {
    public struct Event: Sendable { session: Int; utterance: Int; kind: Kind; var gen: SpeechGen }   // caller's stamp
    public enum Kind: Sendable { warming, ready, micReady, level(dB:thresholdDB:), speechStarted, partial(dt:st:),
                                 utterance(Utterance), noSpeech, sourceRestarted, failed(SpeechError) }
    public func warmUp(context: [String]) async throws        // assets (≈660 ms), priming, first analyzer
    public func start(context:, source:, mode: UtteranceMode, gen: SpeechGen?, hangover: Double?) async throws -> AsyncStream<Event>
    public func rearm(_ mode: UtteranceMode, context: [String]?, gen: SpeechGen?, hangover: Double?) async   // re-arm EOU first, then setContext (~110 ms)
    public func setHangover(_ seconds: Double)                // the flow's value, applied as is
    public func endUtteranceNow() -> Bool                     // press while listening / push-to-talk release
    public func stop() async                                  // mic off, analyzer cancelled, next one pre-built
}
public enum ContextBuilder {
    static func command(projects: [ProjectEntry], now: Date, limit: Int) -> [String]
    static func answer(titles: [String], hasMore: Bool, firstNumber: Int, limit: Int) -> [String]
}
```

Fixed configuration **[V research]**:

```swift
let st = SpeechTranscriber(locale: Locale(identifier: "de_DE"), transcriptionOptions: [],
                           reportingOptions: [.volatileResults, .fastResults, .alternativeTranscriptions], attributeOptions: [])
let dt = DictationTranscriber(locale: Locale(identifier: "de_DE"), contentHints: [.shortForm], transcriptionOptions: [],
                              reportingOptions: [.volatileResults, .alternativeTranscriptions], attributeOptions: [])
let analyzer = SpeechAnalyzer(modules: [st, dt], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
```

Rules **[V research unless marked]**:
- **Audio:** 16 kHz Int16 mono via `bestAvailableAudioFormat`, converted with AVAudioConverter.
- **Finalize:** never call `finalize(through: nil)` with the stream open, because it hangs. Keep feeding mic audio until finalize returns. Guard with a `finalizeTimeout` of 1.2 s that falls back to the last volatile texts **[A, guard design]**.
- **Collecting results:** collect finals per module keyed by `range.start` and dedupe repeated DT finals.
- **Hypotheses passed to the Interpreter:** DT best (1.0), ST best (1.0), DT and ST alternatives (0.9). The Interpreter adds the union of the best texts.
- **Contextual strings (DT only):** at most `Config.contextualStringLimit`, default 35 (`ContextBuilder.defaultLimit`, the size the speech E2E tests measure; REVIEW m10).
  - **Command phase:** all project codes (about 30) in written form ("WWT", "S+K", plus "S und K"), "Ticket", "Meine Aufgaben", "Projekt", user aliases, and distinctive title words of favorite, time-record and recent projects.
  - **Answer phase:** number words of the visible page ("sieben … zwölf" on page 2), "zwo", "die erste/zweite", "abbrechen", "mehr", plus distinctive title words of the visible rows.
  - 185 entries made results worse, 19 targeted entries made them better **[V]**.
- **Live transcript:** DT volatile results drive the overlay text, at a cadence of 200-300 ms **[V]**.
- **Speculative interpretation:** each DT partial runs through `Interpreter.command`, which takes ≤3 ms **[V, this pass]**. This drives the live target preview in the overlay ("→ WWT: Website Relaunch").
- **Adaptive hangover (owned by VoiceFlow):** Core `HangoverPolicy` on the leading best hypothesis of each partial: a trailing numeral → 1.1 s ("Ticket 4" may become 412); a dangling word or fillers only (`Parser.looksIncomplete`) → 1.1 s; a complete intent (`Interpretation.isCompleteIntent`) → 450 ms; else 600 ms. Answers: 400 ms; a new command in the answer phase follows the command rules. A dangling answer word does not extend the live budget (DT shows the last word of "die zweite" late); the speech layer reopens an utterance whose final text dangles instead (same Core rule). The gate's own floors: 1.1 s while a command has no word yet (the transcriber lags the level) and after a reopen. The old floor "lead + 50 ms" is replaced by the synthetic-tail invariant (section 0).
- **Threshold:** threshold = clamp(noiseFloor + 12 dB, -50 … -30 dBFS). The noise floor is the rolling 20th percentile of non-speech buffers **[A, TTS-only tuning so far]**.
- **Analyzer per session:** one analyzer per press. After `stop()`, the next one is pre-built immediately. With a pre-built analyzer, press to listening takes 1-2 ms **[V]**; a cold start takes 180-430 ms.

### 2.4 ACVoiceRuntime and ACVoiceApp (built, M4/M5/M8)

`ACVoiceApp` is a thin executable: `main.swift` exits when the IPC socket answers (a live instance), sets the accessory
policy and hands the `NSApplicationDelegate` calls to `AppCoordinator`. Everything else lives in `ACVoiceRuntime`.

```swift
@MainActor public struct Services {            // every system service behind a protocol; tests pass fakes
    speech: SpeechServing                      // LiveSpeech: VoiceSession + MicSource, events as SpeechEvent(gen, signal)
    tokens: TokenServing                       // LiveTokens: Keychain (private serial queue) + read-only ac-mcp import
    makeIndex: (userId, Config) -> IndexServing // LiveIndex: IndexStore + ACClient with KeychainTokenStore
    permissions: PermissionsServing            // TCC status, requests only from setup-window clicks
    overlay: OverlayPresenting                 // ACVoiceUI.OverlayController
    ipc: IPCEndpoint                           // ACVoiceSystem.IPCServer
    chrome: ChromeService                      // ACVoiceSystem.ChromeOpener (askWhenUndetermined = false)
    earcons, hotkey, loginItem, clock: RuntimeClock (ContinuousClock timers), store: Persisting (config/history files)
}
@MainActor public final class Controller {
    init(services:timings:config:history:)
    func start() async                         // IPC socket, earcons, hotkey, token + cached index, warm-up, refresh timers
    func trigger(_ e: FlowEvent)               // IPC, hotkey ("hk-N" press/release), menu, URL scheme, overlay clicks
    func importToken() / saveToken(_:) async   // Keychain, then ACClient.resetToken (or a new index), then refresh
    func refreshIndexNow(), runSelfTest(), runChromeTest(), startDemo(loop:), setLaunchAtLogin(_:)
    func shutdown() async                      // timers, hotkey, socket, history, microphone
}
```

Effect wiring (in reducer order; speech calls run through one serial queue, so `.startMic` then
`.suspendEndpointing(true)` holds the new session):

| Effect | Controller |
|---|---|
| `.publish(m)` | `overlay.render(m)`, `ipc.broadcast(m.ipcState())` |
| `.showOverlay` / `.hideOverlay(f)` | earcon output prewarm (the engine start blocks the main thread; at the press, not when the first audio arrives), `overlay.show()` / `overlay.hide(fade:)` |
| `.startMic(gen, mode, h)` | microphone permission check first (not granted: `.speechFailed(gen, .micDenied)` and the setup window, never a prompt); `speech.start(context: ContextBuilder.command(…, limit: config.contextualStringLimit))`; a throw → `.speechFailed(gen, SpeechError.failure)`; Chrome active-tab query → `env.activeProjectId` (only with Automation granted) |
| `.rearm` / `.setHangover` / `.suspendEndpointing` / `.endUtteranceNow` / `.stopMic` | `speech.rearm(context: ContextBuilder.answer(titles:hasMore:firstNumber:))` / `setHangover` / `setHold` / `endUtteranceNow` / `stop` |
| `.refreshIndex` | `IndexStore.refreshFast` (ETag), parallel to speech |
| `.revalidateTaskLists` / `.fetchArchive` / `.probeTask` | `revalidateTaskLists(for:activeProjectId:)` / `checkArchives` / `probe`; the env's task index is synced from the store, then `.taskListsRevalidated` / `.archiveFetched(message: check.error?.userMessage)` / `.probed(message: ACError.userMessage)` |
| `.open(url, r)` | `ChromeOpener.open` → `.opened(r, result)` or `.openFailed(r)` |
| `.schedule` / `.cancelTimer` | one monotonic timer per kind, fired as `.timer(id)` |
| `.earcon(e)` | `EarconPlayer.play`; `onPlaybackStart` → `speech.noteEarcon(duration:)` (gate blanking) |
| `.recordOpen` / `.recordPick` | History, debounced save (1.5 s), interpreter rebuild |

Speech events map 1:1 (`.partial(dt, st)` → `Transcript` split into stable and volatile words, hypotheses DT + ST;
`.warming`/`.ready` → `.speechWarm`; `.level` → overlay and IPC, normalized −60…−12 dBFS, current session only;
`.resumed` → `.speechResumed` (a dangling final reopened the utterance); `.discarded` → `.speechDiscarded` (the
onset was noise: the flow's no-speech timeout counts again); `.failed(.micDenied)` also opens the setup window).
`.endpoint` → signpost; also `.speechEnded` while the model is not warm, so the cold finalize watchdog runs from the
gate's end (warm, the final follows within ~50 ms, and a resume or a discard would only flash "processing").
The gate's own no-speech timeout is off in the app (`.infinity`): the flow owns it (from micReady, waiting for a
held key, restarting after a release or a discarded noise onset), and the flow restarts `maxUtterance` at every onset.
Overlay pointer (`onPointer`, after a mouse move only) → `.pointer(inside:)`: a list stops its countdown up to the hard
cap and keeps at least 2.5 s after the pointer leaves (the IPC snapshot has no deadline meanwhile); an error or a
success with a hint stays up to 15 s and fades 1 s after the pointer leaves.
Background refresh: fast every 5 min, task lists + archives every 12 min (at launch only when older), both only
while idle (busy → retry after 30 s), with a 10% timer tolerance. They pause while the Mac, its displays or the
session sleep (NSWorkspace) and run 12 s after the wake; transport errors of the first 30 s after a wake stay out of
the menu. A 401 marks the token invalid; a token import bumps a generation so late results of the old token (refresh
and ticket path) never flip the status back. Chrome's Automation status is cached from preflights (launch, Chrome's
start, the setup window) and open results; `.notDetermined` puts the badge on the icon and a status line in the menu,
and the setup window opens once per run (at launch or Chrome's first start while idle, else after the command that
fell back). `shutdown()` sends `.cancel` first and stops the speech layer through the same serial queue, so a start
queued right before the quit never runs after the stop. Signposts (category `flow`): `pressToMicReady`,
`speechEndToFinal`, `finalToOpened`; the same durations feed "Diagnose kopieren".

Shell: status item (SF Symbol per phase, badge while setup is incomplete; the icon reads phase and badge only, the
menu is built when it opens) with the German menu "Zuhören" (hotkey as key equivalent), "Index aktualisieren",
"Einrichten …", "Beim Anmelden starten" (a dash while macOS waits for approval; a click turns it off), "Anmeldeobjekte
öffnen …" (only then), "Diagnose" (the last test results, then "Spracherkennung testen", "Chrome testen", "Overlay
vorführen", all off while a command runs, and "Diagnose kopieren", which flashes a check on the icon), "Beenden".
Setup window (SwiftUI in an NSWindow, the app activates only for it) with one row per step: AC-Token, Mikrofon,
Chrome, Sprachmodell, Stream Deck, Autostart. It opens by itself when the token or the microphone permission is
missing, or when Chrome runs with Automation not determined (once per run). While it is open it re-reads the statuses
when Chrome starts or quits and when it becomes key again (back from System Settings). "Befehle kopieren" uses the
absolute source folder (`ACVoiceSourceRoot`, written by bundle.sh). `acvoice://press|cancel|setup`. `--demo` and
"Overlay vorführen" first run a scripted command through the real reducer with real timings and fake speech
events, then cycle `OverlayGallery`, without any other service. SIGTERM quits like the menu (install.sh).

Changes to the research AppleScript `open-ac.applescript`:
- If the reused tab's URL already equals the target, skip `set URL` and only focus the tab. This avoids an SPA reload.
- `activate` stays last.

### 2.5 IPC protocol v1 (prototype codec, round-trip tested [V, this pass])

Line format: one UTF-8 JSON object per `\n`, max 64 KB, `v:1`. Unknown `t` values and unknown fields are ignored.

Socket setup:
- The app creates the directory with mode 0700.
- It `unlink`s a stale socket, then binds.
- It sets the socket to `chmod 0600` once the listener is ready.

```jsonc
// plugin → app
{"v":1,"t":"hello","client":"streamdeck","version":"0.1.0"}
{"v":1,"t":"press","id":"sd-7","at":1732440000000}     // keyDown
{"v":1,"t":"release","id":"sd-8","heldMs":812}          // >=600 ms while listening = push-to-talk end
{"v":1,"t":"choose","id":"sd-9","index":2,"seq":6}     // 1-based; kept in the codec, the v1 plugin has no choice keys
{"v":1,"t":"cancel","id":"sd-10"}
{"v":1,"t":"ping","id":"sd-11"}
// app → plugin
{"v":1,"t":"state","seq":6,"phase":"choices","since":1732440001234,"transcript":"Öffne das WWT-Projekt",
 "preview":null,"choices":[{"n":1,"label":"Relaunch","detail":"WWT: Website Relaunch [AGIL]"}],
 "total":4,"deadline":1732440007234,"message":null,"micReady":null}
{"v":1,"t":"level","rms":0.42}                          // ~15 Hz while listening
{"v":1,"t":"pong","id":"sd-11"}
```

- **Phases on the wire:** `idle | listening | processing | choices | success | error`.
- **Internal states and their wire phase:**
  - retry → `listening` with a `message`
  - searching / opening → `processing` with a `message`
- **New optional fields** compared with the streamdeck research: `preview` and `total`. The plugin ignores them until it uses them.
- **Labels:** at most 12 characters, title without code and type.

Press semantics, owned by the app **[V in the fake-app e2e]**:

| Phase when pressed | Result |
|---|---|
| idle / success / error | listen |
| listening, retry | after speech: end the utterance now; before speech: ignored within 0.4 s (`doubleTap`), else cancel |
| processing, choices | cancel |
| opening | cancel (an open already sent to Chrome is not undone) |

Link behavior between plugin and app **[V in the plugin unit tests, fake-host e2e and IPCServerTests]**:
- **Key leaves the page while held:** the plugin sends `release{pressId, heldMs: 0}`. `heldMs: 0` is not a push-to-talk end; the app hands the end of the utterance back to endpointing.
- **Plugin disconnects while its key is held:** the server feeds the same `release{pressId, heldMs: 0}` into the flow. A duplicate is harmless, because `VoiceFlow.release` ignores a pressId that does not match.
- **Missed pong:** the plugin never reconnects because of it. After 4 s without an answer it reports the app as busy (inspector "Verbunden. AC Voice antwortet gerade nicht.") and keeps the key face. Only a closed socket ends the link. Pings are still answered on the main queue, so a blocked main thread (for example a 3 s Apple Event) shows as busy.
- **Page switch:** the plugin keeps the link for 1 s after the last key disappears, so switching pages causes no reconnect and no offline face.
- **Single instance:** before the app unlinks a socket file it tries to connect. A live peer keeps its socket (`alreadyRunning`).

---

## 3. Overlay state machine and timings

The overlay is one `OverlayPanel` (borderless, `.nonactivatingPanel` set at init, `.floating`, `canJoinAllSpaces + fullScreenAuxiliary`, `canBecomeKey=false`). It is created at launch and only ordered in and out. It sits on the screen under the mouse with its top edge at 25% of `visibleFrame` and grows downward. **[V: Chrome stayed frontmost, geometry correct. Glass look not visually verified.]**

| State | Entry actions | Exit → next | Timing |
|---|---|---|---|
| **idle** | panel hidden, mic off, next analyzer pre-built | press → listening | key → face 0.6 ms p50 **[V]** |
| **listening** (micReady=false → true) | orderFrontRegardless + 120 ms fade, `startMic(context)`, ETag refresh in parallel, earcon "tick" on first converted buffer; "Mikrofon startet …" until then, "Ich höre zu" after | speech end + hangover → processing; press or PTT release → processing; partial cancel word → idle; no speech for 4.0 s after micReady → error "Ich höre nichts"; a discarded noise onset restarts that time; 8.0 s max after each onset → processing | analyzer warm 1-2 ms **[V]**; engine start 50-200 ms **[A, measure in M3]** |
| **processing** | `finalize(through: lastSpeech+0.4 s)`, then `Interpreter.command` | unique project, my-work or a resolved ticket → opening; ambiguous → choices; a ticket number < 10000 → revalidate its task lists first (watchdog 1.5 s); `.fetchArchive`/`.probe` → stays here with "Suche Ticket 412 …"; not understood → **retry** (once); finalize timeout of 1.2 s → volatile fallback | finalize 34-51 ms **[V]**, interpret ≤3 ms **[V]**, archive 0.3-1 s **[V]**, probe 25-55 ms **[V]** |
| **retry** (= listening + message) | same session, re-arm EOU, message "Das verstehe ich nicht. Sag es nochmal." | utterance → processing; 5.0 s silence → idle; second failure → error | |
| **choices** | panel grows with the list (spring 250 ms, rows staggered 30 ms), `rearm(.answer(visible page))`, deadline = now + 6.0 s, countdown ring; the command stays the headline, the live answer shows in the footer | pick → opening; a click on a row (`choose{n, seq}`) → opening; one-item confirm + "nein" → idle; `narrow` → re-render the subset with a fresh deadline and "„Website“ passt zu 2 Zeilen"; `more` → next page; new command → processing; cancel word or press → idle; unclear → hint "„Hi.“ passt zu keiner Zeile. Sag eine Zahl.", +4 s, max 2 times → error; pointer on the list → countdown stops (hard cap 30 s), pointer off → at least 2.5 s; deadline → idle | answer end → final p90 473 ms **[V TTS E2E]**; fastSelect ~250-350 ms **[A]** |
| **opening** | `stopMic` immediately (orange dot off), `ChromeOpener.open`, `recordOpen`, `recordPick` when coming from choices; the target becomes the headline, "Öffne in Chrome …" below | ok → success; -1743 (denied) or not determined or failure → NSWorkspace fallback → success (hint for denied always, for not determined once per run); else error | Apple Events 10-40 ms **[A]**; handler overhead 0.03 ms **[V]** |
| **success** | green check + title (same headline as opening), "Chrome zeigt die Seite", earcon "done" | 0.7 s (3.5 s with a hint) → fade 0.2 s → idle; pointer holds a card with a hint; press → listening | |
| **error** | red, message, the next step when there is one ("Die Einrichtung ist offen", "Sag zum Beispiel „Meine Aufgaben“", "Prüfe die Internetverbindung"), earcon "error" | 3.0 s → fade → idle; pointer holds it (max 15 s, 1 s after it leaves); press → listening | |

**Esc** (added after the first test): in every state except idle, Esc does what the close button does (`onDismiss`: cancel to idle, or stop the overlay demo). Nothing new opens; an open already sent to Chrome in **opening** is not undone. The panel never takes the keyboard focus, so Esc is a Carbon hotkey (`CarbonHotkey.escape`, no permission needed), plus Esc with the configured hotkey's modifiers (⌃⌥Esc), because Carbon matches the exact modifier set and push-to-talk holds ⌃⌥. It consumes Esc in every app, so `EscapeClosesOverlay` registers it only between `show()` and `hide()`.

**fastSelect** (flag, default on, verify in M7): in the choices state, commit a `.pick(n)` from DT partials without waiting for finalize. The condition is that the same pick shows up in 2 consecutive partials, or that at least 250 ms of silence passed. Fallback: the normal 400 ms path **[A]**.

**Deadline extension:** while the user speaks during choices, deadline = max(deadline, lastSpeech + 2.5 s).

**Perceived-speed budget, speech end to Chrome:**
- Hangover: 600 ms, or 450 ms with the fast hangover (answers 400 ms).
- Finalize plus interpret: ~50 ms.
- Apple Events: ~20 ms.
- Result: Chrome shows the AC tab with the new URL **≈ 0.5-0.7 s** after speech end **[V parts / A total]**.
- Page render after that depends on the AC SPA reload. The bundle is cached, and render is estimated at 0.5-1.5 s **[A]**.

**Overlay look:**
- Liquid Glass via SwiftUI `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))`, falling back to `NSVisualEffectView(.hudWindow)`.
- Left side: a Jarvis "orb", drawn with a Canvas inside a TimelineView at 60 fps. Concentric rings react to `level`.
  - cyan: listening
  - violet rotating arc: processing
  - amber with countdown ring: choices
  - green: success
  - red: error
- Right side, top to bottom:
  - the live transcript, with the stable part bright and the volatile tail dim
  - the preview line "→ WWT: Website Relaunch"
  - a hint line
- Choice rows: a large numeral pill, the title with the matched words bold, a code + type badge, and a ★ (favorite) or clock (recent) marker.
- The app respects Reduce Motion and keeps width at 560 pt.

---

## 4. Resolver spec (implemented in prototype [V, this pass])

### 4.1 Normalization (`TextNorm.tokenize`)
1. `ß→ss`. Join thousands groups: `47.285`, `47. 285` and `47 285` all become `47285`. `- _ /` become spaces.
2. Split glued acronyms: `WWTilonch` → `WWT ilonch`. Drop punctuation except `+` and `&`. In a word, `&` becomes `+` (`S&K` → `s+k`).
3. Fold case and diacritics. Mark acronyms (≥2 letters, all uppercase in the source).
4. Collapse spelled letters using the German letter-name table (eff/ef, te/tee, de, ha, ku, we, vau, ix, ypsilon, zett, …):
   - A run of ≥2 letters becomes a code if at least half of them are "strong" letter names (not also common words like de/er/es/en/em/el/a/e/i/o/u). Examples: `we we te` and `W W T` → WWT; `I B N` → IBN; `ku zett` → QZ.
   - `letter (und|plus|&|+) letter` becomes `X+Y`, unless both letters are weak. Examples: `S und K`, `es und ka`, `S & K` → S+K.
5. Comparison key = alphanumerics only (`s+k` → `sk`).

### 4.2 Command parsing (`Parser.command`)

The parser checks these in order:
1. **My-tasks phrases:** "meine aufgaben/tasks/tickets/todos", "my work", "bei mir an", "was steht (heute) an", "was liegt an", "mir zugewiesen", "meine offenen", "meine arbeit".
2. **Cancel words only:** "abbrechen", "stopp", "egal", "nein", …
3. **Ticket:** `ticket|task|aufgabe|issue|ticker [nummer|nr] <number>`. The number can be digits, a compound word (`vierhundertzwölf`) or digit by digit (`vier eins zwei`). Project words may come before or after it.
4. **Bare global id:** a single remaining number ≥10000 counts as a ticket id ("öffne 47285").
5. **Otherwise openProject:** the remaining tokens after removing fillers (verbs, articles, "projekt", "bitte", "mal", "jarvis", …).

### 4.3 Scoring (per project, text only)

| Signal | Score |
|---|---|
| Exact code sequence (variants: `&` dropped or spoken as "und") | **+3.0** |
| Alias sequence (config + company name) | +2.5 |
| Partial multi-word code ("Hollenstein" of "Hollenstein TS") | +3.0 × matched/len |
| Lookalike single code (OSA = 1, acronym or ≤4 chars, ≥3 chars). Dropped entirely when any project has an exact code hit | +1.5 |
| Title word exact | +1.0 |
| Synonym (wartung/pflege→maintenance, webseite/homepage→website, …) | +0.9 |
| Prefix (query ≥3, title ≥4) | +0.8 |
| Kölner Phonetik equal (≥4), or compound suffix ("Ebenbetreuung" ⊃ "betreuung", title ≥6) | +0.7 |
| OSA ≤1 (≥4 chars) or ≤2 (≥7 chars) | +0.6 |
| One query word vs two title words: exact / OSA ≤2 ("Grantnavigation") | +1.8 / +1.4 |
| Two query words vs one title word ("TYPO 3" → typo3) | +1.0 |
| Type token (agil/sla/int/fix/cr, "intern"→int) | +0.5 |
| Every title word matched / partial coverage | +0.4 / +0.1 × share |

Each title word can be used only once. `coverage` = matched query tokens / content tokens.

### 4.4 Hypothesis merge
- Score every hypothesis separately and keep the best weighted score per project.
- Also score the **union of the best DT and ST texts**. DT tends to get codes right, ST English title words. Example: "TKZ Tauben" + "CKZ Touren" → the TKZ project with "TourenPlaner" in its title.

### 4.5 Decision thresholds

```swift
// minScore 0.9 (command) / 0.6 (inside a visible list), minCoverage 0.5, epsilon 0.3
guard top.text >= minScore, top.coverage >= 0.5 else { return .none(best: top) }      // → retry
let near = sorted.filter { $0.text >= top.text - 0.3 }
if near.count == 1, !(top.codeHit == .fuzzy && top.titleEvidence < 1.0) { return .unique(top) }   // → open
return .ambiguous(near)                                                                  // → choices
```

- **Order of choices:** `rankKey = text + 0.25·prior + 0.2·min(1, learnedPicks/3)`.
  - Personal signals only order the list; they never turn a list into an auto-open (default).
  - `learnedPicks` counts earlier picks for the same normalized query (`history.json`).
- **Visible choices:** max 6, numbered absolutely. "mehr" shows the next page; the footer names it ("„mehr“ zeigt 6 weitere Projekte", "ein weiteres Projekt") and, on the last page, "„mehr“ zeigt wieder Seite 1".
- **Lookalike codes:** a lookalike code with no title evidence never auto-opens. A one-item list asks "Sag ja oder nein".

### 4.6 Selection parsing (`Parser.selection` + `Interpreter.selection`)

The parser checks these in order:
1. Cancel words only → cancel.
2. A single confirm word ("ja", "genau", "passt") → pick 1.
3. "mehr", "weitere" or "andere" → more.
4. An ordinal in ≤4 tokens ("die zweite", "die letzte") → pick.
5. A single number word or digit ("zwei", "2.", "zwo", "Nummer drei", lookalikes "zwai"/"frei") → pick.
6. An open verb or a ticket word → a new command.
7. Otherwise → resolve by name **within the candidates** at minScore 0.6. Unique → pick; a smaller set → narrow; nothing → unclear.

The parser takes the first hypothesis that yields a valid pick, so an empty ST result plus DT "Eins." still gives 1.

### 4.7 Results

**Fixture tests [V, this pass]:**
- "Öffne das WWT-Projekt" → 4 choices with 628 first.
- Spelled "we we te" → 4.
- **Unique:**
  - "WWT Relaunch", "WWT Relonch", "Relaunch von WWT" → 628
  - "S und K. Leasing Cockpit", "S & K Leasing Cockpit" → the S+K Leasing Cockpit project
  - "Grand Navigation", "Grantnavigation" → 693
  - "Im Pilzdatenbank" → the BDG Pilzdatenbank project
  - "Ebenbetreuung" (with the IBN alias "eben") → IBN Betreuung
  - "ku zett CRM" → QZ CRM
  - "Hollenstein Optical" and "TYPO 3 von WWT" → unique
- **Merged:** "TKZ Tauben" + "CKZ Touren." → unique. "WWT Relaunch" + "WWTilonch." → 628.
- **Choices:** "WWT Website" → 2; "QZ" → all; "Hollenstein" → 3.
- **Not understood:** "YouTube", "Disney+", "Hallo Welt", "App TV".
- **Lookalike:** "WWD" → a list, never an open.
- **Selection:** "Zwei." / "2." / "zwo" / "die zweite" / "nein, die zweite" → 2; "Relonch." → Relaunch; "Website" → narrow to 2; "Hi." → unclear; "abbrechen" → cancel; "Ticket 47285" → new command.

**Real project names [V, this pass, ids only]:**
- WWT → choices(4) [628 first]. WWT Relaunch / Relonch → 628. WWT Rionch → choices(4) with 628 first.
- Grand Navigation / Grantnavigation / Braun Navigation → 693. BDG Pilzdatenbank, Im Pilzdatenbank, IBN Betreuung, QZ CRM, ku zett CRM → unique.
- QZ → choices with all QZ projects. RBZ 5, MOLA 3, ZMF 2, Hollenstein 3, "S & K" 2.
- "WWT Wartung" → 314 (complete title "Maintenance" beats "TYPO3 Website maintenance"). "WWT Website" → 2.
- "WWT Ticket 412" → task with 4 candidate projects. "Ticket 412 im WWT Relaunch" → 628.
- "Ebenbetreuung" without an alias → choices(2) of other "…betreuung" projects. That shows aliases are needed for IBN.
- No TKZ project contains "Touren Planer", so "TKZ Touren Planer" correctly lists both TKZ projects.

**Known limitation [V]:** "WKT Relaunch", where STT misheard WWT, lists the WKT projects. DT contextual strings with "WWT" and the ST+DT union lower the risk. The user can say "nein, WWT Relaunch" in the choices state.

---

## 5. Ticket and My-Tasks flows

URLs: project `https://ac.example.com/projects/{id}`, task `https://ac.example.com/projects/{pid}/tasks/{taskId}`. Both routes exist in the SPA bundle **[V]**. The SPA behavior with a wrong pid is unknown, so the app always resolves the real pid first **[A]**.

**Index (background):**
- `GET /projects/{id}/tasks` once per project, 8 in parallel, a few seconds and several MB raw **[V]**. The app keeps only `{id, project_id, task_number, is_completed}`, `completed_task_ids` and `trashed_task_ids`. That gives `byProject[pid][number]` for open tasks and `projectOfTask[id]` for all ids (a few thousand open ids and many more completed ones) **[V]**.
- `GET /projects/{id}/tasks/archive?page=N` (30 per page, sorted by `completed_on` desc) gives completed tasks with numbers **[V]**. It runs at low priority: favorites and time-record projects first, then the rest. All archives together run to a few hundred pages, 5-10 s **[A]**. Incremental: when `completed_task_ids` has unknown ids, the app fetches page 1, 2, … until they are covered.
- `GET /users/{me}/tasks` gives the user's open tasks with `task_number` and `project_id` **[V]**.

**"Öffne WWT Ticket 412"** → `.task(412, projects: WWT×4)` → `TicketResolver`:
0. **Revalidate first** (every number < 10000): conditional GET of the task lists the decision reads (`revalidateTaskLists(for:activeProjectId:)`, mostly 304 in ~25 ms, budget 800 ms). Lists that stay stale may hide the number in a sibling project: the request turns unconfident, and a single hit becomes a one-item confirm list instead of opening.
1. Look up `byProject[pid][412]` for every candidate pid.
2. One hit opens only when no sibling archive can still hide the number (or it is in the active tab project or the user's own tasks, REVIEW M6). Several hits → choices labelled "Relaunch · #412", detail = task name.
3. Otherwise `.fetchArchive(pids)`. The overlay shows "Suche Ticket 412 …". `checkArchives` fetches pages in parallel (0.3-1 s **[V]**, budget 2.5 s), then the resolver runs again with every fetched id in `attemptedArchives`, whatever the result, so no id is asked twice; at most 2 rounds. Still nothing → "WWT hat kein Ticket 412", or the AC error ("AC antwortet nicht", "AC lehnt den Token ab") when the fetch failed.

**"Ticket 47285" (no project):**
- n ≥ 10000 → global id. Task numbers per project stay in four digits, task ids have up to 5 digits **[V]**.
- `projectOfTask[n]` → open. Otherwise `GET /projects/{anyPid}/tasks/{n}` without following redirects:
  - 301 `Location …/projects/{pid}/tasks/{n}` → open (25 ms warm, 55 ms cold)
  - 404 → "AC kennt kein Ticket 47285" **[V]**
- An id in the trashed set gives the error "Das Ticket liegt im Papierkorb".

**"Ticket 412" (no project, 4 digits or fewer):**
1. The user's own open tasks with that number.
2. Favorites.
3. All projects. One hit → open; up to 6 → choices ranked by prior.
4. Otherwise, if n is at least the smallest task id on the instance (`TicketResolver.minGlobalId`), a global-id probe; else not found.

**"Meine Aufgaben"** → `https://ac.example.com/users/{me}/tasks`, the tasks assigned to the user (confirmed by the user in the first test). `{me}` is `config.userId`, else the token prefix (`Controller.flowConfig`). While no user id is known, `/my-work` opens (route `my-work` with `section:"my_work"` exists in the bundle **[V]**). `config.myTasksPath` makes it configurable.

**Refresh cadence:**
- On every press: conditional GETs for `/projects`, `/favorites` and `/users/{me}/tasks`, mostly 304 in 23-26 ms **[V]**. They finish long before end of speech.
- Every 5 minutes: the same, which also keeps the connection warm.
- Every 10-15 minutes: all task lists with ETag.
- On a project miss: no synchronous refresh. The `refreshIndex` on every press (above) picks up new and renamed projects before the user finishes speaking; the next press resolves them.
- Never use `/whats-new` (21.7 s). Never log ETags (they contain the e-mail address) or `feed_token` **[V]**.

---

## 6. Milestones (build order, each with a check)

| # | Milestone | Check (headless where possible) | Effort [A] |
|---|---|---|---|
| M0 | Repo, Package.swift, bundle.sh (with `SIGN_ID` override), Info.plist (`NSMicrophoneUsageDescription`, `NSAppleEventsUsageDescription`, `NSSpeechRecognitionUsageDescription`, LSUIElement, LSMinimumSystemVersion 26.0), entitlements (`device.audio-input`, `automation.apple-events`), hardened runtime. **Needs the new cert first** | `scripts/bundle.sh AC\ Voice` passes the revocation precheck; `codesign --verify --strict`; `open -g -b io.github.nordavid.acvoice` launches; `pgrep -x "AC Voice"` | 0.5 d |
| M1 | ACVoiceCore: move the prototype in, add Routes, Config and History | `swift test --filter ACVoiceCoreTests` (prototype: 51 cases green in 0.05 s **[V]**); `acvoice resolve --snapshot <index.json> --cases Tests/resolve-cases.txt` regression list (ids only) | 1.5 d |
| M2 | ACVoiceAC: ACClient (GET only by construction), IndexStore with disk cache, ETag, task index, archives, 301 probe; TokenStore + ac-mcp import | URLProtocol stub test asserts that every request is GET and that ETag/304 is handled; `acvoice index refresh --stats` prints counts and timings (expected: about 60 projects and over ten thousand task ids); `acvoice resolve "Öffne WWT Ticket 412" --url` prints the task URL | 2 d |
| M3 | ACVoiceSpeech: port VoiceSession, adaptive threshold, finalize timeout, hypotheses, ContextBuilder; `-D SIMULATE` file source | `scripts/make-tts-fixtures.sh` (Anna + Daniel mixed clips); `ACVOICE_SPEECH_TESTS=1 swift test --filter ACVoiceSpeechTests`: each clip yields the expected Interpretation; simulated real-time p90 speech end → final ≤ 750 ms for commands and ≤ 550 ms for answers; no mic and no prompt **[V research: file input needs no authorization]** | 2 d |
| M4 **built** | VoiceFlow reducer + Controller, overlay (panel, orb, list, transitions), earcons, Carbon hotkey, StatusMenu, `--demo` mode cycling all states | Reducer tests with a fake clock cover every row of section 3 including timeouts, the retry limit and fastSelect; the research `fake-host/host.mjs` runs against the real app socket (keyDown → listening face < 5 ms); the user checks `--demo` visually | 3 d |
| M5 **built** (manual checks open) | ChromeOpener + onboarding (mic request, Automation preflight off-main while Chrome runs), NSWorkspace fallback, -1743 hint | Manual with the user: `acvoice open https://ac.example.com/projects/628` reuses the AC tab; with Chrome closed → launch path; after `tccutil reset AppleEvents io.github.nordavid.acvoice` and a denial → fallback + hint | 1 d |
| M6 | Stream Deck plugin: port the research plugin, rename ids (`io.github.nordavid.acvoice.streamdeck`, action `.voice`, `ApplicationsToMonitor: ["io.github.nordavid.acvoice"]`), keyDown trigger, no choice keys | `npm run build && npx streamdeck validate`; the fake-host e2e headless; on the real deck: key → overlay; check that the setImage rate holds at 10 fps, else 5 fps | 1.5 d |
| M7 | Real-mic tuning: a debug toggle "Aufnahmen speichern" (local, off by default); 30 utterances from the user (built-in mic + headset); tune threshold, hangovers, fastSelect, aliases and synonyms; signposts | Recordings go into the regression suite (git-ignored); targets: first-try success ≥ 90% on the set, p50 speech end → `opened` signpost ≤ 750 ms, answer → opened ≤ 550 ms (key ≤ 50 ms) **[A targets]** | 1.5 d |
| M8 **built** (manual checks open) | Autostart toggle (SMAppService), `scripts/install.sh`, README (setup, permissions, troubleshooting), optional `acvoice://press` | After logout and login the app runs and the Stream Deck key shows "idle" | 1 d |

---

## 7. Risks and mitigations

| Risk | Status | Mitigation / fallback |
|---|---|---|
| Revoked Apple Development cert blocks launch (AMFI -420) | **[V]** blocker | Renew in Xcode. Fallback: self-signed code-signing cert in the login keychain (stable DR, launch verified). Ad-hoc signing is not acceptable because TCC prompts again after every rebuild **[A]** |
| End of utterance and thresholds tuned only on TTS | [A] | Adaptive noise floor, a dBFS readout in the debug menu, M7 recordings. The press-to-end and push-to-talk paths always work |
| Acronyms misheard (IBN → Eben/Imben, S+K → Eska, WWT → WKT/WWD) | **[V]** | DT contextual strings per phase, spelled-letter collapse, user aliases per code in `config.json`, company-name aliases, the lookalike rule (list, never auto-open), and the ST+DT union |
| `finalize(through: nil)` or finalizing at end of fed audio hangs | **[V]** | Always pass an explicit time inside the fed audio, keep feeding the mic, 1.2 s timeout → volatile fallback |
| First syllables lost before micReady | [A] | Earcon + overlay "micReady" state; measure in M3. Rejected: an always-on mic ring buffer (privacy, permanent orange dot) |
| Bluetooth HFP mics (AirPods) slow to start or low quality | [A] | Config `inputDeviceUID` to pin the built-in mic or a wired headset; documented |
| Automation prompt or denial | [A] | Onboarding preflight off-main; -1743 → NSWorkspace fallback (new tab) + hint to Privacy & Security > Automation |
| `set index to 1` raises the wrong window when several are open | [A] | Accepted for v1. AXRaise would need Accessibility, which is rejected |
| SPA full reload on every URL change | [A] | Skip `set URL` when the URL is unchanged. v1.1 option: in-SPA navigation via `execute javascript` (needs the Chrome setting "Allow JavaScript from Apple Events") |
| Keychain prompts after a re-sign | [A] | Stable cert → stable DR → no prompt. Fallback: 0600 file `~/Library/Application Support/ac-voice/token` |
| Token expires or is re-issued by ac-mcp | [A] | On a 401, re-import from ac-mcp once, then show the error and a menu action. Own token via `POST /issue-token` is deferred to v1.1 (the password is never stored) |
| Stream Deck hardware frame rate | [A] | Tick at 100 ms only while animating; fallback 200 ms |
| ⌃⌥Space conflicts with input-source switching on other Macs | **[V]** disabled here | Configurable in the menu |
| SDK 27.2 vs OS 26.6 | **[V]** | Deployment target 26.0; no `AnalyzerInputConverter`/`CaptureInputSequenceProvider` without `#available(macOS 27, *)` |
| Speech assets not installed or in progress | **[V]** first status call may report `.supported` | Run `assetInstallationRequest.downloadAndInstall()` at launch (660 ms when present); the overlay shows "Sprachmodell wird geladen" until warm |
| Privacy | n/a | Everything runs on device. Transcripts are logged with `privacy: .private`. Never log the token, ETags or feed_token. Recordings are opt-in and local |
| FoundationModels unavailable | **[V]** | Not needed. The Interpreter seam allows an opt-in fallback later (low-confidence projects only, never during choices) |

---

## 8. Manual steps for the user, and decisions

**Manual steps:**
1. **Signing:** Xcode > Settings > Accounts > Manage Certificates > "+" Apple Development. Then delete the revoked cert (`<sha1>`) from the login keychain. Alternative: Keychain Access > Certificate Assistant > Create a Certificate, type "Code Signing", self-signed.
2. **AC token:** in onboarding, either "Aus ac-mcp übernehmen" (reads `ac-mcp/.ac-token-cache` or `.env`, read-only) or paste a token.
3. **Microphone:** click "Mikrofon erlauben" in onboarding (a one-time prompt for "AC Voice").
4. **Chrome Automation:** with Chrome running, click "Chrome steuern erlauben" in onboarding (a one-time prompt).
5. **Install:** run `scripts/install.sh` (puts the app in `~/Applications`), then turn on "Beim Anmelden starten".
6. **Stream Deck:** `cd streamdeck && npm install && npm run build && npx streamdeck link io.github.nordavid.acvoice.streamdeck.sdPlugin`. Drag the "AC Voice" action onto a key.
7. **Tuning (M7):** record about 30 real utterances. Also add spoken aliases for codes that STT gets wrong (e.g. IBN).

**Decisions (confirmed by the user):**
- Tap to talk with automatic end of utterance; holding works as push-to-talk.
- Everything on device.
- Reuse an existing AC tab in Chrome, else a new tab.
- Ambiguous code (WWT): always show the ranked list, most likely first; never auto-open.
- No Stream Deck choice keys: select by voice or by clicking an overlay row.
- Hotkey ⌃⌥Space. Earcons on.
- Token: one-time import from ac-mcp into the Keychain.
- Signing: the renewed Apple Development identity (the user signs the real build).
- No wake word in v1; the key, the hotkey or a menu click triggers it.

---

## Files (this pass)
- `spikes/architect/proto/Package.swift`
- `spikes/architect/proto/Sources/ACVoiceCore/Text.swift`
- `spikes/architect/proto/Sources/ACVoiceCore/Projects.swift`
- `spikes/architect/proto/Sources/ACVoiceCore/Resolver.swift`
- `spikes/architect/proto/Sources/ACVoiceCore/Parser.swift`
- `spikes/architect/proto/Sources/ACVoiceCore/Interpreter.swift`
- `spikes/architect/proto/Sources/ACVoiceCore/IPC.swift`
- `spikes/architect/proto/Sources/acvoice-resolve/main.swift` (run it with `.build/release/acvoice-resolve <id\tname tsv> "<utterance>" ["<2nd hypothesis>"]`)
- `spikes/architect/proto/Tests/ACVoiceCoreTests/ResolverTests.swift` (synthetic fixture with the same collision structure as the real data; it is safe to commit)

Research sources to port:
- `speech/src/MicPipeline.swift`
- `streamdeck/plugin/src/*.ts`
- `streamdeck/swift/{IPCServer,GlobalHotkey}.swift`
- `packaging/{scripts/bundle.sh,Sources/ACVoiceShared/*.swift,support/open-ac.applescript}`
- `acapi/swift/main.swift`

All lived in the research session's temporary directory and were not kept.