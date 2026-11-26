import Foundation

// AC v8 wire models: only the fields ac-voice needs, everything else is ignored.
// Decoding is tolerant: optional fields fall back to defaults, and a broken element in a list is skipped
// instead of failing the whole response (`LossyList`).

/// GET /projects item.
public struct ACProject: Sendable, Equatable, Decodable {
    public var id: Int
    public var name: String
    public var companyId: Int?
    /// Unix seconds of the last team activity.
    public var lastActivityOn: Int?
    public var isCompleted: Bool
    public var isTrashed: Bool

    public init(id: Int, name: String, companyId: Int? = nil, lastActivityOn: Int? = nil,
                isCompleted: Bool = false, isTrashed: Bool = false) {
        self.id = id; self.name = name; self.companyId = companyId; self.lastActivityOn = lastActivityOn
        self.isCompleted = isCompleted; self.isTrashed = isTrashed
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case companyId = "company_id", lastActivityOn = "last_activity_on"
        case isCompleted = "is_completed", isTrashed = "is_trashed"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        companyId = (try? c.decodeIfPresent(Int.self, forKey: .companyId)) ?? nil
        lastActivityOn = (try? c.decodeIfPresent(Int.self, forKey: .lastActivityOn)) ?? nil
        isCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .isCompleted)) ?? false
        isTrashed = (try? c.decodeIfPresent(Bool.self, forKey: .isTrashed)) ?? false
    }
}

/// A task as listed by /projects/{id}/tasks, /projects/{id}/tasks/archive and /users/{me}/tasks.
public struct ACTask: Sendable, Equatable, Decodable {
    public var id: Int
    public var projectId: Int
    public var taskNumber: Int
    public var isCompleted: Bool
    public var isTrashed: Bool

    public init(id: Int, projectId: Int, taskNumber: Int, isCompleted: Bool = false, isTrashed: Bool = false) {
        self.id = id; self.projectId = projectId; self.taskNumber = taskNumber
        self.isCompleted = isCompleted; self.isTrashed = isTrashed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id", taskNumber = "task_number"
        case isCompleted = "is_completed", isTrashed = "is_trashed"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        projectId = try c.decode(Int.self, forKey: .projectId)
        taskNumber = try c.decode(Int.self, forKey: .taskNumber)
        isCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .isCompleted)) ?? false
        isTrashed = (try? c.decodeIfPresent(Bool.self, forKey: .isTrashed)) ?? false
    }
}

/// GET /projects/{id}/tasks: open tasks with numbers, completed and trashed tasks as bare ids.
public struct ACProjectTasks: Sendable, Equatable, Decodable {
    public var tasks: [ACTask]
    public var completedTaskIds: [Int]
    public var trashedTaskIds: [Int]
    public var completedTasksCount: Int?

    public init(tasks: [ACTask], completedTaskIds: [Int] = [], trashedTaskIds: [Int] = [], completedTasksCount: Int? = nil) {
        self.tasks = tasks; self.completedTaskIds = completedTaskIds; self.trashedTaskIds = trashedTaskIds
        self.completedTasksCount = completedTasksCount
    }

    enum CodingKeys: String, CodingKey {
        case tasks
        case completedTaskIds = "completed_task_ids", trashedTaskIds = "trashed_task_ids"
        case completedTasksCount = "completed_tasks_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = (try c.decodeIfPresent(LossyList<ACTask>.self, forKey: .tasks))?.items ?? []
        completedTaskIds = (try? c.decodeIfPresent(LossyList<Int>.self, forKey: .completedTaskIds))?.items ?? []
        trashedTaskIds = (try? c.decodeIfPresent(LossyList<Int>.self, forKey: .trashedTaskIds))?.items ?? []
        completedTasksCount = (try? c.decodeIfPresent(Int.self, forKey: .completedTasksCount)) ?? nil
    }
}

/// GET /favorites item: `["Project", 628, false]`. The object form of /user-session
/// (`{"parent_type": "Project", "parent_id": 628}`) decodes as well.
public struct ACFavorite: Sendable, Equatable, Decodable {
    public var parentType: String
    public var parentId: Int

    public init(parentType: String, parentId: Int) { self.parentType = parentType; self.parentId = parentId }

    enum CodingKeys: String, CodingKey { case parentType = "parent_type", parentId = "parent_id" }

    public init(from decoder: any Decoder) throws {
        if var u = try? decoder.unkeyedContainer() {
            parentType = try u.decode(String.self)
            parentId = try u.decode(Int.self)
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            parentType = try c.decode(String.self, forKey: .parentType)
            parentId = try c.decode(Int.self, forKey: .parentId)
        }
    }
}

/// GET /users/{me}/tasks: `{tasks, subtasks, related, tracked_time}`; only `tasks` is used.
public struct ACUserTasks: Sendable, Equatable, Decodable {
    public var tasks: [ACTask]
    public init(tasks: [ACTask]) { self.tasks = tasks }
    enum CodingKeys: String, CodingKey { case tasks }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = (try c.decodeIfPresent(LossyList<ACTask>.self, forKey: .tasks))?.items ?? []
    }
}

/// One own time record (GET /users/{me}/time-records/filtered-by-date).
public struct ACTimeRecord: Sendable, Equatable, Decodable {
    public var projectId: Int
    /// Unix seconds.
    public var recordDate: Int?
    public var isTrashed: Bool

    public init(projectId: Int, recordDate: Int? = nil, isTrashed: Bool = false) {
        self.projectId = projectId; self.recordDate = recordDate; self.isTrashed = isTrashed
    }

    enum CodingKeys: String, CodingKey { case projectId = "project_id", recordDate = "record_date", isTrashed = "is_trashed" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decode(Int.self, forKey: .projectId)
        recordDate = (try? c.decodeIfPresent(Int.self, forKey: .recordDate)) ?? nil
        isTrashed = (try? c.decodeIfPresent(Bool.self, forKey: .isTrashed)) ?? false
    }
}

/// `{"time_records": [...], "related": {...}}` [V]; a plain array is accepted too.
public struct ACTimeRecords: Sendable, Equatable, Decodable {
    public var records: [ACTimeRecord]
    public init(records: [ACTimeRecord]) { self.records = records }
    enum CodingKeys: String, CodingKey { case timeRecords = "time_records" }
    public init(from decoder: any Decoder) throws {
        if let list = try? LossyList<ACTimeRecord>(from: decoder) {
            records = list.items
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            records = (try c.decodeIfPresent(LossyList<ACTimeRecord>.self, forKey: .timeRecords))?.items ?? []
        }
    }
}

/// GET /companies item.
public struct ACCompany: Sendable, Equatable, Decodable {
    public var id: Int
    public var name: String
    /// The agency's own company.
    public var isOwner: Bool
    public var isArchived: Bool
    public var isTrashed: Bool

    public init(id: Int, name: String, isOwner: Bool = false, isArchived: Bool = false, isTrashed: Bool = false) {
        self.id = id; self.name = name; self.isOwner = isOwner; self.isArchived = isArchived; self.isTrashed = isTrashed
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case isOwner = "is_owner", isArchived = "is_archived", isTrashed = "is_trashed"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isOwner = (try? c.decodeIfPresent(Bool.self, forKey: .isOwner)) ?? false
        isArchived = (try? c.decodeIfPresent(Bool.self, forKey: .isArchived)) ?? false
        isTrashed = (try? c.decodeIfPresent(Bool.self, forKey: .isTrashed)) ?? false
    }
}

/// GET /projects/{pid}/tasks/{id}: `{single, subscribers, comments, ...}`; only `single` is used.
struct ACTaskDetails: Sendable, Decodable {
    var single: ACTask
}

/// One archive page (30 tasks, newest completion first) plus the pagination headers.
public struct ACArchivePage: Sendable, Equatable {
    public var tasks: [ACTask]
    /// `X-Angie-PaginationTotalItems`, when sent.
    public var totalItems: Int?
    /// `X-Angie-PaginationItemsPerPage`, when sent.
    public var perPage: Int?
    public init(tasks: [ACTask], totalItems: Int? = nil, perPage: Int? = nil) {
        self.tasks = tasks; self.totalItems = totalItems; self.perPage = perPage
    }
}

/// A JSON array whose undecodable elements are skipped.
struct LossyList<T: Decodable & Sendable>: Decodable, Sendable {
    var items: [T]
    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        if let n = c.count { out.reserveCapacity(n) }
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) {
                out.append(v)
            } else if (try? c.decode(Skip.self)) == nil {
                break   // cannot advance; never loop forever
            }
        }
        items = out
    }
    /// Consumes one element of any shape (the explicit empty init never touches a container).
    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}
