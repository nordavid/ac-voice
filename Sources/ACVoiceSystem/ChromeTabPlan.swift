import Foundation

/// A Chrome window id in the form the script reports it. Chrome's scripting dictionary declares it as text since
/// at least Chrome 158 ("1749650355"); older versions answer an integer, and AppleScript turns integers above
/// 536870911 into reals. The id goes back to `focustab`/`newtab` in the same form, because Chrome resolves
/// `window id …` by comparing values, and a number never equals Chrome's text id.
enum ChromeWindowID: Sendable, Hashable, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case int(Int)
    case text(String)

    /// nil for an empty text, a fraction, a list, a boolean or missing value.
    init?(_ v: ScriptValue) {
        if case .text(let s) = v {
            guard !s.isEmpty else { return nil }
            self = .text(s)
        } else if let i = v.int {
            self = .int(i)
        } else {
            return nil
        }
    }

    init(integerLiteral value: Int) { self = .int(value) }
    init(stringLiteral value: String) { self = .text(value) }

    /// The handler argument that addresses this window.
    var arg: ScriptArg {
        switch self {
        case .int(let i): .int(i)
        case .text(let s): .text(s)
        }
    }
}

/// Chrome's windows as the `chromestate` handler reports them, front to back.
struct ChromeWindows: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        var id: ChromeWindowID
        /// `mode is "normal"`. Incognito windows show AC logged out and never count (REVIEW M4).
        var isNormal: Bool
        /// URL per tab; nil where Chrome answers `missing value`.
        var tabs: [String?]
        /// 1-based.
        var activeTab: Int

        var activeURL: String? { tabs.indices.contains(activeTab - 1) ? tabs[activeTab - 1] : nil }
    }

    var windows: [Window]

    init(windows: [Window]) { self.windows = windows }

    /// From `{ids, modes, urlLists, activeIndexes}`. nil when the answer is malformed or the lists disagree (a
    /// window opened or closed between the reads).
    init?(_ value: ScriptValue) {
        guard let parts = value.list, parts.count == 4,
              let ids = parts[0].list, let modes = parts[1].list, let urls = parts[2].list, let active = parts[3].list,
              ids.count == modes.count, ids.count == urls.count, ids.count == active.count
        else { return nil }
        var ws: [Window] = []
        for i in ids.indices {
            guard let id = ChromeWindowID(ids[i]), let a = active[i].int else { return nil }
            let tabs: [String?]
            switch urls[i] {
            case .list(let l): tabs = l.map(\.text)
            case .text(let s): tabs = [s] // a lone tab may come back unwrapped
            default: tabs = []
            }
            ws.append(Window(id: id, isNormal: modes[i].text == "normal", tabs: tabs, activeTab: a))
        }
        windows = ws
    }

    /// URL of the active tab of the front-most normal window, when it is an AC page on `base`.
    func activeACTabURL(base: String) -> String? {
        guard let w = windows.first(where: \.isNormal), let u = w.activeURL,
              ChromeTabPlan.isAC(u, base: base) else { return nil }
        return u
    }
}

/// Which tab gets the AC page. Pure, so the REVIEW M4 rules are unit tested.
///
/// Only normal windows count, front to back:
/// 1. A tab that already shows the target: focus it, no reload.
/// 2. A window whose active tab is an AC page: load the target there.
/// 3. Any AC tab: load the target there and make it active.
/// 4. The front-most normal window: new tab.
/// 5. No normal window: new normal window.
enum ChromeTabPlan: Sendable, Equatable {
    case focus(windowId: ChromeWindowID, tab: Int, setURL: Bool, setTab: Bool)
    case newTab(windowId: ChromeWindowID)
    case newWindow

    static func make(_ state: ChromeWindows, target: String, base: String) -> ChromeTabPlan {
        let normal = state.windows.filter(\.isNormal)
        // 1. Exact target, preferring a window that shows it already.
        if let w = normal.first(where: { $0.activeURL == target }) {
            return .focus(windowId: w.id, tab: w.activeTab, setURL: false, setTab: false)
        }
        for w in normal {
            if let i = w.tabs.firstIndex(where: { $0 == target }) {
                return .focus(windowId: w.id, tab: i + 1, setURL: false, setTab: i + 1 != w.activeTab)
            }
        }
        // 2. Active AC tab.
        if let w = normal.first(where: { $0.activeURL.map { isAC($0, base: base) } ?? false }) {
            return .focus(windowId: w.id, tab: w.activeTab, setURL: true, setTab: false)
        }
        // 3. Any AC tab.
        for w in normal {
            if let i = w.tabs.firstIndex(where: { $0.map { isAC($0, base: base) } ?? false }) {
                return .focus(windowId: w.id, tab: i + 1, setURL: true, setTab: i + 1 != w.activeTab)
            }
        }
        // 4. and 5.
        if let w = normal.first { return .newTab(windowId: w.id) }
        return .newWindow
    }

    /// `url` is `base` or starts with `base` followed by "/", "?" or "#" (case-insensitive). So
    /// "https://ac.example.com.evil.example" is no AC page.
    static func isAC(_ url: String, base: String) -> Bool {
        var b = base.lowercased()
        while b.hasSuffix("/") { b.removeLast() }
        let u = url.lowercased()
        return u == b || u.hasPrefix(b + "/") || u.hasPrefix(b + "?") || u.hasPrefix(b + "#")
    }
}
