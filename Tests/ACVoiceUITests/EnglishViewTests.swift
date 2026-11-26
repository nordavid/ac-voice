import Foundation
import Testing
import ACVoiceCore
import ACVoiceFlow
@testable import ACVoiceUI

/// German left in an English text: umlauts, German quote marks and frequent German words.
private func germanLeftovers(_ s: String) -> [String] {
    var found = s.unicodeScalars.filter { "äöüÄÖÜß„".unicodeScalars.contains($0) }.map { String($0) }
    let words = Set(s.lowercased().split { !$0.isLetter }.map(String.init))
    let german: Set<String> = [
        "der", "die", "das", "und", "nicht", "ich", "sag", "zahl", "namen", "projekt", "projekte", "seite", "von",
        "noch", "mehr", "zeigt", "welches", "dieses", "weitere", "fertig", "fehler", "schließen", "öffne", "hört",
        "sekunde", "sekunden", "erledigt", "favorit", "einen",
    ]
    found += words.intersection(german).sorted()
    return found
}

/// The overlay in English: the view state takes its words from `OverlayModel.language`.
@Suite struct EnglishViewTests {
    static func model(_ phase: FlowPhase, _ edit: (inout OverlayModel) -> Void = { _ in }) -> OverlayModel {
        ViewStateTests.model(phase) {
            $0.language = .en
            edit(&$0)
        }
    }

    @Test func overlayTextsAreEnglishAndFollowTheStyle() {
        #expect(OverlayText.en.all.count == OverlayText.de.all.count)
        for s in OverlayText.en.all {
            #expect(!s.isEmpty && s.count <= 60, "\(s)")
            #expect(germanLeftovers(s).isEmpty, "\(s): \(germanLeftovers(s))")
            #expect(!s.contains("–") && !s.contains("—") && !s.contains("!") && !s.contains(":"), "\(s)")
            #expect(!s.contains(" …"), "English puts the ellipsis right after the word: \(s)")
            if let first = s.first, first.isLetter { #expect(first.isUppercase, "\(s)") }
        }
        // English example phrases use the English command word.
        #expect(OverlayText.en.more(6, tickets: false) == "“more” shows 6 more projects")
        #expect(OverlayText.en.moreFromStart == "“more” shows page 1 again")
    }

    @Test func listeningInEnglish() {
        let cold = OverlayViewState(model: Self.model(.listening) {
            $0.warming = true
            $0.message = FlowText.en.loadingModel
        })
        #expect(cold.language == .en && cold.headline == .placeholder("Microphone is starting…", dimmed: false))
        // The loading line keeps its icon in English too.
        #expect(cold.lines == [OverlayLine(.status, FlowText.en.loadingModel, symbol: "arrow.down.circle")])
        let hot = OverlayViewState(model: Self.model(.listening) {
            $0.micReady = true
            $0.transcript = Transcript(stable: "Open WWT", volatile: "Relaunch")
            $0.preview = "WWT: Website Relaunch"
        })
        #expect(hot.accessibilityLabel == "Listening. Open WWT Relaunch. WWT: Website Relaunch")
        let idle = OverlayViewState(model: Self.model(.listening) { $0.micReady = true })
        #expect(idle.headline == .placeholder("I’m listening", dimmed: false))
    }

    @Test func choicesInEnglish() {
        let s = OverlayViewState(model: Self.model(.choices) {
            $0.transcript = Transcript(stable: "Open WWT")
            $0.choices = ViewStateTests.wwt
            $0.total = 10
            $0.pageCount = 2
            $0.pageSize = 4
        })
        #expect(s.lines.first == OverlayLine(.question, "Which of the 10 projects?"))
        #expect(s.footer?.hint == "Say a number or a name" && s.footer?.moreText == "“more” shows 4 more projects")
        #expect(s.rows[0].accessibilityLabel == "1, Website Relaunch, WWT AGIL, Favorite, Recently used")
        #expect(s.accessibilityLabel.hasPrefix("Waiting for your choice. Open WWT. Which of the 10 projects?"))

        let confirm = OverlayViewState(model: Self.model(.choices) { $0.choices = [ViewStateTests.wwt[0]] })
        #expect(confirm.headline == .title("This project?") && confirm.footer?.hint == "Say yes or no")

        let tickets = OverlayViewState(model: Self.model(.choices) {
            $0.choices = [OverlayGallery.item(1, 628, "WWT: Website Relaunch [AGIL]", ticket: (40_112, 112)),
                          OverlayGallery.item(2, 315, "WWT: TYPO3 Website maintenance [AGIL]", ticket: (31_877, 112))]
        })
        #expect(tickets.headline == .title("Ticket 112 in which of the 2 projects?"))

        let answering = OverlayViewState(model: Self.model(.choices) {
            $0.choices = ViewStateTests.wwt
            $0.answer = Transcript(stable: "Number", volatile: "two")
        })
        #expect(answering.footer?.hint == "“Number two”" && answering.footer?.hintIsLive == true)
    }

    @Test func resultCardsInEnglish() {
        let success = OverlayViewState(model: Self.model(.success) { $0.message = "WWT: Website Relaunch" })
        #expect(success.lines.first == OverlayLine(.success, "Chrome shows the page"))
        let error = OverlayViewState(model: Self.model(.error) {
            $0.transcript = Transcript(stable: "Open WWT ticket 412")
            $0.message = FlowText.en.nothingHeard
            $0.hint = FlowText.en.tryMyTasks
        })
        #expect(error.lines.map(\.text) == ["“Open WWT ticket 412”", "For example, say “my tasks”"])
        #expect(error.accessibilityLabel.hasPrefix("Error. I can’t hear anything."))
        let opening = OverlayViewState(model: Self.model(.opening) { $0.preview = "WWT: Website Relaunch" })
        #expect(opening.lines.first?.text == "Opening in Chrome…")
        let processing = OverlayViewState(model: Self.model(.processing))
        #expect(processing.headline == .placeholder("One moment", dimmed: false))
    }

    @Test func voiceOverValuesInEnglish() {
        #expect(SecondsLeftValue.text(3.5, .en) == "4 seconds left" && SecondsLeftValue.text(0.4, .en) == "1 second left")
        #expect(RowMarker.completed.accessibilityLabel(.en) == "Completed" && RowMarker.mine.accessibilityLabel(.en) == "Assigned to me")
        #expect(OverlayViewState.toneLabel(.choices, .en) == "Waiting for your choice")
        #expect(OverlayText.en.a11yPage(1, of: 2) == "Page 1 of 2")
    }

    /// English fillers and command words never highlight; title words do.
    @Test func englishCommandWordsDoNotHighlight() {
        let runs = TitleHighlighter.runs("Open Project Portal", query: "open project portal", language: .en)
        #expect(runs == [TitleRun("Open Project ", matched: false), TitleRun("Portal", matched: true)])
        // German keeps its own fillers.
        #expect(TitleHighlighter.runs("Open Portal", query: "open portal")[0] == TitleRun("Open", matched: true))
    }

    @Test func englishGalleryMirrorsTheGermanOne() {
        let de = OverlayGallery.scenarios()
        let en = OverlayGallery.scenarios(language: .en)
        #expect(de.map(\.name) == en.map(\.name))
        #expect(en.allSatisfy { $0.model.language == .en } && de.allSatisfy { $0.model.language == .de })
        for s in en {
            let state = OverlayViewState(model: s.model)
            // Project names come from AC and stay; everything the app or the user says is English.
            let said = [s.model.transcript.text, s.model.answer.text, s.model.message ?? "", s.model.hint ?? ""]
                .filter { !$0.isEmpty && !$0.contains(": ") }
            for text in said + state.lines.map(\.text).filter({ !$0.contains(": ") }) {
                #expect(germanLeftovers(text).isEmpty, "\(s.name): \(text)")
            }
        }
    }
}

@MainActor
@Suite struct EnglishRenderTests {
    @Test func englishStatesRender() throws {
        let scenarios = OverlayGallery.scenarios(language: .en).filter { ["choices", "error-offline"].contains($0.name) }
        #expect(scenarios.count == 2)
        for s in scenarios {
            let image = try #require(OverlaySnapshot.image(s.model, wallpaper: .dark, now: s.now, scale: 1))
            #expect(RendererTests.distinctColors(image) > 50, "\(s.name)")
        }
    }
}
