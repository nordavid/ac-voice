// swift-tools-version: 6.2
import PackageDescription

// ac-voice: voice launcher for ActiveCollab.
// Module layout (see docs/PLAN.md section 1.2):
// - ACVoiceCore:    pure logic (text normalization, parser, resolver, ticket resolver, IPC codec)
// - ACVoiceFlow:    pure state machine reducer for the voice flow (fake-clock testable)
// - ACVoiceAC:      GET-only ActiveCollab client, index cache, token store
// - ACVoiceSpeech:  microphone + SpeechAnalyzer pipeline, end-of-utterance gate
// - ACVoiceUI:      overlay panel and SwiftUI views (orb, transcript, choice list)
// - ACVoiceSystem:  macOS integrations (Chrome opener, IPC server, hotkey, earcons, login item)
// - ACVoiceRuntime: controller that runs the flow's effects against the real services
// - ACVoiceApp:     the "AC Voice" menu-bar executable (thin shell around ACVoiceRuntime)
let package = Package(
    name: "ACVoice",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ACVoiceCore"),
        .target(name: "ACVoiceFlow", dependencies: ["ACVoiceCore"]),
        .target(name: "ACVoiceAC", dependencies: ["ACVoiceCore"]),
        .target(name: "ACVoiceSpeech", dependencies: ["ACVoiceCore"]),
        .target(name: "ACVoiceUI", dependencies: ["ACVoiceCore", "ACVoiceFlow"]),
        .target(name: "ACVoiceSystem", dependencies: ["ACVoiceCore", "ACVoiceFlow"]),
        .target(
            name: "ACVoiceRuntime",
            dependencies: ["ACVoiceCore", "ACVoiceFlow", "ACVoiceAC", "ACVoiceSpeech", "ACVoiceUI", "ACVoiceSystem"]
        ),
        .executableTarget(name: "ACVoiceApp", dependencies: ["ACVoiceRuntime"]),

        // Dev CLIs, one per module so modules can evolve independently.
        .executableTarget(name: "acvoice-resolve", dependencies: ["ACVoiceCore"]),
        .executableTarget(name: "acvoice-index", dependencies: ["ACVoiceCore", "ACVoiceAC"]),
        .executableTarget(name: "acvoice-transcribe", dependencies: ["ACVoiceCore", "ACVoiceSpeech"]),
        .executableTarget(name: "acvoice-overlay-snapshots", dependencies: ["ACVoiceUI", "ACVoiceFlow"]),

        .testTarget(name: "ACVoiceCoreTests", dependencies: ["ACVoiceCore"]),
        .testTarget(name: "ACVoiceFlowTests", dependencies: ["ACVoiceFlow"]),
        .testTarget(name: "ACVoiceACTests", dependencies: ["ACVoiceAC"]),
        .testTarget(name: "ACVoiceSpeechTests", dependencies: ["ACVoiceSpeech"]),
        .testTarget(name: "ACVoiceUITests", dependencies: ["ACVoiceUI", "ACVoiceFlow", "ACVoiceCore"]),
        .testTarget(name: "ACVoiceSystemTests", dependencies: ["ACVoiceSystem"]),
        .testTarget(
            name: "ACVoiceRuntimeTests",
            dependencies: ["ACVoiceRuntime", "ACVoiceCore", "ACVoiceFlow", "ACVoiceAC", "ACVoiceSpeech", "ACVoiceUI", "ACVoiceSystem"]
        ),
    ]
)
