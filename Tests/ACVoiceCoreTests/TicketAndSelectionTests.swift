import Foundation
import Testing
@testable import ACVoiceCore

@Suite struct TicketResolverTests {
    typealias F = Fixture
    static let wwt = [628, 314, 315, 693]

    /// 628 #412 completed, 314 #412 open, 315 #58 open, own #530 in 628; 693's archive is not indexed yet.
    static var index: TaskIndex {
        var i = TaskIndex()
        i.add(TaskRef(id: 50_000, projectId: 628, number: 412, isCompleted: true))
        i.add(TaskRef(id: 45_000, projectId: 314, number: 412))
        i.add(TaskRef(id: 41_000, projectId: 315, number: 58))
        i.add(TaskRef(id: 47_285, projectId: 2032, number: 7))
        i.archiveComplete = [628, 315, 314]
        i.mine = [TaskRef(id: 61_834, projectId: 628, number: 530)]
        i.trashed = [63_000]
        return i
    }
    static var completeIndex: TaskIndex {
        var i = index
        i.archiveComplete = Set(F.projects.map(\.id))
        return i
    }

    func ticket(_ s: String, index: TaskIndex = Self.index, active: Int? = nil, fetched: Bool = false,
                attempted: Set<Int> = []) -> TicketOutcome {
        guard let req = F.request(s) else { return .notFound }
        return F.interpreter.ticket(req, index: index, activeProjectId: active, archivesFetched: fetched,
                                    attemptedArchives: attempted, now: F.now)
    }

    /// The Flow's fetch loop with fetches that never complete an archive (empty or failed): attempted ids only.
    func loop(_ s: String, index: TaskIndex = Self.index, active: Int? = nil) -> (TicketOutcome, rounds: Int) {
        var attempted = Set<Int>(), rounds = 0
        while true {
            let o = ticket(s, index: index, active: active, attempted: attempted)
            guard case .fetchArchive(let ids) = o, rounds < 100 else { return (o, rounds) }
            #expect(attempted.isDisjoint(with: ids) && !ids.isEmpty, "\(s): repeated \(ids.filter(attempted.contains))")
            attempted.formUnion(ids); rounds += 1
        }
    }

    @Test func attemptedArchivesEndTheLoop() {
        // Review: with `archivesFetched: Bool` only, an archive fetch that never marked completeness looped forever.
        #expect(ticket("Öffne WWT Ticket 999", attempted: [693]) == .notFound)
        let scoped = loop("Öffne WWT Ticket 999")
        #expect(scoped.0 == .notFound && scoped.rounds == 1)
        let bare = loop("Ticket 77")
        #expect(bare.0 == .notFound && bare.rounds == 1)
        #expect(loop("Ticket 999").0 == .probe(taskId: 999))
        let (o, rounds) = loop("Ticket 58", active: 2001)
        #expect(o == .open(projectId: 315, taskId: 41_000) && rounds <= 3)
        for s in ["Ticket 412", "Ticket 530", "Öffne WWT Ticket 412", "Ticket 12 im TYPO 3 von WWT", "Ticket 7"] {
            for active in [nil, 628, 693, 2001] {
                let r = loop(s, active: active)
                #expect(r.rounds <= 3, "\(s) active \(active ?? 0): \(r.rounds) rounds")
            }
        }
    }

    @Test func trashedSetHidesHits() {
        // Review: a task listed in `trashed_task_ids` but without the flag showed up in `.choices`.
        var i = Self.completeIndex
        i.add(TaskRef(id: 1, projectId: 628, number: 77))
        i.add(TaskRef(id: 2, projectId: 314, number: 77))
        i.trashed.insert(1)
        #expect(ticket("Öffne WWT Ticket 77", index: i) == .open(projectId: 314, taskId: 2))
        #expect(ticket("Ticket 77", index: i, active: 628) == .open(projectId: 314, taskId: 2))
        i.mine = [TaskRef(id: 1, projectId: 628, number: 77)]
        #expect(ticket("Ticket 77", index: i) == .open(projectId: 314, taskId: 2))
    }
    let ref412done = TaskRef(id: 50_000, projectId: 628, number: 412, isCompleted: true)
    let ref412open = TaskRef(id: 45_000, projectId: 314, number: 412)

    @Test func projectScoped() {
        // Two hits, but 693's archive could still hide a #412: fetch first.
        #expect(ticket("Öffne WWT Ticket 412") == .fetchArchive(projectIds: [693]))
        // After the fetch: open before completed.
        #expect(ticket("Öffne WWT Ticket 412", fetched: true) == .choices([ref412open, ref412done]))
        // The active tab project ranks first.
        #expect(ticket("Öffne WWT Ticket 412", active: 628, fetched: true) == .choices([ref412done, ref412open]))
        // Implicit "<project> <number>" behaves the same.
        #expect(ticket("Öffne WWT 412", fetched: true) == .choices([ref412open, ref412done]))
    }

    @Test func singleHitWaitsForSiblingArchives() {
        // REVIEW M6: one open hit no longer opens while a sibling archive is incomplete...
        #expect(ticket("Öffne WWT Ticket 58") == .fetchArchive(projectIds: [693]))
        #expect(ticket("Öffne WWT Ticket 58", fetched: true) == .open(projectId: 315, taskId: 41_000))
        // ...unless it is in the active tab project or one of the own tasks.
        #expect(ticket("Öffne WWT Ticket 58", active: 315) == .open(projectId: 315, taskId: 41_000))
        #expect(ticket("Öffne WWT Ticket 530") == .open(projectId: 628, taskId: 61_834))
        #expect(ticket("Öffne WWT Relaunch Ticket 412") == .open(projectId: 628, taskId: 50_000))
    }

    @Test func notFoundAndUnrecognized() {
        #expect(ticket("Öffne WWT Ticket 999") == .fetchArchive(projectIds: [693]))
        #expect(ticket("Öffne WWT Ticket 999", fetched: true) == .notFound)
        // Project words that match nothing never widen to a global search.
        #expect(ticket("Öffne Disney Ticket 58") == .projectNotRecognized)
    }

    @Test func globalIds() {
        #expect(ticket("Ticket 47285") == .open(projectId: 2032, taskId: 47_285))
        #expect(ticket("Öffne WWT Ticket 47285") == .open(projectId: 2032, taskId: 47_285))   // id wins over project words
        #expect(ticket("Ticket 63001") == .probe(taskId: 63_001))
        #expect(ticket("Ticket 63000") == .trashed(taskId: 63_000))
    }

    @Test func bareNumbers() {
        #expect(ticket("Ticket 530") == .open(projectId: 628, taskId: 61_834))                     // own open task
        #expect(ticket("Ticket 412", active: 314) == .open(projectId: 314, taskId: 45_000))       // active tab first
        #expect(ticket("Ticket 412", active: 693) == .fetchArchive(projectIds: [693]))           // active archive first
        #expect(ticket("Ticket 58", index: Self.completeIndex) == .open(projectId: 315, taskId: 41_000))
        // A single favorite hit opens (PLAN 5 cascade: own tasks, favorites, all projects).
        #expect(ticket("Ticket 412", index: Self.completeIndex) == .open(projectId: 628, taskId: 50_000))
        // Several hits outside the favorites: open before completed.
        var two = Self.completeIndex
        two.add(TaskRef(id: 46_000, projectId: 2001, number: 58, isCompleted: true))
        #expect(ticket("Ticket 58", index: two).choicesIds == [41_000, 46_000])
        // Hits while archives are incomplete: fetch (favorites and personal projects first, idle ones last), then decide.
        if case .fetchArchive(let ids) = ticket("Ticket 58") {
            #expect(ids.first == 2011 && ids.last == 2119 && ids.contains(693) && !ids.contains(315))
        } else { Issue.record("expected fetchArchive") }
        #expect(ticket("Ticket 58", fetched: true) == .open(projectId: 315, taskId: 41_000))
        #expect(ticket("Ticket 9999", index: Self.completeIndex) == .probe(taskId: 9999))
        #expect(ticket("Ticket 77", index: Self.completeIndex) == .notFound)
    }

    @Test func lowConfidenceAsksFirst() {
        #expect(ticket("Ticket 530 und 5") == .choices([TaskRef(id: 61_834, projectId: 628, number: 530)]))
        #expect(ticket("Ticket 47285 und 5") == .choices([TaskRef(id: 47_285, projectId: 2032, number: 7)]))
    }

    @Test func ownTasksRankFirst() {
        var i = Self.completeIndex
        i.mine = [TaskRef(id: 50_000, projectId: 628, number: 412, isCompleted: true)]
        #expect(ticket("Ticket 412 WWT", index: i).choicesIds == [50_000, 45_000])
    }

    @Test func indexDecodingIsTolerant() throws {
        let old = #"{"byProject":{"628":{"412":{"id":1,"projectId":628,"number":412,"isCompleted":false,"isTrashed":false}}}}"#
        let i = try JSONDecoder().decode(TaskIndex.self, from: Data(old.utf8))
        #expect(i.task(project: 628, number: 412)?.id == 1 && i.trashed.isEmpty && i.mine.isEmpty)
        let round = try JSONDecoder().decode(TaskIndex.self, from: JSONEncoder().encode(Self.index))
        #expect(round == Self.index)
    }
}

extension TicketOutcome {
    var choicesIds: [Int] { if case .choices(let l) = self { return l.map(\.id) }; return [] }
}

@Suite struct SelectionTests {
    let list = [628, 315, 314, 693]
    func sel(_ s: String..., list: [Int]? = nil) -> SelectionOutcome {
        Fixture.interpreter.selection(s.map { Hypothesis($0) }, candidates: list ?? self.list, now: Fixture.now)
    }

    @Test func numbers() {
        #expect(sel("Zwei.") == .pick(1)); #expect(sel("2.") == .pick(1)); #expect(sel("zwo") == .pick(1))
        #expect(sel("die zweite") == .pick(1)); #expect(sel("Nummer drei") == .pick(2)); #expect(sel("die letzte") == .pick(3))
        #expect(sel("eins") == .pick(0)); #expect(sel("nein, die zweite") == .pick(1)); #expect(sel("Ne, die Vier") == .pick(3))
        #expect(sel("nö, die erste") == .pick(0)); #expect(sel("", "Eins.") == .pick(0))   // ST empty, DT heard it
    }

    @Test func confirmWordsOnlyForOneItem() {
        // REVIEW m3: ambient "Ja." must not pick #1 of a longer list.
        #expect(sel("Ja.") == .keepListening); #expect(sel("Genau") == .keepListening)
        #expect(sel("ja", list: [628]) == .pick(0)); #expect(sel("Passt.", list: [628]) == .pick(0))
    }

    @Test func negationKeepsListening() {
        #expect(sel("Nein.") == .keepListening); #expect(sel("nee") == .keepListening)
        #expect(sel("Nein.", "Nein, die zweite") == .pick(1))
        #expect(sel("nein, abbrechen") == .cancel)
    }

    @Test func noFreiLookalike() { #expect(sel("Frei.") == .unclear) }

    @Test func names() {
        #expect(sel("Relaunch") == .pick(0)); #expect(sel("Relonch.") == .pick(0)); #expect(sel("nö, Relaunch") == .pick(0))
        #expect(sel("Grand Navigation") == .pick(3)); #expect(sel("Braun Navigation") == .pick(3))
        #expect(sel("Maintenance") == .pick(2))
        #expect(sel("Website") == .narrow([0, 1]))
    }

    func sel(_ hyps: [(String, Double)]) -> SelectionOutcome {
        Fixture.interpreter.selection(hyps.map { Hypothesis($0.0, weight: $0.1) }, candidates: list, now: Fixture.now)
    }

    @Test func bestHypothesesDecideFirst() {
        // Review: a 0.9 alternative "drei" beat two best hypotheses that agree on a name.
        #expect(sel([("Relaunch", 1), ("Relaunch", 1), ("drei", 0.9)]) == .pick(0))
        #expect(sel([("drei", 0.9), ("Relaunch", 1)]) == .pick(0))
        // A best "nein" or a new command is not overridden by a lookalike number of an alternative.
        #expect(sel([("Nein.", 1), ("Eins.", 0.9)]) == .keepListening)
        if case .command = sel([("Ticket 47285", 1), ("zwei", 0.9)]) {} else { Issue.record("expected new command") }
        #expect(sel([("abbrechen", 1), ("zwei", 0.9)]) == .cancel)
        // Best hypotheses unclear: the alternative's number counts.
        #expect(sel([("Hi.", 1), ("zwei", 0.9)]) == .pick(1))
        #expect(sel([("zwei", 0.9)]) == .pick(1))
        // Inside a list the best hypotheses narrowed to, the alternative's number picks; outside it, narrow.
        #expect(sel([("Website", 1), ("zwei", 0.9)]) == .pick(1))
        #expect(sel([("Website", 1), ("drei", 0.9)]) == .narrow([0, 1]))
        // Best-weight numbers still win at once.
        #expect(sel([("zwei", 1), ("drei", 1)]) == .pick(1))
    }

    @Test func control() {
        #expect(sel("abbrechen") == .cancel); #expect(sel("Hi.") == .unclear); #expect(sel("mehr") == .more)
        if case .command = sel("nein, öffne TKZ") {} else { Issue.record("expected new command") }
        if case .command = sel("Ticket 47285") {} else { Issue.record("expected new command") }
    }
}
