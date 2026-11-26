import ACVoiceCore
import Foundation
import Testing
@testable import ACVoiceAC

@Suite("Mapping to Core types")
struct MappingTests {
    let now = Date(timeIntervalSince1970: 1_764_000_000)

    /// The synthetic instance as a snapshot, built by hand (no network).
    func snapshot() -> IndexSnapshot {
        var s = IndexSnapshot(baseURL: URL(string: "https://ac.example.test")!, userId: 7)
        s.projects = [
            ProjectRecord(id: 101, name: "ABC: Website Relaunch [AGIL]", companyId: 11, lastActivity: now.addingTimeInterval(-3600)),
            ProjectRecord(id: 102, name: "ABC: Maintenance [SLA]", companyId: 11),
            ProjectRecord(id: 103, name: "XYZ: Shop Rollout [AGIL]", companyId: 12, lastActivity: now.addingTimeInterval(-200 * 86_400)),
            ProjectRecord(id: 104, name: "QZ: Intern Tools [INT]", companyId: 1),
            ProjectRecord(id: 105, name: "Muster Kampagne", companyId: 13),
        ]
        s.companies = [1: CompanyRecord(name: "Beispielagentur GmbH", isOwner: true),
                       11: CompanyRecord(name: "Alpha Beta Chemie GmbH & Co. KG"),
                       12: CompanyRecord(name: "Xylo Systems AG"),
                       13: CompanyRecord(name: "Muster e.V.")]
        s.favorites = [101, 999]
        s.timeRecords30d = [101: 12, 103: 1]
        s.mine = [TaskRef(id: 5001, projectId: 101, number: 12)]
        return s
    }

    @Test("entries carry favorites, time records, own tasks, team activity and ac-voice opens")
    func signals() {
        var h = History()
        h.recordOpen(projectId: 103, at: now.addingTimeInterval(-86_400))
        let e = Dictionary(uniqueKeysWithValues: snapshot().entries(history: h).map { ($0.id, $0) })
        #expect(e.count == 5)
        #expect(e[101]?.signals == Signals(favorite: true, timeRecords30d: 12, ownOpenTasks: 1,
                                           lastActivity: now.addingTimeInterval(-3600)))
        #expect(e[101]?.signals.tier(now: now) == 7)          // favorite 3 + records 3 + own task 1
        #expect(e[103]?.signals.recentOpens == [now.addingTimeInterval(-86_400)])
        #expect(e[103]?.signals.tier(now: now) == 1)          // records 1 + open 1 - stale 1
        #expect(e[101]?.code == "ABC" && e[101]?.type == "AGIL")
        #expect(e[105]?.code == nil)
    }

    @Test("aliases: company per project, config per code, learned from picks")
    func aliases() {
        var config = Config()
        config.aliases = ["ABC": ["alfa"]]
        var h = History()
        h.recordPick(query: "zylo shop", projectId: 103)
        h.recordPick(query: "zylo shop", projectId: 103)
        let e = Dictionary(uniqueKeysWithValues: snapshot().entries(config: config, history: h).map { ($0.id, $0) })
        #expect(e[101]?.aliases == ["Alpha Beta Chemie", "Alpha Beta", "alfa"])
        #expect(e[102]?.aliases == ["Alpha Beta Chemie", "Alpha Beta", "alfa"])
        #expect(e[103]?.aliases == ["Xylo Systems", "zylo"])
        #expect(e[104]?.aliases == [])                         // the agency's own company is never an alias
        #expect(e[105]?.aliases == ["Muster"])

        config.learnAliases = false
        let off = snapshot().entries(config: config, history: h, companyAliases: false)
        #expect(off.first { $0.id == 103 }?.aliases == [])
        #expect(off.first { $0.id == 101 }?.aliases == ["alfa"])
    }

    @Test("company aliases resolve through the Core interpreter")
    func aliasResolution() {
        let interp = snapshot().interpreter()
        #expect(Regression.describe(interp.command([Hypothesis("Öffne Xylo Systems")], now: now)) == "unique 103")
        #expect(Regression.describe(interp.command([Hypothesis("Alpha Beta")], now: now)) == "choices 101,102")
        #expect(Regression.describe(interp.command([Hypothesis("Öffne das ABC-Projekt")], now: now)) == "choices 101,102")
        #expect(Regression.describe(interp.command([Hypothesis("ABC Relaunch")], now: now)) == "unique 101")
    }

    @Test("company names lose the legal form; long names get a two-word alias")
    func companyNames() {
        #expect(CompanyAliases.make("Alpha Beta Chemie GmbH & Co. KG") == ["Alpha Beta Chemie", "Alpha Beta"])
        #expect(CompanyAliases.make("Xylo Systems AG") == ["Xylo Systems"])
        #expect(CompanyAliases.make("Muster e.V.") == ["Muster"])
        #expect(CompanyAliases.make("Foo Bar (Deutschland) GmbH") == ["Foo Bar"])
        #expect(CompanyAliases.make("Smith & Co") == ["Smith"])
        #expect(CompanyAliases.make("Müller und Söhne GmbH") == ["Müller und Söhne"])
        #expect(CompanyAliases.make("AB GmbH") == [])
        #expect(CompanyAliases.make("Eins Zwei Drei Vier Fuenf GmbH") == [])
        #expect(CompanyAliases.make("Stadtwerke, Netz") == ["Stadtwerke Netz"])
    }

    @Test("company aliases that collide with codes or other titles are dropped")
    func companyConflicts() {
        var s = snapshot()
        s.companies[11] = CompanyRecord(name: "ABC GmbH")     // equals the code of its own projects
        s.companies[12] = CompanyRecord(name: "Kampagne AG")  // a title word of company 13's project
        s.companies[13] = CompanyRecord(name: "QZ Partner")   // two words: allowed
        let map = s.companyAliasMap()
        #expect(map[11] == nil)
        #expect(map[12] == nil)
        #expect(map[13] == ["QZ Partner"])
        #expect(map[1] == nil)
    }

    @Test("task index: open wins over archive, stale archive rows dropped, unreachable ids complete the archive")
    func taskIndex() {
        var s = snapshot()
        var st = ProjectTaskState()
        st.open = [TaskRow(id: 1, number: 5)]
        st.completedIds = [2, 3, 4]
        st.trashedIds = [7]
        st.mergeArchive([TaskRow(id: 2, number: 4), TaskRow(id: 9, number: 8), TaskRow(id: 4, number: 5)])
        st.fetchedAt = now
        st.normalize()
        #expect(st.archived.map(\.id) == [2, 4])              // 9 is no longer completed
        #expect(st.missingArchiveIds == [3])
        s.projectTasks[101] = st
        s.probed[70000] = TaskRef(id: 70000, projectId: 555, number: 3)
        s.rebuildTasks()
        var t = s.tasks
        #expect(t.byProject[101]?[5] == TaskRef(id: 1, projectId: 101, number: 5))
        #expect(t.byProject[101]?[4] == TaskRef(id: 2, projectId: 101, number: 4, isCompleted: true))
        #expect(t.projectOfTask[3] == 101 && t.projectOfTask[7] == 101 && t.projectOfTask[70000] == 555)
        #expect(t.projectOfTask[5001] == 101)                 // own task
        #expect(t.trashed == [7])
        #expect(t.archiveComplete.isEmpty)
        #expect(t.mine == s.mine)

        s.projectTasks[101]?.unreachable = [3]
        s.rebuildTasks()
        t = s.tasks
        #expect(t.archiveComplete == [101])
        // A project without a fetched task list is never complete.
        s.projectTasks[102] = ProjectTaskState()
        s.rebuildTasks()
        #expect(!s.tasks.archiveComplete.contains(102))
    }

    @Test("archive priority: favorites, time records, own tasks, id")
    func priority() {
        var s = snapshot()
        s.mine.append(TaskRef(id: 9, projectId: 105, number: 1))
        #expect(s.archivePriority() == [101, 103, 105, 102, 104])
    }

    @Test("stats count without names")
    func stats() {
        let st = snapshot().stats
        #expect(st.projects == 5 && st.favorites == 2 && st.activeFavorites == 1)
        #expect(st.ownOpenTasks == 1 && st.timeRecords == 13 && st.timeRecordProjects == 2)
    }
}
