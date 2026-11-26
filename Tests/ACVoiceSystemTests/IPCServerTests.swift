import ACVoiceCore
@testable import ACVoiceSystem
import Darwin
import Foundation
import Testing

/// Real `IPCServer` on a temp socket, real clients (POSIX and Network.framework).
@MainActor
@Suite(.serialized)
struct IPCServerTests {
    /// A started server plus the commands it delivered.
    @MainActor final class Harness {
        let path: String
        let server: IPCServer
        var commands: [(IPC.Command, IPCClient)] = []

        init(path: String = tempSocketPath(), options: IPCServer.Options = .init()) async throws {
            self.path = path
            server = IPCServer(path: path, options: options)
            server.onCommand = { [unowned self] cmd, client in self.commands.append((cmd, client)) }
            try await server.start()
        }

        func finish() {
            server.stop()
            removeTempDir(of: path)
        }
    }

    static func state(_ seq: Int, _ phase: IPC.Phase) -> IPC.State {
        IPC.State(seq: seq, phase: phase, since: 1_732_440_000_000 + Int64(seq))
    }

    @Test func socketAndDirectoryPermissions() async throws {
        let h = try await Harness()
        defer { h.finish() }
        var st = stat()
        #expect(lstat(h.path, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFSOCK)
        #expect((st.st_mode & 0o777) == 0o600)
        var dst = stat()
        #expect(lstat((h.path as NSString).deletingLastPathComponent, &dst) == 0)
        #expect((dst.st_mode & 0o777) == 0o700)
        #expect(h.server.isRunning)
        #expect(IPCServer.probe(path: h.path) == .live)

        h.server.stop()
        #expect(!h.server.isRunning)
        #expect(IPCServer.probe(path: h.path) == .absent)
    }

    @Test func existingDirectoryIsTightened() async throws {
        let path = tempSocketPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let h = try await Harness(path: path)
        defer { h.finish() }
        var dst = stat()
        #expect(lstat(dir, &dst) == 0)
        #expect((dst.st_mode & 0o777) == 0o700)
    }

    @Test func commandsArriveInOrderAndPingIsAnswered() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let c = try PosixClient(path: h.path)
        defer { c.close() }
        #expect(await c.waitFor("state") != nil)

        c.send(#"{"v":1,"t":"hello","client":"streamdeck","version":"0.1.0"}"# + "\n")
        c.send(#"{"v":1,"t":"press","id":"sd-7","at":1732440000000}"# + "\n")
        c.send(#"{"v":1,"t":"release","id":"sd-8","pressId":"sd-7","heldMs":812}"# + "\n")
        c.send(#"{"v":1,"t":"choose","id":"sd-9","index":2,"seq":6}"# + "\n")
        c.send(#"{"v":1,"t":"cancel","id":"sd-10"}"# + "\n")
        c.send(#"{"v":1,"t":"ping","id":"sd-11"}"# + "\n")

        let pong = await c.waitFor("pong")
        #expect(pong?["id"] as? String == "sd-11")
        #expect(await waitUntil { h.commands.count == 5 })
        #expect(h.commands.map(\.0) == [
            .hello(client: "streamdeck", version: "0.1.0"),
            .press(id: "sd-7", at: 1_732_440_000_000),
            .release(id: "sd-8", pressId: "sd-7", heldMs: 812),
            .choose(id: "sd-9", index: 2, seq: 6),
            .cancel(id: "sd-10"),
        ])
        // The client is named after its hello.
        #expect(h.commands.last?.1.name == "streamdeck")
        #expect(h.commands.last?.1.version == "0.1.0")
        #expect(h.server.connectedClients.first?.name == "streamdeck")
    }

    @Test func disconnectWhileHeldReleasesThePress() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let c = try PosixClient(path: h.path)
        #expect(await c.waitFor("state") != nil)
        c.send(#"{"v":1,"t":"press","id":"sd-7","at":1732440000000}"# + "\n")
        #expect(await waitUntil { h.commands.count == 1 })
        c.close()

        #expect(await waitUntil { h.commands.count == 2 })
        guard case let .release(_, pressId, heldMs)? = h.commands.last?.0 else {
            Issue.record("expected a synthetic release, got \(h.commands.map(\.0))")
            return
        }
        #expect(pressId == "sd-7")
        #expect(heldMs == 0)
    }

    @Test func disconnectAfterReleaseAddsNothing() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let c = try PosixClient(path: h.path)
        #expect(await c.waitFor("state") != nil)
        c.send(#"{"v":1,"t":"press","id":"sd-7","at":1732440000000}"# + "\n")
        c.send(#"{"v":1,"t":"release","id":"sd-8","pressId":"sd-7","heldMs":812}"# + "\n")
        #expect(await waitUntil { h.commands.count == 2 })
        c.close()

        #expect(await waitUntil { h.server.connectedClients.isEmpty })
        // Give a late synthetic release the chance to show up before checking that none came.
        _ = await waitUntil(timeout: 0.3) { false }
        #expect(h.commands.count == 2)
    }

    @Test func snapshotOnConnectAndBroadcastToTwoClients() async throws {
        let h = try await Harness()
        defer { h.finish() }
        h.server.broadcast(Self.state(5, .idle))

        let a = try PosixClient(path: h.path)
        defer { a.close() }
        let b = NWClient(path: h.path)
        defer { b.close() }
        #expect(await a.waitFor("state")?["seq"] as? Int == 5)
        #expect(await b.waitFor("state")?["seq"] as? Int == 5)
        #expect(await waitUntil { h.server.connectedClients.count == 2 })

        var listening = Self.state(6, .listening)
        listening.transcript = "Öffne das WWT-Projekt"
        listening.micReady = true
        h.server.broadcast(listening)
        let sa = await a.waitFor("state", count: 2)
        let sb = await b.waitFor("state", count: 2)
        #expect(sa?["seq"] as? Int == 6)
        #expect(sb?["seq"] as? Int == 6)
        #expect(sa?["phase"] as? String == "listening")
        #expect(sb?["transcript"] as? String == "Öffne das WWT-Projekt")
    }

    @Test func malformedAndOversizedLinesAreDroppedWithoutClosing() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let c = try PosixClient(path: h.path)
        defer { c.close() }
        #expect(await c.waitFor("state") != nil)

        c.send("garbage\n")
        c.send(#"{"v":2,"t":"press","id":"x"}"# + "\n")              // other protocol version
        c.send(#"{"v":1,"t":"teleport","id":"x"}"# + "\n")            // unknown type
        c.send(#"{"v":1,"t":"press"}"# + "\n")                         // missing id
        // 70 KB without a newline, in several writes, then the newline.
        let blob = String(repeating: "x", count: 10_000)
        for _ in 0..<7 { c.send(blob) }
        c.send("\n")
        // A valid command padded beyond the 64 KB cap.
        let pad = String(repeating: "p", count: IPC.maxLineBytes)
        c.send(#"{"v":1,"t":"press","id":"big","pad":""# + pad + #""}"# + "\n")
        c.send(#"{"v":1,"t":"ping","id":"after"}"# + "\n")

        let pong = await c.waitFor("pong")
        #expect(pong?["id"] as? String == "after")
        #expect(h.commands.isEmpty)
        #expect(h.server.droppedLines == 6)
        #expect(!c.isClosed)
        #expect(h.server.connectedClients.count == 1)

        // The connection still delivers commands.
        c.send(#"{"v":1,"t":"cancel","id":"c1"}"# + "\n")
        #expect(await waitUntil { h.commands.count == 1 })
        #expect(h.commands.first?.0 == .cancel(id: "c1"))
    }

    @Test func lineExactlyAtTheCapIsAccepted() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let c = try PosixClient(path: h.path)
        defer { c.close() }
        #expect(await c.waitFor("state") != nil)
        let head = #"{"v":1,"t":"ping","id":"cap","pad":""#
        let tail = #""}"#
        let pad = String(repeating: "p", count: IPC.maxLineBytes - head.utf8.count - tail.utf8.count)
        let line = head + pad + tail
        #expect(line.utf8.count == IPC.maxLineBytes)
        c.send(line + "\r\n")
        #expect(await c.waitFor("pong")?["id"] as? String == "cap")
    }

    @Test func staleSocketIsRemoved() async throws {
        let path = tempSocketPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        // Bind and close without unlink: what a crashed instance leaves behind.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try #require(IPCServer.unixAddress(path))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(rc == 0)
        close(fd)
        #expect(IPCServer.probe(path: path) == .stale)

        let h = try await Harness(path: path)
        defer { h.finish() }
        #expect(IPCServer.probe(path: path) == .live)
        let c = try PosixClient(path: path)
        defer { c.close() }
        #expect(await c.waitFor("state") != nil)
    }

    @Test func liveSocketIsNotTakenOver() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let second = IPCServer(path: h.path)
        await #expect(throws: IPCServerError.alreadyRunning) { try await second.start() }
        // The first instance keeps serving.
        let c = try PosixClient(path: h.path)
        defer { c.close() }
        c.send(#"{"v":1,"t":"ping","id":"still"}"# + "\n")
        #expect(await c.waitFor("pong")?["id"] as? String == "still")
    }

    @Test func regularFileIsNeverDeleted() async throws {
        let path = tempSocketPath()
        defer { removeTempDir(of: path) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        let server = IPCServer(path: path)
        await #expect(throws: IPCServerError.pathOccupied) { try await server.start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
    }

    @Test func tooLongPathIsRejected() async throws {
        let path = "/tmp/" + String(repeating: "a", count: 120) + ".sock"
        let server = IPCServer(path: path)
        await #expect(throws: IPCServerError.pathTooLong(path.utf8.count)) { try await server.start() }
        #expect(IPCServer.unixAddress(path) == nil)
    }

    @Test func clientReconnectGetsLatestSnapshot() async throws {
        let h = try await Harness()
        defer { h.finish() }
        h.server.broadcast(Self.state(3, .idle))
        let first = try PosixClient(path: h.path)
        #expect(await first.waitFor("state")?["seq"] as? Int == 3)
        #expect(await waitUntil { h.server.connectedClients.count == 1 })
        first.close()
        #expect(await waitUntil { h.server.connectedClients.isEmpty })

        var success = Self.state(7, .success)
        success.message = "WWT: Website Relaunch"
        h.server.broadcast(success)
        let again = try PosixClient(path: h.path)
        defer { again.close() }
        let snap = await again.waitFor("state")
        #expect(snap?["seq"] as? Int == 7)
        #expect(snap?["phase"] as? String == "success")
        #expect(again.messages(type: "state").count == 1)
    }

    @Test func levelIsThrottledAndOnlySentWhileListening() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let c = try PosixClient(path: h.path)
        defer { c.close() }
        #expect(await c.waitFor("state") != nil)
        #expect(await waitUntil { h.server.connectedClients.count == 1 })

        h.server.level(0.5) // idle: dropped
        h.server.broadcast(Self.state(1, .listening))
        #expect(await c.waitFor("state", count: 2) != nil)
        #expect(c.messages(type: "level").isEmpty)

        // A burst within one main-actor turn: the first goes out at once, the latest one at the next slot.
        for i in 1...50 { h.server.level(Double(i) / 100) }
        try await Task.sleep(for: .milliseconds(300))
        let levels = c.messages(type: "level").compactMap { $0["rms"] as? Double }
        #expect(levels == [0.01, 0.5])

        // Out of range values are clamped.
        try await Task.sleep(for: .milliseconds(80))
        h.server.level(3)
        #expect(await c.waitFor("level", count: 3)?["rms"] as? Double == 1)

        // Leaving listening drops a pending level and stops new ones.
        try await Task.sleep(for: .milliseconds(10))
        h.server.level(0.2) // pending (inside the interval)
        h.server.broadcast(Self.state(2, .processing))
        h.server.level(0.3)
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.messages(type: "level").count == 3)
    }

    @Test func levelRateStaysNearFifteenHertz() async throws {
        let h = try await Harness()
        defer { h.finish() }
        let c = try PosixClient(path: h.path)
        defer { c.close() }
        #expect(await waitUntil { h.server.connectedClients.count == 1 })
        h.server.broadcast(Self.state(1, .listening))
        // About 100 Hz input for about one second.
        let t0 = ProcessInfo.processInfo.systemUptime
        for i in 0..<100 {
            h.server.level(Double(i % 10) / 10)
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        try await Task.sleep(for: .milliseconds(150))
        let n = c.messages(type: "level").count
        // Sends are at least 1/15 s apart: at most one per slot over the loop plus the trailing wait.
        #expect(n <= Int((elapsed + 0.15) * 15) + 1, "\(n) levels in \(elapsed) s")
        #expect(Double(n) / elapsed >= 11, "\(n) levels in \(elapsed) s")
    }

    @Test func stopClosesClients() async throws {
        let h = try await Harness()
        let c = try PosixClient(path: h.path)
        defer { c.close() }
        #expect(await c.waitFor("state") != nil)
        h.finish()
        let closed = await waitUntil { c.isClosed }
        #expect(closed)
    }
}

/// The framer on its own: chunking, cap, CRLF.
struct LineFramerTests {
    @Test func splitsAcrossChunks() {
        var f = LineFramer(maxLineBytes: 16)
        #expect(f.feed(Data("ab".utf8)).isEmpty)
        #expect(f.feed(Data("c\nde\n\nf".utf8)) == [Data("abc".utf8), Data("de".utf8)])
        #expect(f.pendingBytes == 1)
        #expect(f.feed(Data("\r\n".utf8)) == [Data("f".utf8)])
        #expect(f.droppedLines == 0)
    }

    @Test func dropsOversizedLinesAndRecovers() {
        var f = LineFramer(maxLineBytes: 8)
        #expect(f.feed(Data("12345678\n".utf8)) == [Data("12345678".utf8)])   // exactly at the cap
        #expect(f.feed(Data("123456789\nok\n".utf8)) == [Data("ok".utf8)])     // one byte over
        #expect(f.droppedLines == 1)
        // Long line in pieces without a newline: discarded until the newline.
        #expect(f.feed(Data("aaaaa".utf8)).isEmpty)
        #expect(f.feed(Data("aaaaa".utf8)).isEmpty)
        #expect(f.feed(Data("aaaaa".utf8)).isEmpty)
        #expect(f.pendingBytes == 0)
        #expect(f.feed(Data("aa\nnext\n".utf8)) == [Data("next".utf8)])
        #expect(f.droppedLines == 2)
    }
}
