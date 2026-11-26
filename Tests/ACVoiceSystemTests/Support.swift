import Darwin
import Foundation
import Network

/// Package paths, relative to this file.
enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let appleScript = root.appendingPathComponent("Resources/open-ac.applescript")
    static let genScript = root.appendingPathComponent("scripts/gen-applescript.sh")
}

/// A fresh, short socket path under NSTemporaryDirectory (sun_path holds 103 bytes). The directory does not exist
/// yet, so the server creates it.
func tempSocketPath(_ tag: String = "t") -> String {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("acv-\(UUID().uuidString.prefix(8))")
    let path = (dir as NSString).appendingPathComponent("\(tag).sock")
    precondition(path.utf8.count <= 103, "temp socket path too long: \(path.utf8.count) bytes")
    return path
}

func removeTempDir(of path: String) {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Double = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Reads lines a test client received.
protocol LineSource: AnyObject, Sendable {
    func receivedLines() -> [String]
    var isClosed: Bool { get }
}

extension LineSource {
    /// JSON objects received so far, in order.
    func messages() -> [[String: Any]] {
        receivedLines().compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    func messages(type t: String) -> [[String: Any]] { messages().filter { $0["t"] as? String == t } }

    /// Waits for the n-th (1-based) message of type `t`.
    @MainActor
    func waitFor(_ t: String, count: Int = 1, timeout: Double = 3) async -> [String: Any]? {
        _ = await waitUntil(timeout: timeout) { self.messages(type: t).count >= count }
        let all = messages(type: t)
        return all.count >= count ? all[count - 1] : nil
    }
}

/// A blocking POSIX unix-socket client with a reader thread.
final class PosixClient: LineSource, @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "test-posix-writer")
    private var lines: [String] = []
    private var partial = Data()
    private var closed = false

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        let t = Thread { [self] in self.readLoop() }
        t.name = "test-posix-client"
        t.start()
    }

    var isClosed: Bool { lock.withLock { closed } }

    func receivedLines() -> [String] { lock.withLock { lines } }

    func send(_ text: String) { sendRaw(Data(text.utf8)) }

    /// Writes on a serial queue: a blocking write on the main actor would stall the server, which reads there
    /// (the unix socket send buffer is only 8 KB).
    func sendRaw(_ data: Data) {
        let fd = self.fd
        writer.async {
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { return }
                    off += n
                }
            }
        }
    }

    /// Ends both directions after the queued writes; the reader thread closes the descriptor.
    func close() {
        let fd = self.fd
        writer.async { _ = shutdown(fd, SHUT_RDWR) }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            lock.withLock {
                partial.append(contentsOf: buf[0..<n])
                while let nl = partial.firstIndex(of: 0x0A) {
                    let line = partial[partial.startIndex..<nl]
                    lines.append(String(decoding: line, as: UTF8.self))
                    partial.removeSubrange(partial.startIndex...nl)
                }
            }
        }
        lock.withLock { closed = true }
        Darwin.close(fd)
    }
}

/// A Network.framework client, as a second kind of peer.
final class NWClient: LineSource, @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "test-nw-client")
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = Data()
    private var closed = false

    init(path: String) {
        conn = NWConnection(to: .unix(path: path), using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.lock.withLock { self?.closed = true }
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    var isClosed: Bool { lock.withLock { closed } }

    func receivedLines() -> [String] { lock.withLock { lines } }

    func send(_ text: String) { conn.send(content: Data(text.utf8), completion: .idempotent) }

    func close() { conn.cancel() }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                self.lock.withLock {
                    self.partial.append(data)
                    while let nl = self.partial.firstIndex(of: 0x0A) {
                        let line = self.partial[self.partial.startIndex..<nl]
                        self.lines.append(String(decoding: line, as: UTF8.self))
                        self.partial.removeSubrange(self.partial.startIndex...nl)
                    }
                }
            }
            if done || error != nil {
                self.lock.withLock { self.closed = true }
            } else {
                self.receive()
            }
        }
    }
}

/// German UI style (company rules): no en or em dash, no colon or dash inside a sentence, no subjunctive.
func styleViolations(_ s: String) -> [String] {
    var v: [String] = []
    if s.contains("\u{2013}") || s.contains("\u{2014}") { v.append("dash") }
    if s.contains(":") { v.append("colon") }
    if s.contains(" - ") { v.append("dash inside a sentence") }
    let lower = s.lowercased()
    for w in ["könnte", "sollte", "würde", "wäre"] where lower.contains(w) { v.append(w) }
    return v
}
