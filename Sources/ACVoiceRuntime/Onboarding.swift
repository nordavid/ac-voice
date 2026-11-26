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
        case requestMicrophone, openMicrophoneSettings, requestAutomation, openAutomationSettings
        case runSelfTest, requestSpeechRecognition, copyStreamDeckCommands, openReleasePage, openLoginItems
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

    /// "AC-Adresse". Starts with the configured address, empty while that is the placeholder.
    public var address = ""
    /// "E-Mail". Kept after an attempt.
    public var email = ""
    /// "Passwort". Cleared by every sign-in attempt, successful or not, by a token save, when the form hides and when
    /// the window closes; never stored anywhere else.
    public var password = ""
    /// The paste field ("Mit Token anmelden"). Cleared once the token goes to the Keychain, when the form hides and
    /// when the window closes.
    public var pastedToken = ""
    /// "Mit Token anmelden" is expanded (collapsed by default).
    public var showsTokenSignIn = false
    /// A token is stored, but the user wants to sign in again ("Neu anmelden").
    public var signingInAgain = false
    public private(set) var steps: [Step] = []
    public private(set) var launchAtLogin = false
    /// Chrome's Automation status; nil while Chrome is not running or before the first check.
    public private(set) var automation: AutomationStatus?

    @ObservationIgnored private let controller: Controller
    @ObservationIgnored private let copy: @MainActor (String) -> Void
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    /// The app version (Info.plist `CFBundleShortVersionString`). The Stream Deck row of a release build opens the
    /// release of this version.
    @ObservationIgnored public let appVersion: String?
    /// The source folder (Info.plist `ACVoiceSourceRoot`, written by bundle.sh): the Stream Deck commands use it. nil
    /// in a release build, which has no sources, and in a bare `swift run` without an app bundle. The Stream Deck row
    /// then points to the GitHub release.
    @ObservationIgnored public let sourceRoot: String?
    private var chromeRunning = false
    private var working: Set<StepID> = []

    /// `copy`: puts text on the pasteboard (the app) or records it (tests). `openURL`: opens a web page in the default
    /// browser (the app) or records it (tests). Neither has a default, so the app cannot lose its wiring unnoticed.
    /// Without `appVersion`, the release row opens the list of all releases.
    public init(controller: Controller, copy: @escaping @MainActor (String) -> Void,
                openURL: @escaping @MainActor (URL) -> Void, appVersion: String? = nil, sourceRoot: String? = nil) {
        self.controller = controller
        self.copy = copy
        self.openURL = openURL
        self.appVersion = appVersion
        self.sourceRoot = sourceRoot
        address = Self.addressText(controller.config)
        rebuild()
    }

    /// The address field's text for a config: empty while the address is the placeholder.
    static func addressText(_ config: Config) -> String {
        config.hasPlaceholderBaseURL ? "" : config.acBaseURL.absoluteString
    }

    /// The sign-in fields show while no usable token is stored, or on request.
    public var showsSignIn: Bool { controller.status.token != .present || signingInAgain }

    /// "Anmelden" is enabled: address, e-mail and password are filled and no request runs.
    public var canLogin: Bool {
        !working.contains(.token) && Self.filled(address) && Self.filled(email) && !password.isEmpty
    }

    /// "Speichern" of "Mit Token anmelden" is enabled: address and token are filled and no request runs (the same
    /// rules as "Anmelden").
    public var canSaveToken: Bool {
        !working.contains(.token) && Self.filled(address) && Self.filled(pastedToken)
    }

    private static func filled(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Left of "Fertig": how to try the app.
    public var tryItText: String {
        let hk = controller.config.hotkey
        return text.tryIt(hotkey: hk.enabled && controller.status.hotkeyError == nil ? text.hotkey(hk) : nil)
    }

    private var services: Services { controller.services }

    /// The window's texts in the app language (`Controller.language`).
    public var text: AppText { AppText(controller.language) }

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
        if controller.status.token != .present { signingInAgain = false }
        // The form hid (a token arrived): nothing typed into it stays in memory.
        if !showsSignIn { clearSecrets() }
        steps = StepID.allCases.map(step)
        launchAtLogin = controller.loginStatus.isOn
    }

    public func perform(_ kind: ActionKind) async {
        switch kind {
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
            if let sourceRoot { copy(AppText.streamDeckCommands(sourceRoot: sourceRoot)) }
        case .openReleasePage:
            openURL(AppText.releasePageURL(version: appVersion))
        case .openLoginItems:
            services.loginItem.openSettings()
        }
        rebuild()
    }

    /// "Anmelden" (or Return in the password field): saves a changed address first, then signs in. The password field
    /// is cleared right away; the password lives on only for this call. Only a successful sign-in closes the form, so
    /// after a failure the user corrects the input and tries again.
    public func login() async {
        guard canLogin else { return }
        let secret = password
        password = ""
        let user = email.trimmingCharacters(in: .whitespacesAndNewlines)
        var signedIn = false
        await busy(.token) {
            guard await self.applyAddress() else { return }
            signedIn = await self.controller.login(username: user, password: secret)
        }
        if signedIn { signingInAgain = false }
        rebuild()
    }

    /// "Mit Token anmelden" > "Speichern" (or Return in the paste field): saves a changed address first, then the
    /// pasted token for that address. The paste stays while the address is missing or invalid, so the user fixes the
    /// address and saves again. Only a successful save closes the form.
    public func savePastedToken() async {
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !working.contains(.token) else { return }
        // The password form is left without an attempt.
        password = ""
        var saved = false
        await busy(.token) {
            guard await self.applyAddress() else { return }
            // The token goes to the Keychain now: the field empties whatever the Keychain answers.
            self.pastedToken = ""
            saved = await self.controller.saveToken(token)
        }
        if saved { signingInAgain = false }
        rebuild()
    }

    /// "Neu anmelden oder Adresse ändern": opens the form while a token is stored. The message of an earlier attempt
    /// goes away.
    public func beginSignInAgain() {
        signingInAgain = true
        address = Self.addressText(controller.config)
        controller.dismissTokenMessage()
        rebuild()
    }

    /// The window closed ("Fertig" or the close button). The password and a pasted token never outlive the window, the
    /// address field shows the address the app uses again, an open re-sign-in ends and the message of an abandoned
    /// attempt goes away. The e-mail address stays for the next sign-in.
    public func windowClosed() {
        clearSecrets()
        signingInAgain = false
        address = Self.addressText(controller.config)
        controller.dismissTokenMessage()
        rebuild()
    }

    private func clearSecrets() {
        if !password.isEmpty { password = "" }
        if !pastedToken.isEmpty { pastedToken = "" }
    }

    /// Saves the address field when it differs from the configured address. An empty field keeps the configured
    /// address unless that is the placeholder. false: the address is missing or invalid (the row says why).
    private func applyAddress() async -> Bool {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty, !controller.config.hasPlaceholderBaseURL { return true }
        guard await controller.setACBaseURL(typed) else { return false }
        address = Self.addressText(controller.config)
        return true
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

    /// The sign-in fields and "Anmelden" live inside the row (`OnboardingRow`), so the row has no action button.
    /// The message of an attempt shows only next to the form it belongs to: once a stored token closes the form, the
    /// row says where the app is signed in.
    private func tokenStep() -> Step {
        if working.contains(.token) {
            return Step(id: .token, title: text.tokenTitle, status: text.signingIn, tone: .working, action: nil)
        }
        let s = controller.status
        let (status, tone): (String, Tone) = switch s.token {
        case .present: (text.tokenStored(host: Self.hostText(controller.config.acBaseURL)), .done)
        case .invalid: (text.tokenRejected, .todo)
        case .needsUserId: (text.tokenUserId, .todo)
        case .unreadable: (text.tokenUnreadable, .todo)
        case .missing, .unknown: (text.tokenNone, .todo)
        }
        let message = showsSignIn ? s.tokenMessage : nil
        return Step(id: .token, title: text.tokenTitle, status: message ?? status,
                    tone: message == nil ? tone : .todo, action: nil)
    }

    /// The host of an AC address as the row names it, with the port when it is not 443.
    static func hostText(_ base: URL) -> String {
        let host = base.host ?? base.absoluteString
        guard let port = base.port, port != 443 else { return host }
        return "\(host):\(port)"
    }

    private func micStep() -> Step {
        if working.contains(.microphone) {
            return Step(id: .microphone, title: text.micTitle, status: text.checking, tone: .working,
                        action: StepAction(kind: .requestMicrophone, title: text.micRequest, enabled: false))
        }
        switch services.permissions.microphone {
        case .granted:
            return Step(id: .microphone, title: text.micTitle, status: text.micGranted, tone: .done, action: nil)
        case .notDetermined:
            return Step(id: .microphone, title: text.micTitle, status: text.micNotDetermined, tone: .todo,
                        action: StepAction(kind: .requestMicrophone, title: text.micRequest, enabled: true))
        case .denied, .restricted:
            return Step(id: .microphone, title: text.micTitle, status: text.micDenied, tone: .todo,
                        action: StepAction(kind: .openMicrophoneSettings, title: text.openSettings, enabled: true))
        }
    }

    private func chromeStep() -> Step {
        let request = StepAction(kind: .requestAutomation, title: text.chromeRequest, enabled: chromeRunning && !working.contains(.chrome))
        if working.contains(.chrome) {
            return Step(id: .chrome, title: text.chromeTitle, status: text.checking, tone: .working, action: request)
        }
        guard chromeRunning else {
            return Step(id: .chrome, title: text.chromeTitle, status: text.chromeNotRunning, tone: .info, action: request)
        }
        switch automation {
        case .granted?:
            return Step(id: .chrome, title: text.chromeTitle, status: text.chromeGranted, tone: .done, action: nil)
        case .notDetermined?:
            return Step(id: .chrome, title: text.chromeTitle, status: text.chromeNotDetermined, tone: .todo, action: request)
        case .denied?:
            return Step(id: .chrome, title: text.chromeTitle, status: text.chromeDenied, tone: .info,
                        action: StepAction(kind: .openAutomationSettings, title: text.openSettings, enabled: true))
        default:
            return Step(id: .chrome, title: text.chromeTitle, status: text.chromeUnknown, tone: .info, action: request)
        }
    }

    private func speechStep() -> Step {
        let s = controller.status
        let run = StepAction(kind: .runSelfTest, title: text.speechRun,
                             enabled: !s.selfCheckRunning && !working.contains(.speech) && s.speech != .warming)
        if s.selfCheckRunning || working.contains(.speech) {
            return Step(id: .speech, title: text.speechTitle, status: text.selfTestRunning, tone: .working, action: run)
        }
        if let c = s.selfCheck {
            if c.passed {
                return Step(id: .speech, title: text.speechTitle, status: text.selfTestPassed(ms: c.elapsedMs),
                            tone: .done, action: run)
            }
            // REVIEW m7: only when the self-test fails, ask for speech recognition.
            let ask = services.permissions.speechRecognition == .notDetermined
            return Step(id: .speech, title: text.speechTitle, status: text.localized(c.message), tone: .todo,
                        action: ask ? StepAction(kind: .requestSpeechRecognition, title: text.speechRecognitionRequest,
                                                 enabled: true) : run)
        }
        switch s.speech {
        case .warming:
            return Step(id: .speech, title: text.speechTitle, status: text.speechWarming, tone: .working, action: run)
        case .unavailable:
            return Step(id: .speech, title: text.speechTitle, status: text.speechUnavailable, tone: .todo, action: run)
        case .ready:
            return Step(id: .speech, title: text.speechTitle, status: text.speechReady, tone: .done, action: run)
        }
    }

    /// A source build hands out the npm commands for its plugin folder. A release build has no sources, so the row
    /// sends the user to the plugin file of the GitHub release.
    private func streamDeckStep() -> Step {
        if !services.ipc.connectedClients.isEmpty {
            return Step(id: .streamDeck, title: text.streamDeckTitle, status: text.streamDeckConnected, tone: .done, action: nil)
        }
        guard let sourceRoot else {
            return Step(id: .streamDeck, title: text.streamDeckTitle, status: text.streamDeckMissingRelease, tone: .info,
                        action: StepAction(kind: .openReleasePage, title: text.streamDeckOpenRelease, enabled: true))
        }
        return Step(id: .streamDeck, title: text.streamDeckTitle,
                    status: text.streamDeckMissing(folder: AppText.streamDeckFolder(sourceRoot: sourceRoot)), tone: .info,
                    action: StepAction(kind: .copyStreamDeckCommands, title: text.streamDeckCopy, enabled: true))
    }

    /// The switch shows the state; the row adds text only when something is to do (review U24).
    private func autostartStep() -> Step {
        let status = controller.loginStatus
        switch status {
        case .enabled:
            return Step(id: .autostart, title: text.autostartTitle, status: "", tone: .done, action: nil)
        case .disabled:
            return Step(id: .autostart, title: text.autostartTitle, status: "", tone: .info, action: nil)
        case .requiresApproval:
            return Step(id: .autostart, title: text.autostartTitle,
                        status: status.hint(controller.language) ?? text.autostartOff, tone: .todo,
                        action: StepAction(kind: .openLoginItems, title: text.openSettings, enabled: true))
        case .notFound:
            return Step(id: .autostart, title: text.autostartTitle,
                        status: status.hint(controller.language) ?? text.autostartOff, tone: .info, action: nil)
        }
    }
}

/// The setup window's content.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.text.onboardingIntro)
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
                Button(model.text.done, action: onDone).keyboardShortcut(.defaultAction)
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
                    if model.showsSignIn {
                        signInForm
                    } else {
                        Button(model.text.signInAgain) { model.beginSignInAgain() }
                            .buttonStyle(.link)
                    }
                }
                if step.id == .autostart {
                    Toggle(model.text.launchAtLoginSwitch, isOn: Binding(get: { model.launchAtLogin },
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

    /// AC-Adresse, E-Mail, Passwort and "Anmelden"; below, collapsed, the token paste field for single sign-on.
    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(model.text.addressLabel).gridColumnAlignment(.trailing)
                    TextField(model.text.addressLabel, text: $model.address, prompt: Text(model.text.addressPlaceholder))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                GridRow {
                    Text(model.text.emailLabel)
                    TextField(model.text.emailLabel, text: $model.email, prompt: Text(model.text.emailPlaceholder))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                }
                GridRow {
                    Text(model.text.passwordLabel)
                    SecureField(model.text.passwordLabel, text: $model.password)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .onSubmit { Task { await model.login() } }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Button(model.text.signIn) { Task { await model.login() } }
                    .disabled(!model.canLogin)
                Text(model.text.signInHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(model.text.tokenSignIn, isExpanded: $model.showsTokenSignIn) {
                tokenField.padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(model.text.tokenPastePlaceholder, text: $model.pastedToken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.savePastedToken() } }
                Button(model.text.tokenSave) { Task { await model.savePastedToken() } }
                    .disabled(!model.canSaveToken)
            }
            Text(model.text.tokenSignInHint)
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
            w.title = model.text.onboardingTitle
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
        // "Fertig" closes the window too. The model forgets what the form held (password, pasted token, an unsaved
        // address) even though the window object and the model live on.
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.windowClosed()
                self?.stopObserving()
            }
        })
    }

    private func stopObserving() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }
}
