import Foundation
import Testing
import ACVoiceCore
@testable import ACVoiceFlow

/// Effect sequences the controller relies on, written out step by step.
@Suite struct ContractTests {
    static func names(_ fx: [Effect]) -> [String] {
        fx.map { e in
            switch e {
            case .publish(let m): return "publish \(m.phase.rawValue)"
            case .showOverlay: return "show"
            case .hideOverlay(let f): return "hide \(f)"
            case let .startMic(g, m, h): return "startMic \(g) \(m == .command ? "command" : "answer") \(h)"
            case let .rearm(g, m, h): return "rearm \(g) \(m == .command ? "command" : "answer") \(h)"
            case .setHangover(let h): return "hangover \(h)"
            case .suspendEndpointing(let s): return "suspend \(s)"
            case .endUtteranceNow(let g): return "endNow \(g)"
            case .stopMic: return "stopMic"
            case .refreshIndex: return "refresh"
            case let .revalidateTaskLists(t, a, r): return "revalidate \(t.number) \(a.map(String.init) ?? "-") #\(r)"
            case let .open(u, r): return "open \(u.path) #\(r)"
            case let .fetchArchive(p, r): return "fetch \(p) #\(r)"
            case let .probeTask(t, r): return "probe \(t) #\(r)"
            case let .schedule(id, a): return "schedule \(id.kind.rawValue) \(a)"
            case .cancelTimer(let k): return "cancel \(k.rawValue)"
            case .earcon(let e): return "earcon \(e.rawValue)"
            case .recordOpen(let p): return "recordOpen \(p)"
            case let .recordPick(q, p): return "recordPick \(q) \(p)"
            }
        }
    }

    @Test func listThenSpokenPick() {
        var h = Harness()
        var steps: [[String]] = []
        func step(_ fx: [Effect]) { steps.append(Self.names(fx)) }
        step(h.press())
        step(h.micReady())
        step(h.release())
        step(h.onset())
        step(h.partial("Öffne das WWT-Projekt"))
        step(h.ended())
        step(h.final("Öffne das WWT-Projekt"))
        step(h.onset())
        step(h.partial("zwei"))
        step(h.ended())
        step(h.final("zwei"))
        step(h.send(.opened(request: h.pendingRequest!, .reused)))
        step(h.advance(0.7))
        #expect(steps == [
            ["publish listening", "show", "startMic 1.1 command 0.6", "suspend true", "refresh", "schedule micStart 10.0"],
            ["publish listening", "cancel micStart", "earcon listen", "schedule noSpeech 4.0"],
            ["suspend false", "schedule noSpeech 4.0"],
            ["cancel noSpeech", "schedule maxUtterance 8.0"],
            ["publish listening"],
            ["publish processing", "cancel maxUtterance", "schedule finalize 2.0"],
            ["publish choices", "cancel finalize", "schedule choicesDeadline 6.0", "rearm 1.2 answer 0.4"],
            ["schedule maxUtterance 8.0"],   // deadline 6 s away: no extension yet
            ["publish choices"],
            ["cancel maxUtterance", "schedule finalize 2.0"],
            ["publish opening", "cancel finalize", "open /projects/314 #1", "stopMic", "cancel choicesDeadline",
             "schedule open 5.0"],
            ["publish success", "cancel open", "recordOpen 314", "recordPick wwt 314", "earcon done", "schedule success 0.7"],
            ["publish idle", "hide 0.2"],
        ])
    }

    /// The answer phase keeps its hangover after a dangling word (the speech layer reopens a dangling final); a new
    /// command in the answer phase follows the command rules.
    @Test func answerHangoverChangesOnlyForANewCommand() {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        let a = Self.names(h.onset())
        let b = Self.names(h.partial("die"))
        let c = Self.names(h.partial("Öffne WWT Ticket"))
        let d = Self.names(h.partial("Öffne WWT Relaunch"))
        #expect(a == ["schedule maxUtterance 8.0"])
        #expect(b == ["publish choices"])
        #expect(c == ["publish choices", "hangover 1.1"])
        #expect(d == ["publish choices", "hangover 0.45"])
    }

    @Test func ticketWithRevalidationAndArchiveFetch() {
        var h = Harness()
        h.autoRevalidate = nil
        h.press(); h.micReady(); h.release(); h.onset()
        h.partial("Öffne WWT Ticket 58")
        h.ended()
        let a = Self.names(h.final("Öffne WWT Ticket 58"))
        #expect(a == ["publish processing", "cancel finalize", "revalidate 58 - #1", "schedule revalidate 1.5"])
        let b = Self.names(h.send(.taskListsRevalidated(request: 1, complete: true)))
        #expect(b == ["publish processing", "cancel revalidate", "fetch [693] #2", "schedule archive 4.0"])
        h.env.index.archiveComplete.insert(693)
        let c = Self.names(h.send(.archiveFetched(request: 2, complete: true)))
        #expect(c == ["publish opening", "cancel archive", "open /projects/315/tasks/41000 #3", "stopMic", "schedule open 5.0"])
    }

    /// PLAN 2.5 press table with REVIEW m4/m5, one row per phase.
    @Test func pressTable() {
        func outcome(_ setup: (inout Harness) -> Void) -> String {
            var h = Harness()
            setup(&h)
            let fx = h.press("px")
            if fx.isEmpty { return "ignored" }
            if fx.contains(where: { if case .endUtteranceNow = $0 { return true }; return false }) { return "end" }
            if fx.contains(where: { if case .startMic = $0 { return true }; return false }) { return "listen" }
            return h.phase == .idle ? "cancel" : "other \(h.phase)"
        }
        #expect(outcome { _ in } == "listen")
        #expect(outcome { $0.command("WWT Relaunch"); $0.send(.opened(request: $0.pendingRequest!, .reused)) } == "listen")
        #expect(outcome { $0.command("Hallo"); $0.say("Welt") } == "listen")
        #expect(outcome { $0.press(); $0.micReady(); $0.release(); $0.onset() } == "end")
        // Double-tap guard 0.4 s (FlowTimings.doubleTap).
        #expect(outcome { $0.press(); $0.micReady(); $0.release(); $0.advance(0.3) } == "ignored")
        #expect(outcome { $0.press(); $0.micReady(); $0.release(); $0.advance(0.5) } == "cancel")
        #expect(outcome { $0.press(); $0.micReady(); $0.release(); $0.advance(1.5) } == "cancel")
        #expect(outcome { $0.command("Hallo Welt") } == "cancel")
        #expect(outcome { $0.command("Hallo Welt"); $0.onset() } == "end")
        #expect(outcome { $0.press(); $0.micReady(); $0.release(); $0.onset(); $0.ended() } == "cancel")
        #expect(outcome { $0.command("Öffne WWT Ticket 58") } == "cancel")
        #expect(outcome { $0.command("WWT Relaunch") } == "cancel")
        #expect(outcome { $0.command("Öffne das WWT-Projekt") } == "cancel")
    }

    @Test func stateEncodesForThePlugin() throws {
        var h = Harness()
        h.command("Öffne das WWT-Projekt")
        let line = IPC.line(h.state)
        let json = try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        #expect(json?["phase"] as? String == "choices" && (json?["choices"] as? [Any])?.count == 4)
        #expect(json?["seq"] as? Int == h.model.seq)
    }
}
