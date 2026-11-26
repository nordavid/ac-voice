import Foundation
import ACVoiceCore

/// Speech event stamp, declared in Core so the speech layer stamps its events with it (REVIEW M3).
public typealias SpeechGen = ACVoiceCore.SpeechGen
/// Why a mic session failed, declared in Core so the speech layer maps its errors to it (`SpeechError.failure`).
public typealias SpeechFailure = ACVoiceCore.SpeechFailure

/// Where a press came from.
public enum TriggerSource: String, Sendable, Equatable {
    case streamDeck, hotkey, menu, url, overlay
    /// Sources that send a release edge. Only these suspend end-of-utterance detection while the key is down.
    public var hasRelease: Bool { self == .streamDeck || self == .hotkey }
}

public struct Press: Sendable, Equatable {
    /// IPC `press.id` or a controller-made id for the hotkey ("hk-7"); a matching `release` names it.
    public var id: String?
    public var source: TriggerSource
    /// When the key went down (plugin `at`). Presses older than `FlowTimings.stalePress` are dropped (REVIEW m5).
    /// nil means "now".
    public var at: Date?
    public init(id: String? = nil, source: TriggerSource, at: Date? = nil) { self.id = id; self.source = source; self.at = at }
}

/// What the speech layer listens for. The controller builds the contextual strings from it:
/// `ContextBuilder.command(projects:)` or `ContextBuilder.answer(titles:hasMore:firstNumber:)`.
public enum ListenMode: Sendable, Equatable {
    case command
    /// Answer while a list is visible. `titles`: the titles of the visible page only (`ChoiceItem.title`, no
    /// truncated labels); `firstNumber`: the absolute number of its first row (7 on the second page of 6);
    /// `hasMore`: "mehr" shows another page. Every page change re-arms with the new page.
    case answer(titles: [String], firstNumber: Int, hasMore: Bool)
}

public enum Earcon: String, Sendable, Equatable {
    /// Mic is hot (first converted buffer). The speech layer must blank its gate while it plays (REVIEW M1).
    case listen
    case done
    case error
}

/// Why `ChromeOpener` used the NSWorkspace fallback (a new tab instead of the AC tab).
public enum FallbackReason: String, Sendable, Equatable, CaseIterable {
    /// Automation for Chrome is denied: the overlay points to System Settings.
    case denied
    /// Automation was never asked for (the prompt belongs to the setup window): the overlay points to the setup.
    case undetermined
    /// Chrome missing, busy or late, or the script failed: nothing for the user to do.
    case other
}

/// Result of `ChromeOpener.open`.
public enum OpenResult: Sendable, Equatable {
    case reused, newTab, newWindow, launched
    /// NSWorkspace fallback: a new tab, never the AC tab.
    case fallback(FallbackReason)
}

/// Result of the 301 probe `GET /projects/{any}/tasks/{id}`.
public enum ProbeResult: Sendable, Equatable {
    case found(projectId: Int)
    case notFound
    /// Network or HTTP error other than 404.
    case failed
}

public enum TimerKind: String, Sendable, CaseIterable {
    /// No speech `noSpeech` s after micReady -> error "Nichts gehört".
    case noSpeech
    /// Speech onset + `maxUtterance` -> end the utterance now.
    case maxUtterance
    /// Press + `micStart` without micReady -> error.
    case micStart
    /// End of utterance sent, final not back after `finalize` -> use the last partial.
    case finalize
    /// Retry without speech for `retrySilence` -> idle.
    case retrySilence
    /// Choices window end (extended while the user speaks) -> idle.
    case choicesDeadline
    /// fastSelect: a partial pick followed by `fastSelectSilence` of silence commits.
    case fastSelect
    /// Watchdogs for the async requests.
    case archive, probe, open
    /// Watchdog for `.revalidateTaskLists`: decide with the cached lists, as after an incomplete revalidation.
    case revalidate
    /// success -> fade -> idle, error -> fade -> idle (held while the pointer rests on the card).
    case success, error
}

/// The controller keeps at most one timer per kind: `.schedule` replaces a pending one of the same kind,
/// `.cancelTimer` drops it. A fired timer comes back as `.timer(id)`; the reducer ignores stale tokens.
public struct TimerID: Sendable, Hashable, CustomStringConvertible {
    public var kind: TimerKind
    public var token: Int
    public init(kind: TimerKind, token: Int) { self.kind = kind; self.token = token }
    public var description: String { "\(kind.rawValue)#\(token)" }
}

public enum FlowEvent: Sendable, Equatable {
    // Triggers (IPC, hotkey, menu, overlay).
    case press(Press)
    /// Key up. `pressId` nil: older plugin, matches any held key.
    case release(pressId: String?, heldMs: Int)
    /// 1-based absolute choice number from an overlay click (v1 has no Stream Deck choice keys; IPC `choose` stays
    /// in the codec). `seq`: the `seq` of the snapshot (`OverlayModel` / `IPC.State`) the row was rendered from; older than the list's first snapshot ->
    /// ignored (REVIEW m4). A click handler must capture that seq with the row it draws. The live `model.seq` at
    /// click time defeats the check: after a narrow it is new enough, and an old row number picks another project.
    case choose(n: Int, seq: Int?)
    case cancel
    /// The pointer moved onto the card (`true`) or left it. While inside, a list keeps its time (up to
    /// `choicesHardCap` after its render), and an error or a success with a hint stays up (up to `pointerHoldCap`).
    case pointer(inside: Bool)

    // Speech layer. Every event but `speechWarm` carries the armed stamp.
    /// The analyzer is prepared. A press before that still listens and shows "Sprachmodell lädt" (REVIEW m5).
    case speechWarm(Bool)
    /// First converted mic buffer of the session.
    case micReady(SpeechGen)
    /// Gate onset (debounced, REVIEW M1).
    case speechStarted(SpeechGen)
    /// Optional voiced/unvoiced transitions after onset. Drive the choices deadline extension and the
    /// fastSelect silence rule; without them fastSelect relies on two equal partials.
    case voice(SpeechGen, active: Bool)
    /// Live result. `hypotheses` empty: the transcript text alone.
    case partial(SpeechGen, Transcript, [Hypothesis])
    /// The gate decided the utterance is over; finalize is running. The runtime sends it while the speech model is not
    /// warm yet (the final waits for the analyzer, REVIEW m5): the finalize watchdog runs from here, not from
    /// `maxUtterance`.
    case speechEnded(SpeechGen)
    /// The utterance after `.speechEnded` goes on: its final text dangled ("Öffne WWT Ticket"), so the speech layer
    /// listens on with the incomplete hangover. Back to listening.
    case speechResumed(SpeechGen)
    /// The onset of the armed utterance was noise (a cough, a knock: no word): the speech layer waits for speech
    /// again in the same utterance. The no-speech timeout counts again.
    case speechDiscarded(SpeechGen)
    /// Final hypotheses (DT best, ST best, alternatives). Empty: nothing recognized. Exactly one per armed
    /// utterance after `.speechEnded` or `.endUtteranceNow`.
    case utterance(SpeechGen, [Hypothesis])
    /// The speech layer's own no-speech timeout. Treated like the reducer's timer.
    case noSpeech(SpeechGen)
    /// The mic session failed (permission, device, engine stopped, model missing). The speech layer stamps it with
    /// the stamp of the session it was started for (`.startMic`, or any later `.rearm` of it), also for teardown
    /// errors: `.speechFailed(event.gen, error.failure)`; a throwing `VoiceSession.start` uses the `.startMic` stamp.
    /// Only the session matters here: a failure of an older session is dropped (REVIEW M3).
    case speechFailed(SpeechGen, SpeechFailure)

    // Async results, matched by the request token of the effect that started them.
    /// `complete`: every requested task list is current now (`IndexStore.revalidateTaskLists(for:activeProjectId:)`,
    /// `IndexCheck.complete`). Not complete: a single hit becomes a one-item confirm list instead of opening. The
    /// controller passes the updated `FlowEnv.index` with this event.
    case taskListsRevalidated(request: Int, complete: Bool)
    /// `complete`: every requested archive is fully indexed now. The controller passes the updated
    /// `FlowEnv.index` with this event. `message`: why not, for the overlay instead of "nicht gefunden"
    /// (`IndexCheck.error?.userMessage`, "AC nicht erreichbar", "AC-Token ungültig"). With a message the flow decides
    /// with what is indexed and fetches no further archives.
    case archiveFetched(request: Int, complete: Bool, message: String? = nil)
    /// `message`: shown for `.failed` instead of "AC nicht erreichbar" (`ACError.userMessage`).
    case probed(request: Int, ProbeResult, message: String? = nil)
    case opened(request: Int, OpenResult)
    /// Chrome and the NSWorkspace fallback both failed.
    case openFailed(request: Int)

    case timer(TimerID)
}

extension FlowEvent {
    /// Maps a plugin command. `hello` and `ping` are not flow events (nil).
    public init?(_ cmd: IPC.Command, source: TriggerSource = .streamDeck) {
        switch cmd {
        case let .press(id, at):
            self = .press(Press(id: id, source: source, at: at > 0 ? Date(timeIntervalSince1970: Double(at) / 1000) : nil))
        case let .release(_, pressId, heldMs): self = .release(pressId: pressId, heldMs: heldMs)
        case let .choose(_, index, seq): self = .choose(n: index, seq: seq)
        case .cancel: self = .cancel
        case .hello, .ping: return nil
        }
    }
}

/// Side effects for the controller, in the order they should run. A `.publish` always comes first.
public enum Effect: Sendable, Equatable {
    /// New overlay snapshot (also the IPC state via `OverlayModel.ipcState()`).
    case publish(OverlayModel)
    /// Order the panel in (cancels a running fade-out).
    case showOverlay
    /// Fade the panel out. The view keeps the last visible content while it fades.
    case hideOverlay(fade: Double)

    /// New mic session: mic on, events stamped with `gen`, end of utterance armed with `hangover`
    /// (`VoiceSession.start(context:source:mode:gen:hangover:)`).
    case startMic(SpeechGen, mode: ListenMode, hangover: Double)
    /// Same session, next utterance: re-arm end of utterance first, then the context
    /// (`VoiceSession.rearm(_:context:gen:hangover:)`).
    case rearm(SpeechGen, mode: ListenMode, hangover: Double)
    /// Adaptive hangover from the live partial (PLAN 2.3, REVIEW M1, Core `HangoverPolicy`), for commands and answers:
    /// the pause budget in seconds that applies from now on in the armed utterance (`VoiceSession.setHangover(_:)`).
    case setHangover(Double)
    /// Push-to-talk: no energy end of utterance while the key is down (REVIEW m4).
    case suspendEndpointing(Bool)
    /// Press while speaking or push-to-talk release: synthetic tail + finalize now (REVIEW M2).
    case endUtteranceNow(SpeechGen)
    case stopMic

    /// Conditional GETs on press (PLAN 5).
    case refreshIndex
    case open(URL, request: Int)
    /// Before the first decision on a ticket number below 10000: revalidate the task lists the decision reads
    /// (`IndexStore.revalidateTaskLists(for: task, activeProjectId:)`), then send `.taskListsRevalidated`.
    case revalidateTaskLists(task: TaskRequest, activeProjectId: Int?, request: Int)
    /// `IndexStore.checkArchives(projectIds)`, then `.archiveFetched(request:complete:message:)`.
    case fetchArchive(projectIds: [Int], request: Int)
    case probeTask(taskId: Int, request: Int)

    case schedule(TimerID, after: Double)
    case cancelTimer(TimerKind)
    case earcon(Earcon)
    /// Persist in History after a successful open.
    case recordOpen(projectId: Int)
    /// `History.recordPick(query:projectId:)`. Sent after `.recordOpen` once Chrome confirmed the open (a pick
    /// cancelled during opening or a failed open teaches nothing) for:
    /// - a pick from a project list shown for `query`;
    /// - a correction (REVIEW m9): a command of this listening session that was not understood
    ///   (`Interpreter.correctionKey`) or whose ticket project was not recognized (`TaskRequest.query`), followed by an
    ///   open of a project resolved from spoken project words.
    /// Rebuild the interpreter afterwards (`Interpreter(projects:config:history:)`).
    case recordPick(query: String, projectId: Int)
}

/// All durations in seconds. Defaults follow PLAN 3 and REVIEW M1/m4/m5; tune in M7.
///
/// The flow owns the end-of-utterance hangovers: it applies `hangovers` (Core `HangoverPolicy`) to every live partial
/// and sends the seconds to the speech layer, which applies them as is. The speech layer's own floor for "no word
/// yet" and for a reopened utterance is `EndpointGate.Config.incompleteHangover`; set it to `incompleteHangover`
/// when tuning.
public struct FlowTimings: Sendable, Equatable {
    /// Hangover for commands.
    public var commandHangover = HangoverPolicy.standard.command
    /// Hangover when the live preview is already a complete intent.
    public var fastHangover = HangoverPolicy.standard.fast
    /// Hangover for answers while a list is visible (0.40 s, as in the speech layer).
    public var answerHangover = HangoverPolicy.standard.answer
    /// Hangover when a command partial ends in a dangling word ("öffne das", "Ticket", "Nummer") (REVIEW M1).
    public var incompleteHangover = HangoverPolicy.standard.incomplete
    /// Hangover when a command partial ends in a number: "Ticket 4" may become 412, "47000" may become 47285, and a
    /// confident single hit opens without a list (REVIEW M1). Not in the answer phase: there a number is the answer.
    public var trailingNumberHangover = HangoverPolicy.standard.trailingNumber

    /// The hangover rule with these values.
    public var hangovers: HangoverPolicy {
        HangoverPolicy(command: commandHangover, fast: fastHangover, answer: answerHangover,
                       incomplete: incompleteHangover, trailingNumber: trailingNumberHangover)
    }

    public var noSpeech = 4.0
    public var maxUtterance = 8.0
    /// Press without micReady after this long -> error.
    public var micStart = 10.0
    /// End of utterance without a final after this long -> use the last partial.
    public var finalize = 2.0
    /// End of utterance while the speech model still loads (cold start, REVIEW m5): the buffered audio is
    /// transcribed once the model is ready, so wait this long; `.speechWarm(true)` shortens it to `finalize`.
    public var coldFinalize = 10.0
    public var retrySilence = 5.0
    /// Choices deadline >= last speech + this.
    public var speechExtension = 2.5
    /// An unclear answer extends the deadline by this.
    public var unclearExtension = 4.0
    /// Speech never extends a list beyond its render time + this (continuous noise).
    public var choicesHardCap = 30.0
    public var fastSelectSilence = 0.25
    /// Chrome shows the page already: a plain success only confirms.
    public var successHold = 0.7
    /// Success with a hint (three lines and an action to read).
    public var hintHold = 3.5
    public var errorHold = 3.0
    /// The pointer left a held card: it fades after at least this.
    public var pointerRelease = 1.0
    /// A list the pointer left keeps at least this much time.
    public var pointerExtension = 2.5
    /// An error or a success with a hint stays at most this long while the pointer rests on it.
    public var pointerHoldCap = 15.0
    public var fade = 0.2
    /// Presses older than this are dropped (queued during a cold app launch).
    public var stalePress = 3.0
    /// A second press this soon after the listening press, before any speech, is an accidental double tap.
    /// 0.4 s: a real double tap takes 0.1-0.3 s, and a deliberate second press to cancel should work soon after
    /// (1.0 s felt too long in the first test). Esc cancels at any time.
    public var doubleTap = 0.4
    /// Release after at least this hold while listening ends the utterance (push-to-talk).
    public var pushToTalkMs = 600
    /// Failed commands answered with a retry before the error.
    public var maxRetries = 1
    /// `IndexStore.revalidateTaskLists` has an 800 ms budget.
    public var revalidateWatchdog = 1.5
    public var archiveWatchdog = 4.0
    public var probeWatchdog = 3.0
    public var openWatchdog = 5.0
    /// Archive fetch rounds before the ticket resolver decides with what is indexed. Every round names only projects
    /// not attempted before (`attemptedArchives`), so the resolver ends by itself after at most 3 rounds; this bound
    /// keeps the wait short (each round has its own `archiveWatchdog`).
    public var maxArchiveRounds = 2
    public init() {}
}

/// Inputs the controller passes with every event. Rebuild the interpreter when projects, signals or the
/// history change; pass the latest task index.
public struct FlowEnv: Sendable {
    public var interpreter: Interpreter
    public var index: TaskIndex
    /// Uses: acBaseURL, myWorkURL, earcons, fastSelect, visibleChoices, choicesWindow, maxUnclearAnswers.
    public var config: Config
    /// Project of the active Chrome AC tab (`Routes.projectId(in:base:)`), when known.
    public var activeProjectId: Int?
    /// Language of the texts and the voice commands, resolved once at launch (`Config.appLanguage`).
    public var language: AppLanguage
    public init(interpreter: Interpreter, index: TaskIndex = .init(), config: Config = .init(), activeProjectId: Int? = nil,
                language: AppLanguage = .de) {
        self.interpreter = interpreter; self.index = index; self.config = config; self.activeProjectId = activeProjectId
        self.language = language
    }
}
