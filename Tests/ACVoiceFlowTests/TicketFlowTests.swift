import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

/// Ticket flows (PLAN 5, REVIEW M6): archive fetch, probe, trashed, project not recognized.
@Suite struct TicketFlowTests {
    @Test func archiveFetchThenOpen() {
        var h = Harness()
        h.command("Öffne WWT Ticket 58")
        #expect(h.phase == .processing && h.state.phase == .processing)
        #expect(h.model.message == "Suche Ticket 58 …" && h.state.message == "Suche Ticket 58 …")
        let r = h.pendingRequest!
        #expect(h.has(.fetchArchive(projectIds: [693], request: r)) && h.dueIs(.archive, 4.0))
        #expect(h.micOn)   // a list may follow
        h.env.index.archiveComplete.insert(693)
        h.send(.archiveFetched(request: r, complete: true))
        #expect(h.phase == .opening && h.opened == Fixture.taskURL(315, 41_000))
        #expect(h.model.preview == "Ticket 58 · WWT: TYPO3 Website maintenance")
        h.send(.opened(request: h.pendingRequest!, .reused))
        #expect(h.has(.recordOpen(projectId: 315)))
    }

    @Test func incompleteArchiveDecidesWithWhatIsIndexed() {
        var h = Harness()
        h.command("Öffne WWT Ticket 58")
        h.send(.archiveFetched(request: h.pendingRequest!, complete: false))
        #expect(h.opened == Fixture.taskURL(315, 41_000))
    }

    @Test func archiveWatchdogDecidesWithWhatIsIndexed() {
        var h = Harness()
        h.command("Öffne WWT Ticket 58")
        h.advance(3.9)
        #expect(h.phase == .processing)
        h.advance(0.2)
        #expect(h.opened == Fixture.taskURL(315, 41_000))
    }

    @Test func archiveFetchThenChoices() {
        var h = Harness()
        h.command("Öffne WWT Ticket 412")
        h.env.index.archiveComplete.insert(693)
        h.send(.archiveFetched(request: h.pendingRequest!, complete: true))
        #expect(h.phase == .choices && h.model.choices.map(\.target.projectId) == [314, 628])
        // "Website Relaunch" does not fit 12 characters: the longest distinctive word wins.
        #expect(h.model.choices.map(\.label) == ["Maintenance", "Relaunch"])
        #expect(h.gen == SpeechGen(session: 1, utterance: 2))
        h.say("zwei")
        #expect(h.opened == Fixture.taskURL(628, 50_000))
    }

    @Test func archiveFetchThenNotFoundNamesTheCode() {
        var h = Harness()
        h.command("Öffne WWT Ticket 999")
        h.env.index.archiveComplete.insert(693)
        h.send(.archiveFetched(request: h.pendingRequest!, complete: true))
        #expect(h.phase == .error && h.model.message == "WWT hat kein Ticket 999")
    }

    @Test func staleArchiveResultIsIgnored() {
        var h = Harness()
        h.command("Öffne WWT Ticket 58")
        #expect(h.send(.archiveFetched(request: h.pendingRequest! + 1, complete: true)).isEmpty)
        #expect(h.phase == .processing)
    }

    /// Every fetched id counts as attempted whatever the result (`attemptedArchives`): an AC layer that never marks
    /// the archive complete does not make the flow ask for it again.
    @Test func attemptedArchivesEndTheSearch() {
        var h = Harness()
        h.command("Öffne WWT Ticket 999")
        #expect(h.has(.fetchArchive(projectIds: [693], request: h.pendingRequest!)))
        h.send(.archiveFetched(request: h.pendingRequest!, complete: true))   // index unchanged
        #expect(h.phase == .error && h.model.message == "WWT hat kein Ticket 999")
    }

    /// A bare number searches the active tab project, then everything else; each round names only new projects, and
    /// `maxArchiveRounds` bounds the wait.
    @Test func archiveRoundsNameNewProjectsAndAreBounded() {
        func fetches(_ h: Harness) -> [[Int]] {
            h.all.compactMap { if case let .fetchArchive(p, _) = $0 { return p }; return nil }
        }
        var h = Harness(activeProjectId: 693)
        h.command("Ticket 999")
        h.send(.archiveFetched(request: h.pendingRequest!, complete: true))
        let rounds = fetches(h)
        #expect(rounds.count == 2 && rounds[0] == [693] && !rounds[1].contains(693) && !rounds[1].isEmpty)
        h.send(.archiveFetched(request: h.pendingRequest!, complete: true))
        // Nothing indexed anywhere: a number above the smallest id may still be a global id.
        #expect(h.has(.probeTask(taskId: 999, request: h.pendingRequest!)))

        var t = FlowTimings()
        t.maxArchiveRounds = 1
        var bounded = Harness(timings: t, activeProjectId: 693)
        bounded.command("Ticket 999")
        bounded.send(.archiveFetched(request: bounded.pendingRequest!, complete: true))
        #expect(fetches(bounded).count == 1 && bounded.has(.probeTask(taskId: 999, request: bounded.pendingRequest!)))
    }

    /// An AC error ends the search and replaces "nicht gefunden"; a hit still opens.
    @Test func archiveErrorMessage() {
        var a = Harness()
        a.command("Öffne WWT Ticket 999")
        a.send(.archiveFetched(request: a.pendingRequest!, complete: false, message: "AC lehnt den Token ab"))
        #expect(a.phase == .error && a.model.message == "AC lehnt den Token ab")

        var b = Harness()
        b.command("Öffne WWT Ticket 58")
        b.send(.archiveFetched(request: b.pendingRequest!, complete: false, message: "AC antwortet nicht"))
        #expect(b.opened == Fixture.taskURL(315, 41_000))

        // The watchdog: AC did not answer in time.
        var c = Harness()
        c.command("Öffne WWT Ticket 999")
        c.advance(4.1)
        #expect(c.phase == .error && c.model.message == "AC antwortet nicht")
    }

    // MARK: Revalidation before the decision (PLAN 5)

    @Test func revalidationComesFirstForTaskNumbers() {
        var h = Harness()
        h.autoRevalidate = nil
        h.command("Ticket 530")
        #expect(h.phase == .processing && h.revalidations.map(\.number) == [530] && h.dueIs(.revalidate, 1.5))
        #expect(h.opened == nil && h.model.message == nil)
        h.send(.taskListsRevalidated(request: h.pendingRequest!, complete: true))
        #expect(h.opened == Fixture.taskURL(628, 61_834))
        // A stale answer is ignored.
        var s = Harness()
        s.autoRevalidate = nil
        s.command("Ticket 530")
        #expect(s.send(.taskListsRevalidated(request: s.pendingRequest! + 1, complete: true)).isEmpty)
    }

    /// Lists that could not be revalidated may hide the same number in a sibling project: a single hit asks first.
    @Test func staleListsTurnASingleHitIntoAConfirmPrompt() {
        var h = Harness()
        h.autoRevalidate = false
        h.command("Ticket 530")
        #expect(h.phase == .choices && h.model.choices.count == 1 && h.model.hint == "Sag ja oder nein")
        h.say("ja")
        #expect(h.opened == Fixture.taskURL(628, 61_834))

        var w = Harness()
        w.autoRevalidate = nil
        w.command("Ticket 530")
        w.advance(1.6)   // watchdog: the same as an incomplete revalidation
        #expect(w.phase == .choices && w.model.choices.count == 1)
    }

    @Test func noRevalidationForGlobalIdsOrUnknownProjects() {
        var h = Harness()
        h.autoRevalidate = nil
        h.command("Ticket 47285")
        #expect(h.revalidations.isEmpty && h.opened == Fixture.taskURL(2032, 47_285))
        var u = Harness()
        u.autoRevalidate = nil
        u.command("Öffne Disney Ticket 58")
        #expect(u.revalidations.isEmpty && u.phase == .retry)
    }

    @Test func activeTabProjectOpensWithoutFetch() {
        var h = Harness(activeProjectId: 315)
        h.command("Öffne WWT Ticket 58")
        #expect(h.opened == Fixture.taskURL(315, 41_000))
    }

    @Test func knownGlobalIdOpens() {
        var h = Harness()
        h.command("Ticket 47285")
        #expect(h.opened == Fixture.taskURL(2032, 47_285))
        #expect(h.model.preview?.hasPrefix("Ticket 47285 · ") == true)
    }

    @Test func probeFound() {
        var h = Harness()
        h.command("Ticket 61234")
        let r = h.pendingRequest!
        #expect(h.has(.probeTask(taskId: 61_234, request: r)) && h.model.message == "Suche Ticket 61234 …")
        #expect(h.dueIs(.probe, 3.0))
        h.send(.probed(request: r, .found(projectId: 2032)))
        #expect(h.opened == Fixture.taskURL(2032, 61_234))
    }

    @Test func probeNotFoundFailedAndTimeout() {
        var a = Harness()
        a.command("Ticket 61234")
        a.send(.probed(request: a.pendingRequest!, .notFound))
        #expect(a.phase == .error && a.model.message == "AC kennt kein Ticket 61234")

        var b = Harness()
        b.command("Ticket 61234")
        b.send(.probed(request: b.pendingRequest!, .failed))
        #expect(b.model.message == "AC antwortet nicht")

        var m = Harness()
        m.command("Ticket 61234")
        m.send(.probed(request: m.pendingRequest!, .failed, message: "AC lehnt den Token ab"))
        #expect(m.phase == .error && m.model.message == "AC lehnt den Token ab")

        var c = Harness()
        c.command("Ticket 61234")
        c.advance(3.1)
        #expect(c.phase == .error && c.model.message == "AC antwortet nicht")
    }

    @Test func bareNumberAboveMinGlobalIdProbes() {
        var index = Fixture.index
        index.archiveComplete = Set(Fixture.projects.map(\.id))
        var h = Harness(index: index)
        h.command("Ticket 1200")
        #expect(h.last.contains(.probeTask(taskId: 1200, request: h.pendingRequest!)))
    }

    @Test func trashedTicket() {
        var h = Harness()
        h.command("Ticket 63000")
        #expect(h.phase == .error && h.model.message == "Das Ticket liegt im Papierkorb")
    }

    @Test func projectNotRecognizedRetriesThenFails() {
        var h = Harness()
        h.command("Öffne Disney Ticket 58")
        #expect(h.phase == .retry && h.model.message == "Welches Projekt? Sag es nochmal.")
        #expect(h.state.phase == .listening)
        h.say("Öffne Disney Ticket 58")
        #expect(h.phase == .error && h.model.message == "Ich finde das Projekt nicht")
    }

    @Test func projectNotRecognizedThenGoodRetry() {
        var h = Harness()
        h.command("Öffne Disney Ticket 58")
        h.say("Öffne WWT Relaunch Ticket 412")
        #expect(h.opened == Fixture.taskURL(628, 50_000))
    }

    @Test func ownTicketOpensDirectly() {
        var h = Harness()
        h.command("Ticket 530")
        #expect(h.opened == Fixture.taskURL(628, 61_834))
    }
}
