import ACVoiceRuntime
import ACVoiceSystem
import AppKit

/// Forwards the application events to the coordinator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: [String]
    private var coordinator: AppCoordinator?

    init(arguments: [String]) {
        self.arguments = arguments
        super.init()
    }

    /// Created before launch finishes: a launch by `open acvoice://press` delivers the URL before
    /// `applicationDidFinishLaunching`. Creating it starts nothing.
    func applicationWillFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator.live(arguments: arguments)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = coordinator ?? AppCoordinator.live(arguments: arguments)
        coordinator = c
        c.start()
        Log.event(.app, "app.launched", .bool("demo", c.isDemoMode))
    }

    /// `acvoice://press`, `acvoice://cancel`, `acvoice://setup`.
    func application(_ application: NSApplication, open urls: [URL]) {
        coordinator?.open(urls)
    }

    /// Stop the microphone, remove the socket and write the history first.
    /// - The app's own quits (menu "Beenden", SIGTERM, a second instance) go through `AppCoordinator.quit()`, which
    ///   shuts down first. They arrive here with `didShutDown` set and terminate at once.
    /// - A quit from outside (logout, restart, a quit Apple Event) arrives from an event, outside any main-queue job,
    ///   so AppKit's nested run loop can run the shutdown task and its reply.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, !coordinator.didShutDown else { return .terminateNow }
        Task { @MainActor in
            await coordinator.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// A menu-bar app keeps running without windows (the setup window closes, the app stays).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
