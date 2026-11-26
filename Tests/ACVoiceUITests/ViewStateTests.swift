import Foundation
import Testing
import ACVoiceCore
import ACVoiceFlow
@testable import ACVoiceUI

/// OverlayModel -> OverlayViewState: what each phase shows.
@Suite struct ViewStateTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func model(_ phase: FlowPhase, seq: Int = 3, _ edit: (inout OverlayModel) -> Void = { _ in }) -> OverlayModel {
        var m = OverlayModel()
        m.seq = seq
        m.phase = phase
        m.visible = true
        m.since = t0
        edit(&m)
        return m
    }

    static let wwt: [ChoiceItem] = [
        OverlayGallery.item(1, 628, "WWT: Website Relaunch [AGIL]", badges: [.recent, .favorite]),
        OverlayGallery.item(2, 315, "WWT: TYPO3 Website maintenance [AGIL]"),
        OverlayGallery.item(3, 314, "WWT: Maintenance [SLA]"),
        OverlayGallery.item(4, 693, "WWT: Grand Navigation [AGIL]"),
    ]

    @Test func listeningCold() {
        let s = OverlayViewState(model: Self.model(.listening) {
            $0.warming = true
            $0.message = FlowText.loadingModel
        })
        #expect(s.tone == .warming)
        #expect(!s.micLive)
        // Review U17: before the first audio, "Ich höre zu" would invite speech the mic cannot hear yet.
        #expect(s.headline == .placeholder(OverlayText.micStarting, dimmed: false))
        #expect(s.lines == [OverlayLine(.status, FlowText.loadingModel, symbol: "arrow.down.circle")])
        #expect(s.rows.isEmpty && s.footer == nil && s.deadline == nil)
        #expect(s.phaseStart == Self.t0)
    }

    @Test func listeningWithPartialAndPreview() {
        let s = OverlayViewState(model: Self.model(.listening) {
            $0.micReady = true
            $0.transcript = Transcript(stable: "Öffne WWT ", volatile: " Relaunch")
            $0.preview = "WWT: Website Relaunch"
        })
        #expect(s.tone == .listening && s.micLive)
        #expect(s.headline == .transcript(stable: "Öffne WWT", volatile: "Relaunch"))
        #expect(s.lines == [OverlayLine(.preview, "WWT: Website Relaunch", symbol: "arrow.right")])
        #expect(s.accessibilityLabel == "Hört zu. Öffne WWT Relaunch. WWT: Website Relaunch")
    }

    @Test func hotMicWithoutTranscriptIsNotDimmed() {
        let s = OverlayViewState(model: Self.model(.listening) { $0.micReady = true })
        #expect(s.headline == .placeholder(OverlayText.listening, dimmed: false))
        #expect(s.lines.isEmpty)
    }

    @Test func retryShowsTheMessageAsAlert() {
        let s = OverlayViewState(model: Self.model(.retry) {
            $0.micReady = true
            $0.transcript = Transcript(stable: "Hallo Welt")
            $0.message = FlowText.notUnderstoodRetry
        })
        #expect(s.tone == .listening)
        #expect(s.headline == .transcript(stable: "Hallo Welt", volatile: ""))
        #expect(s.lines == [OverlayLine(.alert, FlowText.notUnderstoodRetry, symbol: "arrow.counterclockwise")])
    }

    @Test func processingWithSearchMessage() {
        let s = OverlayViewState(model: Self.model(.processing) {
            $0.transcript = Transcript(stable: "Öffne WWT Ticket 412")
            $0.message = FlowText.searchingTicket(412)
        })
        #expect(s.tone == .processing)
        #expect(s.headline.text == "Öffne WWT Ticket 412")
        #expect(s.lines == [OverlayLine(.status, "Suche Ticket 412 …", symbol: "magnifyingglass")])
        // Nothing heard yet: a neutral placeholder.
        let empty = OverlayViewState(model: Self.model(.processing))
        #expect(empty.headline == .placeholder(OverlayText.working, dimmed: false))
    }

    /// Review U10: the target takes the headline at opening and keeps it through success; only line 2 changes.
    @Test func openingShowsTheTarget() {
        let s = OverlayViewState(model: Self.model(.opening) {
            $0.transcript = Transcript(stable: "Öffne das WWT-Projekt")
            $0.preview = "WWT: Website Relaunch"
        })
        #expect(s.tone == .processing)
        #expect(s.headline == .title("WWT: Website Relaunch"))
        #expect(s.lines == [OverlayLine(.status, OverlayText.openingInChrome, symbol: "arrow.up.forward")])
        let clicked = OverlayViewState(model: Self.model(.opening) { $0.preview = "WWT: Website Relaunch" })
        #expect(clicked.headline == s.headline && clicked.lines == s.lines)
        let done = OverlayViewState(model: Self.model(.success) {
            $0.transcript = Transcript(stable: "Öffne das WWT-Projekt")
            $0.message = "WWT: Website Relaunch"
        })
        #expect(done.headline == s.headline && done.lines.count == s.lines.count)
    }

    @Test func choicesRowsCarryNumberSeqAndMarkers() {
        let s = OverlayViewState(model: Self.model(.choices, seq: 9) {
            $0.transcript = Transcript(stable: "Öffne das WWT-Projekt")
            OverlayGallery.list(&$0, Self.wwt, page: 0, pageSize: 6, deadline: Self.t0.addingTimeInterval(6))
        })
        #expect(s.tone == .choices)
        #expect(s.lines == [OverlayLine(.question, "Welches der 4 Projekte?")])
        #expect(s.rows.map(\.n) == [1, 2, 3, 4])
        #expect(s.rows.allSatisfy { $0.seq == 9 })
        #expect(s.rows.map(\.index) == [0, 1, 2, 3])
        #expect(s.rows.map(\.id) == ["p628-1", "p315-2", "p314-3", "p693-4"])
        #expect(s.rows[0].title == "Website Relaunch")
        #expect(s.rows[0].badge == "WWT · AGIL")
        #expect(s.rows[2].badge == "WWT · SLA")
        #expect(s.rows[0].markers == [.favorite, .recent])
        #expect(s.rows[0].ticket == nil)
        #expect(s.rows[0].accessibilityLabel == "1, Website Relaunch, WWT AGIL, Favorit, Zuletzt genutzt")
        #expect(s.footer == ChoiceFooterState(hint: OverlayText.defaultChoiceHint, hintIsAlert: false, hintIsLive: false,
                                              page: 0, pageCount: 1, nextCount: 0, isLastPage: true, tickets: false))
        #expect(s.footer?.moreText == nil)
        #expect(s.deadline == Self.t0.addingTimeInterval(6))
    }

    @Test func secondPageShowsMore() {
        let items = (1...10).map { OverlayGallery.item($0, 3000 + $0, "QZ: Projekt \($0) [INT]") }
        let s = OverlayViewState(model: Self.model(.choices) {
            OverlayGallery.list(&$0, items, page: 1, pageSize: 6, deadline: Self.t0)
        })
        #expect(s.rows.map(\.n) == [7, 8, 9, 10])
        #expect(s.rows.map(\.index) == [0, 1, 2, 3])
        // Review U2: the last page leads back to page 1 ("mehr" wraps), it announces no "6 weitere".
        #expect(s.footer?.page == 1 && s.footer?.pageCount == 2 && s.footer?.isLastPage == true)
        #expect(s.footer?.moreText == OverlayText.moreFromStart)
        // No transcript: the question is the headline.
        #expect(s.headline == .title("Welches der 10 Projekte?"))
        let first = OverlayViewState(model: Self.model(.choices) {
            OverlayGallery.list(&$0, items, page: 0, pageSize: 6, deadline: Self.t0)
        })
        #expect(first.footer?.moreText == "„mehr“ zeigt 4 weitere Projekte")
    }

    /// Review U2: "mehr" names the size of the next page (three pages), and one entry in the singular.
    @Test func moreNamesTheNextPage() {
        func footer(_ count: Int, page: Int, tickets: Bool = false) -> String? {
            let items = (1...count).map { i in
                OverlayGallery.item(i, 3000 + i, "QZ: Projekt \(i) [INT]", ticket: tickets ? (40000 + i, i) : nil)
            }
            return OverlayViewState(model: Self.model(.choices) {
                OverlayGallery.list(&$0, items, page: page, pageSize: 6, deadline: Self.t0)
            }).footer?.moreText
        }
        #expect(footer(15, page: 0) == "„mehr“ zeigt 6 weitere Projekte")
        #expect(footer(15, page: 1) == "„mehr“ zeigt 3 weitere Projekte")
        #expect(footer(15, page: 2) == "„mehr“ zeigt wieder Seite 1")
        #expect(footer(7, page: 0) == "„mehr“ zeigt ein weiteres Projekt")
        #expect(footer(7, page: 0, tickets: true) == "„mehr“ zeigt ein weiteres Ticket")
        #expect(footer(9, page: 0, tickets: true) == "„mehr“ zeigt 3 weitere Tickets")
        #expect(footer(6, page: 0) == nil)
    }

    /// Review U11: while the user answers, the headline keeps the command; the footer shows the live answer.
    @Test func liveAnswerShowsInTheFooter() {
        let s = OverlayViewState(model: Self.model(.choices) {
            $0.transcript = Transcript(stable: "Öffne das WWT-Projekt")
            OverlayGallery.list(&$0, Self.wwt, page: 0, pageSize: 6, deadline: Self.t0)
            $0.answer = Transcript(stable: "Die", volatile: "zweite")
        })
        #expect(s.headline == .transcript(stable: "Öffne das WWT-Projekt", volatile: ""))
        #expect(s.footer?.hint == "„Die zweite“" && s.footer?.hintIsLive == true && s.footer?.hintIsAlert == false)
        // A new partial changes text only: no spring.
        let next = OverlayViewState(model: Self.model(.choices) {
            $0.transcript = Transcript(stable: "Öffne das WWT-Projekt")
            OverlayGallery.list(&$0, Self.wwt, page: 0, pageSize: 6, deadline: Self.t0)
            $0.answer = Transcript(stable: "Die zweite")
        })
        #expect(next.structure == s.structure)
    }

    /// Review U4: a held list freezes its countdown; the model's frozen seconds reach the orb.
    @Test func heldListFreezesTheCountdown() {
        let s = OverlayViewState(model: Self.model(.choices) {
            OverlayGallery.list(&$0, Self.wwt, page: 0, pageSize: 6, deadline: Self.t0.addingTimeInterval(30))
            $0.countdownFrozen = 3.5
        })
        #expect(s.countdownFrozen == 3.5)
        #expect(SecondsLeftValue.text(3.5) == "Noch 4 Sekunden" && SecondsLeftValue.text(0.4) == "Noch 1 Sekunde")
    }

    /// Review U14: a long code does not take the title's width.
    @Test func longCodesAreShortened() {
        let row = OverlayViewState.row(OverlayGallery.item(1, 2122, "Tourismusverband Nord-Ost: Webportal Neubau [AGIL]"),
                                       index: 0, seq: 1, query: "")
        #expect(row.badge == "Tourismusverb… · AGIL")
        #expect(row.accessibilityLabel.contains("Tourismusverband Nord-Ost"))   // VoiceOver reads the whole code
    }

    @Test func hintsAfterUnclearAndForOneItem() {
        let unclear = OverlayViewState(model: Self.model(.choices) {
            OverlayGallery.list(&$0, Self.wwt, page: 0, pageSize: 6, deadline: Self.t0)
            $0.hint = FlowText.unclearAnswer("Hi.")
            $0.hintIsAlert = true
        })
        #expect(unclear.footer?.hint == "„Hi.“ passt zu keiner Zeile. Sag eine Zahl." && unclear.footer?.hintIsAlert == true)
        let one = OverlayViewState(model: Self.model(.choices) {
            $0.transcript = Transcript(stable: "WWD")
            OverlayGallery.list(&$0, [Self.wwt[0]], page: 0, pageSize: 6, deadline: Self.t0)
        })
        #expect(one.footer?.hint == FlowText.sayYesOrOne && one.footer?.hintIsAlert == false)
        #expect(one.lines == [OverlayLine(.question, "Dieses Projekt?")])
    }

    @Test func narrowRenumbersAndChangesRowIdentity() {
        let before = OverlayViewState(model: Self.model(.choices, seq: 9) {
            OverlayGallery.list(&$0, Self.wwt, page: 0, pageSize: 6, deadline: Self.t0)
        })
        var kept = [Self.wwt[1], Self.wwt[2]]
        kept[0].n = 1; kept[1].n = 2
        let after = OverlayViewState(model: Self.model(.choices, seq: 11) {
            $0.transcript = Transcript(stable: "Maintenance")
            OverlayGallery.list(&$0, kept, page: 0, pageSize: 6, deadline: Self.t0)
        })
        #expect(after.rows.map(\.id) == ["p315-1", "p314-2"])
        #expect(Set(after.rows.map(\.id)).isDisjoint(with: before.rows.map(\.id)))
        #expect(after.rows.allSatisfy { $0.seq == 11 })
        #expect(before.structure != after.structure)
        // Both titles contain the spoken word.
        #expect(after.rows.allSatisfy { $0.titleRuns.contains(TitleRun("Maintenance", matched: true))
            || $0.titleRuns.contains(TitleRun("maintenance", matched: true)) })
    }

    @Test func ticketListSaysTheSharedNumberOnce() {
        let items = [
            OverlayGallery.item(1, 628, "WWT: Website Relaunch [AGIL]", badges: [.mine], ticket: (40112, 112)),
            OverlayGallery.item(2, 693, "WWT: Grand Navigation [AGIL]", badges: [.completed], ticket: (18233, 112)),
        ]
        let s = OverlayViewState(model: Self.model(.choices) {
            $0.transcript = Transcript(stable: "Öffne WWT Ticket 112")
            OverlayGallery.list(&$0, items, page: 0, pageSize: 6, deadline: Self.t0)
        })
        #expect(s.lines == [OverlayLine(.question, "Ticket 112 in welchem der 2 Projekte?")])
        #expect(s.rows.map(\.ticket) == [nil, nil])
        #expect(s.rows.map(\.id) == ["t40112-1", "t18233-2"])
        #expect(s.rows[0].markers == [.mine] && s.rows[1].markers == [.completed])
        #expect(s.rows[0].accessibilityLabel.contains("Ticket 112"))
        // Different numbers (global ids): a chip per row.
        let mixed = OverlayViewState(model: Self.model(.choices) {
            OverlayGallery.list(&$0, [OverlayGallery.item(1, 628, "WWT: Website Relaunch [AGIL]", ticket: (47285, 0)),
                                      OverlayGallery.item(2, 693, "WWT: Grand Navigation [AGIL]", ticket: (18233, 112))],
                                page: 0, pageSize: 6, deadline: Self.t0)
        })
        #expect(mixed.rows.map(\.ticket) == ["#47285", "#112"])
        #expect(mixed.headline == .title("Welches der 2 Tickets?"))
    }

    @Test func successAndHint() {
        let s = OverlayViewState(model: Self.model(.success) {
            $0.transcript = Transcript(stable: "Öffne WWT Relaunch")
            $0.message = "WWT: Website Relaunch"
        })
        #expect(s.tone == .success)
        #expect(s.headline == .title("WWT: Website Relaunch"))
        #expect(s.lines == [OverlayLine(.success, OverlayText.opened)])
        let hinted = OverlayViewState(model: Self.model(.success) {
            $0.message = "WWT: Website Relaunch"
            $0.hint = FlowText.automationHint
        })
        #expect(hinted.lines.map(\.style) == [.success, .alert])
        #expect(hinted.lines[1].text == FlowText.automationHint)
    }

    @Test func errorQuotesWhatWasHeard() {
        let s = OverlayViewState(model: Self.model(.error) {
            $0.transcript = Transcript(stable: "Öffne WWT Ticket 412")
            $0.message = FlowText.ticketNotFound(412, code: "WWT")
        })
        #expect(s.tone == .error)
        #expect(s.headline == .title("WWT hat kein Ticket 412"))
        #expect(s.lines == [OverlayLine(.quote, "„Öffne WWT Ticket 412“")])
        // Review U27: the next step under the error.
        let bare = OverlayViewState(model: Self.model(.error) {
            $0.message = FlowText.nothingHeard
            $0.hint = FlowText.hint(forError: FlowText.nothingHeard)
        })
        #expect(bare.lines == [OverlayLine(.alert, FlowText.tryMyTasks, symbol: "exclamationmark.triangle")])
    }

    @Test func structureIgnoresTextOnlyChanges() {
        let a = OverlayViewState(model: Self.model(.listening, seq: 4) {
            $0.micReady = true
            $0.transcript = Transcript(stable: "Öffne", volatile: "WW")
            $0.preview = "4 WWT-Projekte"
        })
        let b = OverlayViewState(model: Self.model(.listening, seq: 5) {
            $0.micReady = true
            $0.transcript = Transcript(stable: "Öffne WWT", volatile: "Relaunch")
            $0.preview = "WWT: Website Relaunch"
        })
        #expect(a != b)
        #expect(a.structure == b.structure)
        let c = OverlayViewState(model: Self.model(.processing, seq: 6) { $0.transcript = Transcript(stable: "Öffne WWT Relaunch") })
        #expect(b.structure != c.structure)
    }

    @Test func longTranscriptKeepsTheNewestWords() {
        let t = Transcript(stable: "Öffne bitte das Projekt Hollenstein Optical mit der Hotline und danach noch das Ticket",
                           volatile: "siebenundvierzigtausend")
        guard case let .transcript(stable, volatile) = OverlayViewState.clampedTranscript(t, limit: 60) else {
            Issue.record("expected a transcript"); return
        }
        #expect(stable.hasPrefix("… "))
        #expect(volatile == "siebenundvierzigtausend")
        #expect(stable.hasSuffix("das Ticket"))
        #expect(stable.count + 1 + volatile.count <= 60)
        // Cut at a word boundary.
        let firstWord = stable.dropFirst(2).split(separator: " ").first.map(String.init) ?? ""
        #expect(t.stable.contains(" \(firstWord) "))
        // A volatile tail longer than the limit on its own.
        let only = Transcript(stable: "kurz", volatile: String(repeating: "wort ", count: 30))
        guard case let .transcript(s2, v2) = OverlayViewState.clampedTranscript(only, limit: 40) else {
            Issue.record("expected a transcript"); return
        }
        #expect(s2.isEmpty && v2.hasPrefix("… ") && v2.count <= 40)
        // Short transcripts stay as they are.
        #expect(OverlayViewState.clampedTranscript(Transcript(stable: "WWT", volatile: "Relaunch"))
            == .transcript(stable: "WWT", volatile: "Relaunch"))
    }

    @Test func titleHighlightMarksSpokenWords() {
        #expect(TitleHighlighter.runs("TYPO3 Website maintenance", query: "WWT Website")
            == [TitleRun("TYPO3 ", matched: false), TitleRun("Website", matched: true),
                TitleRun(" maintenance", matched: false)])
        // Fillers and the code never highlight.
        #expect(TitleHighlighter.runs("Website Relaunch", query: "Öffne das WWT-Projekt")
            == [TitleRun("Website Relaunch", matched: false)])
        // One typo in a long word, a shared prefix of four letters.
        #expect(TitleHighlighter.runs("Grand Navigation", query: "Grand Navigazion").allSatisfy { $0.text == " " || $0.matched })
        #expect(TitleHighlighter.runs("Pilzdatenbank Portal", query: "Pilzdaten")[0] == TitleRun("Pilzdatenbank", matched: true))
        #expect(TitleHighlighter.runs("", query: "x") == [TitleRun("", matched: false)])
    }

    @Test func idleMapsToAQuietListeningState() {
        let s = OverlayViewState(model: OverlayModel())
        #expect(s.tone == .listening && !s.micLive && s.rows.isEmpty && s.lines.isEmpty)
        #expect(OverlayViewState.initial.seq == 0)
    }

    @Test func overlayStringsFollowTheStyleRules() {
        for s in OverlayText.all {
            #expect(!s.contains("–") && !s.contains("—"), "\(s)")
            #expect(!s.contains(":"), "\(s)")
            let lower = s.lowercased()
            for word in ["könnte", "sollte", "würde", "wäre", "bitte"] { #expect(!lower.contains(word), "\(s)") }
            #expect(!s.isEmpty && s.count <= 60, "\(s)")
        }
    }
}
