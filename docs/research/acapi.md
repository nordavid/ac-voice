# AC API and web routes for ac-voice v1: verification report

This document uses fantasy names for project codes, company names and distinctive project titles, the same ones as `Tests/Fixtures/projects.sample.json`. Its examples and transcripts follow these names. The real names stay in the git-ignored `Tests/Fixtures/private`. Project, task and user ids are invented as well. Counts and sizes of the instance are rounded or left out.

spikes/ holds unpublished research code and is not part of this repository.

Instance: ActiveCollab 8 (`GET /api/v1/info`, VERIFIED). I used GET requests only. The research reused an existing API token from a local MCP server (format `{userId}-…`, sent as the full `X-Angie-AuthApiToken`); it is not printed here. `/user-session` reports `authenticated_with: ApiSubscription` (VERIFIED).
Working files are in `spikes/acapi`:
- `acget.sh`: GET helper
- `bench.sh`: latency runs
- `prefetch.sh`: parallel fetch of all task lists
- `swift/main.swift`: Swift 6 client sketch that compiles and runs

## General API behaviour (all VERIFIED)
- **Unknown API path** returns **HTTP 500** with `{"type":"RuntimeException","message":"Failed to match '<path>' path."}`, not 404. Treat 500 plus this message as "endpoint does not exist".
- **Unknown task id, or a project with no access** (e.g. `/projects/1/...`) returns **HTTP 404** with an empty body.
- **Pagination headers:** `x-angie-paginationcurrentpage`, `-itemsperpage`, `-totalitems`.
  - `/projects` uses 100 per page. The instance has about 60 active projects, so one page is enough.
  - `/projects/{id}/tasks/archive` uses 30 per page. Adding `per_page` or `limit` to it changes nothing.
- **ETag:** every collection tested sends an ETag. `If-None-Match` returns **304** with 0 bytes.
  - curl: 304 in 50-160 ms. From Swift URLSession it was **23-26 ms**, measured with a manual header and `.reloadIgnoringLocalCacheData`.
  - The ETag string contains the user's e-mail address, so never log it.

## 1. Projects: fields, ranking signals, user relevance

**`GET /projects`** returns `[Project]` (VERIFIED): one item per visible project, below 100 KB, latency below.

Keys and types for project 628:
- `id` int, `name` str, `url_path` str (`/projects/628`), `class` "Project"
- `project_number` int (differs from the id)
- `last_activity_on` int (unix), `updated_on` int, `created_on` int
- `members` [int], `leader_id` int, `company_id` int, `label_id` int, `category_id` int
- `is_completed` bool, `completed_on` null|int, `is_trashed` bool
- `count_tasks` int (= open tasks), `count_discussions`, `count_files`, `count_notes` int
- `member_permissions` str, `is_tracking_enabled`, `is_billable`, `budget`, `budget_type`, `currency_id`
- `body` and `body_formatted` str, `email` str, `subscribers` list, plus a few booleans and `*_by_*` fields

Naming facts across the active projects (VERIFIED):
- Almost all match the pattern `CODE: Title`. Most carry a `[TYPE]` suffix: AGIL, INT, SLA, FIX or CR, with AGIL the most common.
- There are about 30 distinct codes.
- **About a third of the codes are ambiguous.** Most of them cover 2 to 5 projects; the own company code QZ covers about ten. The ambiguous codes are QZ, RBZ, WKT, WWT, IBN, MOLA, TKZ, S+K, BDG, ZMF and "Hollenstein TS".
- Codes are not always acronyms ("Hollenstein TS", "S+K"), so the speech recognizer needs them as custom vocabulary.

Ranking signals (VERIFIED unless noted):
- **`members` is useless for ranking.** The user is a member of every project in the list, because `/projects` only returns projects the user can see.
- **`last_activity_on`** reflects activity by the whole team. It almost always equals `updated_on`. About half of the projects had activity within the last day and most within the last 30 days. It helps only as a tiebreaker.
- **Favorites:**
  - **`GET /favorites`** (a few hundred bytes, ~55-75 ms) returns `[["Project", 628, false], …]`, i.e. `[type, id, bool]`. It lists active and completed projects alike. The bool is always false here; its meaning is ASSUMED unknown.
  - `GET /user-session` also contains `favorites: [{parent_id, parent_type}]`.
- **`GET /users/538/tasks`** (~50 KB, ~90 ms cold, ~42 ms warm) returns `{tasks, subtasks, related{Project,TaskList,Task}, tracked_time}`.
  - It returns the user's own open tasks across several projects, all with `assignee_id == 538`.
  - Task keys include `id`, `project_id`, `task_number`, `task_list_id`, `is_completed`, `is_trashed`, `is_important`, `due_on`, `start_on`, `updated_on`, `labels`, `url_path` (`/projects/{pid}/tasks/{id}`) and `name`.
  - **Yes, it includes `project_id` and `task_number`.**
- **Own time records are the strongest personal signal:**
  - Endpoint: `GET /users/538/time-records/filtered-by-date?from=YYYY-MM-DD&to=YYYY-MM-DD` (~230 ms for 30 days).
  - Each record has `project_id`, `parent_type` (Task or Project), `parent_id` and `record_date`.
  - The last 30 days cover a small set of projects, a much sharper signal than membership or activity.
  - Unfiltered `GET /users/538/time-records` returns the latest 100 records.
- **The WWT case shows that the signals separate well** (values described, not exact):

| id | Favorite | Last activity | Own open tasks | Own time records, 30 days |
|---|---|---|---|---|
| 628 | yes | today | some | many |
| 315 | no | about 1 day | none | none |
| 314 | no | about 1 day | none | none |
| 693 | no | about 1 year | none | none |

- **No "recently visited" endpoint exists.** Each of these returns 500 "Failed to match":
  - `/projects/recent`
  - `/users/538/recently-visited`
  - `/users/538/activity-logs`
  - `/users/538/favorites`
- **`GET /whats-new`** (activity logs) took **21.7 s**. Avoid it.
- **Cheap helpers:**
  - **`GET /projects/names`**: `{ "id": "name" }` for exactly the active projects, a few KB, ~55 ms. Ideal for a cheap name refresh.
  - **`GET /users/538/projects/ids`**: `[int]` with the ids of the user's active and archived projects.
  - **`GET /projects/archive`**: the completed projects.
  - **`GET /user-session`**: one bootstrap call (several hundred KB, ~220 ms cold, ~73 ms warm). It returns `projects` (same objects as `/projects`), `favorites`, `settings`, `users`, `companies`, `job_types`, `projects_total` and `archived_projects_total`. It also **contains a `feed_token` secret**: never log or persist it.

## 2. Ticket by number

**`GET /projects/{id}/tasks`** for 628 (VERIFIED) returns this structure:

`{tasks[open], task_lists, label_ids, project, completed_task_ids, completed_tasks_count, trashed_task_ids, task_max_updated_on}`

- **Open tasks include `task_number`.** Numbers are unique per project.
- **Completed tasks appear only as bare ids.** `completed_task_ids` carries no numbers.
- **Completed tasks with numbers come from `GET /projects/{id}/tasks/archive?page=N`.**
  - The archive returns a plain array with the same keys as open tasks, including `task_number`.
  - It has 30 per page, sorted by `completed_on` descending across all pages.
  - Its ids equal `completed_task_ids` exactly.
  - A page past the end returns `[]`.
  - Task 412 in 628 is completed and was found this way.
- **No lookup by number exists:**
  - `/projects/628/tasks?task_number=412` ignores the parameter and returns the full list (byte-identical response).
  - `…/tasks/number/412`, `…/tasks/by-number/412` and `…/task-number/412` all return 500 "Failed to match".
- **`GET /search?q=412`** (190-430 ms) returns `[{hit, score, highlight}]`. The hits were full-text matches on `body`, and none had task_number 412. Not usable for number lookup.
- `GET /reports/run?type=AssignmentFilter…` returns 404.
- **A bare global id resolves without knowing the project.**
  - `GET /tasks/47285` and `/task/47285` return 500.
  - **`GET /projects/{ANY accessible project}/tasks/{id}` returns HTTP 301** with `Location: https://ac.example.com/api/v1/projects/{realPid}/tasks/{id}`. Examples:
    - `/projects/628/tasks/47285` redirects to project 2032
    - `/projects/315/tasks/47285` redirects to project 2032
    - `/projects/2032/tasks/61834` redirects to project 628
  - This also works for tasks in **archived projects** and for **trashed** tasks. Check `single.is_trashed` before opening.
  - Unknown ids return 404.
  - Latency is **~25 ms warm, ~55 ms cold** when the redirect is not followed. Following it costs ~85 ms in total.
  - The followed response `{single, subscribers, comments, reminders, subtasks, task_list, tracked_time, tracked_expenses}` carries `single.project_id` and `single.task_number`.
- **Local id-to-project map without any archive fetch:** the `/projects/{id}/tasks` responses of all active projects together give every open, completed and trashed id of every active project (VERIFIED: a few thousand open and several thousand completed tasks). A bare id therefore resolves offline, with the 301 probe as fallback for archived projects.
- **Id versus number disambiguation** (VERIFIED from current data):
  - Global task ids reach 5 digits; the oldest ones have fewer.
  - Open `task_number` values stay at 4 digits or fewer across all projects. That completed tasks stay below 10000 is ASSUMED.
  - Rule:
    - A number with 5 or more digits is a global id.
    - A number said together with a project code is a `task_number`.
    - A bare number with 4 or fewer digits is first matched against `/users/538/tasks` `task_number`, then favorites. If it stays ambiguous, show the overlay list.
- **Rejected heuristic:** guessing the id by rank between open-task anchors (ids and numbers are almost monotonic) was right for only **53%** of the completed tasks in 628, with 2 monotonicity breaks (VERIFIED). Use the archive index instead.

## 3. Web route for "Meine Aufgaben"

- **The server returns the same SPA shell for every path.** HTTP 200 with an identical MD5 for `/`, `/my-work`, `/my-tasks`, `/users/538/tasks`, `/projects/628` and `/login` (VERIFIED). The server therefore cannot confirm routes.
- **The route table in the SPA bundle `js/main.<hash>.js`** (React Router) contains (VERIFIED):
  - `my-work`, mounted with `section:"my_work"`
  - `my-updates`, `activity`, `timesheet`
  - `projects/:projectId`, `projects/:projectId/tasks/:id`, `projects/:projectId/tasks/archive`
  - `users/:userId` with child `tasks`
  - `search`
  - There is no `my-tasks`.
- The homepage switch in the bundle maps `case"my_work":return"my-work"`, and the index route redirects to `/${homepage}` (VERIFIED).
- **Best URL: `https://ac.example.com/my-work`, high confidence.** Alternative: `https://ac.example.com/users/538/tasks` (profile task view).
- **Project URL:** `https://ac.example.com/projects/{id}`.
- **Task URL:** `https://ac.example.com/projects/{pid}/tasks/{taskId}`.
  - Modal variant, also built by the SPA itself: `/projects/{pid}?modal=Task-{taskId}-{pid}` (VERIFIED in the bundle).
  - What the SPA does with a wrong `pid` in the web URL is ASSUMED to be inconsistent. Always resolve the correct pid through the API or cache first.

## 4. Latency (VERIFIED)

Measured from a Mac with curl, n=10. Cold means a new TLS connection each time; the TLS handshake alone takes ~30 ms. Warm means a reused keep-alive connection. Sizes are rounded.

| Endpoint | Size | Cold median / p90 | Warm median |
|---|---|---|---|
| `/projects` | ~100 KB | 96 / 177 ms | 42 ms |
| `/projects/628/tasks` | ~100 KB | 122 / 217 ms | 57 ms |
| `/users/538/tasks` | ~50 KB | 93 / 161 ms | 42 ms |
| `/user-session` | several hundred KB | 219 / 287 ms | 73 ms |
| `/projects/628/tasks/archive` (1 page) | ~70 KB | 92 / 166 ms | 33 ms |
| `/projects/{x}/tasks/{id}` (301, not followed) | 0 | 59 / 140 ms | 25 ms |
| any of the above with `If-None-Match` | 0 (304) | 50-160 ms | 23-26 ms (URLSession) |

Bulk fetches:
- `/projects/{id}/tasks` of all active projects, 8 in parallel: **3.4 s**, several MB of raw JSON.
- Archive of 628 (all pages in parallel): curl 0.64 s. Swift TaskGroup: 0.30 s warm, one cold outlier at 1.5 s.
- Archive of the largest project (a few dozen pages, 16 in parallel): 0.98 s.
- Full archive of all projects: a few hundred pages, estimated 5-10 s and a few dozen MB (ASSUMED extrapolation, not run).

## Caching recommendation

The goal is that resolving a voice command never waits on the network.
1. **At app start (background daemon):**
   - Fetch `/projects` (or `/user-session`), `/favorites`, `/users/538/tasks` and `/users/538/time-records/filtered-by-date` (last 30 days). In parallel this takes about 250 ms.
   - Build the project index: parsed code, title, type, favorite flag, own time-record count, own open tasks and `last_activity_on`.
   - Feed the project codes to the speech recognizer as custom vocabulary.
2. **Background, right after:**
   - Fetch `/projects/{id}/tasks` for every active project (about 3.4 s).
   - Keep only `{id, project_id, task_number, is_completed}`, plus the `completed_task_ids` and `trashed_task_ids` for the id-to-project map. That is on the order of ten thousand rows, around 1 MB.
3. **Background, low priority:**
   - Build the archive index (number to id for completed tasks).
   - Do favorites and projects with own time records first, then the rest.
   - Persist to disk, e.g. `~/Library/Application Support/ac-voice/index.json`, so later starts are instant.
4. **Refresh:**
   - On every Stream Deck press, while speech capture runs for 1-3 s, send conditional GETs with ETags for `/projects`, `/favorites` and `/users/538/tasks`. They are mostly 304 and finish in about 25-60 ms.
   - Repeat the same every 5 minutes.
   - Revalidate all task lists every 10-15 minutes. They are mostly 304; run them in parallel.
   - **Update the archive incrementally:** when `completed_task_ids` contains ids missing from the archive index, fetch archive page 1, 2, … until all new ids are covered (the archive is sorted by `completed_on` descending).
   - Drop ids that reappear in `tasks`, because reopened tasks move back to the open list.
5. **On a miss (project and number not in the index):**
   - Fetch that project's archive pages in parallel (0.3-1 s) and show a "Suche Ticket …" state in the overlay.
   - For a bare global id missing from the map, use the 301 probe (about 25 ms).
6. **Keep the HTTP/2 or keep-alive connection warm**, e.g. through the 5-minute refresh. This saves the ~30 ms TLS handshake plus the cold-start penalty, roughly halving latency.

## Swift client sketch (VERIFIED: compiles with `swiftc -swift-version 6`, Swift 6.4.2, and ran against the instance)

Full file: `spikes/acapi/swift/main.swift`. It contains the models, ETag GET, the 301 resolver and the parallel archive fetch.

Run output:
- All projects in 0.17-0.24 s
- 304 revalidation in 25 ms
- Favorites loaded
- 628: open tasks and completed ids in 70-140 ms
- 47285 resolved to project 2032 in 26 ms
- Archive of 628: all completed tasks, number 412 resolved, in 0.30 s

The core of the 301 resolver:
```swift
final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
// GET /projects/{anyAccessiblePid}/tasks/{id}: 200 -> same pid, 301 -> parse Location, 404 -> unknown
let (_, resp) = try await session.data(for: request("/projects/\(probePid)/tasks/\(taskId)"), delegate: NoRedirect())
if let http = resp as? HTTPURLResponse, http.statusCode == 301,
   let loc = http.value(forHTTPHeaderField: "Location"),
   let m = loc.firstMatch(of: /\/projects\/(\d+)\/tasks\/\d+/) { return Int(m.1) }
```

## Open points for the architect
- **Token:** reusing an existing API token works (VERIFIED). Issuing its own token through `POST /issue-token` is ASSUMED to work the same way; I did not test it because of the GET-only rule. (The app now signs in this way, see PLAN 2.2.)
- **Chrome:** setting the URL of an existing AC tab reloads the whole SPA (a large `main.js` bundle, browser-cached). Switching routes in-page without a reload would need JavaScript inside the tab. Both points are ASSUMED and not tested.
- **Auto-pick versus list:** the signals separate 628 clearly from the other WWT projects. Whether to auto-open on a clear score lead or always show the numbered list is a product decision.
