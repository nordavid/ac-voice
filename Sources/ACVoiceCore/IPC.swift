import Foundation

/// IPC protocol v1: one JSON object per line over ~/Library/Application Support/ac-voice/ipc.sock (`AppPaths.socket`).
/// Mirrors streamdeck/src/protocol.ts. Unknown "t" values and unknown fields are ignored, new fields are optional,
/// and numbers decode from integers or floats (JavaScript sends either).
public enum IPC {
    public static let version = 1
    /// Longest accepted line in bytes, newline excluded. Longer lines are dropped.
    public static let maxLineBytes = 65_536
    /// Valid `choose.index` values. Lines outside are dropped.
    public static let chooseRange: ClosedRange<Int64> = 1...1000

    public enum Phase: String, Codable, Sendable {
        case idle, listening, processing, choices, success, error
    }

    public struct Choice: Codable, Sendable, Equatable {
        public var n: Int
        public var label: String        // <= 12 chars for a 144 px key
        public var detail: String?
        public init(n: Int, label: String, detail: String? = nil) { self.n = n; self.label = label; self.detail = detail }
    }

    /// App -> plugin snapshot. Sent on connect and on every change.
    public struct State: Codable, Sendable, Equatable {
        public var v = 1
        public var t = "state"
        /// Monotonic per app run. The plugin drops older snapshots and echoes it in `choose`.
        public var seq: Int
        public var phase: Phase
        public var since: Int64                 // epoch ms
        public var transcript: String?
        /// Live target preview while listening ("WWT: Website Relaunch").
        public var preview: String?
        public var choices: [Choice]?
        public var total: Int?                  // candidates in total when more than shown
        public var deadline: Int64?             // epoch ms, choices window end
        public var message: String?             // German status for success / error / hints
        public var micReady: Bool?
        public init(seq: Int, phase: Phase, since: Int64, transcript: String? = nil, preview: String? = nil,
                    choices: [Choice]? = nil, total: Int? = nil, deadline: Int64? = nil, message: String? = nil,
                    micReady: Bool? = nil) {
            self.seq = seq; self.phase = phase; self.since = since; self.transcript = transcript; self.preview = preview
            self.choices = choices; self.total = total; self.deadline = deadline; self.message = message
            self.micReady = micReady
        }
    }

    public struct Level: Codable, Sendable, Equatable {
        public var v = 1; public var t = "level"; public var rms: Double
        public init(rms: Double) { self.rms = rms }
    }
    public struct Pong: Codable, Sendable, Equatable {
        public var v = 1; public var t = "pong"; public var id: String
        public init(id: String) { self.id = id }
    }

    /// Plugin -> app.
    public enum Command: Sendable, Equatable {
        case hello(client: String, version: String)
        case press(id: String, at: Int64)
        /// `pressId` names the `press` this release ends (REVIEW m4); nil from older plugins.
        case release(id: String, pressId: String?, heldMs: Int)
        /// `seq` is the `State.seq` the plugin showed when the key was pressed, so a renumbered list ("narrow")
        /// cannot pick the wrong item (REVIEW m4); nil from older plugins.
        case choose(id: String, index: Int, seq: Int?)
        case cancel(id: String)
        case ping(id: String)
    }

    /// Decodes an integer that may arrive as a JSON float.
    struct FlexInt: Decodable {
        let value: Int64
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int64.self) { value = i; return }
            let d = try c.decode(Double.self)
            guard d.isFinite, abs(d) < 9e15 else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "number out of range") }
            value = Int64(d.rounded())
        }
    }

    private struct Envelope: Decodable {
        let v: FlexInt?; let t: String?
        let id: String?; let at: FlexInt?; let heldMs: FlexInt?; let index: FlexInt?; let seq: FlexInt?
        let pressId: String?; let client: String?; let version: String?

        enum CodingKeys: String, CodingKey { case v, t, id, at, heldMs, index, seq, pressId, client, version }
        /// Each field on its own: a wrong type in an unused field does not drop the line.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = try? c.decodeIfPresent(FlexInt.self, forKey: .v); t = try? c.decodeIfPresent(String.self, forKey: .t)
            id = try? c.decodeIfPresent(String.self, forKey: .id); at = try? c.decodeIfPresent(FlexInt.self, forKey: .at)
            heldMs = try? c.decodeIfPresent(FlexInt.self, forKey: .heldMs)
            index = try? c.decodeIfPresent(FlexInt.self, forKey: .index)
            seq = try? c.decodeIfPresent(FlexInt.self, forKey: .seq)
            pressId = try? c.decodeIfPresent(String.self, forKey: .pressId)
            client = try? c.decodeIfPresent(String.self, forKey: .client)
            version = try? c.decodeIfPresent(String.self, forKey: .version)
        }
    }

    /// Returns nil for junk, other versions, unknown types or missing required fields (forward compatible).
    public static func decodeCommand(_ line: Data) -> Command? {
        guard line.count <= maxLineBytes,
              let e = try? JSONDecoder().decode(Envelope.self, from: line), e.v?.value == Int64(version), let t = e.t
        else { return nil }
        switch t {
        case "hello": return .hello(client: e.client ?? "?", version: e.version ?? "?")
        case "press": return e.id.map { .press(id: $0, at: e.at?.value ?? 0) }
        case "release": return e.id.map { .release(id: $0, pressId: e.pressId, heldMs: Int(e.heldMs?.value ?? 0)) }
        case "choose":
            // A choice number is small and 1-based; anything else is junk (Int.min would trap in `n - 1`).
            guard let id = e.id, let index = e.index, chooseRange.contains(index.value) else { return nil }
            return .choose(id: id, index: Int(index.value), seq: e.seq.map { Int($0.value) })
        case "cancel": return e.id.map { .cancel(id: $0) }
        case "ping": return e.id.map { .ping(id: $0) }
        default: return nil
        }
    }

    /// One NDJSON line for a plugin command (fake hosts, tests, the dev CLI).
    public static func line(_ cmd: Command) -> Data {
        var o: [String: Any] = ["v": version]
        switch cmd {
        case let .hello(client, ver): o["t"] = "hello"; o["client"] = client; o["version"] = ver
        case let .press(id, at): o["t"] = "press"; o["id"] = id; o["at"] = at
        case let .release(id, pressId, heldMs): o["t"] = "release"; o["id"] = id; o["heldMs"] = heldMs; o["pressId"] = pressId
        case let .choose(id, index, seq): o["t"] = "choose"; o["id"] = id; o["index"] = index; o["seq"] = seq
        case let .cancel(id): o["t"] = "cancel"; o["id"] = id
        case let .ping(id): o["t"] = "ping"; o["id"] = id
        }
        var d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        d.append(0x0A)
        return d
    }

    /// One NDJSON line, newline included.
    public static func line<T: Encodable>(_ msg: T) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var d = (try? enc.encode(msg)) ?? Data()
        d.append(0x0A)
        return d
    }
}
