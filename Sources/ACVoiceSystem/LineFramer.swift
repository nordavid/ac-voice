import Foundation

/// NDJSON framing with a line cap (IPC v1: one JSON object per `\n`, at most 64 KB).
///
/// A line longer than `maxLineBytes` (newline excluded) is dropped as a whole, also when it arrives in many chunks:
/// the framer discards bytes until the next newline and then continues with the next line, so one oversized
/// message never kills the connection. A trailing `\r` is removed; empty lines are skipped.
struct LineFramer {
    let maxLineBytes: Int
    private var buffer = Data()
    private var discarding = false
    /// Lines dropped because they were too long.
    private(set) var droppedLines = 0

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    /// Bytes of an incomplete line held back.
    var pendingBytes: Int { buffer.count }

    /// Feeds received bytes, returns the complete lines in order (newline excluded).
    mutating func feed(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var rest = data[data.startIndex...]
        while let nl = rest.firstIndex(of: 0x0A) {
            let chunk = rest[rest.startIndex..<nl]
            rest = rest[rest.index(after: nl)...]
            if discarding {
                discarding = false
                buffer.removeAll(keepingCapacity: false)
                continue
            }
            var line = buffer
            line.append(contentsOf: chunk)
            buffer.removeAll(keepingCapacity: true)
            if line.last == 0x0D { line.removeLast() }
            if line.count > maxLineBytes {
                droppedLines += 1
                continue
            }
            if !line.isEmpty { lines.append(line) }
        }
        if !rest.isEmpty, !discarding {
            // A line may carry a "\r" before its newline, so allow one byte more before giving up on it.
            if buffer.count + rest.count > maxLineBytes + 1 {
                buffer.removeAll(keepingCapacity: false)
                discarding = true
                droppedLines += 1
            } else {
                buffer.append(contentsOf: rest)
            }
        }
        return lines
    }
}
