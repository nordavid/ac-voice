import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import ACVoiceSystem
import Foundation
import Testing
@testable import ACVoiceRuntime

/// Synthetic projects (Tests/Fixtures/projects.sample.json) as an AC index snapshot, plus a small task index.
enum Fixture {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let catalog: ProjectCatalog = {
        do { return try ProjectCatalog.load(dir.appendingPathComponent("projects.sample.json")) }
        catch { fatalError("Tests/Fixtures/projects.sample.json: \(error)") }
    }()
    static var now: Date { catalog.referenceDate }
    static let base = URL(string: "https://ac.example.com")!
    static let userId = 538

    static var config: Config {
        var c = Config()
        c.aliases = catalog.aliases
        return c
    }

    /// "Meine Aufgaben" with the token's user id: the tasks assigned to that user.
    static let myTasksURL = URL(string: "https://ac.example.com/users/538/tasks")!

    /// The catalog's signals as AC delivers them; tasks:
    /// - 628: open #412 (id 31412), own #530 (id 61834); archive complete
    /// - 314: open #58 (id 41058); 315: nothing open; both archives complete
    /// - 693: one completed id (60001) without a number yet: its archive can still hide any number
    static func snapshot(without excluded: Set<Int> = []) -> IndexSnapshot {
        var s = IndexSnapshot(baseURL: base, userId: userId)
        let items = catalog.projects.filter { !excluded.contains($0.id) }
        s.projects = items.map { p in
            ProjectRecord(id: p.id, name: p.name, lastActivity: p.lastActivityDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
        }
        s.favorites = items.filter { $0.favorite == true }.map(\.id)
        s.timeRecords30d = Dictionary(uniqueKeysWithValues: items.compactMap { p in p.timeRecords30d.map { (p.id, $0) } })
        s.mine = [TaskRef(id: 61_834, projectId: 628, number: 530)]
        func state(_ open: [TaskRow], completed: [Int] = []) -> ProjectTaskState {
            var st = ProjectTaskState()
            st.open = open
            st.completedIds = completed
            st.fetchedAt = now
            return st
        }
        s.projectTasks[628] = state([TaskRow(id: 31_412, number: 412), TaskRow(id: 61_834, number: 530)])
        s.projectTasks[314] = state([TaskRow(id: 41_058, number: 58)])
        s.projectTasks[315] = state([])
        s.projectTasks[693] = state([], completed: [60_001])
        s.fetchedAt = now
        s.taskListsFetchedAt = now
        s.rebuildTasks()
        return s
    }

    static func projectURL(_ id: Int) -> URL { Routes.project(base, id) }
    static func taskURL(_ pid: Int, _ tid: Int) -> URL { Routes.task(base, projectId: pid, taskId: tid) }
}

/// Creates the fake index when the controller asks for one (launch with a token, sign-in, pasted token, new address).
@MainActor
final class IndexFactory {
    var snapshot: IndexSnapshot
    private(set) var made: [FakeIndex] = []
    /// The AC address of each index made.
    private(set) var bases: [URL] = []
    init(snapshot: IndexSnapshot) { self.snapshot = snapshot }

    func make(_ userId: Int, base: URL = Fixture.base) -> FakeIndex {
        let i = FakeIndex(userId: userId, snapshot: snapshot)
        made.append(i)
        bases.append(base)
        return i
    }
}

/// A controller on fakes and a fake clock, with helpers that play the speech layer.
@MainActor
final class Rig {
    let clock = ManualClock(now: Fixture.now)
    let speech = FakeSpeech()
    let tokens: FakeTokens
    let factory: IndexFactory
    let permissions: FakePermissions
    let overlay = FakeOverlay()
    let ipc: any IPCEndpoint
    let chrome = FakeChrome()
    let earcons = FakeEarcons()
    let hotkey = FakeHotkey()
    let login = FakeLogin()
    let workspace = FakeWorkspace()
    /// Esc as the live app wires it: `EscapeClosesOverlay` around the fake overlay.
    let escape = FakeEscape()
    let store: FakeStore
    let controller: Controller
    var setupRequests = 0
    var secondInstance = false

    init(token: StoredToken = .present(userId: Fixture.userId), snapshot: IndexSnapshot = Fixture.snapshot(),
         mic: Permission = .granted, config: Config = Fixture.config, history: History = History(),
         ipc: (any IPCEndpoint)? = nil, timings: FlowTimings = .init(), preferredLanguages: [String] = ["de-DE"]) {
        tokens = FakeTokens(token, account: KeychainTokenStore.account(for: config.acBaseURL))
        permissions = FakePermissions(microphone: mic)
        store = FakeStore(config: config, history: history)
        let factory = IndexFactory(snapshot: snapshot)
        self.factory = factory
        let ipc = ipc ?? FakeIPC()
        self.ipc = ipc
        let services = Services(
            speech: speech, tokens: tokens, makeIndex: { userId, config in factory.make(userId, base: config.acBaseURL) },
            permissions: permissions, overlay: EscapeClosesOverlay(overlay, escape: escape), ipc: ipc, chrome: chrome, earcons: earcons, hotkey: hotkey,
            loginItem: login, clock: clock, store: store, workspace: workspace,
            preferredLanguages: preferredLanguages)
        controller = Controller(services: services, timings: timings)
        controller.onNeedsSetup = { [weak self] in self?.setupRequests += 1 }
        controller.onSecondInstance = { [weak self] in self?.secondInstance = true }
    }

    /// The index the controller uses (the latest one made).
    var index: FakeIndex? { factory.made.last }
    var fakeIPC: FakeIPC { ipc as! FakeIPC }

    func start() async {
        await controller.start()
        await settle()
    }

    func settle() async {
        let quiet = await controller.settle()
        if !quiet { Issue.record("controller did not settle") }
    }

    var phase: FlowPhase { controller.flow.phase }
    var model: OverlayModel { controller.model }

    // MARK: Triggers

    func press(_ id: String? = "p1", source: TriggerSource = .streamDeck) async {
        controller.trigger(.press(Press(id: id, source: source)))
        await settle()
    }

    func release(_ id: String? = "p1", heldMs: Int = 120) async {
        controller.trigger(.release(pressId: id, heldMs: heldMs))
        await settle()
    }

    // MARK: Speech

    func emit(_ s: SpeechSignal) async {
        speech.emit(s)
        await settle()
    }

    /// Mic ready, then a tap release.
    func listen() async {
        await press()
        await emit(.micReady)
        await release()
    }

    /// Onset, a partial with DT and ST, the gate's end and the final.
    func say(_ text: String, latencyMs: Double? = 520) async {
        await settle()
        speech.emit(.speechStarted)
        speech.emit(.partial(dt: text, st: text))
        speech.emit(.endpoint)
        clock.advance(0.05)
        speech.emit(.utterance([Hypothesis(text)], latencyMs: latencyMs))
        await settle()
    }

    /// Press, mic ready, tap release, one command.
    func command(_ text: String) async {
        await listen()
        await say(text)
    }

    func advance(_ dt: Double) async {
        clock.advance(dt)
        await settle()
    }
}
