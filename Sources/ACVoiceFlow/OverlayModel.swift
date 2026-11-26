import Foundation
import ACVoiceCore

/// Internal flow phase. The wire knows fewer phases (`wire`).
public enum FlowPhase: String, Sendable, Equatable, CaseIterable {
    case idle
    case listening
    /// Listening again after a failed command, with a message.
    case retry
    /// Finalizing, interpreting, archive search or probe.
    case processing
    /// Waiting for Chrome.
    case opening
    case choices
    case success
    case error

    /// PLAN 2.5: retry -> listening, opening -> processing.
    public var wire: IPC.Phase {
        switch self {
        case .idle: return .idle
        case .listening, .retry: return .listening
        case .processing, .opening: return .processing
        case .choices: return .choices
        case .success: return .success
        case .error: return .error
        }
    }
}

/// Live transcript: the stable part is shown bright, the volatile tail dim.
public struct Transcript: Sendable, Equatable {
    public var stable: String
    public var volatile: String
    public init(stable: String = "", volatile: String = "") { self.stable = stable; self.volatile = volatile }
    public var text: String {
        [stable, volatile].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    public var isEmpty: Bool { text.isEmpty }
}

/// Row markers in the choice list.
public enum Badge: String, Sendable, Hashable, CaseIterable {
    /// AC favorite (star).
    case favorite
    /// Opened with ac-voice or own time records in the last 30 days (clock).
    case recent
    /// Ticket assigned to the user.
    case mine
    /// Completed ticket.
    case completed
}

public enum ChoiceTarget: Sendable, Hashable {
    case project(id: Int)
    /// `number` 0: unknown task number (bare global id).
    case task(projectId: Int, taskId: Int, number: Int)

    public var projectId: Int {
        switch self {
        case .project(let id): return id
        case .task(let pid, _, _): return pid
        }
    }
}

public struct ChoiceItem: Sendable, Equatable, Identifiable {
    /// 1-based absolute number, what the user says or clicks.
    public var n: Int
    /// At most 12 characters for a Stream Deck key: the distinctive title words ("Relaunch").
    public var label: String
    /// Title without code and type ("Website Relaunch").
    public var title: String
    public var code: String?
    public var type: String?
    /// "CODE: Title", used for success messages ("WWT: Website Relaunch").
    public var displayName: String
    /// Full AC name, for tickets with the number in front ("Ticket 412 · WWT: Website Relaunch [AGIL]").
    public var detail: String
    public var badges: Set<Badge>
    public var target: ChoiceTarget
    public var id: Int { n }

    public init(n: Int, label: String, title: String, code: String?, type: String?, displayName: String,
                detail: String, badges: Set<Badge> = [], target: ChoiceTarget) {
        self.n = n; self.label = label; self.title = title; self.code = code; self.type = type
        self.displayName = displayName; self.detail = detail; self.badges = badges; self.target = target
    }
}

/// Everything the overlay and the Stream Deck key show. A value type: the reducer emits a new snapshot with a
/// higher `seq` whenever anything changes.
public struct OverlayModel: Sendable, Equatable {
    /// Monotonic per app run; becomes `IPC.State.seq`.
    public var seq = 0
    public var phase: FlowPhase = .idle
    /// When `phase` started.
    public var since = Date(timeIntervalSince1970: 0)
    public var visible = false
    /// The command. A list keeps it while the user answers (`answer`).
    public var transcript = Transcript()
    /// Choices only: the live answer ("zwei", "Website"); empty once the flow acted on it.
    public var answer = Transcript()
    /// Live target while listening ("WWT: Website Relaunch", "Ticket 412", "Meine Aufgaben"); the target while
    /// opening.
    public var preview: String?
    /// The visible page of choices.
    public var choices: [ChoiceItem] = []
    /// All candidates, across pages.
    public var total = 0
    public var page = 0
    public var pageCount = 0
    /// Rows per page (`Config.visibleChoices`); the last page may hold fewer.
    public var pageSize = 0
    /// Short instruction under the list ("Sag eine Zahl", "Sag ja oder nein"), or the next step under an error.
    public var hint: String?
    /// The hint answers an unclear answer: drawn in the accent color.
    public var hintIsAlert = false
    /// Status text (retry, search, success title, error).
    public var message: String?
    /// Choices window end for the countdown ring.
    public var deadline: Date?
    /// The pointer rests on the list: the countdown stands still with this many seconds left (`deadline` is the hard
    /// cap meanwhile, and the Stream Deck key gets no deadline).
    public var countdownFrozen: Double?
    /// listening: false while the engine starts, true once the mic is hot.
    public var micReady = false
    /// The speech model is still loading ("Sprachmodell lädt").
    public var warming = false

    public init() {}

    /// Choices on the other pages.
    public var hiddenCount: Int { max(0, total - choices.count) }

    /// "mehr" wraps around: the last page leads back to page 1.
    public var isLastPage: Bool { page + 1 >= pageCount }

    /// Rows "mehr" shows next: the size of the next page, 0 on the last page (and without paging).
    public var nextPageCount: Int {
        guard pageCount > 1, !isLastPage else { return 0 }
        let size = pageSize > 0 ? pageSize : choices.count
        return max(0, min(size, total - (page + 1) * size))
    }

    /// Snapshot for the Stream Deck plugin (PLAN 2.5).
    public func ipcState() -> IPC.State {
        let wire = phase.wire
        let isChoices = phase == .choices
        return IPC.State(
            seq: seq, phase: wire, since: Self.epochMs(since),
            transcript: transcript.isEmpty ? nil : transcript.text,
            preview: wire == .idle ? nil : preview,
            choices: isChoices ? choices.map { IPC.Choice(n: $0.n, label: $0.label, detail: $0.detail) } : nil,
            total: isChoices && total > choices.count ? total : nil,
            // A held list has no running deadline: the key shows a full ring until the pointer leaves.
            deadline: isChoices && countdownFrozen == nil ? deadline.map(Self.epochMs) : nil,
            message: message ?? hint,
            micReady: wire == .listening ? micReady : nil)
    }

    static func epochMs(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
}
