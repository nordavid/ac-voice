import ACVoiceCore
import ACVoiceFlow
import ACVoiceSystem
import AppKit

/// Menu commands of the status item.
public enum MenuCommand: String, CaseIterable, Sendable {
    case listen, refreshIndex, setup, launchAtLogin, openLoginItems, selfTest, chromeTest, overlayDemo, copyDiagnostics, quit
}

/// One menu row, independent of AppKit (testable).
public struct MenuItemSpec: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A disabled status line.
        case status
        case command(MenuCommand)
        case submenu([MenuItemSpec])
        case separator
    }

    public var kind: Kind
    public var title: String
    public var enabled = true
    public var checked = false
    /// Mixed state (a dash): on, but waiting for something (the login item's approval).
    public var mixed = false
    /// Key equivalent next to the title ("" for none).
    public var key = ""
    /// `NSEvent.ModifierFlags.rawValue` of the key equivalent.
    public var modifiers: UInt = 0

    public init(kind: Kind, title: String, enabled: Bool = true, checked: Bool = false, mixed: Bool = false,
                key: String = "", modifiers: UInt = 0) {
        self.kind = kind; self.title = title; self.enabled = enabled; self.checked = checked; self.mixed = mixed
        self.key = key; self.modifiers = modifiers
    }

    static let separator = MenuItemSpec(kind: .separator, title: "")
}

/// What the menu shows.
public struct MenuState: Equatable, Sendable {
    public var phase: FlowPhase
    public var statusLines: [String]
    /// The registered hotkey, shown next to "Zuhören".
    public var hotkey: Hotkey?
    public var loginItem: LoginItemStatus
    public var hasIndex: Bool
    public var demoRunning: Bool
    public var selfTestRunning: Bool
    public var chromeTestRunning: Bool
    public var attention: Bool
    /// Results of the Diagnose commands, shown inside the Diagnose submenu.
    public var diagnosticLines: [String]
    /// Language of the menu titles (`Controller.language`).
    public var language: AppLanguage

    public init(phase: FlowPhase = .idle, statusLines: [String] = [], hotkey: Hotkey? = nil,
                loginItem: LoginItemStatus = .disabled, hasIndex: Bool = false, demoRunning: Bool = false,
                selfTestRunning: Bool = false, chromeTestRunning: Bool = false, attention: Bool = false,
                diagnosticLines: [String] = [], language: AppLanguage = .de) {
        self.phase = phase; self.statusLines = statusLines; self.hotkey = hotkey; self.loginItem = loginItem
        self.hasIndex = hasIndex; self.demoRunning = demoRunning; self.selfTestRunning = selfTestRunning
        self.chromeTestRunning = chromeTestRunning; self.attention = attention; self.diagnosticLines = diagnosticLines
        self.language = language
    }
}

/// What the menu bar icon shows. Cheap to read: no XPC, no TCC (it updates at every phase change).
public struct MenuIcon: Equatable, Sendable {
    public var phase: FlowPhase
    public var attention: Bool
    /// A short-lived symbol instead of the phase symbol (a check after "Diagnose kopieren").
    public var flash: String?
    /// Language of the icon's VoiceOver label and tooltip.
    public var language: AppLanguage
    public init(phase: FlowPhase = .idle, attention: Bool = false, flash: String? = nil, language: AppLanguage = .de) {
        self.phase = phase; self.attention = attention; self.flash = flash; self.language = language
    }
}

/// The status item's menu and icon as plain data.
public enum StatusMenuModel {
    public static func items(_ s: MenuState) -> [MenuItemSpec] {
        let text = AppText(s.language)
        var out = s.statusLines.map { MenuItemSpec(kind: .status, title: $0, enabled: false) }
        out.append(.separator)
        var listen = MenuItemSpec(kind: .command(.listen), title: text.listen)
        if let hk = s.hotkey, let eq = keyEquivalent(hk) {
            listen.key = eq.key
            listen.modifiers = eq.modifiers.rawValue
        }
        out.append(listen)
        out.append(MenuItemSpec(kind: .command(.refreshIndex), title: text.refreshIndex, enabled: s.hasIndex))
        out.append(MenuItemSpec(kind: .command(.setup), title: text.setup))
        // Waiting for approval counts as on (a dash), so a click turns it off (review C9).
        out.append(MenuItemSpec(kind: .command(.launchAtLogin), title: text.launchAtLogin,
                                checked: s.loginItem == .enabled, mixed: s.loginItem == .requiresApproval))
        if s.loginItem == .requiresApproval {
            out.append(MenuItemSpec(kind: .command(.openLoginItems), title: text.openLoginItems))
        }
        out.append(.separator)
        // The tests need an idle flow: disabled while a command runs, instead of a notice nobody sees (review U9).
        let idle = s.phase == .idle
        var diagnose = s.diagnosticLines.map { MenuItemSpec(kind: .status, title: $0, enabled: false) }
        if !diagnose.isEmpty { diagnose.append(.separator) }
        diagnose += [
            MenuItemSpec(kind: .command(.selfTest), title: text.selfTest, enabled: idle && !s.selfTestRunning),
            MenuItemSpec(kind: .command(.chromeTest), title: text.chromeTest, enabled: idle && !s.chromeTestRunning),
            MenuItemSpec(kind: .command(.overlayDemo), title: text.overlayDemo, enabled: idle && !s.demoRunning),
            MenuItemSpec(kind: .command(.copyDiagnostics), title: text.copyDiagnostics),
        ]
        out.append(MenuItemSpec(kind: .submenu(diagnose), title: text.diagnostics))
        out.append(.separator)
        out.append(MenuItemSpec(kind: .command(.quit), title: text.quit, key: "q",
                                modifiers: NSEvent.ModifierFlags.command.rawValue))
        return out
    }

    /// SF Symbol of the menu bar icon.
    public static func symbol(_ icon: MenuIcon) -> String {
        icon.flash ?? symbol(phase: icon.phase, attention: icon.attention)
    }

    /// SF Symbol of the menu bar icon per phase.
    public static func symbol(phase: FlowPhase, attention: Bool) -> String {
        switch phase {
        case .idle: return attention ? "waveform.badge.exclamationmark" : "waveform"
        case .listening, .retry: return "waveform.circle.fill"
        case .processing, .opening: return "ellipsis.circle"
        case .choices: return "list.number"
        case .success: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    /// VoiceOver label of the icon.
    public static func accessibilityLabel(phase: FlowPhase, attention: Bool, language: AppLanguage = .de) -> String {
        AppText(language).iconLabel(phase: phase, attention: attention)
    }

    /// Menu key equivalent for the hotkey: Space and F1 to F20. nil for other keys (the menu then shows none).
    public static func keyEquivalent(_ hotkey: Hotkey) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        let key: String
        if hotkey.keyCode == 49 {
            key = " "
        } else if let n = functionKeys[hotkey.keyCode], let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            key = String(Character(scalar))
        } else {
            return nil
        }
        return (key, CarbonHotkey.flags(from: hotkey.modifiers))
    }

    /// Carbon key code -> F-key number.
    static let functionKeys: [UInt32: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]
}

extension Controller {
    /// Status lines at the top of the menu, in the app language.
    public var statusLines: [String] {
        let text = AppText(language)
        var lines: [String] = []
        switch flow.phase {
        case .idle: lines.append(text.ready)
        case .listening, .retry: lines.append(text.phaseListening)
        case .processing: lines.append(text.phaseProcessing)
        case .opening: lines.append(text.phaseOpening)
        case .choices: lines.append(text.phaseChoices)
        case .success: lines.append(text.phaseSuccess)
        case .error: lines.append(text.phaseError)
        }
        switch status.token {
        case .missing: lines.append(text.tokenMissing)
        case .invalid: lines.append(text.tokenInvalid)
        case .unreadable: lines.append(text.tokenUnreadable)
        case .needsUserId: lines.append(text.userIdMissing)
        case .present, .unknown: break
        }
        if services.permissions.microphone != .granted { lines.append(text.micMissing) }
        if status.chromeAutomation == .notDetermined { lines.append(text.chromeAutomationMissing) }
        switch status.speech {
        case .warming: lines.append(text.speechWarming)
        case .unavailable: lines.append(text.speechUnavailable)
        case .ready: break
        }
        if let e = status.indexError { lines.append(e) }
        if index != nil { lines.append(status.projects > 0 ? text.indexCount(status.projects) : text.indexEmpty) }
        if let e = status.hotkeyError { lines.append(e) }
        if let e = status.ipcError { lines.append(e) }
        if let t = status.loginMessage { lines.append(t) }
        if isDemoRunning { lines.append(text.demoRunning) }
        if let t = status.notice { lines.append(t) }
        return lines
    }

    /// Results of the Diagnose commands, inside the Diagnose submenu (they do not crowd the top of the menu).
    public var diagnosticLines: [String] {
        let text = AppText(language)
        var lines: [String] = []
        if status.selfCheckRunning {
            lines.append(text.selfTestRunning)
        } else if let c = status.selfCheck {
            lines.append(c.passed ? text.selfTestPassed(ms: c.elapsedMs) : text.localized(c.message))
        }
        if let t = status.chromeTest { lines.append(t) }
        if let t = status.chromeFront { lines.append(t) }
        return lines
    }

    /// The whole menu (built when it opens). Reads the login item status again first (an XPC call, off the hot path).
    public func menuState() -> MenuState {
        refreshLoginStatus(notify: false)
        return MenuState(phase: flow.phase, statusLines: statusLines,
                         hotkey: config.hotkey.enabled && status.hotkeyError == nil ? config.hotkey : nil,
                         loginItem: loginStatus, hasIndex: index != nil, demoRunning: isDemoRunning,
                         selfTestRunning: status.selfCheckRunning, chromeTestRunning: status.chromeTestRunning,
                         attention: needsAttention, diagnosticLines: diagnosticLines, language: language)
    }

    /// The menu bar icon: phase, badge and flash only.
    public var menuIcon: MenuIcon {
        MenuIcon(phase: flow.phase, attention: needsAttention, flash: iconFlash, language: language)
    }
}

/// Builds an `NSMenu` from specs. No window and no status item involved, so tests can build menus too.
@MainActor
enum StatusMenuBuilder {
    static func fill(_ menu: NSMenu, with specs: [MenuItemSpec], perform: @escaping @MainActor (MenuCommand) -> Void) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for spec in specs { menu.addItem(item(spec, perform: perform)) }
    }

    static func item(_ spec: MenuItemSpec, perform: @escaping @MainActor (MenuCommand) -> Void) -> NSMenuItem {
        switch spec.kind {
        case .separator:
            return .separator()
        case .status:
            let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .command(let command):
            let item = CommandMenuItem(command: command, title: spec.title, key: spec.key, handler: perform)
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: spec.modifiers)
            item.isEnabled = spec.enabled
            item.state = spec.mixed ? .mixed : (spec.checked ? .on : .off)
            return item
        case .submenu(let children):
            let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: spec.title)
            fill(sub, with: children, perform: perform)
            item.submenu = sub
            return item
        }
    }
}

/// A menu item that runs a closure.
@MainActor
final class CommandMenuItem: NSMenuItem {
    let command: MenuCommand
    private let handler: @MainActor (MenuCommand) -> Void

    init(command: MenuCommand, title: String, key: String, handler: @escaping @MainActor (MenuCommand) -> Void) {
        self.command = command
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler(command) }
}

/// The menu bar item. Created by the app only (never in tests: it puts an icon on screen).
@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let state: @MainActor () -> MenuState
    private let icon: @MainActor () -> MenuIcon
    private let items: @MainActor (MenuState) -> [MenuItemSpec]
    private let perform: @MainActor (MenuCommand) -> Void
    private var shownSymbol = ""

    /// `state`: the whole menu, built when it opens. `icon`: what the icon shows, read at every status change
    /// (keep it cheap). `items`: the rows for a state (the full menu by default; the demo mode passes a short one).
    public init(state: @escaping @MainActor () -> MenuState,
                icon: @escaping @MainActor () -> MenuIcon,
                items: @escaping @MainActor (MenuState) -> [MenuItemSpec] = { StatusMenuModel.items($0) },
                perform: @escaping @MainActor (MenuCommand) -> Void) {
        self.state = state
        self.icon = icon
        self.items = items
        self.perform = perform
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    /// Updates the icon (phase, attention badge, flash). The menu itself is built when it opens.
    public func refresh() {
        let s = icon()
        let symbol = StatusMenuModel.symbol(s)
        guard symbol != shownSymbol else { return }
        shownSymbol = symbol
        let label = StatusMenuModel.accessibilityLabel(phase: s.phase, attention: s.attention, language: s.language)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: label)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = label
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        StatusMenuBuilder.fill(menu, with: items(state()), perform: perform)
    }
}
