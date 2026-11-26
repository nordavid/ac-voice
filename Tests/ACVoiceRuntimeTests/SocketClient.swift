import Darwin
import Foundation

/// A fresh, short socket path under NSTemporaryDirectory (sun_path holds 103 bytes). The server creates the folder.
func tempSocketPath() -> String {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("acvr-\(UUID().uuidString.prefix(8))")
    let path = (dir as NSString).appendingPathComponent("r.sock")
    precondition(path.utf8.count <= 103, "temp socket path too long")
    return path
}

func removeTempDir(of path: String) {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

/// A blocking unix-socket client (the Stream Deck plugin's side) with a reader thread.
final class PosixClient: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "runtime-test-posix-writer")
    private var lines: [String] = []
    private var partial = Data()

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
        t.name = "runtime-test-posix-client"
        t.start()
    }

    /// Writes on a serial queue: the server reads on the main thread.
    func send(_ text: String) {
        let fd = self.fd
        let data = Data(text.utf8)
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

    func close() {
        let fd = self.fd
        writer.async { _ = shutdown(fd, SHUT_RDWR) }
    }

    /// JSON objects received so far.
    func messages() -> [[String: Any]] {
        lock.withLock { lines }.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    /// Waits (polling on the main actor, so the server keeps running) for the first message of type `t` that
    /// matches `predicate`.
    @MainActor
    func waitFor(_ t: String, timeout: Double = 3, where predicate: ([String: Any]) -> Bool = { _ in true }) async -> [String: Any]? {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if let m = messages().first(where: { $0["t"] as? String == t && predicate($0) }) { return m }
            if ProcessInfo.processInfo.systemUptime > end { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            lock.withLock {
                partial.append(contentsOf: buf[0..<n])
                while let nl = partial.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: partial[partial.startIndex..<nl], as: UTF8.self))
                    partial.removeSubrange(partial.startIndex...nl)
                }
            }
        }
        Darwin.close(fd)
    }
}
