import ACVoiceFlow
@testable import ACVoiceSystem
import Carbon
import Foundation
import Testing

/// One Chrome window for a `chromestate` answer.
struct W {
    /// An integer literal gives an integer id (older Chrome), a string literal a text id (Chrome 158 and later).
    var id: ChromeWindowID
    var mode = "normal"
    var tabs: [String]
    var active = 1
}

/// The `chromestate` answer for `windows`, front to back.
func chromeState(_ windows: [W]) -> ScriptValue {
    .list([
        .list(windows.map {
            switch $0.id {
            case .int(let i): .int(i)
            case .text(let s): .text(s)
            }
        }),
        .list(windows.map { .text($0.mode) }),
        .list(windows.map { .list($0.tabs.map(ScriptValue.text)) }),
        .list(windows.map { .int($0.active) }),
    ])
}

/// Scripted runner: records calls, answers per handler from a queue (defaults: one normal window with an AC tab,
/// and "ok" for the actions).
final class FakeRunner: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [ScriptArg], Double)] = []
    private var _answers: [String: [ScriptCallResult]] = [:]
    private var _busy = false
    var defaultState = chromeState([W(id: 11, tabs: ["https://ac.example.com/projects/1"])])

    var calls: [(String, [ScriptArg], Double)] { lock.withLock { _calls } }
    var handlers: [String] { calls.map(\.0) }
    var isBusy: Bool {
        get { lock.withLock { _busy } }
        set { lock.withLock { _busy = newValue } }
    }

    func answer(_ handler: String, _ r: ScriptCallResult...) {
        lock.withLock { _answers[handler, default: []].append(contentsOf: r) }
    }

    func call(_ handler: String, _ args: [ScriptArg], deadline: Double) async -> ScriptCallResult {
        lock.withLock {
            _calls.append((handler, args, deadline))
            if var q = _answers[handler], !q.isEmpty {
                let r = q.removeFirst()
                _answers[handler] = q
                return r
            }
            return handler == ChromeOpener.stateHandler ? .value(defaultState) : .value(.text("ok"))
        }
    }

    func prepare() async -> Bool { true }
}

@MainActor
final class FakeHost: ChromeHost {
    var chromeAppURL: URL? = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    var isChromeRunning = true
    var isChromeFrontmost = false
    var automation: AutomationStatus = .granted
    var openError: (any Error)?
    private(set) var opened: [(URL, URL?)] = []
    private(set) var asked: [Bool] = []
    private(set) var activations: [ActivationStrategy] = []

    func automationStatus(ask: Bool) async -> AutomationStatus {
        asked.append(ask)
        return automation
    }

    func open(_ url: URL, withApplicationAt app: URL?) async throws {
        if let openError { throw openError }
        opened.append((url, app))
    }

    func activateChrome(_ strategy: ActivationStrategy) { activations.append(strategy) }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 100.0
    var now: Double { lock.withLock { t } }
    func advance(_ s: Double) { lock.withLock { t += s } }
}

@MainActor
struct ChromeOpenerTests {
    static let base = URL(string: "https://ac.example.com")!
    static let target = URL(string: "https://ac.example.com/projects/628")!
    static let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")

    let runner = FakeRunner()
    let host = FakeHost()

    func opener(_ configure: (inout ChromeOpener.Settings) -> Void = { _ in }) -> ChromeOpener {
        var s = ChromeOpener.Settings(acBaseURL: Self.base)
        s.verifyActivationAfter = nil
        configure(&s)
        return ChromeOpener(settings: s, runner: runner, host: host)
    }

    func opener(clock: FakeClock) -> ChromeOpener {
        var s = ChromeOpener.Settings(acBaseURL: Self.base)
        s.verifyActivationAfter = nil
        return ChromeOpener(settings: s, runner: runner, host: host, now: { clock.now })
    }

    @Test func notInstalledOpensDefaultBrowser() async throws {
        host.chromeAppURL = nil
        #expect(try await opener().open(Self.target) == .fallback(.other))
        #expect(runner.calls.isEmpty)
        #expect(host.opened.count == 1)
        #expect(host.opened.first?.1 == nil)
        #expect(host.asked.isEmpty)
    }

    @Test func notRunningLaunchesChromeWithoutAppleEvents() async throws {
        host.isChromeRunning = false
        #expect(try await opener().open(Self.target) == .launched)
        #expect(runner.calls.isEmpty)
        #expect(host.asked.isEmpty)
        #expect(host.opened.first?.0 == Self.target)
        #expect(host.opened.first?.1 == Self.chrome)
    }

    @Test func reusesTheActiveACTab() async throws {
        let o = opener()
        #expect(try await o.open(Self.target) == .reused)
        #expect(runner.handlers == ["chromestate", "focustab"])
        #expect(runner.calls[0].1 == [.int(2)])
        #expect(runner.calls[0].2 == 3.0)
        #expect(runner.calls[1].1 == [.int(11), .int(1), .text(Self.target.absoluteString), .bool(true), .bool(false),
                                      .int(2), .bool(true)])
        #expect(host.opened.isEmpty)
        // Granted once, then cached.
        _ = try await o.open(Self.target)
        #expect(host.asked == [false])
    }

    @Test func tabThatShowsTheTargetIsOnlyFocused() async throws {
        runner.defaultState = chromeState([
            W(id: 11, tabs: ["https://ac.example.com/projects/1"]),
            W(id: 22, tabs: ["https://example.com", Self.target.absoluteString], active: 1),
        ])
        #expect(try await opener().open(Self.target) == .reused)
        #expect(runner.calls[1].1.prefix(5) == [.int(22), .int(2), .text(Self.target.absoluteString), .bool(false), .bool(true)])
    }

    @Test func textWindowIdsGoBackAsText() async throws {
        // Chrome 158 reports window ids as text. Before the fix every answer was unreadable and each open fell back
        // to NSWorkspace, which always makes a new tab. The id must go back as text: Chrome never matches a number.
        let o = opener()
        runner.answer("chromestate",
                      .value(chromeState([W(id: "1749650355", tabs: ["https://example.com", "https://ac.example.com/projects/1"]),
                                          W(id: "1749650301", tabs: ["https://example.com"])])),
                      .value(chromeState([W(id: "1749650355", tabs: ["https://example.com"])])))
        #expect(try await o.open(Self.target) == .reused)
        try #require(runner.calls.count == 2)   // a fallback makes one call only: fail here, not with an index trap
        #expect(runner.calls[1].0 == "focustab")
        #expect(runner.calls[1].1.prefix(5) == [.text("1749650355"), .int(2), .text(Self.target.absoluteString), .bool(true), .bool(true)])
        #expect(try await o.open(Self.target) == .newTab)
        try #require(runner.calls.count == 4)
        #expect(runner.calls[3].0 == "newtab")
        #expect(runner.calls[3].1.first == .text("1749650355"))
        #expect(host.opened.isEmpty)
    }

    @Test func newTabAndNewWindow() async throws {
        let o = opener()
        runner.answer("chromestate",
                      .value(chromeState([W(id: 5, tabs: ["https://example.com"])])),
                      .value(chromeState([W(id: 6, mode: "incognito", tabs: ["https://ac.example.com/projects/1"])])),
                      .value(chromeState([])))
        #expect(try await o.open(Self.target) == .newTab)
        #expect(runner.calls[1].0 == "newtab")
        #expect(runner.calls[1].1 == [.int(5), .text(Self.target.absoluteString), .int(2), .bool(true)])
        #expect(try await o.open(Self.target) == .newWindow)
        #expect(runner.calls[3].0 == "newwindow")
        #expect(runner.calls[3].1 == [.text(Self.target.absoluteString), .int(2), .bool(true)])
        #expect(try await o.open(Self.target) == .newWindow)
    }

    @Test func baseURLWithTrailingSlashStillMatches() async throws {
        let o = opener { $0.acBaseURL = URL(string: "https://ac.example.com/")! }
        #expect(try await o.open(Self.target) == .reused)
        #expect(runner.calls[1].0 == "focustab")
    }

    @Test func chromeQuitBetweenTheCallsLaunchesIt() async throws {
        runner.answer("chromestate", .value(.text("notrunning")))
        #expect(try await opener().open(Self.target) == .launched)
        #expect(host.opened.first?.1 == Self.chrome)
        runner.answer("focustab", .value(.text("notrunning")))
        #expect(try await opener().open(Self.target) == .launched)
        #expect(host.opened.count == 2)
    }

    @Test func malformedStateFallsBack() async throws {
        runner.answer("chromestate", .value(.list([.list([.int(1)]), .list([])])), .value(.text("garbage")))
        let o = opener()
        #expect(try await o.open(Self.target) == .fallback(.other))
        #expect(try await o.open(Self.target) == .fallback(.other))
        #expect(runner.handlers == ["chromestate", "chromestate"])
        #expect(host.opened.count == 2)
    }

    @Test func deniedAutomationFallsBackWithHint() async throws {
        host.automation = .denied
        #expect(try await opener().open(Self.target) == .fallback(.denied))
        #expect(runner.calls.isEmpty)
        #expect(host.opened.first?.1 == Self.chrome)
        #expect(host.asked == [false])
    }

    @Test func deniedDuringTheCallResetsTheCache() async throws {
        let o = opener()
        runner.answer("chromestate", .failed(code: -1743, message: "Not authorized"))
        #expect(try await o.open(Self.target) == .fallback(.denied))
        #expect(host.opened.count == 1)
        // The next open checks the permission again.
        #expect(try await o.open(Self.target) == .reused)
        #expect(host.asked == [false, false])
        // Denied in the action step too.
        runner.answer("focustab", .failed(code: -1743, message: nil))
        #expect(try await o.open(Self.target) == .fallback(.denied))
    }

    @Test func undeterminedFallsBackAndAsksOnceInTheBackground() async throws {
        host.automation = .notDetermined
        let o = opener()
        #expect(try await o.open(Self.target) == .fallback(.undetermined))
        #expect(try await o.open(Self.target) == .fallback(.undetermined))
        #expect(runner.calls.isEmpty)
        #expect(await waitUntil { host.asked.contains(true) })
        try await Task.sleep(for: .milliseconds(30))
        #expect(host.asked.filter { $0 }.count == 1)
    }

    /// Review C2: -1744 during the call is "not asked yet" too, so the overlay can point to the setup window.
    @Test func undeterminedDuringTheCallSaysSo() async throws {
        runner.answer("chromestate", .failed(code: -1744, message: nil))
        let o = opener { $0.askWhenUndetermined = false }
        #expect(try await o.open(Self.target) == .fallback(.undetermined))
        #expect(host.opened.count == 1)
    }

    @Test func undeterminedWithoutAskingNeverPrompts() async throws {
        host.automation = .notDetermined
        let o = opener { $0.askWhenUndetermined = false }
        #expect(try await o.open(Self.target) == .fallback(.undetermined))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!host.asked.contains(true))
    }

    @Test func timeoutsAndErrorsFallBackToWorkspace() async throws {
        let o = opener()
        runner.answer("chromestate", .timedOut, .failed(code: -1712, message: nil), .unavailable(code: -2))
        runner.answer("focustab", .timedOut, .failed(code: -1728, message: "Can't get window id 11."))
        for _ in 0..<5 {
            #expect(try await o.open(Self.target) == .fallback(.other))
        }
        #expect(host.opened.count == 5)
        let allChrome = host.opened.allSatisfy { $0.1 == Self.chrome }
        #expect(allChrome)
    }

    @Test func busyRunnerSkipsAppleScript() async throws {
        runner.isBusy = true
        #expect(try await opener().open(Self.target) == .fallback(.other))
        #expect(runner.calls.isEmpty)
        #expect(host.opened.count == 1)
    }

    @Test func workspaceFailureThrows() async throws {
        host.isChromeRunning = false
        host.openError = CocoaError(.fileNoSuchFile)
        await #expect(throws: ChromeOpenerError.openFailed) { try await opener().open(Self.target) }
    }

    @Test func actionGetsTheRestOfTheDeadline() async throws {
        let clock = FakeClock()
        // Instant state read: the action gets the whole deadline.
        _ = try await opener(clock: clock).open(Self.target)
        #expect(runner.calls[1].2 == 3.0)
        var settings = ChromeOpener.Settings(acBaseURL: Self.base)
        settings.verifyActivationAfter = nil
        // A state read of 1 s leaves 2 s; one of 2.9 s leaves the minimum.
        for (cost, left) in [(1.0, 2.0), (2.9, ChromeOpener.minActionDeadline)] {
            let slow = SlowStateRunner(clock: clock, cost: cost)
            let o = ChromeOpener(settings: settings, runner: slow, host: host, now: { clock.now })
            #expect(try await o.open(Self.target) == .reused)
            #expect(slow.deadlines.count == 2)
            #expect(abs(slow.deadlines[1] - left) < 1e-9)
        }
    }

    @Test func activationStrategies() async throws {
        _ = try await opener().open(Self.target)
        #expect(host.activations.isEmpty)
        #expect(runner.calls[1].1.last == .bool(true))

        _ = try await opener { $0.activation = .runningApplication }.open(Self.target)
        #expect(runner.calls[3].1.last == .bool(false))
        #expect(host.activations == [.runningApplication])

        _ = try await opener { $0.activation = .workspace }.open(Self.target)
        #expect(runner.calls[5].1.last == .bool(false))
        #expect(host.activations == [.runningApplication, .workspace])
    }

    @Test func activationCheckRecordsFrontmost() async throws {
        host.isChromeFrontmost = true
        let o = opener { $0.verifyActivationAfter = 0.01 }
        _ = try await o.open(Self.target)
        #expect(await waitUntil { o.lastActivationCheck != nil })
        #expect(o.lastActivationCheck?.strategy == .appleScript)
        #expect(o.lastActivationCheck?.frontmost == true)
    }

    @Test func activeTabURL() async throws {
        let o = opener()
        runner.answer("chromestate",
                      .value(chromeState([W(id: 1, tabs: ["https://x.example", "https://ac.example.com/projects/628/tasks/47285"], active: 2)])),
                      .value(chromeState([W(id: 1, tabs: ["https://ac.example.com/projects/693"])])),
                      .value(chromeState([W(id: 1, tabs: ["https://example.com/projects/1"])])),
                      .value(chromeState([W(id: 1, mode: "incognito", tabs: ["https://ac.example.com/projects/9"])])),
                      .timedOut)
        #expect(await o.currentACTabURL() == URL(string: "https://ac.example.com/projects/628/tasks/47285"))
        let call = try #require(runner.calls.first)
        #expect(call.0 == "chromestate")
        #expect(call.1 == [.int(1)])
        #expect(call.2 == 0.4)
        #expect(await o.activeProjectId() == 693)
        #expect(await o.currentACTabURL() == nil)
        #expect(await o.currentACTabURL() == nil)
        #expect(await o.currentACTabURL() == nil)
        #expect(!runner.handlers.contains { $0 != "chromestate" })
    }

    @Test func activeTabNeverPromptsOrLaunches() async throws {
        host.automation = .notDetermined
        let o = opener()
        #expect(await o.currentACTabURL() == nil)
        #expect(host.asked == [false])
        host.isChromeRunning = false
        #expect(await o.currentACTabURL() == nil)
        host.isChromeRunning = true
        host.automation = .granted
        runner.isBusy = true
        #expect(await o.currentACTabURL() == nil)
        #expect(runner.calls.isEmpty)
        #expect(host.opened.isEmpty)
    }

    @Test func automationStatusMapping() {
        #expect(AutomationStatus(status: 0) == .granted)
        #expect(AutomationStatus(status: -1743) == .denied)
        #expect(AutomationStatus(status: -1744) == .notDetermined)
        #expect(AutomationStatus(status: -600) == .targetNotRunning)
        #expect(AutomationStatus(status: -50) == .other(-50))
    }
}

/// A runner whose state read costs `cost` seconds on the fake clock.
final class SlowStateRunner: AppleScriptRunning, @unchecked Sendable {
    let clock: FakeClock
    let cost: Double
    private let lock = NSLock()
    private var _deadlines: [Double] = []
    var deadlines: [Double] { lock.withLock { _deadlines } }
    var isBusy: Bool { false }

    init(clock: FakeClock, cost: Double) { self.clock = clock; self.cost = cost }

    func call(_ handler: String, _ args: [ScriptArg], deadline: Double) async -> ScriptCallResult {
        lock.withLock { _deadlines.append(deadline) }
        if handler == ChromeOpener.stateHandler {
            clock.advance(cost)
            return .value(chromeState([W(id: 3, tabs: ["https://ac.example.com"])]))
        }
        return .value(.text("ok"))
    }

    func prepare() async -> Bool { true }
}

/// The tab choice on its own (REVIEW M4: normal windows, reuse, no needless reload).
struct ChromeTabPlanTests {
    static let base = "https://ac.example.com"
    static let target = "https://ac.example.com/projects/628"

    static func plan(_ ws: [W], target: String = target) -> ChromeTabPlan {
        ChromeTabPlan.make(ChromeWindows(chromeState(ws))!, target: target, base: base)
    }

    @Test func exactTargetWins() {
        // Window 2 shows the target; window 1 has an active AC tab: focus window 2, no reload.
        #expect(Self.plan([W(id: 1, tabs: ["https://ac.example.com/projects/1"]),
                           W(id: 2, tabs: [Self.target])])
                == .focus(windowId: 2, tab: 1, setURL: false, setTab: false))
        // In a background tab: make it active, still no reload.
        #expect(Self.plan([W(id: 1, tabs: ["https://example.com", Self.target], active: 1)])
                == .focus(windowId: 1, tab: 2, setURL: false, setTab: true))
    }

    @Test func activeACTabBeforeOtherACTabs() {
        #expect(Self.plan([W(id: 1, tabs: ["https://ac.example.com/my-work", "https://example.com"], active: 2),
                           W(id: 2, tabs: ["https://example.com", "https://ac.example.com/projects/1"], active: 2)])
                == .focus(windowId: 2, tab: 2, setURL: true, setTab: false))
        #expect(Self.plan([W(id: 1, tabs: ["https://example.com", "https://ac.example.com/my-work"], active: 1)])
                == .focus(windowId: 1, tab: 2, setURL: true, setTab: true))
    }

    @Test func incognitoWindowsNeverCount() {
        #expect(Self.plan([W(id: 1, mode: "incognito", tabs: [Self.target]),
                           W(id: 2, tabs: ["https://example.com"])])
                == .newTab(windowId: 2))
        #expect(Self.plan([W(id: 1, mode: "incognito", tabs: ["https://ac.example.com/projects/1"])]) == .newWindow)
        #expect(Self.plan([]) == .newWindow)
    }

    @Test func acRule() {
        let b = Self.base
        #expect(ChromeTabPlan.isAC("https://ac.example.com", base: b))
        #expect(ChromeTabPlan.isAC("https://ac.example.com/my-work", base: b))
        #expect(ChromeTabPlan.isAC("https://ac.example.com?x=1", base: b))
        #expect(ChromeTabPlan.isAC("https://ac.example.com#top", base: b))
        #expect(ChromeTabPlan.isAC("https://AC.example.com/projects/1", base: b + "/"))
        #expect(!ChromeTabPlan.isAC("https://ac.example.com.evil.example/projects/1", base: b))
        #expect(!ChromeTabPlan.isAC("http://ac.example.com/projects/1", base: b))
        #expect(!ChromeTabPlan.isAC("", base: b))
        #expect(ChromeOpener.normalizedBase(URL(string: "https://ac.example.com//")!) == b)
    }

    @Test func parsingState() throws {
        // Lists that disagree (a window closed between the reads) or a wrong shape: nil.
        #expect(ChromeWindows(.list([.list([.int(1)]), .list([]), .list([]), .list([])])) == nil)
        #expect(ChromeWindows(.text("notrunning")) == nil)
        #expect(ChromeWindows(.list([.list([.bool(true)]), .list([.text("normal")]), .list([.list([])]), .list([.int(1)])])) == nil)
        #expect(ChromeWindows(.list([.list([.text("")]), .list([.text("normal")]), .list([.list([])]), .list([.int(1)])])) == nil)
        #expect(ChromeWindows(.list([.list([.missing]), .list([.text("normal")]), .list([.list([])]), .list([.int(1)])])) == nil)
        // missing value URLs and a lone unwrapped tab.
        let s = try #require(ChromeWindows(.list([
            .list([.int(7), .int(8)]), .list([.text("normal"), .text("incognito")]),
            .list([.list([.missing, .text("https://ac.example.com/x")]), .text("https://example.com")]),
            .list([.int(2), .int(1)]),
        ])))
        #expect(s.windows.map(\.id) == [7, 8])
        #expect(s.windows[0].tabs == [nil, "https://ac.example.com/x"])
        #expect(s.windows[1].tabs == ["https://example.com"])
        #expect(!s.windows[1].isNormal)
        #expect(s.activeACTabURL(base: Self.base) == "https://ac.example.com/x")
        #expect(ChromeTabPlan.make(s, target: Self.target, base: Self.base) == .focus(windowId: 7, tab: 2, setURL: true, setTab: false))
    }

    @Test func parsingStateWithTextWindowIds() throws {
        // The answer of Chrome 158 as the app logged it: text ids ("chrome.state.unreadable shape=[[t],[t],[[t,…]],[i]]"
        // before the fix). The id keeps its text form for the action call.
        let state = ScriptValue.list([
            .list([.text("1749650355")]), .list([.text("normal")]),
            .list([.list([.text("https://example.com"), .text("https://ac.example.com/projects/1")])]),
            .list([.int(1)]),
        ])
        let s = try #require(ChromeWindows(state))
        #expect(s.windows.map(\.id) == ["1749650355"])
        #expect(ChromeTabPlan.make(s, target: Self.target, base: Self.base)
                == .focus(windowId: "1749650355", tab: 2, setURL: true, setTab: true))
        #expect(ChromeWindowID("1749650355").arg == .text("1749650355"))
        #expect(state.shape() == "[[t],[t],[[t,t]],[i]]")
    }

    @Test func parsingStateWithRealWindowIds() throws {
        // Older Chrome reports integer ids; above AppleScript's integer range (536870911) they arrive as reals.
        let state = ScriptValue.list([
            .list([.real(1_749_650_355), .real(1_749_650_301)]), .list([.text("normal"), .text("normal")]),
            .list([.list([.text("https://example.com"), .text("https://ac.example.com/projects/1")]),
                   .list([.text("https://example.com")])]),
            .list([.int(1), .int(1)]),
        ])
        let s = try #require(ChromeWindows(state))
        #expect(s.windows.map(\.id) == [1_749_650_355, 1_749_650_301])
        #expect(ChromeTabPlan.make(s, target: Self.target, base: Self.base)
                == .focus(windowId: 1_749_650_355, tab: 2, setURL: true, setTab: true))
        // A fractional id is still no id.
        #expect(ChromeWindows(.list([.list([.real(1.5)]), .list([.text("normal")]), .list([.list([])]), .list([.int(1)])])) == nil)
        // The log shows only the kinds of the parts, never a URL.
        #expect(state.shape() == "[[r,r],[t,t],[[t,t],[t]],[i,i]]")
        #expect(ScriptValue.list(Array(repeating: .int(1), count: 8)).shape() == "[i,i,i,i,i,i,…+2]")
    }

    @Test func activeTabOfFrontNormalWindow() throws {
        let s = try #require(ChromeWindows(chromeState([
            W(id: 1, mode: "incognito", tabs: ["https://ac.example.com/projects/9"]),
            W(id: 2, tabs: ["https://ac.example.com/projects/3", "https://example.com"], active: 2),
            W(id: 3, tabs: ["https://ac.example.com/projects/4"]),
        ])))
        // The front normal window shows no AC page: no hint (other windows are not what the user looks at).
        #expect(s.activeACTabURL(base: Self.base) == nil)
    }

    @Test func scriptValueFromDescriptors() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(int32: 42), at: 1)
        list.insert(NSAppleEventDescriptor(string: "normal"), at: 2)
        list.insert(NSAppleEventDescriptor(boolean: true), at: 3)
        list.insert(NSAppleEventDescriptor(typeCode: OSType(cMissingValue)), at: 4)
        list.insert(NSAppleEventDescriptor.null(), at: 5)
        var big = Int64(5_000_000_000)
        list.insert(NSAppleEventDescriptor(descriptorType: DescType(typeSInt64), bytes: &big, length: 8)!, at: 6)
        let inner = NSAppleEventDescriptor.list()
        inner.insert(NSAppleEventDescriptor(string: "https://ac.example.com"), at: 1)
        list.insert(inner, at: 7)
        #expect(ScriptValue(list) == .list([.int(42), .text("normal"), .bool(true), .missing, .missing, .int(5_000_000_000),
                                            .list([.text("https://ac.example.com")])]))
        let e = AppleScriptRunner.handlerEvent("focustab", [.int(5_000_000_000)])
        let arg = e.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.atIndex(1)
        #expect(arg.map(ScriptValue.init) == .int(5_000_000_000))
    }
}
