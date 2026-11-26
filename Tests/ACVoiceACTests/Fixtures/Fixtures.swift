import Foundation
import Synchronization
@testable import ACVoiceAC

/// Sanitized synthetic AC v8 responses. Invented ids, codes, titles and companies; the shapes (including fields
/// ac-voice ignores) mirror the real API [V in docs/research/acapi.md]. Kept as Swift literals so the test target
/// needs no resource declaration in Package.swift.
///
/// Instance: user 7. Projects 101-105 active, 106 trashed. Company 1 is the agency itself.
enum Fixtures {
    static let userId = 7
    static let token = "7-StubTokenAbcdefghijklmnop"
    /// Contains an e-mail address like the real ETags: must never show up in error text or logs.
    static func etag(_ name: String) -> String { "W/\"\(name)-stub.user@example.com-1\"" }

    static let projects = """
    [
      {"class": "Project", "id": 101, "name": "ABC: Website Relaunch [AGIL]", "company_id": 11, "last_activity_on": 1763900000,
       "is_completed": false, "is_trashed": false, "members": [7, 8], "url_path": "/projects/101", "body": "<p>Synthetic</p>",
       "created_by_email": "someone@example.com", "count_tasks": 2},
      {"class": "Project", "id": 102, "name": "ABC: Maintenance [SLA]", "company_id": 11, "last_activity_on": 1763000000,
       "is_completed": false, "is_trashed": false},
      {"class": "Project", "id": 103, "name": "XYZ: Shop Rollout [AGIL]", "company_id": 12, "last_activity_on": null,
       "is_completed": false, "is_trashed": false},
      {"class": "Project", "id": 104, "name": "QZ: Intern Tools [INT]", "company_id": 1, "last_activity_on": 1700000000,
       "is_completed": false, "is_trashed": false},
      {"class": "Project", "id": 105, "name": "Muster Kampagne", "company_id": 13, "last_activity_on": 1763900000,
       "is_completed": false, "is_trashed": false},
      {"class": "Project", "id": 106, "name": "OLD: Trashed [FIX]", "company_id": 12, "is_completed": false, "is_trashed": true},
      {"class": "Project", "id": "broken"}
    ]
    """

    static let projectNames = """
    {"101": "ABC: Website Relaunch [AGIL]", "102": "ABC: Maintenance [SLA]", "103": "XYZ: Shop Rollout [AGIL]",
     "104": "QZ: Intern Tools [INT]", "105": "Muster Kampagne Neu", "107": "NEW: Fresh Project [AGIL]"}
    """

    static let companies = """
    [
      {"class": "Company", "id": 1, "name": "Beispielagentur GmbH", "is_owner": true, "is_archived": false, "is_trashed": false,
       "address": "Musterstrasse 1", "homepage_url": "https://example.com"},
      {"class": "Company", "id": 11, "name": "Alpha Beta Chemie GmbH & Co. KG", "is_owner": false, "is_trashed": false},
      {"class": "Company", "id": 12, "name": "Xylo Systems AG", "is_owner": false, "is_trashed": false},
      {"class": "Company", "id": 13, "name": "Muster e.V.", "is_owner": false, "is_trashed": false},
      {"class": "Company", "id": 14, "name": "Trash Corp", "is_owner": false, "is_trashed": true}
    ]
    """

    /// `[type, id, bool]` triples [V]; duplicates and non-project favorites are dropped.
    static let favorites = """
    [["Project", 101, false], ["Project", 999, false], ["Task", 5001, false], ["Project", 101, false], ["Project", "x", false]]
    """

    static let userTasks = """
    {
      "tasks": [
        {"class": "Task", "id": 5001, "project_id": 101, "task_number": 12, "is_completed": false, "is_trashed": false,
         "assignee_id": 7, "name": "Synthetic task", "url_path": "/projects/101/tasks/5001"},
        {"class": "Task", "id": 5101, "project_id": 103, "task_number": 3, "is_completed": false, "is_trashed": false},
        {"class": "Task", "id": 5102, "project_id": 103, "task_number": 4, "is_completed": true, "is_trashed": false},
        {"class": "Task", "id": 5103, "project_id": 103}
      ],
      "subtasks": [],
      "related": {"Project": {}, "TaskList": {}, "Task": {}},
      "tracked_time": {"5001": 1.5}
    }
    """

    static let timeRecords = """
    {
      "time_records": [
        {"class": "TimeRecord", "id": 1, "project_id": 101, "parent_type": "Task", "parent_id": 5001, "record_date": 1763800000,
         "is_trashed": false, "value": 1.5, "user_id": 7, "summary": "synthetic"},
        {"class": "TimeRecord", "id": 2, "project_id": 101, "parent_type": "Project", "parent_id": 101, "record_date": 1763700000, "is_trashed": false},
        {"class": "TimeRecord", "id": 3, "project_id": 101, "parent_type": "Task", "parent_id": 5003, "record_date": 1763600000, "is_trashed": false},
        {"class": "TimeRecord", "id": 4, "project_id": 103, "parent_type": "Task", "parent_id": 5101, "record_date": 1763500000, "is_trashed": false},
        {"class": "TimeRecord", "id": 5, "project_id": 102, "parent_type": "Task", "parent_id": 5201, "record_date": 1763400000, "is_trashed": true}
      ],
      "related": {"Project": {}, "Task": {}}
    }
    """

    static func task(_ id: Int, _ pid: Int, _ number: Int, completed: Bool = false, trashed: Bool = false) -> String {
        """
        {"class": "Task", "id": \(id), "project_id": \(pid), "task_number": \(number), "is_completed": \(completed), \
        "is_trashed": \(trashed), "name": "Synthetic \(number)", "body": "", "labels": [], "task_list_id": 1}
        """
    }

    static func projectTasks(open: [(id: Int, number: Int)], completed: [Int], trashed: [Int], pid: Int,
                             extra: [String] = []) -> String {
        let tasks = open.map { task($0.id, pid, $0.number) } + extra
        return """
        {"tasks": [\(tasks.joined(separator: ","))], "task_lists": [{"id": 1, "name": "Synthetic"}], "label_ids": [],
         "project": {"id": \(pid)}, "completed_task_ids": [\(completed.map(String.init).joined(separator: ","))],
         "completed_tasks_count": \(completed.count), "trashed_task_ids": [\(trashed.map(String.init).joined(separator: ","))],
         "task_max_updated_on": 1763900000}
        """
    }

    /// Per project: open tasks, completed ids, trashed ids; archive rows newest completion first.
    struct ProjectData: Sendable {
        var open: [(id: Int, number: Int)]
        var archive: [(id: Int, number: Int)]
        var trashed: [Int] = []
        var completed: [Int] { archive.map(\.id) }
    }

    static let data: [Int: ProjectData] = [
        101: ProjectData(open: [(5001, 12), (5003, 13)], archive: [(4003, 9), (4002, 8), (4001, 7)], trashed: [4900]),
        102: ProjectData(open: [(5201, 1)], archive: []),
        103: ProjectData(open: [(5101, 3)], archive: [(5102, 4)]),
        104: ProjectData(open: [], archive: []),
        105: ProjectData(open: [(5501, 12)], archive: [(5502, 7)]),
    ]

    static func archivePage(_ rows: [(id: Int, number: Int)], pid: Int, page: Int, perPage: Int = 30) -> StubResponse {
        let slice = rows.dropFirst((page - 1) * perPage).prefix(perPage)
        let body = "[" + slice.map { task($0.id, pid, $0.number, completed: true) }.joined(separator: ",") + "]"
        return .json(body, etag: etag("archive-\(pid)-\(page)"), headers: [
            "X-Angie-PaginationCurrentPage": "\(page)", "X-Angie-PaginationItemsPerPage": "\(perPage)",
            "X-Angie-PaginationTotalItems": "\(rows.count)",
        ])
    }

    /// The whole synthetic instance, with ETag/304 handling. Probe: task 47285 lives in project 103 (number 77);
    /// task 61000 is trashed in project 102; anything else is 404.
    static func router(host: @escaping @Sendable () -> String) -> StubServer.Handler {
        { r in
            func conditional(_ name: String, _ body: String) -> StubResponse {
                let tag = etag(name)
                return r.ifNoneMatch == tag ? .notModified : .json(body, etag: tag)
            }
            let path = r.path
            let me = "/users/\(userId)"
            switch path {
            case "/projects": return conditional("projects", projects)
            case "/projects/names": return .json(projectNames)
            case "/companies": return conditional("companies", companies)
            case "/favorites": return conditional("favorites", favorites)
            case "\(me)/tasks": return conditional("mine", userTasks)
            default: break
            }
            if path.hasPrefix("\(me)/time-records/filtered-by-date?from=") { return conditional("records", timeRecords) }
            let parts = path.split(separator: "?", maxSplits: 1)
            let segs = parts[0].split(separator: "/").map(String.init)
            guard segs.count >= 3, segs[0] == "projects", let pid = Int(segs[1]) else { return .notFound }
            if segs.count == 3, segs[2] == "tasks", let d = data[pid] {
                return conditional("tasks-\(pid)", projectTasks(open: d.open, completed: d.completed, trashed: d.trashed, pid: pid))
            }
            if segs.count == 4, segs[3] == "archive", let d = data[pid] {
                let page = parts.count > 1 ? Int(parts[1].replacingOccurrences(of: "page=", with: "")) ?? 1 : 1
                return archivePage(d.archive, pid: pid, page: page)
            }
            if segs.count == 4, segs[2] == "tasks", let tid = Int(segs[3]) {
                let home: [Int: (pid: Int, number: Int, trashed: Bool)] = [47285: (103, 77, false), 61000: (102, 9, true)]
                guard let h = home[tid] else { return .notFound }
                if h.pid != pid {
                    return StubResponse(status: 301, headers: ["Location": "https://\(host())/api/v1/projects/\(h.pid)/tasks/\(tid)"])
                }
                return .json("{\"single\": \(task(tid, h.pid, h.number, trashed: h.trashed)), \"comments\": [], \"subscribers\": [7]}")
            }
            return .notFound
        }
    }

    /// A server that serves the synthetic instance.
    static func server() -> StubServer {
        let box = HostBox()
        let server = StubServer(router(host: { box.value }))
        box.set(server.host)
        return server
    }

    static func tempCache() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acvoice-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.json")
    }
}

/// Late-bound host name for the router closure.
final class HostBox: Sendable {
    private let stored = Mutex("")
    var value: String { stored.withLock { $0 } }
    func set(_ v: String) { stored.withLock { $0 = v } }
}
