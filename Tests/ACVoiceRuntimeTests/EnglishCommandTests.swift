import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import ACVoiceSpeech
import ACVoiceSystem
import Foundation
import Testing
@testable import ACVoiceRuntime

/// English voice commands end to end: the real reducer and controller on a Rig whose macOS language is English, every
/// service faked, a fake clock. Project codes and titles are the AC names of Tests/Fixtures/projects.sample.json.
/// UI texts are not checked here (they belong to the text tests); only what opens and how the flow moves.
@MainActor
@Suite struct EnglishCommandTests {
    func englishRig(config: Config = Fixture.config) -> Rig { Rig(config: config, preferredLanguages: ["en-US"]) }

    @Test func languageFollowsMacOSAndTheConfig() async {
        let en = englishRig()
        #expect(en.controller.language == .en && en.controller.env.language == .en)
        #expect(en.controller.env.interpreter.language == .en && en.controller.env.interpreter.resolver.config.language == .en)
        let de = Rig()
        #expect(de.controller.language == .de && de.controller.env.interpreter.language == .de)
        // config.json overrides the macOS language.
        var config = Fixture.config
        config.language = "de"
        #expect(englishRig(config: config).controller.env.interpreter.language == .de)
        config.language = "en"
        #expect(Rig(config: config).controller.env.interpreter.language == .en)
        // The interpreter keeps its language when the index arrives and the controller rebuilds it.
        await en.start()
        #expect(!en.controller.env.interpreter.resolver.projects.isEmpty && en.controller.env.interpreter.language == .en)
    }

    @Test func uniqueProjectOpens() async {
        let rig = englishRig()
        await rig.start()
        await rig.listen()
        rig.speech.emit(.speechStarted)
        rig.speech.emit(.partial(dt: "open WWT Relaunch", st: "open WWT Relaunch"))
        #expect(rig.model.preview == "WWT: Website Relaunch")
        #expect(rig.speech.hangover == 0.45)   // a complete intent: the fast hangover
        rig.speech.emit(.endpoint)
        rig.clock.advance(0.05)
        rig.speech.emit(.utterance([Hypothesis("open WWT Relaunch")], latencyMs: 520))
        await rig.settle()
        #expect(rig.chrome.opened == [Fixture.projectURL(628)])
        #expect(rig.phase == .success)
        #expect(rig.controller.history.recentOpens(628).count == 1)
    }

    @Test func projectListAndNumberTwoPicks() async throws {
        let rig = englishRig()
        await rig.start()
        await rig.command("open the WWT project")
        #expect(rig.phase == .choices)
        let list = rig.model.choices
        #expect(list.count == 4 && list.first?.target.projectId == 628)
        #expect(Set(list.map(\.target.projectId)) == [628, 314, 315, 693])
        let rearm = try #require(rig.speech.rearms.last)
        #expect(rearm.mode == .answer && rearm.gen == SpeechGen(session: 1, utterance: 2))

        await rig.say("number two")
        let second = list[1].target.projectId
        #expect(rig.chrome.opened == [Fixture.projectURL(second)])
        #expect(rig.phase == .success)
        #expect(rig.controller.history.picks(for: "wwt") == [second: 1])
    }

    @Test(arguments: [("the second one", 1), ("two", 1), ("2.", 1), ("the last one", 3), ("one", 0), ("no, the third", 2)])
    func answersPickFromTheList(answer: String, index: Int) async {
        let rig = englishRig()
        await rig.start()
        await rig.command("open the WWT project")
        let list = rig.model.choices
        await rig.say(answer)
        #expect(rig.chrome.opened == [Fixture.projectURL(list[index].target.projectId)], "\(answer)")
    }

    @Test func titleWordsNarrowAndPick() async {
        let rig = englishRig()
        await rig.start()
        await rig.command("open the WWT project")
        await rig.say("Website")   // narrows to two rows
        #expect(rig.phase == .choices && rig.model.choices.map(\.target.projectId) == [628, 315])
        await rig.say("Relaunch")
        #expect(rig.chrome.opened == [Fixture.projectURL(628)])
    }

    @Test func ticketWithProjectWords() async {
        let rig = englishRig()
        await rig.start()
        await rig.command("ticket 412 in WWT Relaunch")
        #expect(rig.chrome.opened == [Fixture.taskURL(628, 31_412)])
        #expect(rig.phase == .success)
    }

    @Test func ticketInTheActiveTabProject() async {
        let rig = englishRig()
        await rig.start()
        rig.chrome.tabURL = URL(string: "https://ac.example.com/projects/628")
        await rig.command("open WWT ticket four hundred twelve")
        #expect(rig.index?.revalidations.map(\.number) == [412])
        #expect(rig.chrome.opened == [Fixture.taskURL(628, 31_412)])
    }

    @Test(arguments: ["my tasks", "Show my tasks", "What's on my plate"])
    func myTasksOpensMyWork(_ text: String) async {
        let rig = englishRig()
        await rig.start()
        await rig.command(text)
        #expect(rig.chrome.opened == [Fixture.myTasksURL], "\(text)")
        #expect(rig.phase == .success)
    }

    @Test func spokenCancel() async {
        let rig = englishRig()
        await rig.start()
        // A live "cancel" ends at once.
        await rig.listen()
        rig.speech.emit(.speechStarted)
        await rig.emit(.partial(dt: "cancel", st: "cancel"))
        #expect(rig.phase == .idle && rig.speech.stops == 1)
        // A final "never mind" cancels too.
        await rig.command("never mind")
        #expect(rig.phase == .idle && rig.chrome.opened.isEmpty)
        // "cancel" while the list is visible closes it.
        await rig.command("open the WWT project")
        #expect(rig.phase == .choices)
        await rig.say("cancel")
        #expect(rig.phase == .idle && rig.chrome.opened.isEmpty)
    }

    @Test func noKeepsTheListOpen() async {
        let rig = englishRig()
        await rig.start()
        await rig.command("open the WWT project")
        let list = rig.model.choices
        await rig.say("no")
        #expect(rig.phase == .choices && rig.chrome.opened.isEmpty && rig.model.choices == list)
        await rig.say("no, the second")
        #expect(rig.chrome.opened == [Fixture.projectURL(list[1].target.projectId)])
    }

    @Test func germanCommandsAreNotEnglishCommands() async {
        // The language is fixed per run: an English rig does not read German verbs, a German rig no English phrases.
        let en = englishRig()
        await en.start()
        await en.command("Zeig meine Aufgaben")
        #expect(en.phase == .retry && en.chrome.opened.isEmpty)
        let de = Rig()
        await de.start()
        await de.command("Show my tasks")
        #expect(de.phase == .retry && de.chrome.opened.isEmpty)
    }

    @Test func notUnderstoodRetriesAndTheOpenTeachesTheHeardWords() async {
        let rig = englishRig()
        await rig.start()
        await rig.command("Hello world")
        #expect(rig.phase == .retry)
        await rig.say("open WWT Relaunch")
        #expect(rig.chrome.opened == [Fixture.projectURL(628)])
        #expect(rig.controller.history.picks(for: "hello world") == [628: 1])
    }

    // MARK: Review fixes: the app path uses the English speech setup

    /// The en_US recognizer gets English contextual strings (review: the controller built German ones).
    @Test func contextsAreEnglish() async throws {
        let rig = englishRig()
        await rig.start()
        let warm = try #require(rig.speech.warmUpContext)
        #expect(warm.prefix(3) == ["Ticket", "My tasks", "Project"] && !warm.contains("Meine Aufgaben"))
        let command = rig.controller.commandContext
        #expect(command.contains("S and K") && !command.contains("S und K") && !command.contains("Projekt"))
        await rig.command("open the WWT project")
        let answer = try #require(rig.speech.rearms.last?.context)
        #expect(answer.contains("two") && answer.contains("the second") && answer.contains("cancel"))
        #expect(!answer.contains("zwei") && !answer.contains("die zweite") && !answer.contains("abbrechen"))
        // A German Mac keeps the German contexts.
        let de = Rig()
        await de.start()
        #expect(de.controller.commandContext.prefix(3) == ["Ticket", "Meine Aufgaben", "Projekt"])
    }

    /// "Test speech recognition" checks the model the sessions use (review: it always tested de_DE).
    @Test func selfCheckUsesTheAppLanguage() async {
        let en = englishRig()
        await en.start()
        en.controller.runSelfTest()
        await en.settle()
        #expect(en.speech.selfCheckLanguages == [.en])
        var config = Fixture.config
        config.language = "de"
        let de = englishRig(config: config)
        await de.start()
        de.controller.runSelfTest()
        await de.settle()
        #expect(de.speech.selfCheckLanguages == [.de])
    }

    /// A plugin that connects before the first press learns the app language from the launch snapshot.
    @Test func launchSnapshotCarriesTheLanguage() async {
        let en = englishRig()
        await en.start()
        let first = en.fakeIPC.states.first
        #expect(first?.phase == .idle && first?.lang == "en" && en.model.language == .en)
        var config = Fixture.config
        config.language = "de"
        let de = englishRig(config: config)
        await de.start()
        #expect(de.fakeIPC.states.first?.lang == "de")
    }

    /// The live hangover reads English dangling words: "tasks" is no dangling task word here.
    @Test func liveHangoverFollowsTheEnglishRule() async {
        let rig = englishRig()
        await rig.start()
        await rig.listen()
        rig.speech.emit(.speechStarted)
        rig.speech.emit(.partial(dt: "Show my tasks", st: "Show my tasks"))
        #expect(rig.speech.hangover == 0.45)
        rig.speech.emit(.partial(dt: "Open the", st: "Open the"))
        #expect(rig.speech.hangover == 1.10)
    }

    @Test(arguments: ["Close it", "That's all", "All right", "Stop it", "That's it", "Thank you so much"])
    func closingsOpenNothing(_ text: String) async {
        let rig = englishRig()
        await rig.start()
        await rig.command(text)
        #expect(rig.phase == .idle && rig.chrome.opened.isEmpty, "\(text)")
        await rig.command("open the WWT project")
        #expect(rig.phase == .choices)
        await rig.say(text)
        #expect(rig.phase == .idle && rig.chrome.opened.isEmpty, "\(text)")
    }

    /// The stale-list confirm prompt: "Go ahead" opens the ticket instead of starting a new command.
    @Test(arguments: ["Go ahead", "Yes, that's it", "Okay"])
    func oneRowPromptConfirms(_ text: String) async {
        let rig = englishRig()
        await rig.start()
        rig.index?.revalidateCheck = IndexCheck(complete: false, timedOut: true)
        rig.chrome.tabURL = URL(string: "https://ac.example.com/projects/628")
        await rig.command("Open WWT ticket 412")
        #expect(rig.phase == .choices && rig.model.choices.count == 1)
        await rig.say(text)
        #expect(rig.chrome.opened == [Fixture.taskURL(628, 31_412)], "\(text)")
    }

    @Test(arguments: ["I think the second one", "Two, thanks", "None of them"])
    func everydayAnswersAreNoFailedAttempt(_ text: String) async {
        let rig = englishRig()
        await rig.start()
        await rig.command("open the WWT project")
        await rig.say(text)
        #expect(!rig.model.hintIsAlert, "\(text)")
    }

    @Test(arguments: ["wait a second", "one second", "just a second", "um", "the"])
    func stallingInAListOpensNothing(_ text: String) async {
        let rig = englishRig()
        await rig.start()
        await rig.command("open the WWT project")
        await rig.say(text)
        #expect(rig.phase == .choices && rig.chrome.opened.isEmpty && !rig.model.hintIsAlert, "\(text)")
    }

    /// Live partials as the transcribers send them (Samantha clips through acvoice-transcribe --realtime): DT and ST
    /// show "one" or "second" twice before the next word. fastSelect must not commit there; the final decides.
    @Test(arguments: [
        ("One second", [("one", ""), ("one", "One"), ("one second", "One")], nil),
        ("One moment please", [("one", ""), ("one", "One"), ("one moment", "One")], nil),
        ("Hold on, one second", [("hold on", "Hold on, one"), ("hold on one", "Hold on, one"), ("hold on one second", "Hold on, one")], nil),
        ("Second to last", [("second", ""), ("second", "Sec"), ("second", "Second"), ("second to", "Second to last")], 2),
        ("The second to last one", [("the", "The 2"), ("the", "The 2nd"), ("the second", "The 2nd"), ("the second to", "The 2nd")], 2),
        ("I think the second to last", [("I think the second", "I think the second"), ("I think the second", "I think the second")], 2),
    ] as [(String, [(String, String)], Int?)])
    func liveStallOrSecondToLastWaitsForTheFinal(final: String, partials: [(String, String)], index: Int?) async {
        let rig = englishRig()
        await rig.start()
        await rig.command("open the WWT project")
        let list = rig.model.choices
        rig.speech.emit(.speechStarted)
        for (dt, st) in partials { await rig.emit(.partial(dt: dt, st: st)) }
        #expect(rig.chrome.opened.isEmpty && rig.phase == .choices, "\(final)")
        rig.speech.emit(.endpoint)
        rig.clock.advance(0.05)
        await rig.emit(.utterance([Hypothesis(final)], latencyMs: 450))
        if let index {
            #expect(rig.chrome.opened == [Fixture.projectURL(list[index].target.projectId)], "\(final)")
        } else {
            #expect(rig.chrome.opened.isEmpty && rig.phase == .choices, "\(final)")
        }
    }

    /// The one-row prompt with the live partials of "Okay, cancel" (Samantha clips through acvoice-transcribe
    /// --realtime): "Okay" twice must not confirm before "cancel" arrives. A plain "Okay" confirms with the final.
    @Test(arguments: [
        ("Okay, cancel", [("", "Okay"), ("OK", "Okay"), ("OK cancel", "Okay")], false),
        ("OK, never mind", [("", "Okay"), ("OK", "Okay"), ("OK never mind", "Okay")], false),
        ("Okay, no", [("", "Okay"), ("OK", "Okay"), ("OK no", "Okay")], false),
        ("Okay.", [("", "Okay"), ("OK", "Okay")], true),
    ] as [(String, [(String, String)], Bool)])
    func liveOkayWaitsForTheFinal(final: String, partials: [(String, String)], opens: Bool) async {
        let rig = englishRig()
        await rig.start()
        rig.index?.revalidateCheck = IndexCheck(complete: false, timedOut: true)
        rig.chrome.tabURL = URL(string: "https://ac.example.com/projects/628")
        await rig.command("Open WWT ticket 412")
        #expect(rig.phase == .choices && rig.model.choices.count == 1)
        rig.speech.emit(.speechStarted)
        for (dt, st) in partials { await rig.emit(.partial(dt: dt, st: st)) }
        #expect(rig.chrome.opened.isEmpty, "\(final)")
        rig.speech.emit(.endpoint)
        rig.clock.advance(0.05)
        await rig.emit(.utterance([Hypothesis(final)], latencyMs: 450))
        if opens {
            #expect(rig.chrome.opened == [Fixture.taskURL(628, 31_412)], "\(final)")
        } else {
            #expect(rig.chrome.opened.isEmpty && rig.phase == .idle, "\(final)")
        }
    }

    /// Two equal live picks still commit before the final when nothing can follow that changes them.
    @Test(arguments: [
        ("Two", [("Two", ""), ("Two", "Two")], 1),
        ("The third one", [("the", ""), ("the third", ""), ("the third", "The")], 2),
        ("The last one", [("the last", ""), ("the last", "The")], 3),
        ("The second one", [("the second", "The second one"), ("the second one", "The second one")], 1),
        ("Number one", [("number one", ""), ("number one", "Number one")], 0),
    ])
    func livePickCommitsBeforeTheFinal(final: String, partials: [(String, String)], index: Int) async {
        let rig = englishRig()
        await rig.start()
        await rig.command("open the WWT project")
        let list = rig.model.choices
        rig.speech.emit(.speechStarted)
        for (dt, st) in partials { await rig.emit(.partial(dt: dt, st: st)) }
        #expect(rig.chrome.opened == [Fixture.projectURL(list[index].target.projectId)], "\(final)")
    }

    @Test func pronounOneOpensTheProject() async {
        let rig = englishRig()
        await rig.start()
        await rig.command("Open the maintenance one")
        #expect(rig.index?.revalidations.isEmpty == true)
        #expect(rig.chrome.opened == [Fixture.projectURL(314)])
    }

    /// DT writes "ticket four twelve" as "Ticket for 12".
    @Test func ticketForTwelveIsTicket412() async {
        let rig = englishRig()
        await rig.start()
        await rig.command("Ticket for 12 in WWT Relaunch")
        #expect(rig.chrome.opened == [Fixture.taskURL(628, 31_412)])
    }
}
