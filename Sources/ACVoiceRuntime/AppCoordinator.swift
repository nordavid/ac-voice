import ACVoiceCore
import ACVoiceFlow
import ACVoiceSystem
import ACVoiceUI
import AppKit

/// The app shell around the controller: status item, setup window, URL scheme, overlay demo, SIGTERM.
/// `ACVoiceApp` creates one at launch (`live(arguments:)`) and forwards the `NSApplicationDelegate` calls.
@MainActor
public final class AppCoordinator {
    /// `--demo`: cycle every overlay state with synthetic data; no microphone, AC, Chrome, hotkey or socket.
    public static let demoArgument = "--demo"

    public let controller: Controller?
    private let demoOverlay: (any OverlayPresenting)?
    /// Language of the demo mode's menu and overlay (the controller has its own).
    private let demoLanguage: AppLanguage
    private let clock: any RuntimeClock
    private var statusMenu: StatusMenuController?
    private var onboarding: OnboardingWindowController?
    private var demo: OverlayDemo?
    private var signalSource: (any DispatchSourceSignal)?
    /// URLs that arrived before the controller finished `start()` (a launch by `open acvoice://press`).
    private var pendingURLs: [URL] = []
    private var ready = false

    /// The real app. Nothing starts before `start()`.
    public static func live(arguments: [String]) -> AppCoordinator {
        let store = FileStore()
        let config = store.loadConfig()
        if arguments.contains(demoArgument) {
            let overlay = OverlayController()
            overlay.backdrop = OverlayBackdrop(rawValue: config.overlayBackdrop) ?? .liquidGlass
            return AppCoordinator(demoOverlay: overlay, clock: SystemClock(), language: config.appLanguage())
        }
        let timings = FlowTimings()
        let controller = Controller(services: .live(config: config, timings: timings, store: store), timings: timings,
                                    config: config)
        return AppCoordinator(controller: controller)
    }

    public init(controller: Controller) {
        self.controller = controller
        demoOverlay = nil
        clock = controller.services.clock
        demoLanguage = controller.language
    }

    init(demoOverlay: any OverlayPresenting, clock: any RuntimeClock, language: AppLanguage = .de) {
        controller = nil
        self.demoOverlay = demoOverlay
        self.clock = clock
        demoLanguage = language
    }

    public var isDemoMode: Bool { controller == nil }

    // MARK: Launch and quit

    public func start() {
        installSignalHandler()
        guard let controller else {
            startDemoMode()
            return
        }
        statusMenu = StatusMenuController(state: { [weak controller] in controller?.menuState() ?? MenuState() },
                                          icon: { [weak controller] in controller?.menuIcon ?? MenuIcon() },
                                          perform: { [weak self] in self?.perform($0) })
        controller.observeStatus { [weak self] in
            // Cheap on every status change: the icon reads phase and badge only; the setup window rebuilds only
            // while it is on screen (review C8).
            self?.statusMenu?.refresh()
            if self?.onboarding?.isVisible == true { self?.onboarding?.model.rebuild() }
        }
        controller.onNeedsSetup = { [weak self] in self?.showOnboarding() }
        controller.onSecondInstance = { [weak self] in self?.quit() }
        controller.onChromeRunningChanged = { [weak self] _ in self?.onboarding?.refreshIfVisible() }
        Task { [weak self] in
            await controller.start()
            guard let self, controller.isRunning else { return }
            self.ready = true
            let urls = self.pendingURLs
            self.pendingURLs = []
            self.open(urls)
            // Chrome runs and its Automation was never asked for: the setup window explains the step (no prompt).
            // Chrome's later first start and an open that fell back check again (Controller).
            await controller.checkChromeAutomation()
        }
    }

    /// Quit from any context (menu, SIGTERM from install.sh, a second instance): shut down first, then terminate.
    /// `terminateApp` then finds `didShutDown` set and `applicationShouldTerminate` answers `.terminateNow`.
    ///
    /// Never call `NSApp.terminate` directly from a main-queue job (a dispatch source handler or a Task) before the
    /// shutdown: `.terminateLater` makes AppKit wait in a nested run loop, and that loop cannot drain the main queue
    /// the job still occupies, so the reply task never runs. SIGTERM hung that way until install.sh sent SIGKILL.
    public func quit() {
        Task { @MainActor in
            await self.shutdown()
            self.terminateApp()
        }
    }

    /// The final step of `quit()`. Tests replace it.
    var terminateApp: @MainActor () -> Void = { NSApp.terminate(nil) }

    /// The shutdown ran (or gave up after its limit): terminating needs no further wait.
    public private(set) var didShutDown = false
    private var shutdownTask: Task<Void, Never>?

    /// Microphone off, socket removed, history written. Waits at most `limit` seconds for the speech layer. Runs once;
    /// a second call waits for the first.
    public func shutdown(limit: Double = 2) async {
        if let shutdownTask { return await shutdownTask.value }
        let task = Task { @MainActor in await self.runShutdown(limit: limit) }
        shutdownTask = task
        await task.value
    }

    private func runShutdown(limit: Double) async {
        defer { didShutDown = true }
        demo?.stop()
        guard let controller else { return }
        let done = Flag()
        Task { @MainActor in
            await controller.shutdown()
            done.set()
        }
        let deadline = clock.uptime + limit
        while !done.value, clock.uptime < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        Log.event(.app, "app.shutdown", .bool("clean", done.value))
    }

    /// `acvoice://press` and friends. Before the launch finished (index and socket ready) they wait.
    public func open(_ urls: [URL]) {
        guard ready else {
            pendingURLs += urls
            return
        }
        for url in urls {
            if controller?.handleURL(url) != true { Log.event(.app, "app.url.ignored") }
        }
    }

    // MARK: Menu

    func perform(_ command: MenuCommand) {
        guard let controller else {
            if command == .quit { quit() }
            return
        }
        switch command {
        case .listen: controller.listen()
        case .refreshIndex: controller.refreshIndexNow()
        case .setup: showOnboarding()
        case .launchAtLogin: controller.toggleLaunchAtLogin()
        case .openLoginItems: controller.services.loginItem.openSettings()
        case .selfTest: controller.runSelfTest()
        case .chromeTest: controller.runChromeTest()
        case .overlayDemo: controller.startDemo()
        case .copyDiagnostics: Task { await copyDiagnostics() }
        case .quit: quit()
        }
    }

    func showOnboarding() {
        guard let controller else { return }
        if onboarding == nil {
            onboarding = OnboardingWindowController(model: OnboardingModel(
                controller: controller, copy: Self.copyToPasteboard,
                sourceRoot: Bundle.main.object(forInfoDictionaryKey: AppText.sourceRootKey) as? String))
        }
        onboarding?.show()
    }

    private func copyDiagnostics() async {
        guard let controller else { return }
        let automation: AutomationStatus? = controller.services.permissions.isChromeRunning
            ? await controller.services.chrome.preflight(ask: false) : nil
        let info = Bundle.main.infoDictionary ?? [:]
        let input = controller.diagnosticsInput(
            automation: automation, appVersion: info["CFBundleShortVersionString"] as? String ?? "dev",
            build: info["CFBundleVersion"] as? String ?? "dev",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        Self.copyToPasteboard(Diagnostics.text(input))
        controller.diagnosticsCopied()
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Demo mode

    private func startDemoMode() {
        guard let overlay = demoOverlay else { return }
        let language = demoLanguage
        let text = AppText(language)
        statusMenu = StatusMenuController(
            state: { MenuState(statusLines: [text.demoRunning], language: language) },
            icon: { MenuIcon(language: language) },
            items: { s in
                s.statusLines.map { MenuItemSpec(kind: .status, title: $0, enabled: false) }
                    + [.separator, MenuItemSpec(kind: .command(.quit), title: text.quit, key: "q",
                                                modifiers: NSEvent.ModifierFlags.command.rawValue)]
            },
            perform: { [weak self] in self?.perform($0) })
        let d = OverlayDemo(overlay: overlay, clock: clock, language: language)
        demo = d
        d.start(loop: true)
    }

    // MARK: SIGTERM

    /// install.sh quits a running instance with SIGTERM: quit like the menu does.
    private func installSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.quit() }
        }
        source.resume()
        signalSource = source
    }
}

/// A flag shared between the shutdown task and its deadline loop (both on the main actor).
@MainActor
private final class Flag {
    private(set) var value = false
    func set() { value = true }
}
