import ACVoiceCore
import ServiceManagement

/// Login item state, mapped from `SMAppService.Status`.
public enum LoginItemStatus: String, Sendable, Equatable {
    case enabled
    case disabled
    /// Registered, but the user has to allow it under System Settings > General > Login Items.
    case requiresApproval
    /// The bundle is not where LaunchServices tracks it (a temp folder, `swift run`).
    case notFound

    public init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        case .notRegistered: self = .disabled
        @unknown default: self = .notFound
        }
    }

    /// Registered: enabled, or waiting for the user's approval. The menu shows it as on, and a click turns it off.
    public var isOn: Bool { self == .enabled || self == .requiresApproval }

    /// Hint for the menu in the app language, nil when nothing is to do.
    public func hint(_ language: AppLanguage) -> String? {
        let de = language == .de
        switch self {
        case .enabled, .disabled: return nil
        case .requiresApproval:
            return de ? "Erlaube AC Voice in den Systemeinstellungen unter Anmeldeobjekte."
                : "Allow AC Voice in System Settings under Login Items."
        case .notFound:
            return de ? "Installiere AC Voice in deinem Programme-Ordner." : "Install AC Voice in your Applications folder."
        }
    }
}

/// "Beim Anmelden starten". The runtime talks to this protocol, tests use fakes.
@MainActor
public protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSettings()
}

/// Launch at login via `SMAppService.mainApp` (PLAN 0, M8): registers the app bundle itself, no plist. The user
/// sees it under System Settings > General > Login Items. Not called in tests.
@MainActor
public final class LaunchAtLogin: LoginItemControlling {
    public init() {}

    public var status: LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }

    public func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
        Log.event(.login, "login.set", .bool("enabled", enabled), .tag("status", status))
    }

    /// Opens Login Items in System Settings (for `.requiresApproval`).
    public func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
