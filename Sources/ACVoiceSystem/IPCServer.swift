import ACVoiceCore
import Darwin
import Foundation
import Network

/// A connected plugin.
public struct IPCClient: Sendable, Hashable {
    public var id: Int
    /// From `hello` ("streamdeck"), nil before it.
    public var name: String?
    public var version: String?
    public init(id: Int, name: String? = nil, version: String? = nil) {
        self.id = id; self.name = name; self.version = version
    }
}

public enum IPCServerError: Error, Equatable {
    /// The socket path does not fit `sockaddr_un.sun_path` (103 bytes plus NUL).
    case pathTooLong(Int)
    /// Another process accepts connections on the socket: an ac-voice instance runs already.
    case alreadyRunning
    /// Something other than a socket exists at the path. The server never deletes it.
    case pathOccupied
    case directory(String)
    case listener(String)
}

/// What `IPCServer.probe` finds at a socket path.
public enum SocketProbe: Sendable, Equatable {
    case absent
    /// A socket file nobody listens on (left over by a crash).
    case stale
    /// A live peer accepts connections.
    case live
    case notASocket
}

/// The IPC endpoint the runtime talks to. Tests use fakes.
@MainActor
public protocol IPCServing: AnyObject {
    /// Plugin commands except `ping` (answered by the server), on the main actor.
    var onCommand: (@MainActor (IPC.Command, IPCClient) -> Void)? { get set }
    func start() async throws
    func stop()
    /// Stores the snapshot (sent to every client on connect) and sends it to all clients.
    func broadcast(_ state: IPC.State)
    /// Mic level 0...1. Sent only while the last snapshot is `listening`, at most `levelRate` times per second.
    func level(_ rms: Double)
}

/// IPC v1 server: NDJSON over a unix domain socket (PLAN 2.5, research streamdeck 3.3).
///
/// - Directory created with 0700 when missing (an existing directory owned by the user is tightened to 0700).
/// - Single instance: a socket a live peer accepts on is never taken over (`alreadyRunning`); a stale socket file
///   is unlinked; any other file at the path is left alone (`pathOccupied`).
/// - The socket is chmod 0600 once the listener is ready. `start()` returns then.
/// - Framing: one JSON object per line, lines above `IPC.maxLineBytes` and malformed lines are dropped, the
///   connection stays open.
/// - Every client gets the current snapshot on connect, so a reconnecting plugin renders the right key at once.
/// - A client that stops reading is dropped once `maxQueuedBytes` are waiting for it.
@MainActor
public final class IPCServer: IPCServing {
    public struct Options: Sendable {
        public var levelRate: Double = 15
        public var maxLineBytes: Int = IPC.maxLineBytes
        /// Unsent bytes per client before the server drops it.
        public var maxQueuedBytes: Int = 512 * 1024
        /// Level messages are skipped for a client with more than this many unsent bytes.
        public var levelQueueLimit: Int = 16 * 1024
        public var maxClients: Int = 16
        public init() {}
    }

    public var onCommand: (@MainActor (IPC.Command, IPCClient) -> Void)?
    /// Connect, hello and disconnect, for logs and a debug menu.
    public var onClientsChanged: (@MainActor ([IPCClient]) -> Void)?

    public let path: String
    public let options: Options
    public private(set) var isRunning = false
    /// Lines dropped as oversized or malformed, over all clients.
    public private(set) var droppedLines = 0

    private var listener: NWListener?
    private var clients: [Int: Connection] = [:]
    private var nextClientId = 1
    private var snapshot: IPC.State
    private var snapshotLine: Data
    private var socketInode: ino_t?
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    // Level throttle.
    private var lastLevelSent = -Double.infinity
    private var pendingLevel: Double?
    private var levelFlushScheduled = false
    private let now: @Sendable () -> Double

    public init(path: String = AppPaths.socket.path, options: Options = .init(),
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.path = path
        self.options = options
        self.now = now
        let idle = IPC.State(seq: 0, phase: .idle, since: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
        snapshot = idle
        snapshotLine = IPC.line(idle)
    }

    /// PLAN 2.4 shape.
    public convenience init(path: String, onCommand: @escaping @MainActor (IPC.Command, IPCClient) -> Void) {
        self.init(path: path)
        self.onCommand = onCommand
    }

    public var connectedClients: [IPCClient] { clients.keys.sorted().compactMap { clients[$0]?.info } }

    // MARK: Lifecycle

    public func start() async throws {
        guard listener == nil else { return }
        try Self.validate(path: path)
        try prepareDirectory()
        switch Self.probe(path: path) {
        case .live:
            Log.event(.ipc, "ipc.alreadyRunning", level: .error)
            throw IPCServerError.alreadyRunning
        case .notASocket:
            throw IPCServerError.pathOccupied
        case .stale:
            unlink(path)
            Log.event(.ipc, "ipc.staleSocketRemoved")
        case .absent:
            break
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            throw IPCServerError.listener(String(describing: error))
        }
        l.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated {
                if let self { self.accept(conn) } else { conn.cancel() }
            }
        }
        l.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state) }
        }
        listener = l
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            readyContinuation = c
            l.start(queue: .main)
        }
    }

    public func stop() {
        guard let l = listener else { return }
        listener = nil
        l.cancel()
        for c in clients.values { c.conn.cancel() }
        clients.removeAll()
        if isRunning, let ino = socketInode {
            var st = stat()
            if lstat(path, &st) == 0, st.st_ino == ino { unlink(path) }
        }
        isRunning = false
        socketInode = nil
        resumeReady(throwing: IPCServerError.listener("stopped"))
        Log.event(.ipc, "ipc.stopped")
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard listener != nil else { return } // stopped meanwhile
        switch state {
        case .ready:
            chmod(path, 0o600)
            var st = stat()
            if lstat(path, &st) == 0 { socketInode = st.st_ino }
            isRunning = true
            Log.event(.ipc, "ipc.ready")
            resumeReady(throwing: nil)
        case .failed(let error), .waiting(let error):
            // A unix socket listener has nothing to wait for: treat waiting as failed, so start() never hangs.
            Log.error(.ipc, "ipc.listener.failed", error)
            isRunning = false
            listener?.cancel()
            listener = nil
            resumeReady(throwing: IPCServerError.listener(String(describing: error)))
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func resumeReady(throwing error: (any Error)?) {
        guard let c = readyContinuation else { return }
        readyContinuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    // MARK: Outgoing

    public func broadcast(_ state: IPC.State) {
        snapshot = state
        snapshotLine = IPC.line(state)
        if state.phase != .listening {
            pendingLevel = nil
        }
        for c in clients.values where c.isReady { send(snapshotLine, to: c) }
    }

    public func level(_ rms: Double) {
        guard snapshot.phase == .listening else {
            pendingLevel = nil
            return
        }
        let value = rms.isFinite ? min(max(rms, 0), 1) : 0
        let interval = 1 / max(options.levelRate, 1)
        let t = now()
        if t - lastLevelSent >= interval {
            sendLevel(value, at: t)
            return
        }
        pendingLevel = value
        guard !levelFlushScheduled else { return }
        levelFlushScheduled = true
        let delay = max(0, lastLevelSent + interval - t)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.flushLevel() }
        }
    }

    private func flushLevel() {
        levelFlushScheduled = false
        guard let v = pendingLevel, snapshot.phase == .listening else {
            pendingLevel = nil
            return
        }
        pendingLevel = nil
        sendLevel(v, at: now())
    }

    private func sendLevel(_ value: Double, at t: Double) {
        lastLevelSent = t
        let line = IPC.line(IPC.Level(rms: (value * 1000).rounded() / 1000))
        for c in clients.values where c.isReady && c.queuedBytes <= options.levelQueueLimit { send(line, to: c) }
    }

    private func send(_ data: Data, to client: Connection) {
        client.queuedBytes += data.count
        if client.queuedBytes > options.maxQueuedBytes {
            Log.event(.ipc, "ipc.client.slow", .int("client", client.info.id), .int("queued", client.queuedBytes), level: .error)
            drop(client)
            return
        }
        let size = data.count
        client.conn.send(content: data, completion: .contentProcessed { [weak client] _ in
            MainActor.assumeIsolated { client?.queuedBytes -= size }
        })
    }

    private func sendPong(_ id: String, to client: Connection) {
        send(IPC.line(IPC.Pong(id: id)), to: client)
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        guard clients.count < options.maxClients else {
            Log.event(.ipc, "ipc.client.rejected", .int("clients", clients.count), level: .error)
            conn.cancel()
            return
        }
        let client = Connection(id: nextClientId, conn: conn, maxLineBytes: options.maxLineBytes)
        nextClientId += 1
        clients[client.info.id] = client
        conn.stateUpdateHandler = { [weak self, weak client] state in
            MainActor.assumeIsolated {
                guard let self, let client else { return }
                self.connectionChanged(client, state)
            }
        }
        conn.start(queue: .main)
        receive(client)
    }

    private func connectionChanged(_ client: Connection, _ state: NWConnection.State) {
        switch state {
        case .ready:
            client.isReady = true
            // Snapshot first, so a (re)connecting plugin renders the right key at once.
            send(snapshotLine, to: client)
            Log.event(.ipc, "ipc.client.connected", .int("client", client.info.id), .int("clients", clients.count))
            onClientsChanged?(connectedClients)
        case .failed, .cancelled:
            drop(client)
        default:
            break
        }
    }

    private func drop(_ client: Connection) {
        guard clients.removeValue(forKey: client.info.id) != nil else { return }
        client.conn.cancel()
        Log.event(.ipc, "ipc.client.closed", .int("client", client.info.id), .int("clients", clients.count))
        onClientsChanged?(connectedClients)
        // A plugin that vanishes while its key is held never sends the release. heldMs 0 hands the end of
        // the utterance back to endpointing instead of leaving it suspended until maxUtterance.
        if let held = client.heldPress {
            client.heldPress = nil
            onCommand?(.release(id: "disconnect-\(client.info.id)", pressId: held, heldMs: 0), client.info)
        }
    }

    private func receive(_ client: Connection) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak client] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let client, self.clients[client.info.id] === client else { return }
                if let data, !data.isEmpty {
                    let before = client.framer.droppedLines
                    let lines = client.framer.feed(data)
                    self.droppedLines += client.framer.droppedLines - before
                    for line in lines {
                        self.handle(line, from: client)
                        // A handler may stop the server or drop the client.
                        guard self.clients[client.info.id] === client else { return }
                    }
                }
                if isComplete || error != nil {
                    self.drop(client)
                } else {
                    self.receive(client)
                }
            }
        }
    }

    private func handle(_ line: Data, from client: Connection) {
        guard let cmd = IPC.decodeCommand(line) else {
            droppedLines += 1
            Log.event(.ipc, "ipc.line.dropped", .int("client", client.info.id), .int("bytes", line.count), level: .debug)
            return
        }
        switch cmd {
        case .ping(let id):
            sendPong(id, to: client)
            return
        case let .hello(name, version):
            client.info.name = name
            client.info.version = version
            Log.event(.ipc, "ipc.hello", .int("client", client.info.id), .private("client", "\(name) \(version)"))
            onClientsChanged?(connectedClients)
        case let .press(id, _):
            client.heldPress = id
        case let .release(_, pressId, _):
            if pressId == nil || pressId == client.heldPress { client.heldPress = nil }
        default:
            break
        }
        onCommand?(cmd, client.info)
    }

    // MARK: Socket file

    /// sun_path holds 104 bytes including the terminating NUL.
    nonisolated static let maxPathBytes = 103

    nonisolated static func validate(path: String) throws {
        let n = path.utf8.count
        guard n > 0, n <= maxPathBytes else { throw IPCServerError.pathTooLong(n) }
    }

    private func prepareDirectory() throws {
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        if lstat(dir, &st) != 0 {
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw IPCServerError.directory(String(describing: error))
            }
            chmod(dir, 0o700)
        } else if (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), (st.st_mode & 0o777) != 0o700 {
            chmod(dir, 0o700)
        }
    }

    /// Checks a socket path without side effects on a live peer beyond one connect and close.
    public nonisolated static func probe(path: String) -> SocketProbe {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .absent }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else { return .notASocket }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .stale }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var addr = unixAddress(path) else { return .stale }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0 ? .live : .stale
    }

    nonisolated static func unixAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
}

/// One plugin connection. Main actor only.
@MainActor
private final class Connection {
    let conn: NWConnection
    var info: IPCClient
    var framer: LineFramer
    var isReady = false
    var queuedBytes = 0
    /// The id of a press from this connection that has no release yet.
    var heldPress: String?

    init(id: Int, conn: NWConnection, maxLineBytes: Int) {
        self.conn = conn
        info = IPCClient(id: id)
        framer = LineFramer(maxLineBytes: maxLineBytes)
    }
}
