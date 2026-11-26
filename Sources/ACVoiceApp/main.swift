import ACVoiceCore
import ACVoiceRuntime
import ACVoiceSystem
import AppKit

// AC Voice: resident menu-bar app (LSUIElement). Single instance: a live IPC socket means another instance runs,
// so this one exits before it shows anything. `--demo` skips that check (it opens no socket).
let arguments = CommandLine.arguments
if !arguments.contains(AppCoordinator.demoArgument), IPCServer.probe(path: AppPaths.socket.path) == .live {
    Log.event(.app, "app.alreadyRunning")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate(arguments: arguments)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
