import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

/// REVIEW m9: what a listening session teaches the history once Chrome confirmed the open.
@Suite struct CorrectionLearningTests {
    @Test func notUnderstoodThenAProjectTeachesTheHeardQuery() {
        var h = Harness()
        h.command("Hallo Welt")
        #expect(h.phase == .retry)
        h.say("Öffne WWT Relaunch")
        #expect(h.opened == Fixture.projectURL(628) && h.picks.isEmpty)   // nothing before Chrome confirms
        h.confirmOpen()
        let key = Fixture.interpreter.correctionKey([Hypothesis("Hallo Welt")])
        #expect(key == "hallo welt")
        #expect(h.has(.recordOpen(projectId: 628)) && h.has(.recordPick(query: "hallo welt", projectId: 628)))
        // `.recordPick` comes after `.recordOpen`.
        let open = h.last.firstIndex(of: .recordOpen(projectId: 628))!, pick = h.last.firstIndex(of: .recordPick(query: "hallo welt", projectId: 628))!
        #expect(open < pick)
    }

    @Test func aPickFromAListTeachesBothQueries() {
        var h = Harness()
        h.command("Hallo Welt")
        h.say("Öffne das WWT-Projekt")
        #expect(h.phase == .choices)
        h.say("zwei")
        h.confirmOpen()
        #expect(h.picks == [.recordPick(query: "wwt", projectId: 314), .recordPick(query: "hallo welt", projectId: 314)])
    }

    @Test func projectNotRecognizedThenATicketTeachesTheProjectWords() {
        var h = Harness()
        h.command("Öffne Disney Ticket 58")
        #expect(h.phase == .retry)
        h.say("Öffne WWT Relaunch Ticket 412")
        h.confirmOpen()
        #expect(h.picks == [.recordPick(query: "disney", projectId: 628)])
    }

    @Test func nothingIsLearnedWithoutSpokenProjectWords() {
        // A global id names no project words: the failed query does not map to its project.
        var g = Harness()
        g.command("Hallo Welt")
        g.say("Ticket 47285")
        g.confirmOpen()
        #expect(g.has(.recordOpen(projectId: 2032)) && g.picks.isEmpty)
        // My tasks has no project.
        var m = Harness()
        m.command("Hallo Welt")
        m.say("Meine Aufgaben")
        m.confirmOpen()
        #expect(m.picks.isEmpty)
    }

    @Test func aCorrectionDoesNotOutliveItsSession() {
        var h = Harness()
        h.command("Hallo Welt")
        h.press()          // retry without speech: cancel
        #expect(h.phase == .idle)
        h.command("Öffne WWT Relaunch")
        h.confirmOpen()
        #expect(h.picks.isEmpty)
        // A failed open teaches nothing.
        var f = Harness()
        f.command("Hallo Welt")
        f.say("Öffne WWT Relaunch")
        f.send(.openFailed(request: f.pendingRequest!))
        #expect(f.picks.isEmpty)
    }
}
