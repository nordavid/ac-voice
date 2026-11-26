import ACVoiceCore
import ACVoiceSystem
import AppKit
import Observation
import SwiftUI

/// The setup window's state (PLAN M5): one row per step with a live status and one action. Every permission request
/// runs only when the user clicks its button.
@MainActor
@Observable
public final class OnboardingModel {
    public enum StepID: String, CaseIterable, Identifiable, Sendable {
        case token, microphone, chrome, speech, streamDeck, autostart
        public var id: String { rawValue }
    }

    public enum Tone: Sendable, Equatable {
        case done, todo, working, info
    }

    public enum ActionKind: String, Sendable, Equatable {
        case importToken, requestMicrophone, openMicrophoneSettings, requestAutomation, openAutomationSettings
        case runSelfTest, requestSpeechRecognition, copyStreamDeckCommands, openLoginItems
    }

    public struct StepAction: Sendable, Equatable {
        public var kind: ActionKind
        public var title: String
        public var enabled: Bool
    }

    public struct Step: Identifiable, Sendable, Equatable {
        public var id: StepID
        public var title: String
        public var status: String
        public var tone: Tone
        public var action: StepAction?
    }

    /// The paste field. Cleared right after a save.
    public var pastedToken = ""
    /// A token is stored, but the user wants to paste another one ("Anderen Token einfügen").
    public var replacingToken = false
    public private(set) var steps: [Step] = []
    public private(set) var launchAtLogin = false
    /// Chrome's Automation status; nil while Chrome is not running or before the first check.
    public private(set) var automation: AutomationStatus?

    @ObservationIgnored private let controller: Controller
    @ObservationIgnored private let copy: @MainActor (String) -> Void
    /// The source folder (Info.plist `ACVoiceSourceRoot`, written by bundle.sh): the Stream Deck commands use it.
    @ObservationIgnored public let sourceRoot: String?
    private var chromeRunning = false
    private var working: Set<StepID> = []

    /// `copy`: puts text on the pasteboard (the app) or records it (tests).
    public init(controller: Controller, copy: @escaping @MainActor (String) -> Void, sourceRoot: String? = nil) {
        self.controller = controller
        self.copy = copy
        self.sourceRoot = sourceRoot
        rebuild()
    }

    /// The paste field shows while no usable token is stored, or on request.
    public var showsTokenField: Bool { controller.status.token != .present || replacingToken }

    /// Above "Fertig": how to try the app.
    public var tryItText: String {
        let hk = controller.config.hotkey
        return AppText.tryIt(hotkey: hk.enabled && controller.status.hotkeyError == nil ? hk.display : nil)
    }

    private var services: Services { controller.services }

    /// Token, microphone or a Chrome Automation that was never asked for.
    public var needsAttention: Bool {
        controller.needsSetup || automation == .notDetermined
    }

    /// Re-reads the statuses without a prompt (Chrome's Automation, the login item), then rebuilds the rows. Runs
    /// when the window opens, comes back to the front (from System Settings) and when Chrome starts or quits.
    public func refresh() async {
        controller.refreshLoginStatus()
        chromeRunning = services.permissions.isChromeRunning
        if chromeRunning {
            working.insert(.chrome)
            rebuild()
            let status = await services.chrome.preflight(ask: false)
            automation = status
            controller.recordAutomation(status)
            working.remove(.chrome)
        } else {
            automation = nil
        }
        rebuild()
    }

    public func rebuild() {
        chromeRunning = services.permissions.isChromeRunning
        if !chromeRunning { automation = nil }
        if controller.status.token != .present { replacingToken = false }
        steps = StepID.allCases.map(step)
        launchAtLogin = controller.loginStatus.isOn
    }

    public func perform(_ kind: ActionKind) async {
        switch kind {
        case .importToken:
            await busy(.token) { _ = await self.controller.importToken() }
        case .requestMicrophone:
            await busy(.microphone) { _ = await self.services.permissions.requestMicrophone() }
        case .openMicrophoneSettings:
            services.permissions.openSettings(.microphone)
        case .requestAutomation:
            await busy(.chrome) {
                let status = await self.services.chrome.preflight(ask: true)
                self.automation = status
                self.controller.recordAutomation(status)
            }
        case .openAutomationSettings:
            services.permissions.openSettings(.automation)
        case .runSelfTest:
            controller.runSelfTest()
        case .requestSpeechRecognition:
            await busy(.speech) { _ = await self.services.permissions.requestSpeechRecognition() }
            controller.runSelfTest()
        case .copyStreamDeckCommands:
            copy(AppText.streamDeckCommands(sourceRoot: sourceRoot))
        case .openLoginItems:
            services.loginItem.openSettings()
        }
        rebuild()
    }

    public func savePastedToken() async {
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        pastedToken = ""
        guard !token.isEmpty else { return }
        await busy(.token) { _ = await self.controller.saveToken(token) }
        if controller.status.token == .present { replacingToken = false }
        rebuild()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        controller.setLaunchAtLogin(enabled)
        rebuild()
    }

    private func busy(_ id: StepID, _ work: @MainActor () async -> Void) async {
        working.insert(id)
        rebuild()
        await work()
        working.remove(id)
    }

    // MARK: Rows

    func step(_ id: StepID) -> Step {
        switch id {
        case .token: return tokenStep()
        case .microphone: return micStep()
        case .chrome: return chromeStep()
        case .speech: return speechStep()
        case .streamDeck: return streamDeckStep()
        case .autostart: return autostartStep()
        }
    }

    private func tokenStep() -> Step {
        let action = StepAction(kind: .importToken, title: AppText.tokenImport, enabled: !working.contains(.token))
        if working.contains(.token) {
            return Step(id: .token, title: AppText.tokenTitle, status: AppText.checking, tone: .working, action: action)
        }
        let s = controller.status
        let (text, tone): (String, Tone) = switch s.token {
        case .present: (AppText.tokenStored, .done)
        case .invalid: (AppText.tokenRejected, .todo)
        case .needsUserId: (AppText.tokenUserId, .todo)
        case .unreadable: (AppText.tokenUnreadable, .todo)
        case .missing, .unknown: (AppText.tokenNone, .todo)
        }
        return Step(id: .token, title: AppText.tokenTitle, status: s.tokenMessage ?? text,
                    tone: s.tokenMessage == nil ? tone : .todo, action: action)
    }

    private func micStep() -> Step {
        if working.contains(.microphone) {
            return Step(id: .microphone, title: AppText.micTitle, status: AppText.checking, tone: .working,
                        action: StepAction(kind: .requestMicrophone, title: AppText.micRequest, enabled: false))
        }
        switch services.permissions.microphone {
        case .granted:
            return Step(id: .microphone, title: AppText.micTitle, status: AppText.micGranted, tone: .done, action: nil)
        case .notDetermined:
            return Step(id: .microphone, title: AppText.micTitle, status: AppText.micNotDetermined, tone: .todo,
                        action: StepAction(kind: .requestMicrophone, title: AppText.micRequest, enabled: true))
        case .denied, .restricted:
            return Step(id: .microphone, title: AppText.micTitle, status: AppText.micDenied, tone: .todo,
                        action: StepAction(kind: .openMicrophoneSettings, title: AppText.openSettings, enabled: true))
        }
    }

    private func chromeStep() -> Step {
        let request = StepAction(kind: .requestAutomation, title: AppText.chromeRequest, enabled: chromeRunning && !working.contains(.chrome))
        if working.contains(.chrome) {
            return Step(id: .chrome, title: AppText.chromeTitle, status: AppText.checking, tone: .working, action: request)
        }
        guard chromeRunning else {
            return Step(id: .chrome, title: AppText.chromeTitle, status: AppText.chromeNotRunning, tone: .info, action: request)
        }
        switch automation {
        case .granted?:
            return Step(id: .chrome, title: AppText.chromeTitle, status: AppText.chromeGranted, tone: .done, action: nil)
        case .notDetermined?:
            return Step(id: .chrome, title: AppText.chromeTitle, status: AppText.chromeNotDetermined, tone: .todo, action: request)
        case .denied?:
            return Step(id: .chrome, title: AppText.chromeTitle, status: AppText.chromeDenied, tone: .info,
                        action: StepAction(kind: .openAutomationSettings, title: AppText.openSettings, enabled: true))
        default:
            return Step(id: .chrome, title: AppText.chromeTitle, status: AppText.chromeUnknown, tone: .info, action: request)
        }
    }

    private func speechStep() -> Step {
        let s = controller.status
        let run = StepAction(kind: .runSelfTest, title: AppText.speechRun,
                             enabled: !s.selfCheckRunning && !working.contains(.speech) && s.speech != .warming)
        if s.selfCheckRunning || working.contains(.speech) {
            return Step(id: .speech, title: AppText.speechTitle, status: AppText.selfTestRunning, tone: .working, action: run)
        }
        if let c = s.selfCheck {
            if c.passed {
                return Step(id: .speech, title: AppText.speechTitle, status: AppText.selfTestPassed(ms: c.elapsedMs),
                            tone: .done, action: run)
            }
            // REVIEW m7: only when the self-test fails, ask for speech recognition.
            let ask = services.permissions.speechRecognition == .notDetermined
            return Step(id: .speech, title: AppText.speechTitle, status: c.message, tone: .todo,
                        action: ask ? StepAction(kind: .requestSpeechRecognition, title: AppText.speechRecognitionRequest,
                                                 enabled: true) : run)
        }
        switch s.speech {
        case .warming:
            return Step(id: .speech, title: AppText.speechTitle, status: AppText.speechWarming, tone: .working, action: run)
        case .unavailable:
            return Step(id: .speech, title: AppText.speechTitle, status: AppText.speechUnavailable, tone: .todo, action: run)
        case .ready:
            return Step(id: .speech, title: AppText.speechTitle, status: AppText.speechReady, tone: .done, action: run)
        }
    }

    private func streamDeckStep() -> Step {
        if !services.ipc.connectedClients.isEmpty {
            return Step(id: .streamDeck, title: AppText.streamDeckTitle, status: AppText.streamDeckConnected, tone: .done, action: nil)
        }
        return Step(id: .streamDeck, title: AppText.streamDeckTitle,
                    status: AppText.streamDeckMissing(folder: AppText.streamDeckFolder(sourceRoot: sourceRoot)), tone: .info,
                    action: StepAction(kind: .copyStreamDeckCommands, title: AppText.streamDeckCopy, enabled: true))
    }

    /// The switch shows the state; the row adds text only when something is to do (review U24).
    private func autostartStep() -> Step {
        let status = controller.loginStatus
        switch status {
        case .enabled:
            return Step(id: .autostart, title: AppText.autostartTitle, status: "", tone: .done, action: nil)
        case .disabled:
            return Step(id: .autostart, title: AppText.autostartTitle, status: "", tone: .info, action: nil)
        case .requiresApproval:
            return Step(id: .autostart, title: AppText.autostartTitle, status: status.hint ?? AppText.autostartOff,
                        tone: .todo, action: StepAction(kind: .openLoginItems, title: AppText.openSettings, enabled: true))
        case .notFound:
            return Step(id: .autostart, title: AppText.autostartTitle, status: status.hint ?? AppText.autostartOff,
                        tone: .info, action: nil)
        }
    }
}

/// The setup window's content.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppText.onboardingIntro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.steps) { step in
                OnboardingRow(step: step, model: model)
                if step.id != OnboardingModel.StepID.allCases.last { Divider() }
            }
            HStack {
                Text(model.tryItText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(AppText.done, action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}

struct OnboardingRow: View {
    let step: OnboardingModel.Step
    @Bindable var model: OnboardingModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.headline)
                if !step.status.isEmpty {
                    Text(step.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if step.id == .token {
                    if model.showsTokenField {
                        tokenField
                    } else {
                        Button(AppText.tokenReplace) { model.replacingToken = true }
                            .buttonStyle(.link)
                    }
                }
                if step.id == .autostart {
                    Toggle(AppText.launchAtLogin, isOn: Binding(get: { model.launchAtLogin },
                                                                set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                }
            }
            Spacer(minLength: 8)
            if let action = step.action {
                Button(action.title) { Task { await model.perform(action.kind) } }
                    .disabled(!action.enabled)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(AppText.tokenPastePlaceholder, text: $model.pastedToken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.savePastedToken() } }
                Button(AppText.tokenSave) { Task { await model.savePastedToken() } }
                    .disabled(model.pastedToken.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(AppText.tokenImportHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.tone {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .todo:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.title3)
        case .working:
            ProgressView().controlSize(.small)
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.title3)
        }
    }
}

/// The setup window: a normal titled window. The app activates only to show it.
@MainActor
public final class OnboardingWindowController {
    public let model: OnboardingModel
    private var window: NSWindow?
    private var observers: [any NSObjectProtocol] = []

    public init(model: OnboardingModel) { self.model = model }

    public var isVisible: Bool { window?.isVisible ?? false }

    public func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView(model: model, onDone: { [weak self] in self?.close() }))
            let w = NSWindow(contentViewController: host)
            w.title = AppText.onboardingTitle
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        observeWindow()
        model.rebuild()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
    }

    public func close() { window?.close() }

    /// Chrome started or quit: re-read the rows while the window is on screen (review U5).
    public func refreshIfVisible() {
        guard isVisible else { return }
        Task { await model.refresh() }
    }

    /// While the window is open: it becomes key again when the user comes back from System Settings, so the rows
    /// re-read the statuses then (without a prompt). The observers go away with the window.
    private func observeWindow() {
        guard observers.isEmpty, let window else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfVisible() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopObserving() }
        })
    }

    private func stopObserving() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }
}
