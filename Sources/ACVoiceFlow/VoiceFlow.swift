import Foundation
import ACVoiceCore

/// The voice flow as a pure reducer (PLAN 2.1 and 3). The controller feeds every trigger, speech event, async
/// result and fired timer into `handle` and runs the returned effects in order. No clocks, no I/O: tests drive
/// it with a fake clock.
///
/// Press semantics (PLAN 2.5 with REVIEW m4/m5):
/// | phase                     | press                                                                  |
/// |---------------------------|------------------------------------------------------------------------|
/// | idle / success / error    | listen (new mic session)                                               |
/// | listening / retry, speech | end the utterance now                                                  |
/// | listening, no speech yet  | ignored within `doubleTap` of the listening press, else cancel -> idle |
/// | retry, no speech yet      | cancel -> idle                                                         |
/// | processing / opening      | cancel -> idle (an open already sent to Chrome is not undone)          |
/// | choices                   | cancel -> idle                                                         |
/// Presses older than `stalePress` are dropped. A release with `heldMs >= pushToTalkMs` after speech ends the
/// utterance (push-to-talk); without speech it only resumes listening. End of utterance by energy is suspended
/// while a key with a release edge is down, and the no-speech timeout waits for the release (at most
/// `maxUtterance` after the press).
public struct VoiceFlow: Sendable {
    public private(set) var phase: FlowPhase = .idle
    /// The last published snapshot plus pending changes of the current event.
    public private(set) var model = OverlayModel()
    public var timings: FlowTimings
    /// False until the controller reports a prepared analyzer. A press before that shows "Sprachmodell lädt".
    public private(set) var speechWarm: Bool
    /// The speech stamp accepted now; nil drops every speech event.
    public private(set) var armed: SpeechGen?
    public private(set) var session = 0

    var utterance = 0
    var micOn = false
    var micReady = false
    var listenStart = Date.distantPast
    /// Onset, or any non-empty partial, in the armed utterance.
    var speechSeen = false
    var voiceActive = false
    var silenceSince: Date?
    var lastPartial: [Hypothesis] = []
    var hangover = 0.0
    var suspended = false
    var keyDown: KeyDown?
    /// Failed commands in this session (retry once, then error).
    var failures = 0
    /// End of utterance sent or detected; waiting for the final.
    var finalizing = false
    /// Finalizing started while the speech model was still loading: the `.finalize` watchdog runs with
    /// `coldFinalize` until the model is warm (REVIEW m5).
    var finalizeCold = false
    /// The no-speech timeout already waited once for a held key. A second wait would trust the wall clock twice.
    var noSpeechDeferred = false
    /// Phase and message before `beginFinalizing` moved listening or retry to processing: a resumed or discarded
    /// utterance goes back there.
    var beforeFinalize: (phase: FlowPhase, message: String?)?
    /// The pointer rests on the card (`.pointer`). Physical state; reset when the card goes away.
    var pointerInside = false
    /// success / error: the pointer holds the card (until it leaves, at most `pointerHoldCap`).
    var pointerHolding = false
    /// success / error: when the card fades unless the pointer holds it.
    var fadeDue: Date?
    /// The undetermined-Automation hint showed once in this app run.
    var setupHintShown = false
    /// Queries of this listening session that failed: not understood (`Interpreter.correctionKey`) or a ticket
    /// whose project was not recognized (`TaskRequest.query`). A later open of a project resolved from spoken words
    /// records them as picks (REVIEW m9).
    var corrections: [String] = []
    /// The texts of `FlowEnv.language`, taken from the env at every event (the language is fixed for an app run).
    var texts = FlowText.de

    var request = 0
    var ticketWait: TicketWait?
    var opening: Opening?
    var list: ChoiceList?

    var timerToken = 0
    var timers: [TimerKind: Int] = [:]
    var renumbered = false
    var published = OverlayModel()
    var fx: [Effect] = []

    struct KeyDown: Sendable, Equatable { var id: String?; var at: Date }

    struct TicketWait: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case revalidate, archive, probe(taskId: Int) }
        var request: TaskRequest
        var token: Int
        var kind: Kind
        var rounds: Int
        /// Every project id of the `.fetchArchive` rounds so far, whatever their result (`attemptedArchives`).
        var attempted: Set<Int> = []
    }

    struct Opening: Sendable, Equatable {
        var url: URL
        var title: String
        var projectId: Int?
        var token: Int
        /// Query of the project list the user picked from; recorded once the open is confirmed.
        var pickQuery: String?
        /// Failed queries of this session to record as corrections once the open is confirmed.
        var corrections: [String] = []
    }

    struct ChoiceList: Sendable, Equatable {
        /// `spokenProject`: the ticket command named its project, so a pick may teach a correction.
        enum Kind: Sendable, Equatable { case projects(query: String), tickets(number: Int, spokenProject: Bool) }
        var kind: Kind
        var items: [ChoiceItem]
        var pageSize: Int
        var deadline: Date
        /// Last render (new list, page, narrow); base of the hard cap.
        var renderedAt: Date
        var page = 0
        /// First `seq` that showed this numbering; `choose` with an older seq is stale (REVIEW m4).
        var listSeq = Int.max
        var unclear = 0
        /// fastSelect: pick seen in the latest partial.
        var pendingPick: Int?
        /// The pointer rests on the list: seconds left when it arrived. `deadline` is the hard cap meanwhile.
        var pausedRemaining: Double?
        var pageCount: Int { max(1, (items.count + pageSize - 1) / pageSize) }
        var visible: ArraySlice<ChoiceItem> {
            let lo = min(page * pageSize, items.count)
            return items[lo..<min(lo + pageSize, items.count)]
        }
    }

    enum Failure: Sendable {
        case notUnderstood, projectNotRecognized, nothingHeard
        func retryText(_ t: FlowText) -> String {
            switch self {
            case .notUnderstood: return t.notUnderstoodRetry
            case .projectNotRecognized: return t.projectNotRecognizedRetry
            case .nothingHeard: return t.nothingHeardRetry
            }
        }
        func errorText(_ t: FlowText) -> String {
            switch self {
            case .notUnderstood: return t.notUnderstood
            case .projectNotRecognized: return t.projectNotRecognized
            case .nothingHeard: return t.nothingHeard
            }
        }
    }

    struct Ctx { let now: Date; let env: FlowEnv }

    public init(timings: FlowTimings = .init(), speechWarm: Bool = false) {
        self.timings = timings
        self.speechWarm = speechWarm
    }

    /// Visible list state for the controller (`nil` outside choices).
    public var choiceItems: [ChoiceItem]? { list?.items }

    // MARK: - Entry point

    public mutating func handle(_ event: FlowEvent, now: Date, env: FlowEnv) -> [Effect] {
        fx = []
        if texts.language != env.language { texts = FlowText(env.language) }
        let c = Ctx(now: now, env: env)
        switch event {
        case .press(let p): press(p, c)
        case let .release(pressId, heldMs): release(pressId, heldMs, c)
        case let .choose(n, seq): choose(n, seq, c)
        case .cancel: if phase != .idle { toIdle(c) }
        case .pointer(let inside): pointer(inside, c)

        case .speechWarm(let warm):
            if warm {
                becameWarm()
            } else {
                speechWarm = false
                if phase == .listening || phase == .retry { setWarming(true) }
            }
        case .micReady(let g):
            guard micOn, g.session == session, !micReady else { break }
            micReady = true
            model.micReady = true
            cancel(.micStart)
            earcon(.listen, c)
            if phase == .listening, !speechSeen { schedule(.noSpeech, timings.noSpeech) }
        case .speechStarted(let g):
            guard accepts(g) else { break }
            voiceActive = true
            silenceSince = nil
            let first = !speechSeen
            markSpeech()
            // Every onset restarts the utterance cap (the first one inside `markSpeech`): an onset the speech layer
            // discarded as noise must not cap the real command (review C1).
            if !first, !finalizing, phase == .listening || phase == .retry || phase == .choices {
                schedule(.maxUtterance, timings.maxUtterance)
            }
            cancel(.fastSelect)
            extendDeadline(c)
        case .speechResumed(let g):
            guard accepts(g) else { break }
            resumeUtterance(c)
        case .speechDiscarded(let g):
            guard accepts(g) else { break }
            discardOnset(c)
        case let .voice(g, active):
            guard accepts(g) else { break }
            voiceActive = active
            if active {
                silenceSince = nil
                markSpeech()
                cancel(.fastSelect)
            } else {
                silenceSince = c.now
                armFastSelect(c)
            }
            extendDeadline(c)
        case let .partial(g, transcript, hyps):
            guard accepts(g) else { break }
            partial(transcript, hyps, c)
        case .speechEnded(let g):
            guard accepts(g), !finalizing else { break }
            voiceActive = false
            if silenceSince == nil { silenceSince = c.now }
            beginFinalizing()
        case let .utterance(g, hyps):
            guard accepts(g) else { break }
            finishUtterance(hyps, c)
        case .noSpeech(let g):
            guard accepts(g) else { break }
            noSpeechTimeout(c)
        case let .speechFailed(g, failure):
            // Session-level: any utterance of the current session counts, an older session never (REVIEW M3).
            guard micOn, g.session == session else { break }
            error(texts.failure(failure), c)

        case let .taskListsRevalidated(token, complete):
            guard phase == .processing, let w = ticketWait, w.token == token, w.kind == .revalidate else { break }
            ticketDecision(w.request, listsCurrent: complete, c)
        case let .archiveFetched(token, _, message):
            // Every attempted id stays attempted whatever the result, so the resolver never asks for it again. An AC
            // error ends the search: decide with what is indexed and show the error instead of "nicht gefunden".
            guard phase == .processing, let w = ticketWait, w.token == token, w.kind == .archive else { break }
            resolveTicket(w.request, rounds: w.rounds, attempted: w.attempted,
                          decideNow: message != nil || w.rounds >= timings.maxArchiveRounds, message: message, c)
        case let .probed(token, result, message):
            guard phase == .processing, let w = ticketWait, w.token == token, case .probe(let taskId) = w.kind else { break }
            cancel(.probe)
            ticketWait = nil
            switch result {
            case .found(let pid): openTask(projectId: pid, taskId: taskId, number: w.request.number, learns: false, c)
            case .notFound: error(texts.ticketNotFound(w.request.number), c)
            case .failed: error(message ?? texts.acUnreachable, c)
            }
        case let .opened(token, result):
            guard phase == .opening, let o = opening, o.token == token else { break }
            cancel(.open)
            opening = nil
            // History learns real opens only: a pick cancelled during opening or a failed open teaches nothing.
            if let pid = o.projectId {
                fx.append(.recordOpen(projectId: pid))
                if let q = o.pickQuery { fx.append(.recordPick(query: q, projectId: pid)) }
                for q in o.corrections where q != o.pickQuery { fx.append(.recordPick(query: q, projectId: pid)) }
            }
            var hint: String?
            switch result {
            case .fallback(.denied):
                hint = texts.automationHint
            case .fallback(.undetermined) where !setupHintShown:
                // Once per app run; the menu badge and the setup window cover the rest.
                setupHintShown = true
                hint = texts.automationSetupHint
            default:
                break
            }
            success(o.title, hint: hint, c)
        case .openFailed(let token):
            guard phase == .opening, let o = opening, o.token == token else { break }
            opening = nil
            error(texts.openFailed, c)

        case .timer(let id):
            guard timers[id.kind] == id.token else { break }
            timers[id.kind] = nil
            fire(id.kind, c)
        }
        flush(c)
        let out = fx
        fx = []
        return out
    }

    // MARK: - Triggers

    mutating func press(_ p: Press, _ c: Ctx) {
        if let at = p.at, c.now.timeIntervalSince(at) > timings.stalePress { return }
        switch phase {
        case .idle, .success, .error:
            startListening(p, c)
        case .listening, .retry:
            if speechSeen {
                endNow()
            } else if phase == .listening, c.now.timeIntervalSince(listenStart) < timings.doubleTap {
                return   // accidental double tap before any speech (REVIEW m5)
            } else {
                toIdle(c)
            }
        case .processing, .opening, .choices:
            toIdle(c)
        }
    }

    mutating func release(_ pressId: String?, _ heldMs: Int, _ c: Ctx) {
        guard let k = keyDown else { return }
        if let pressId, let held = k.id, pressId != held { return }
        keyDown = nil
        if suspended {
            suspended = false
            if micOn { fx.append(.suspendEndpointing(false)) }
        }
        guard phase == .listening || phase == .retry else { return }
        if speechSeen {
            if heldMs >= timings.pushToTalkMs { endNow() }
        } else if phase == .listening, micReady {
            // A slow tap or a hold without speech: keep listening, 4 s of silence from now on.
            schedule(.noSpeech, timings.noSpeech)
        }
    }

    mutating func choose(_ n: Int, _ seq: Int?, _ c: Ctx) {
        guard phase == .choices, let l = list else { return }
        if let seq, seq < l.listSeq { return }
        // Range check before any arithmetic: `n` comes from the wire (Int.min would trap in `n - 1`).
        guard n >= 1, n <= l.items.count else { return }
        pick(n - 1, c)
    }

    mutating func startListening(_ p: Press, _ c: Ctx) {
        cancelAllTimers()
        clearSession()
        failures = 0
        session += 1
        utterance = 1
        let gen = SpeechGen(session: session, utterance: utterance)
        armed = gen
        micOn = true
        micReady = false
        listenStart = c.now
        hangover = timings.commandHangover
        phase = .listening
        model = OverlayModel()
        model.phase = .listening
        model.visible = true
        setWarming(!speechWarm)
        fx.append(.showOverlay)
        fx.append(.startMic(gen, mode: .command, hangover: hangover))
        if p.source.hasRelease {
            keyDown = KeyDown(id: p.id, at: p.at ?? c.now)
            suspended = true
            fx.append(.suspendEndpointing(true))
        }
        fx.append(.refreshIndex)
        schedule(.micStart, timings.micStart)
    }

    // MARK: - Speech

    func accepts(_ g: SpeechGen) -> Bool { armed == g }

    mutating func markSpeech() {
        guard !speechSeen else { return }
        speechSeen = true
        cancel(.noSpeech)
        cancel(.retrySilence)
        if !finalizing { schedule(.maxUtterance, timings.maxUtterance) }
    }

    mutating func setWarming(_ warming: Bool) {
        model.warming = warming
        if warming {
            if model.message == nil { model.message = texts.loadingModel }
        } else if model.message == texts.loadingModel {
            model.message = nil
        }
    }

    /// The analyzer is prepared (`.speechWarm(true)` or a first partial). A cold finalize gets the normal watchdog.
    mutating func becameWarm() {
        speechWarm = true
        if model.warming { setWarming(false) }
        if finalizing, finalizeCold {
            finalizeCold = false
            schedule(.finalize, timings.finalize)
        }
    }

    mutating func updateHangover(_ h: Double) {
        guard h != hangover else { return }
        hangover = h
        fx.append(.setHangover(h))
    }

    mutating func partial(_ t: Transcript, _ hyps: [Hypothesis], _ c: Ctx) {
        let text = t.text
        let hs = (hyps.isEmpty ? [Hypothesis(text)] : hyps).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !hs.isEmpty else { return }
        lastPartial = hs
        // A list keeps the command as its headline; the answer shows in the footer.
        if phase == .choices { model.answer = t } else { model.transcript = t }
        if !speechWarm || model.warming { becameWarm() }
        markSpeech()
        switch phase {
        case .listening, .retry:
            guard !finalizing else { return }
            let i = c.env.interpreter.command(hs, now: c.now)
            let language = c.env.language
            if i == .cancel, LivePolicy.isStrongCancel(text, language: language) { toIdle(c); return }
            model.preview = LivePolicy.preview(i, texts)
            updateHangover(timings.hangovers.command(text: LivePolicy.leading(hs, language: language), interpretation: i,
                                                     language: language))
        case .choices:
            extendDeadline(c)
            guard let l = list else { return }
            let out = c.env.interpreter.selection(hs, candidates: l.items.map(\.target.projectId), now: c.now)
            let language = c.env.language
            if out == .cancel, LivePolicy.isStrongCancel(text, language: language) { toIdle(c); return }
            // A new command ("Öffne … TKZ", "Ticket 4…12") follows the command rules. A dangling answer word ("die …
            // zweite") keeps the answer budget: the speech layer reopens a final that dangles (REVIEW M1).
            if !finalizing {
                updateHangover(timings.hangovers.answer(text: LivePolicy.leading(hs, language: language), outcome: out,
                                                        language: language, command: {
                    c.env.interpreter.command(hs, now: c.now)
                }))
            }
            guard c.env.config.fastSelect else { return }
            // English: a live pick commits only when the leading hypothesis reads it too and its last word cannot
            // still change it ("one" -> "one second", "second" -> "second to last"). A lagging hypothesis that still
            // says "One" must not win over "one moment". Otherwise the final decides.
            let lead = LivePolicy.leading(hs, language: language)
            if case .pick(let i) = out, language == .de || (!Parser.pickMayChange(lead, language: language)
                && c.env.interpreter.selection([Hypothesis(lead)], candidates: l.items.map(\.target.projectId), now: c.now) == out) {
                // Two consecutive partials with the same pick commit at once (PLAN 3 fastSelect).
                if l.pendingPick == i { pick(i, c); return }
                list?.pendingPick = i
                armFastSelect(c)
            } else {
                list?.pendingPick = nil
                cancel(.fastSelect)
            }
        default:
            break   // processing: finalizing, transcript only
        }
    }

    /// fastSelect: a pending partial pick commits after `fastSelectSilence` of silence (needs `.voice` events).
    mutating func armFastSelect(_ c: Ctx) {
        guard phase == .choices, let i = list?.pendingPick, c.env.config.fastSelect, !voiceActive,
              let quiet = silenceSince else { return }
        let left = quiet.addingTimeInterval(timings.fastSelectSilence).timeIntervalSince(c.now)
        if left <= 0 { pick(i, c) } else { schedule(.fastSelect, min(left, timings.fastSelectSilence)) }
    }

    mutating func endNow() {
        guard let g = armed, !finalizing else { return }
        fx.append(.endUtteranceNow(g))
        beginFinalizing()
    }

    mutating func beginFinalizing() {
        if phase == .listening || phase == .retry { beforeFinalize = (phase, model.message) }
        finalizing = true
        for k: TimerKind in [.noSpeech, .maxUtterance, .retrySilence, .micStart] { cancel(k) }
        // Cold start (REVIEW m5): the speech layer buffers the audio until the model is ready. Wait for it instead
        // of deciding from an empty partial after `finalize`.
        finalizeCold = !speechWarm
        schedule(.finalize, finalizeCold ? max(timings.coldFinalize, timings.finalize) : timings.finalize)
        if phase == .listening || phase == .retry {
            phase = .processing
            model.phase = .processing
            model.message = nil
            setWarming(finalizeCold)   // "Sprachmodell lädt" stays up while the model is not ready
        }
    }

    /// `.speechResumed`: the utterance the gate ended goes on (its final text dangled). Undo `beginFinalizing`.
    mutating func resumeUtterance(_ c: Ctx) {
        voiceActive = true
        silenceSince = nil
        guard finalizing else { return }   // no `.speechEnded` came first: nothing to undo
        finalizing = false
        finalizeCold = false
        cancel(.finalize)
        restoreBeforeFinalize()
        if phase == .listening || phase == .retry || phase == .choices { schedule(.maxUtterance, timings.maxUtterance) }
    }

    /// `.speechDiscarded`: the onset was noise. Listen on as if nothing was said: the no-speech timeout (or the retry
    /// silence) counts again, and the utterance cap waits for the next onset (review C1).
    mutating func discardOnset(_ c: Ctx) {
        guard speechSeen || finalizing else { return }
        speechSeen = false
        voiceActive = false
        silenceSince = nil
        lastPartial = []
        finalizing = false
        finalizeCold = false
        for k: TimerKind in [.finalize, .maxUtterance, .fastSelect] { cancel(k) }
        restoreBeforeFinalize()
        switch phase {
        case .listening, .retry:
            model.transcript = Transcript()
            model.preview = nil
            updateHangover(timings.commandHangover)
            if phase == .retry {
                schedule(.retrySilence, timings.retrySilence)
            } else if micReady {
                schedule(.noSpeech, timings.noSpeech)
            }
        default:
            break
        }
    }

    mutating func restoreBeforeFinalize() {
        defer { beforeFinalize = nil }
        guard phase == .processing, let before = beforeFinalize else { return }
        phase = before.phase
        model.phase = before.phase
        model.message = before.message
        setWarming(!speechWarm)
    }

    mutating func finishUtterance(_ raw: [Hypothesis], _ c: Ctx) {
        armed = nil
        beforeFinalize = nil
        finalizing = false
        finalizeCold = false
        for k: TimerKind in [.finalize, .maxUtterance, .noSpeech, .retrySilence, .fastSelect, .micStart] { cancel(k) }
        let hyps = raw.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch phase {
        case .listening, .retry, .processing: command(hyps, c)
        case .choices: answer(hyps, c)
        default: break
        }
    }

    mutating func noSpeechTimeout(_ c: Ctx) {
        guard !speechSeen, !finalizing else { return }
        switch phase {
        case .listening:
            // A held key (push-to-talk) keeps listening up to `maxUtterance` after the press. One wait at most, and
            // never longer than `maxUtterance`: a wall clock that went back must not keep the mic on.
            if let k = keyDown, !noSpeechDeferred {
                let left = k.at.addingTimeInterval(timings.maxUtterance).timeIntervalSince(c.now)
                if left > 0 {
                    noSpeechDeferred = true
                    schedule(.noSpeech, min(left, timings.maxUtterance))
                    return
                }
            }
            error(texts.nothingHeard, c)
        case .retry:
            toIdle(c)
        default:
            break
        }
    }

    // MARK: - Commands

    mutating func command(_ hyps: [Hypothesis], _ c: Ctx) {
        list = nil
        phase = .processing
        clearListModel()
        model.phase = .processing
        model.transcript = Transcript(stable: hyps.first?.text ?? "")
        model.preview = nil
        model.message = nil
        model.warming = false
        guard !hyps.isEmpty else { retryOrFail(.nothingHeard, c); return }
        apply(c.env.interpreter.command(hyps, now: c.now), hyps, c)
    }

    mutating func apply(_ i: Interpretation, _ hyps: [Hypothesis], _ c: Ctx) {
        switch i {
        case .myTasks:
            open(url: c.env.config.myWorkURL, title: texts.myTasks, projectId: nil, c)
        case .project(.unique(let s), _):
            open(url: Routes.project(c.env.config.acBaseURL, s.project.id), title: ChoiceBuilder.display(s.project),
                 projectId: s.project.id, learns: true, c)
        case .project(.ambiguous(let candidates), let query) where !candidates.isEmpty:
            showList(.projects(query: query), ChoiceBuilder.projects(candidates.map(\.project), now: c.now), c)
        case .task(let req):
            beginTicket(req, c)
        case .cancel:
            toIdle(c)
        case .project, .notUnderstood:
            if c.env.interpreter.resolver.projects.isEmpty { error(texts.noProjectData, c); return }
            noteCorrection(c.env.interpreter.correctionKey(hyps))
            retryOrFail(.notUnderstood, c)
        }
    }

    /// Remembers a failed query of this session for correction learning (REVIEW m9).
    mutating func noteCorrection(_ key: String?) {
        guard let key, !key.isEmpty, !corrections.contains(key), corrections.count < 3 else { return }
        corrections.append(key)
    }

    /// Ticket flow, first step. A task number (< 10000) is decided from cached task lists that refresh only every
    /// 10-15 minutes: revalidate the lists the decision reads first (PLAN 5). A global id or project words that matched
    /// nothing need no lists.
    mutating func beginTicket(_ req: TaskRequest, _ c: Ctx) {
        if case .none? = req.projects { resolveTicket(req, rounds: 0, attempted: [], decideNow: false, c); return }
        guard req.number < TicketResolver.globalIdThreshold else {
            resolveTicket(req, rounds: 0, attempted: [], decideNow: false, c)
            return
        }
        request += 1
        ticketWait = TicketWait(request: req, token: request, kind: .revalidate, rounds: 0)
        fx.append(.revalidateTaskLists(task: req, activeProjectId: c.env.activeProjectId, request: request))
        schedule(.revalidate, timings.revalidateWatchdog)
    }

    /// After the revalidation (or its watchdog). Stale lists may hide the same number in a sibling project, so a single
    /// hit only asks for confirmation ("Sag ja oder eins") instead of opening.
    mutating func ticketDecision(_ req: TaskRequest, listsCurrent: Bool, _ c: Ctx) {
        cancel(.revalidate)
        var r = req
        if !listsCurrent { r.confident = false }
        resolveTicket(r, rounds: 0, attempted: [], decideNow: false, c)
    }

    /// Ticket flow (PLAN 5, REVIEW M6): open, list, archive search, probe, or a message. `attempted`: every project of
    /// the archive rounds so far (`attemptedArchives`). `decideNow`: no further archive round. `message`: an AC error
    /// to show instead of "nicht gefunden".
    mutating func resolveTicket(_ req: TaskRequest, rounds: Int, attempted: Set<Int>, decideNow: Bool,
                                message: String? = nil, _ c: Ctx) {
        ticketWait = nil
        for k: TimerKind in [.revalidate, .archive, .probe] { cancel(k) }
        let outcome = c.env.interpreter.ticket(req, index: c.env.index, activeProjectId: c.env.activeProjectId,
                                               archivesFetched: decideNow, attemptedArchives: attempted, now: c.now)
        // A task number resolved from spoken project words may teach a correction; a global id may not.
        let learns = req.projects != nil && req.number < TicketResolver.globalIdThreshold
        let texts = texts
        let notFound = { message ?? texts.ticketNotFound(req.number, code: req.projects.flatMap { LivePolicy.commonCode($0.candidates.map(\.project)) }) }
        switch outcome {
        case let .open(pid, tid):
            openTask(projectId: pid, taskId: tid, number: req.number, learns: learns, c)
        case .choices(let refs) where !refs.isEmpty:
            // One item is a confirm prompt: "Sag ja oder eins", "nein" closes it.
            let byId = Dictionary(c.env.interpreter.resolver.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let items = ChoiceBuilder.tickets(refs, projects: byId, mine: Set(c.env.index.mine.map(\.id)), now: c.now, texts: texts)
            showList(.tickets(number: req.number, spokenProject: learns), items, c)
        case .choices, .notFound:
            error(notFound(), c)
        case .fetchArchive(let pids):
            if decideNow {
                error(notFound(), c)   // defensive: Core never asks again once told to decide
            } else if rounds >= timings.maxArchiveRounds {
                resolveTicket(req, rounds: rounds, attempted: attempted, decideNow: true, message: message, c)
            } else {
                request += 1
                ticketWait = TicketWait(request: req, token: request, kind: .archive, rounds: rounds + 1,
                                        attempted: attempted.union(pids))
                waitForAC(texts.searchingTicket(req.number))
                fx.append(.fetchArchive(projectIds: pids, request: request))
                schedule(.archive, timings.archiveWatchdog)
            }
        case .probe(let taskId):
            request += 1
            ticketWait = TicketWait(request: req, token: request, kind: .probe(taskId: taskId), rounds: rounds,
                                    attempted: attempted)
            waitForAC(texts.searchingTicket(req.number))
            fx.append(.probeTask(taskId: taskId, request: request))
            schedule(.probe, timings.probeWatchdog)
        case .trashed:
            error(texts.ticketTrashed, c)
        case .projectNotRecognized:
            noteCorrection(req.query)
            retryOrFail(.projectNotRecognized, c)
        }
    }

    mutating func waitForAC(_ message: String) {
        phase = .processing
        model.phase = .processing
        model.message = message
    }

    mutating func openTask(projectId: Int, taskId: Int, number: Int, learns: Bool, _ c: Ctx) {
        let project = c.env.interpreter.resolver.projects.first { $0.id == projectId }
        open(url: Routes.task(c.env.config.acBaseURL, projectId: projectId, taskId: taskId),
             title: texts.ticketTitle(number, project: project.map(ChoiceBuilder.display)), projectId: projectId,
             learns: learns, c)
    }

    mutating func retryOrFail(_ f: Failure, _ c: Ctx) {
        failures += 1
        guard micOn, failures <= timings.maxRetries else { error(f.errorText(texts), c); return }
        list = nil
        ticketWait = nil
        for k: TimerKind in [.revalidate, .archive, .probe] { cancel(k) }
        let gen = nextUtterance()
        hangover = timings.commandHangover
        phase = .retry
        clearListModel()
        model.phase = .retry
        model.message = f.retryText(texts)
        model.preview = nil
        model.micReady = micReady
        fx.append(.rearm(gen, mode: .command, hangover: hangover))
        schedule(.retrySilence, timings.retrySilence)
    }

    // MARK: - Choices

    mutating func showList(_ kind: ChoiceList.Kind, _ items: [ChoiceItem], _ c: Ctx) {
        ticketWait = nil
        for k: TimerKind in [.revalidate, .archive, .probe, .noSpeech, .maxUtterance, .retrySilence, .micStart, .finalize] { cancel(k) }
        let window = c.env.config.choicesWindow
        list = ChoiceList(kind: kind, items: items, pageSize: max(1, c.env.config.visibleChoices),
                          deadline: c.now.addingTimeInterval(window), renderedAt: c.now)
        renumbered = true
        phase = .choices
        schedule(.choicesDeadline, window)
        renderList()
        if pointerInside { pauseList(c) }
        rearmAnswer()
    }

    mutating func renderList() {
        guard let l = list else { return }
        model.phase = .choices
        model.choices = Array(l.visible)
        model.total = l.items.count
        model.page = l.page
        model.pageCount = l.pageCount
        model.pageSize = l.pageSize
        model.deadline = l.deadline
        model.countdownFrozen = l.pausedRemaining
        model.hint = l.items.count == 1 ? texts.sayYesOrOne : nil
        model.hintIsAlert = false
        model.preview = nil
        model.message = nil
        model.warming = false
    }

    /// Next answer in the same session (PLAN `expectAnswer`). The contextual strings cover the visible page only,
    /// numbered from its first row (absolute numbers across "mehr" pages).
    mutating func rearmAnswer() {
        guard micOn, let l = list else { armed = nil; return }
        for k: TimerKind in [.fastSelect, .maxUtterance, .finalize] { cancel(k) }
        list?.pendingPick = nil
        let gen = nextUtterance()
        hangover = timings.answerHangover
        let page = Array(l.visible)
        let mode = ListenMode.answer(titles: page.map { $0.title.isEmpty ? $0.label : $0.title },
                                     firstNumber: page.first?.n ?? 1, hasMore: l.pageCount > 1)
        fx.append(.rearm(gen, mode: mode, hangover: hangover))
    }

    mutating func answer(_ hyps: [Hypothesis], _ c: Ctx) {
        guard let l = list else { return }
        // The headline keeps the command; what the user answered shows in the footer hint when it explains something.
        let heard = Self.clipped(hyps.first?.text ?? "")
        model.answer = Transcript()
        guard !hyps.isEmpty else { rearmAnswer(); return }   // noise: listen on, no failure
        switch c.env.interpreter.selection(hyps, candidates: l.items.map(\.target.projectId), now: c.now) {
        case .pick(let i): pick(i, c)
        case .narrow(let idx): narrow(idx, heard: heard, c)
        case .cancel: toIdle(c)
        case .more: nextPage(c)
        case .keepListening: rearmAnswer()
        case .unclear:
            // "die", "Nummer", "Öffne das": the gate cut a hesitation (REVIEW M1). Listen on, no failed attempt.
            if Self.isHesitation(hyps, language: c.env.language) { rearmAnswer() } else { unclear(heard: heard, c) }
        case .command: command(hyps, c)
        }
    }

    /// An answer quoted in the footer: at most `limit` characters, cut at the end.
    static func clipped(_ text: String, limit: Int = 24) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= limit ? t : String(t.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Every best hypothesis (all of them when none weighs 1) holds only dangling words and lead-ins.
    static func isHesitation(_ hyps: [Hypothesis], language: AppLanguage = .de) -> Bool {
        let best = hyps.filter { $0.weight >= 1 }
        return (best.isEmpty ? hyps : best).allSatisfy { LivePolicy.isHesitation($0.text, language: language) }
    }

    mutating func pick(_ i: Int, _ c: Ctx) {
        guard let l = list, l.items.indices.contains(i) else { return }
        let item = l.items[i]
        let base = c.env.config.acBaseURL
        switch item.target {
        case .project(let id):
            // Ticket lists do not teach project picks.
            var query: String?
            if case .projects(let q) = l.kind, !q.isEmpty { query = q }
            open(url: Routes.project(base, id), title: item.displayName, projectId: id, pickQuery: query, learns: true, c)
        case let .task(pid, tid, number):
            var learns = false
            if case .tickets(_, let spoken) = l.kind { learns = spoken }
            open(url: Routes.task(base, projectId: pid, taskId: tid),
                 title: texts.ticketTitle(number > 0 ? number : tid, project: item.displayName), projectId: pid,
                 learns: learns, c)
        }
    }

    mutating func narrow(_ idx: [Int], heard: String = "", _ c: Ctx) {
        guard var l = list else { return }
        let kept = idx.filter(l.items.indices.contains).map { l.items[$0] }
        guard !kept.isEmpty else { unclear(heard: heard, c); return }
        l.items = kept.enumerated().map { offset, item in
            var copy = item
            copy.n = offset + 1
            return copy
        }
        l.page = 0
        l.pendingPick = nil
        l.pausedRemaining = nil
        l.deadline = c.now.addingTimeInterval(c.env.config.choicesWindow)
        l.renderedAt = c.now
        list = l
        renumbered = true
        schedule(.choicesDeadline, c.env.config.choicesWindow)
        renderList()
        if kept.count > 1 { model.hint = texts.narrowed(heard, count: kept.count) }
        if pointerInside { pauseList(c) }
        rearmAnswer()
    }

    mutating func nextPage(_ c: Ctx) {
        guard var l = list else { return }
        guard l.pageCount > 1 else {
            model.hint = texts.noMoreChoices
            rearmAnswer()
            return
        }
        l.page = (l.page + 1) % l.pageCount
        l.pausedRemaining = nil
        l.deadline = c.now.addingTimeInterval(c.env.config.choicesWindow)
        l.renderedAt = c.now
        list = l
        schedule(.choicesDeadline, c.env.config.choicesWindow)
        renderList()
        if pointerInside { pauseList(c) }
        rearmAnswer()
    }

    mutating func unclear(heard: String = "", _ c: Ctx) {
        guard var l = list else { return }
        l.unclear += 1
        guard l.unclear <= c.env.config.maxUnclearAnswers else { error(texts.selectionFailed, c); return }
        // A held list keeps its frozen countdown; the hard cap is its deadline meanwhile.
        if l.pausedRemaining == nil {
            l.deadline = min(max(l.deadline, c.now).addingTimeInterval(timings.unclearExtension), capDate(l, c))
        }
        list = l
        model.deadline = l.deadline
        model.hint = l.items.count == 1 ? texts.sayYesOrOne : texts.unclearAnswer(heard)
        model.hintIsAlert = true
        scheduleDeadline(c)
        guard phase == .choices else { return }   // hard cap reached or wall clock jumped: closed
        rearmAnswer()
    }

    /// Longest time a list stays up after its render: the hard cap, or a longer configured window.
    func listSpan(_ c: Ctx) -> Double { max(timings.choicesHardCap, c.env.config.choicesWindow) }

    /// Neither speech nor unclear answers extend a list beyond this date.
    func capDate(_ l: ChoiceList, _ c: Ctx) -> Date { l.renderedAt.addingTimeInterval(listSpan(c)) }

    /// While the user speaks: deadline >= now + `speechExtension`, at most `choicesHardCap` after the render.
    mutating func extendDeadline(_ c: Ctx) {
        guard phase == .choices, var l = list, l.pausedRemaining == nil else { return }
        let cap = max(capDate(l, c), l.deadline)
        let want = min(max(l.deadline, c.now.addingTimeInterval(timings.speechExtension)), cap)
        guard want > l.deadline else { return }
        l.deadline = want
        list = l
        model.deadline = want
    }

    /// (Re)schedules the deadline timer from the wall-clock deadline. The controller's timers run on a monotonic
    /// clock: more time left than a list can have means the wall clock went back, so the list closes (mic off)
    /// instead of waiting for the jump.
    mutating func scheduleDeadline(_ c: Ctx) {
        guard let l = list else { return }
        let left = l.deadline.timeIntervalSince(c.now)
        if left <= 0.001 { toIdle(c); return }
        if left > listSpan(c) + 1 { toIdle(c); return }
        schedule(.choicesDeadline, left)
    }

    mutating func deadlineReached(_ c: Ctx) {
        guard phase == .choices else { return }
        if voiceActive || finalizing { extendDeadline(c) }
        scheduleDeadline(c)
    }

    // MARK: - Pointer

    /// The pointer moved onto the card or left it (`.pointer`).
    mutating func pointer(_ inside: Bool, _ c: Ctx) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        switch phase {
        case .choices: if inside { pauseList(c) } else { resumeList(c) }
        case .success, .error: if inside { holdCard(c) } else { releaseCard(c) }
        default: break
        }
    }

    /// The pointer rests on the list: the countdown stands still, the list stays up to its hard cap.
    mutating func pauseList(_ c: Ctx) {
        guard phase == .choices, var l = list, l.pausedRemaining == nil else { return }
        l.pausedRemaining = max(0, l.deadline.timeIntervalSince(c.now))
        l.deadline = max(l.deadline, capDate(l, c))
        list = l
        model.deadline = l.deadline
        model.countdownFrozen = l.pausedRemaining
        scheduleDeadline(c)
    }

    /// The pointer left the list: the countdown goes on with the time it had, at least `pointerExtension`.
    mutating func resumeList(_ c: Ctx) {
        guard phase == .choices, var l = list, let left = l.pausedRemaining else { return }
        l.pausedRemaining = nil
        l.deadline = min(capDate(l, c), c.now.addingTimeInterval(max(left, timings.pointerExtension)))
        list = l
        model.deadline = l.deadline
        model.countdownFrozen = nil
        scheduleDeadline(c)
    }

    /// The fade timer of the card on screen.
    var fadeKind: TimerKind? {
        switch phase {
        case .success: return .success
        case .error: return .error
        default: return nil
        }
    }

    /// An error, or a success with a hint, stays while the pointer rests on it (at most `pointerHoldCap`).
    mutating func holdCard(_ c: Ctx) {
        guard !pointerHolding, let kind = fadeKind, phase == .error || model.hint != nil else { return }
        pointerHolding = true
        schedule(kind, timings.pointerHoldCap)
    }

    /// The pointer left a held card: it fades after the time it had left, at least `pointerRelease`.
    mutating func releaseCard(_ c: Ctx) {
        guard pointerHolding, let kind = fadeKind else { return }
        pointerHolding = false
        let left = max(fadeDue.map { $0.timeIntervalSince(c.now) } ?? 0, timings.pointerRelease)
        fadeDue = c.now.addingTimeInterval(left)
        schedule(kind, left)
    }

    // MARK: - Opening, success, error, idle

    /// `learns`: the project came from spoken project words, so the session's failed queries teach it (REVIEW m9).
    mutating func open(url: URL, title: String, projectId: Int?, pickQuery: String? = nil, learns: Bool = false, _ c: Ctx) {
        request += 1
        fx.append(.open(url, request: request))
        stopMic()
        cancelAllTimers()
        list = nil
        ticketWait = nil
        finalizing = false
        finalizeCold = false
        opening = Opening(url: url, title: title, projectId: projectId, token: request, pickQuery: pickQuery,
                          corrections: learns && projectId != nil ? corrections : [])
        phase = .opening
        clearListModel()
        model.phase = .opening
        model.preview = title
        model.message = nil
        model.micReady = false
        model.warming = false
        schedule(.open, timings.openWatchdog)
    }

    mutating func success(_ title: String, hint: String?, _ c: Ctx) {
        cancelAllTimers()
        phase = .success
        clearListModel()
        model.phase = .success
        model.message = title
        model.hint = hint
        model.preview = nil
        earcon(.done, c)
        let hold = hint == nil ? timings.successHold : timings.hintHold
        fadeDue = c.now.addingTimeInterval(hold)
        pointerHolding = false
        schedule(.success, hold)
        if pointerInside { holdCard(c) }
    }

    mutating func error(_ message: String, _ c: Ctx) {
        stopMic()
        cancelAllTimers()
        clearSession()
        phase = .error
        if !model.visible { fx.append(.showOverlay) }
        clearListModel()
        model.visible = true
        model.phase = .error
        model.message = message
        model.hint = texts.hint(forError: message)
        model.preview = nil
        model.micReady = false
        model.warming = false
        earcon(.error, c)
        fadeDue = c.now.addingTimeInterval(timings.errorHold)
        pointerHolding = false
        schedule(.error, timings.errorHold)
        if pointerInside { holdCard(c) }
    }

    mutating func toIdle(_ c: Ctx) {
        let wasVisible = model.visible
        stopMic()
        cancelAllTimers()
        clearSession()
        phase = .idle
        model = OverlayModel()
        // The card goes away: the pointer is on nothing of ours (the overlay reports its next entry anew).
        pointerInside = false
        if wasVisible { fx.append(.hideOverlay(fade: timings.fade)) }
    }

    // MARK: - Timers

    mutating func fire(_ kind: TimerKind, _ c: Ctx) {
        switch kind {
        case .noSpeech:
            noSpeechTimeout(c)
        case .maxUtterance:
            if armed != nil, !finalizing, phase == .listening || phase == .retry || phase == .choices { endNow() }
        case .micStart:
            if micOn, !micReady, phase == .listening { error(texts.micNotReady, c) }
        case .finalize:
            // The final did not come back: decide with the last partial (volatile fallback, REVIEW M2). A model that
            // never got ready heard nothing yet: say so instead of "Nichts gehört".
            guard finalizing else { break }
            if finalizeCold, lastPartial.isEmpty { error(texts.modelStillLoading, c) } else { finishUtterance(lastPartial, c) }
        case .retrySilence:
            if phase == .retry, !speechSeen { toIdle(c) }
        case .choicesDeadline:
            deadlineReached(c)
        case .fastSelect:
            if phase == .choices, let i = list?.pendingPick, !voiceActive { pick(i, c) }
        case .revalidate:
            if phase == .processing, let w = ticketWait, w.kind == .revalidate { ticketDecision(w.request, listsCurrent: false, c) }
        case .archive:
            // No answer from AC in time: decide with what is indexed; nothing found means AC did not answer.
            if phase == .processing, let w = ticketWait, w.kind == .archive {
                resolveTicket(w.request, rounds: w.rounds, attempted: w.attempted, decideNow: true,
                              message: texts.acUnreachable, c)
            }
        case .probe:
            if phase == .processing, let w = ticketWait, case .probe = w.kind { error(texts.acUnreachable, c) }
        case .open:
            if phase == .opening { opening = nil; error(texts.chromeTimeout, c) }
        case .success:
            if phase == .success { toIdle(c) }
        case .error:
            if phase == .error { toIdle(c) }
        }
    }

    mutating func schedule(_ kind: TimerKind, _ after: Double) {
        timerToken += 1
        timers[kind] = timerToken
        fx.append(.schedule(TimerID(kind: kind, token: timerToken), after: max(0, after)))
    }

    mutating func cancel(_ kind: TimerKind) {
        if timers.removeValue(forKey: kind) != nil { fx.append(.cancelTimer(kind)) }
    }

    mutating func cancelAllTimers() {
        for k in TimerKind.allCases where timers[k] != nil { cancel(k) }
    }

    // MARK: - Helpers

    mutating func nextUtterance() -> SpeechGen {
        utterance += 1
        let gen = SpeechGen(session: session, utterance: utterance)
        armed = gen
        speechSeen = false
        voiceActive = false
        silenceSince = nil
        lastPartial = []
        finalizing = false
        finalizeCold = false
        return gen
    }

    mutating func stopMic() {
        if micOn { fx.append(.stopMic) }
        micOn = false
        micReady = false
        suspended = false
        armed = nil
    }

    mutating func clearSession() {
        armed = nil
        speechSeen = false
        voiceActive = false
        silenceSince = nil
        lastPartial = []
        finalizing = false
        finalizeCold = false
        noSpeechDeferred = false
        keyDown = nil
        list = nil
        ticketWait = nil
        opening = nil
        renumbered = false
        corrections = []
        beforeFinalize = nil
        pointerHolding = false
        fadeDue = nil
    }

    mutating func clearListModel() {
        model.choices = []
        model.answer = Transcript()
        model.total = 0
        model.page = 0
        model.pageCount = 0
        model.pageSize = 0
        model.deadline = nil
        model.countdownFrozen = nil
        model.hint = nil
        model.hintIsAlert = false
    }

    mutating func earcon(_ e: Earcon, _ c: Ctx) {
        if c.env.config.earcons { fx.append(.earcon(e)) }
    }

    /// Emits `.publish` first when the snapshot changed. `seq` and `since` are set here only.
    mutating func flush(_ c: Ctx) {
        // The language rides along with every snapshot. It is fixed for the app run, so it never publishes one alone.
        model.language = c.env.language
        published.language = c.env.language
        var probe = model
        probe.seq = published.seq
        probe.since = published.since
        if probe != published {
            model.seq = published.seq + 1
            model.since = model.phase != published.phase ? c.now : published.since
            published = model
            fx.insert(.publish(model), at: 0)
        } else {
            model = published
        }
        if renumbered {
            list?.listSeq = model.seq
            renumbered = false
        }
    }
}
