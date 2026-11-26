import Foundation

/// ActiveCollab web URLs (SPA routes, VERIFIED in the bundle: `projects/:projectId`, `projects/:projectId/tasks/:id`,
/// `my-work`). Always resolve the real project id before building a task URL.
public enum Routes {
    /// Fallback for "Meine Aufgaben" while the user id is unknown (no token yet).
    public static let defaultMyWorkPath = "/my-work"
    /// "Meine Aufgaben": the tasks assigned to the user ("{me}" becomes the user id).
    public static let defaultMyTasksPath = "/users/{me}/tasks"

    /// {base}/projects/{id}
    public static func project(_ base: URL, _ id: Int) -> URL {
        join(base, "projects/\(id)")
    }

    /// {base}/projects/{projectId}/tasks/{taskId}
    public static func task(_ base: URL, projectId: Int, taskId: Int) -> URL {
        join(base, "projects/\(projectId)/tasks/\(taskId)")
    }

    /// {base}{path}, default "/my-work". "{me}" in `path` becomes `userId` ("/users/{me}/tasks").
    /// Falls back to the default path when `path` needs a user id that is unknown or is not a valid URL path.
    public static func myWork(_ base: URL, path: String = defaultMyWorkPath, userId: Int? = nil) -> URL {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.contains("{me}") {
            guard let userId else { return join(base, defaultMyWorkPath) }
            p = p.replacingOccurrences(of: "{me}", with: String(userId))
        }
        if p.isEmpty || p.contains("://") { p = defaultMyWorkPath }
        return join(base, p)
    }

    /// Project id of an AC web URL on `base`'s host ("…/projects/628", "…/projects/628/tasks/123",
    /// "…/projects/628?modal=Task-1-628"). nil for other hosts and other routes. Used for the active-tab hint.
    public static func projectId(in url: URL, base: URL) -> Int? {
        guard let host = url.host?.lowercased(), host == base.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/")
        guard let i = parts.firstIndex(of: "projects"), i + 1 < parts.count else { return nil }
        return Int(parts[i + 1])
    }

    static func join(_ base: URL, _ path: String) -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        let tail = path.drop { $0 == "/" }
        return URL(string: root + "/" + tail) ?? base
    }
}
