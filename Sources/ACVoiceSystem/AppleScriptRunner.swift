import Carbon // OpenScripting constants: kASAppleScriptSuite, kASSubroutineEvent, keyASSubroutineName
import Foundation

/// An argument of an AppleScript handler call.
public enum ScriptArg: Sendable, Equatable {
    case text(String)
    case int(Int)
    case bool(Bool)
}

/// A handler result, converted from its Apple Event descriptor on the worker thread.
public indirect enum ScriptValue: Sendable, Equatable {
    case text(String)
    case int(Int)
    case bool(Bool)
    case list([ScriptValue])
    /// AppleScript `real`. AppleScript integers stop at ±536870911 (29 bits); a larger whole number, such as a
    /// Chrome window id (about 1.7e9), arrives as a real.
    case real(Double)
    /// AppleScript `missing value`, or no result.
    case missing

    public var text: String? { if case .text(let s) = self { return s }; return nil }
    /// An integer, or a real that holds a whole number (see `real`).
    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .real(let d): return Self.wholeNumber(d)
        default: return nil
        }
    }
    public var list: [ScriptValue]? { if case .list(let l) = self { return l }; return nil }

    /// The kinds of the value without its content, for logs: "[[r,r],[t,t],[[t,m],t],[i,i]]". Lists show at most
    /// `limit` items, then the count of the rest ("…+3").
    public func shape(limit: Int = 6) -> String {
        switch self {
        case .text: return "t"
        case .int: return "i"
        case .bool: return "b"
        case .real: return "r"
        case .missing: return "m"
        case .list(let items):
            var parts = items.prefix(limit).map { $0.shape(limit: limit) }
            if items.count > limit { parts.append("…+\(items.count - limit)") }
            return "[" + parts.joined(separator: ",") + "]"
        }
    }

    /// `d` as an Int when it is a whole number that a Double holds exactly (|d| ≤ 2^53).
    static func wholeNumber(_ d: Double) -> Int? {
        guard d.isFinite, d.rounded(.towardZero) == d, abs(d) <= 9_007_199_254_740_992 else { return nil }
        return Int(d)
    }

    init(_ d: NSAppleEventDescriptor) {
        switch d.descriptorType {
        case DescType(typeAEList):
            self = .list((0..<d.numberOfItems).map { ScriptValue(d.atIndex($0 + 1) ?? NSAppleEventDescriptor.null()) })
        case DescType(typeSInt16), DescType(typeSInt32), DescType(typeUInt16):
            self = .int(Int(d.int32Value))
        case DescType(typeSInt64), DescType(typeUInt32):
            if let c = d.coerce(toDescriptorType: DescType(typeSInt64)), c.data.count == 8 {
                self = .int(Int(c.data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }))
            } else {
                self = .int(Int(d.int32Value))
            }
        case DescType(typeIEEE64BitFloatingPoint), DescType(typeIEEE32BitFloatingPoint):
            self = .real(d.doubleValue)
        case DescType(typeTrue), DescType(typeFalse), DescType(typeBoolean):
            self = .bool(d.booleanValue)
        case DescType(typeNull):
            self = .missing
        case DescType(typeType) where d.typeCodeValue == OSType(cMissingValue):
            self = .missing
        default:
            self = d.stringValue.map(ScriptValue.text) ?? .missing
        }
    }
}

public enum ScriptCallResult: Sendable, Equatable {
    /// The handler returned.
    case value(ScriptValue)
    /// The script raised an error: AppleScript error number (-1743 Automation denied, -1712 Apple Event timeout,
    /// -600 app not running) and its message. The message may contain URLs, so log it only as private text.
    case failed(code: Int, message: String?)
    /// The deadline passed first. The handler may still run; its result is discarded.
    case timedOut
    /// A previous call is still running past its deadline (Chrome hangs). The call was not queued.
    case busy
    /// The script did not compile (error number), or the runner was shut down.
    case unavailable(code: Int)
}

/// Calls handlers of one compiled AppleScript without blocking the caller.
public protocol AppleScriptRunning: AnyObject, Sendable {
    /// A call runs past its deadline right now. New calls return `.busy` at once.
    var isBusy: Bool { get }
    /// Calls `handler` (lowercase name) with `args`. Answers within `deadline` seconds, counted from the call.
    func call(_ handler: String, _ args: [ScriptArg], deadline: Double) async -> ScriptCallResult
    /// Waits for the compile step. false: the script did not compile.
    func prepare() async -> Bool
}

/// Runs one `NSAppleScript` on a dedicated thread (`DeadlineWorker`). NSAppleScript is not thread-safe, so the
/// compile step and every handler call of this instance run on that one thread, one at a time. The caller only
/// awaits a continuation, so a hung or busy Chrome never blocks the main thread (REVIEW M4).
///
/// Compiling takes about 105 ms once per process (OSA component load) plus about 32 ms for the script, and sends no
/// Apple Event: Chrome terms resolve from its static scripting.sdef.
public final class AppleScriptRunner: AppleScriptRunning, @unchecked Sendable {
    private let worker: DeadlineWorker
    // Worker thread only.
    private var script: NSAppleScript?
    private var compileError: Int?

    /// Starts the thread and queues the compile step.
    public init(source: String, threadName: String = "io.github.nordavid.acvoice.applescript") {
        worker = DeadlineWorker(name: threadName)
        worker.enqueue { [self] in compile(source) }
    }

    public var isBusy: Bool { worker.isBusy }

    public func prepare() async -> Bool {
        if case .done(let ok) = await worker.run(deadline: nil, { [self] in script != nil }) { return ok }
        return false
    }

    public func call(_ handler: String, _ args: [ScriptArg], deadline: Double) async -> ScriptCallResult {
        switch await worker.run(deadline: deadline, { [self] in execute(handler, args) }) {
        case .done(let r): return r
        case .timedOut: return .timedOut
        case .busy: return .busy
        case .stopped: return .unavailable(code: -1)
        }
    }

    /// Ends the thread after the queued calls.
    public func shutdown() { worker.shutdown() }

    private func compile(_ source: String) {
        guard let s = NSAppleScript(source: source) else {
            compileError = -2
            return
        }
        var err: NSDictionary?
        if s.compileAndReturnError(&err) {
            script = s
        } else {
            let code = (err?[NSAppleScript.errorNumber] as? Int) ?? -2
            compileError = code
            Log.event(.chrome, "applescript.compile.failed", .int("code", code),
                      .private("message", (err?[NSAppleScript.errorMessage] as? String) ?? ""), level: .error)
        }
    }

    private func execute(_ handler: String, _ args: [ScriptArg]) -> ScriptCallResult {
        guard let script else { return .unavailable(code: compileError ?? -2) }
        var err: NSDictionary?
        let result = script.executeAppleEvent(Self.handlerEvent(handler, args), error: &err)
        if let err {
            return .failed(code: (err[NSAppleScript.errorNumber] as? Int) ?? -1,
                           message: err[NSAppleScript.errorMessage] as? String)
        }
        return .value(ScriptValue(result))
    }

    /// The Apple Event that calls a user-defined handler of a compiled script. Building it sends nothing.
    /// AppleScript stores user handler names in lowercase, so the name is lowercased here.
    static func handlerEvent(_ name: String, _ args: [ScriptArg]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: name.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, arg) in args.enumerated() {
            let d: NSAppleEventDescriptor
            switch arg {
            case .text(let s): d = NSAppleEventDescriptor(string: s)
            case .int(let v):
                if let small = Int32(exactly: v) {
                    d = NSAppleEventDescriptor(int32: small)
                } else {
                    var wide = Int64(v)
                    d = NSAppleEventDescriptor(descriptorType: DescType(typeSInt64), bytes: &wide, length: 8)
                        ?? NSAppleEventDescriptor(int32: Int32(clamping: v))
                }
            case .bool(let b): d = NSAppleEventDescriptor(boolean: b)
            }
            list.insert(d, at: i + 1)
        }
        event.setDescriptor(list, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
}

/// One dedicated thread that runs jobs in order, with a deadline per job.
///
/// - `run` answers `.timedOut` when the deadline passes first. A job still waiting in the queue then never runs; a
///   job that already runs keeps running, its result is discarded, and `isBusy` is true until it ends.
/// - While `isBusy`, `run` answers `.busy` at once instead of queueing behind the hung job.
/// - The caller never blocks: it awaits a continuation that the worker or the deadline resumes, exactly once.
final class DeadlineWorker: @unchecked Sendable {
    enum Outcome<T: Sendable>: Sendable {
        case done(T)
        case timedOut
        case busy
        case stopped
    }

    private struct Job {
        var ticket: (any WorkerTicket)?
        var body: @Sendable () -> Void
        var isStop = false
    }

    private let cond = NSCondition()
    // Guarded by `cond`.
    private var jobs: [Job] = []
    private var current: (any WorkerTicket)?
    private var stopped = false

    init(name: String, qos: QualityOfService = .userInitiated) {
        let thread = Thread { [self] in self.loop() }
        thread.name = name
        thread.qualityOfService = qos
        thread.start()
    }

    var isBusy: Bool {
        cond.lock()
        defer { cond.unlock() }
        return current?.isOverdue ?? false
    }

    /// Queues `work` without a result (setup steps).
    func enqueue(_ work: @escaping @Sendable () -> Void) {
        _ = push(Job(ticket: nil, body: work))
    }

    /// Runs `work` on the thread. `deadline` in seconds from now; nil waits as long as it takes.
    func run<T: Sendable>(deadline: Double?, _ work: @escaping @Sendable () -> T) async -> Outcome<T> {
        if isBusy { return .busy }
        return await withCheckedContinuation { (c: CheckedContinuation<Outcome<T>, Never>) in
            let ticket = Ticket(c)
            guard push(Job(ticket: ticket, body: { ticket.finish(.done(work())) })) else {
                ticket.finish(.stopped)
                return
            }
            if let deadline {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, deadline)) {
                    ticket.finish(.timedOut, expiring: true)
                }
            }
        }
    }

    /// Ends the thread after the queued jobs; later `run` calls answer `.stopped`.
    func shutdown() {
        _ = push(Job(ticket: nil, body: {}, isStop: true))
    }

    private func push(_ job: Job) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        guard !stopped else { return false }
        if job.isStop { stopped = true }
        jobs.append(job)
        cond.signal()
        return true
    }

    private func loop() {
        while true {
            cond.lock()
            while jobs.isEmpty { cond.wait() }
            let job = jobs.removeFirst()
            current = job.ticket
            cond.unlock()

            if job.isStop { return }
            if job.ticket?.begin() ?? true {
                autoreleasepool { job.body() }
            }
            cond.lock()
            current = nil
            cond.unlock()
        }
    }
}

private protocol WorkerTicket: AnyObject, Sendable {
    /// Started before its deadline, deadline passed, not finished yet.
    var isOverdue: Bool { get }
    /// false when the deadline already answered: the job must not run.
    func begin() -> Bool
}

/// One `run` call: answered exactly once, by the worker or by the deadline.
private final class Ticket<T: Sendable>: WorkerTicket, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DeadlineWorker.Outcome<T>, Never>?
    private var started = false
    private var expired = false
    private var finished = false

    init(_ c: CheckedContinuation<DeadlineWorker.Outcome<T>, Never>) { continuation = c }

    var isOverdue: Bool { lock.withLock { started && expired && !finished } }

    func begin() -> Bool {
        lock.withLock {
            guard !expired else { return false }
            started = true
            return true
        }
    }

    func finish(_ outcome: DeadlineWorker.Outcome<T>, expiring: Bool = false) {
        let c = lock.withLock { () -> CheckedContinuation<DeadlineWorker.Outcome<T>, Never>? in
            if expiring {
                if continuation != nil { expired = true }
            } else {
                finished = true
            }
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: outcome)
    }
}
