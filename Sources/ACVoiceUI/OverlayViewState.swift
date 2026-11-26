import Foundation
import ACVoiceCore
import ACVoiceFlow

/// Visual tone of the overlay: orb color, accent and ambient glow.
public enum OverlayTone: String, Sendable, CaseIterable {
    /// Cyan. Mic on (or starting).
    case listening
    /// Cyan, dimmed, with a slow loading ring: the speech model is not ready yet.
    case warming
    /// Violet rotating arc: finalize, interpret, archive search, opening Chrome.
    case processing
    /// Amber with the countdown ring.
    case choices
    /// Green check.
    case success
    /// Red.
    case error
}

/// The large first line next to the orb.
public enum OverlayHeadline: Sendable, Equatable {
    /// Live transcript: stable part bright, volatile tail dim.
    case transcript(stable: String, volatile: String)
    /// Nothing heard yet: "Ich höre zu" once the mic is hot, "Mikrofon startet …" before. `dimmed`: drawn weaker
    /// than the secondary style (unused by the flow states; kept for custom states).
    case placeholder(String, dimmed: Bool)
    /// Status title (success target, error message, list question).
    case title(String)

    public var text: String {
        switch self {
        case let .transcript(stable, volatile):
            return [stable, volatile].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .joined(separator: " ")
        case let .placeholder(text, _): return text
        case let .title(text): return text
        }
    }
}

/// A secondary line under the headline. At most one line per style.
public struct OverlayLine: Sendable, Equatable, Identifiable {
    public enum Style: String, Sendable, CaseIterable {
        /// Live target ("→ WWT: Website Relaunch"), accent color.
        case preview
        /// Neutral status ("Sprachmodell lädt", "Suche Ticket 412 …").
        case status
        /// Needs attention ("Nicht verstanden. Sag es nochmal.", automation hint).
        case alert
        /// Success confirmation ("Chrome zeigt die Seite").
        case success
        /// The heard text under an error.
        case quote
        /// List question ("Welches der 4 Projekte?"), accent color.
        case question
    }

    public var style: Style
    public var text: String
    /// SF Symbol shown in front of the text.
    public var symbol: String?
    public var id: Style { style }

    public init(_ style: Style, _ text: String, symbol: String? = nil) {
        self.style = style; self.text = text; self.symbol = symbol
    }
}

/// Row marker icons, in display order.
public enum RowMarker: String, Sendable, CaseIterable {
    case favorite, mine, recent, completed

    public var symbol: String {
        switch self {
        case .favorite: return "star.fill"
        case .mine: return "person.fill"
        case .recent: return "clock"
        case .completed: return "archivebox"
        }
    }

    public func accessibilityLabel(_ text: OverlayText) -> String {
        switch self {
        case .favorite: return text.a11yFavorite
        case .mine: return text.a11yMine
        case .recent: return text.a11yRecent
        case .completed: return text.a11yCompleted
        }
    }
}

/// A piece of a row title; `matched` pieces are words the user said (drawn bold).
public struct TitleRun: Sendable, Equatable {
    public var text: String
    public var matched: Bool
    public init(_ text: String, matched: Bool) { self.text = text; self.matched = matched }
}

/// One clickable choice row. `seq` is the seq of the snapshot this row was drawn from: a click reports it, never
/// the live model seq (`FlowEvent.choose`, REVIEW m4).
public struct ChoiceRowState: Sendable, Equatable, Identifiable {
    /// 1-based absolute number: what the user says or clicks.
    public var n: Int
    public var seq: Int
    public var title: String
    public var titleRuns: [TitleRun]
    /// Code and type badge ("WWT · AGIL").
    public var badge: String?
    /// Ticket number chip ("#412").
    public var ticket: String?
    public var markers: [RowMarker]
    /// Position on the visible page, for the staggered entrance.
    public var index: Int
    /// Identity across renders: the target plus its number. A narrow renumbers rows, so they enter again.
    public var id: String
    public var accessibilityLabel: String
}

/// Footer under the list: hint on the left, page dots and "mehr" on the right.
public struct ChoiceFooterState: Sendable, Equatable {
    public var hint: String
    /// The hint follows an unclear answer ("„Hi.“ passt zu keiner Zeile. Sag eine Zahl."): drawn in the accent color.
    public var hintIsAlert: Bool
    /// The live answer ("„zwei“") replaces the hint while the user speaks: drawn dim.
    public var hintIsLive: Bool
    /// 0-based.
    public var page: Int
    public var pageCount: Int
    /// Rows "mehr" shows next; 0 on the last page.
    public var nextCount: Int
    /// "mehr" wraps around to page 1 from here.
    public var isLastPage: Bool
    /// Ticket rows ("weitere Tickets").
    public var tickets: Bool
    /// Language of the footer texts (`OverlayModel.language`).
    public var language: AppLanguage = .de

    /// The "mehr" text, nil without paging.
    public var moreText: String? {
        guard pageCount > 1 else { return nil }
        let text = OverlayText(language)
        return isLastPage ? text.moreFromStart : text.more(nextCount, tickets: tickets)
    }
}

/// Everything the overlay view draws, derived from one `OverlayModel` snapshot. Pure and `Equatable`, so the
/// controller can skip no-op renders and tests can check the mapping without views.
public struct OverlayViewState: Sendable, Equatable {
    public var seq: Int
    public var phase: FlowPhase
    public var tone: OverlayTone
    /// The mic is hot: the orb reacts to the level.
    public var micLive: Bool
    /// When the shown phase started (one-shot orb animations, success check).
    public var phaseStart: Date
    public var headline: OverlayHeadline
    public var lines: [OverlayLine]
    public var rows: [ChoiceRowState]
    public var footer: ChoiceFooterState?
    /// Choices window end for the countdown ring.
    public var deadline: Date?
    /// The pointer holds the list: the ring stands still with this many seconds left.
    public var countdownFrozen: Double?
    /// Language of the overlay's own words and its VoiceOver labels (`OverlayModel.language`).
    public var language: AppLanguage

    /// The overlay's own words in `language`.
    public var text: OverlayText { OverlayText(language) }

    /// The state shown before the first render.
    public static let initial = OverlayViewState(model: OverlayModel(), phaseStart: Date(timeIntervalSince1970: 0))

    /// Maps a model snapshot. `phaseStart` defaults to `model.since`; the live controller passes the local time
    /// the phase first appeared on screen.
    public init(model m: OverlayModel, phaseStart: Date? = nil) {
        seq = m.seq
        phase = m.phase
        language = m.language
        let text = OverlayText(m.language)
        let flowText = FlowText(m.language)
        self.phaseStart = phaseStart ?? m.since
        rows = []
        footer = nil
        deadline = nil
        countdownFrozen = nil
        micLive = false
        var lines: [OverlayLine] = []
        let heard = m.transcript
        let transcriptHeadline: OverlayHeadline? = heard.isEmpty ? nil : Self.clampedTranscript(heard)
        let preview = Self.nonEmpty(m.preview)
        let message = Self.nonEmpty(m.message)
        let hint = Self.nonEmpty(m.hint)

        switch m.phase {
        case .idle, .listening, .retry:
            tone = m.warming ? .warming : .listening
            micLive = m.micReady && m.phase != .idle
            // Before the first audio arrives, "Ich höre zu" would invite speech the mic cannot hear yet (PLAN 7).
            headline = transcriptHeadline
                ?? .placeholder(m.micReady ? text.listening : text.micStarting, dimmed: false)
            if let preview { lines.append(OverlayLine(.preview, preview, symbol: "arrow.right")) }
            if let message {
                if m.phase == .retry {
                    lines.append(OverlayLine(.alert, message, symbol: "arrow.counterclockwise"))
                } else if message == flowText.loadingModel {
                    lines.append(OverlayLine(.status, message, symbol: "arrow.down.circle"))
                } else {
                    lines.append(OverlayLine(.status, message))
                }
            }

        case .processing:
            tone = .processing
            headline = transcriptHeadline ?? preview.map(OverlayHeadline.title) ?? .placeholder(text.working, dimmed: false)
            if let preview, transcriptHeadline != nil {
                lines.append(OverlayLine(.preview, preview, symbol: "arrow.right"))
            }
            if let message { lines.append(OverlayLine(.status, message, symbol: "magnifyingglass")) }

        case .opening:
            // The target takes the headline now and keeps it through success: only the line under it changes.
            tone = .processing
            headline = preview.map(OverlayHeadline.title) ?? transcriptHeadline ?? .placeholder(text.working, dimmed: false)
            lines.append(OverlayLine(.status, text.openingInChrome, symbol: "arrow.up.forward"))
            if let message { lines.append(OverlayLine(.alert, message, symbol: "exclamationmark.triangle")) }

        case .choices:
            tone = .choices
            let numbers = m.choices.map { item -> Int? in
                if case let .task(_, taskId, number) = item.target { return number > 0 ? number : taskId }
                return nil
            }
            let tickets = !numbers.isEmpty && numbers.allSatisfy { $0 != nil }
            // One ticket number in several projects (the usual case): say it once in the question, not per row.
            let sharedNumber: Int? = tickets && Set(numbers).count == 1 ? numbers.first.flatMap { $0 } : nil
            let count = max(m.total, m.choices.count)
            let question = sharedNumber.map { text.ticketQuestion($0, count: count) }
                ?? text.question(count: count, tickets: tickets)
            if let transcriptHeadline {
                headline = transcriptHeadline
                lines.append(OverlayLine(.question, question))
            } else {
                headline = .title(question)
            }
            if let message { lines.append(OverlayLine(.status, message)) }
            let query = heard.text
            rows = m.choices.enumerated().map { i, item in
                var row = Self.row(item, index: i, seq: m.seq, query: query, text: text)
                if sharedNumber != nil { row.ticket = nil }
                return row
            }
            // While the user answers, the footer shows what the speech layer hears; the headline keeps the command.
            let live = m.answer.isEmpty ? nil : text.quoted(m.answer.text)
            footer = ChoiceFooterState(
                hint: live ?? hint ?? (m.choices.count == 1 ? flowText.sayYesOrOne : text.defaultChoiceHint),
                hintIsAlert: live == nil && m.hintIsAlert, hintIsLive: live != nil,
                page: m.page, pageCount: max(1, m.pageCount), nextCount: m.nextPageCount, isLastPage: m.isLastPage,
                tickets: tickets, language: m.language)
            deadline = m.deadline
            countdownFrozen = m.countdownFrozen

        case .success:
            tone = .success
            let title = message ?? preview ?? text.opened
            headline = .title(title)
            if title != text.opened { lines.append(OverlayLine(.success, text.opened)) }
            if let hint { lines.append(OverlayLine(.alert, hint, symbol: "exclamationmark.triangle")) }

        case .error:
            tone = .error
            headline = .title(message ?? text.a11yError)
            if !heard.isEmpty { lines.append(OverlayLine(.quote, text.quoted(heard.text))) }
            if let hint { lines.append(OverlayLine(.alert, hint, symbol: "exclamationmark.triangle")) }
        }
        self.lines = lines
    }

    // MARK: Derived

    /// What VoiceOver reads for the header.
    public var accessibilityLabel: String {
        var parts = [Self.toneLabel(tone, text), headline.text]
        parts += lines.map(\.text)
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    public static func toneLabel(_ tone: OverlayTone, _ text: OverlayText) -> String {
        switch tone {
        case .listening: return text.a11yListening
        case .warming: return text.a11yWarming
        case .processing: return text.a11yProcessing
        case .choices: return text.a11yChoices
        case .success: return text.a11ySuccess
        case .error: return text.a11yError
        }
    }

    /// Changes that move things around (phase, lines, rows, footer). Text-only changes (live transcript, preview
    /// text, countdown) render without animation; structural ones get the spring.
    public struct Structure: Hashable, Sendable {
        var tone: OverlayTone
        var headlineKind: Int
        var lines: [OverlayLine.Style]
        var rows: [String]
        var footer: [String]
    }

    public var structure: Structure {
        let kind: Int
        switch headline {
        case .transcript: kind = 0
        case .placeholder: kind = 1
        case .title: kind = 2
        }
        // The live answer changes with every partial: text only, no spring.
        let footerKey = footer.map { [$0.hintIsLive ? "live" : $0.hint, "\($0.page)/\($0.pageCount)", $0.moreText ?? ""] } ?? []
        return Structure(tone: tone, headlineKind: kind, lines: lines.map(\.style), rows: rows.map(\.id), footer: footerKey)
    }

    // MARK: Rows

    static func row(_ item: ChoiceItem, index: Int, seq: Int, query: String, text: OverlayText = .de) -> ChoiceRowState {
        let title = item.title.trimmingCharacters(in: .whitespaces).isEmpty ? item.displayName : item.title
        let badgeParts = [item.code, item.type].compactMap { Self.nonEmpty($0) }
        // A long code ("Hollenstein Optical") would take the title's width: the badge is secondary information.
        let shown = [item.code.flatMap { Self.nonEmpty($0) }.map(Self.shortCode), Self.nonEmpty(item.type)].compactMap { $0 }
        let badge = shown.isEmpty ? nil : shown.joined(separator: " · ")
        var ticket: String?
        var ticketNumber: Int?
        let id: String
        switch item.target {
        case .project(let pid):
            id = "p\(pid)-\(item.n)"
        case let .task(_, taskId, number):
            ticketNumber = number > 0 ? number : taskId
            ticket = ticketNumber.map(text.ticketNumber)
            id = "t\(taskId)-\(item.n)"
        }
        let markers = RowMarker.allCases.filter { marker in
            switch marker {
            case .favorite: return item.badges.contains(.favorite)
            case .mine: return item.badges.contains(.mine)
            case .recent: return item.badges.contains(.recent)
            case .completed: return item.badges.contains(.completed)
            }
        }
        var label = ["\(item.n)", title]
        if !badgeParts.isEmpty { label.append(badgeParts.joined(separator: " ")) }
        if let ticketNumber { label.append(text.a11yTicket(ticketNumber)) }
        label += markers.map { $0.accessibilityLabel(text) }
        return ChoiceRowState(n: item.n, seq: seq, title: title,
                              titleRuns: TitleHighlighter.runs(title, query: query, language: text.language),
                              badge: badge, ticket: ticket, markers: markers, index: index, id: id,
                              accessibilityLabel: label.joined(separator: ", "))
    }

    /// Characters of transcript the two headline lines hold at 20 pt on a 560 pt card.
    public static let headlineLimit = 78

    /// Keeps the newest words of a long transcript: cuts the start at a word boundary and marks the cut with "…".
    static func clampedTranscript(_ t: Transcript, limit: Int = headlineLimit) -> OverlayHeadline {
        var stable = t.stable.trimmingCharacters(in: .whitespaces)
        var volatile = t.volatile.trimmingCharacters(in: .whitespaces)
        let total = stable.count + (stable.isEmpty || volatile.isEmpty ? 0 : 1) + volatile.count
        guard total > limit else { return .transcript(stable: stable, volatile: volatile) }
        var cut = total - (limit - 2)   // room for "… "
        if cut >= stable.count {
            cut -= stable.isEmpty ? 0 : stable.count + 1
            stable = ""
            volatile = clip(volatile, dropping: max(0, cut))
            return .transcript(stable: "", volatile: "… " + volatile)
        }
        stable = clip(stable, dropping: cut)
        return .transcript(stable: "… " + stable, volatile: volatile)
    }

    /// Drops `count` leading characters, then the rest of a cut word.
    static func clip(_ s: String, dropping count: Int) -> String {
        var rest = Substring(s.dropFirst(count))
        if count > 0, let space = rest.firstIndex(of: " "), rest.distance(from: rest.startIndex, to: space) < 16 {
            rest = rest[rest.index(after: space)...]
        }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// Codes longer than `codeLimit` characters are cut at the end ("Hollenstein O…").
    static let codeLimit = 14

    static func shortCode(_ code: String) -> String {
        code.count <= codeLimit ? code : String(code.prefix(codeLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Marks title words the user said, so a row shows why it matched ("WWT Website" -> **Website** Relaunch).
/// Cosmetic only: exact word, a shared prefix of at least 4 letters, or one typo in words of 5 letters or more.
public enum TitleHighlighter {
    /// Query words that never highlight: fillers, verbs, articles, command and answer words of each language.
    static let ignored: [AppLanguage: Set<String>] = [
        .de: [
            "und", "von", "vom", "der", "die", "das", "den", "dem", "des", "mit", "fur", "auf", "bei", "ins", "zum", "zur",
            "projekt", "projekte", "ticket", "tickets", "offne", "oeffne", "offnen", "zeige", "zeig", "bitte", "mal",
            "meine", "mein", "nummer", "eins", "zwei", "drei", "vier", "funf", "sechs", "mehr", "nein", "doch",
        ],
        .en: [
            "and", "the", "for", "with", "from", "into", "open", "show", "please", "project", "projects", "ticket",
            "tickets", "task", "tasks", "number", "one", "two", "three", "four", "five", "six", "more", "yes",
            "cancel", "first", "second", "third", "fourth", "fifth", "sixth",
        ],
    ]

    public static func runs(_ title: String, query: String, language: AppLanguage = .de) -> [TitleRun] {
        let skip = ignored[language] ?? []
        let queryKeys = Set(words(query).compactMap { w -> String? in
            let k = key(w.text)
            return w.isWord && k.count >= 3 && !skip.contains(k) ? k : nil
        })
        var out: [TitleRun] = []
        for piece in words(title) {
            let matched = piece.isWord && !queryKeys.isEmpty && matches(key(piece.text), queryKeys)
            if let last = out.last, last.matched == matched {
                out[out.count - 1].text += piece.text
            } else {
                out.append(TitleRun(piece.text, matched: matched))
            }
        }
        // Separators between two matched words stay bold; a trailing separator does not matter.
        return out.isEmpty ? [TitleRun(title, matched: false)] : out
    }

    static func matches(_ k: String, _ query: Set<String>) -> Bool {
        guard k.count >= 3 else { return false }
        if query.contains(k) { return true }
        for q in query {
            if k.count >= 4, q.count >= 4, k.hasPrefix(q) || q.hasPrefix(k) { return true }
            if k.count >= 5, q.count >= 5, Fuzzy.osa(k, q, cap: 2) <= 1 { return true }
        }
        return false
    }

    static func key(_ s: String) -> String {
        String(TextNorm.fold(s).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Splits into alternating word and separator pieces, keeping every character.
    static func words(_ s: String) -> [(text: String, isWord: Bool)] {
        var out: [(text: String, isWord: Bool)] = []
        for ch in s {
            let isWord = ch.isLetter || ch.isNumber
            if let last = out.last, last.isWord == isWord {
                out[out.count - 1].text.append(ch)
            } else {
                out.append((String(ch), isWord))
            }
        }
        return out
    }
}
