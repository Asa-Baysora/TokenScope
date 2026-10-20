import Foundation

/// Framework-free line reader shared by the Claude and Codex transcript watchers
/// (and `tools/bench-transcript.swift`). Reads a JSONL file in 1–4 MB chunks with
/// `pread`, scans for newlines with `memchr`, and hands each complete line to the
/// caller as a raw buffer that is only valid inside the callback. A partial
/// trailing line is carried over to the next chunk; the carry buffer grows as
/// needed (Claude Code lines reach ~4.5 MB). Peak memory is therefore ~one chunk
/// (or the longest line ×2), never the whole file.
enum TranscriptIO {
    static let chunkSize = 2 << 20

    /// Calls `body(line, absoluteOffsetOfLine)` for every complete, non-empty line
    /// at or after `offset`. Returns the offset of the first byte NOT consumed (the
    /// start of a partial trailing line, or EOF), which is what the watcher stores
    /// as the file's next read offset. Bytes appended after the initial `fstat` are
    /// left for the next poll.
    @discardableResult
    static func forEachLine(path: String, from offset: UInt64, chunk: Int = chunkSize,
                            _ body: (UnsafeRawBufferPointer, UInt64) -> Void) -> UInt64 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return offset }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= 0, UInt64(st.st_size) > offset else { return offset }
        let size = UInt64(st.st_size)

        var cap = Int(min(UInt64(max(chunk, 4096)), size - offset))
        guard var buf = malloc(cap) else { return offset }
        defer { free(buf) }
        var filled = 0        // valid bytes in buf (carry + fresh)
        var base = offset     // absolute file offset of buf[0] == first unconsumed byte

        while base + UInt64(filled) < size {
            if filled == cap {                       // one line longer than the buffer: grow the carry
                cap *= 2
                guard let nb = realloc(buf, cap) else { break }
                buf = nb
            }
            let want = min(cap - filled, Int(size - base - UInt64(filled)))
            let n = pread(fd, buf + filled, want, off_t(base + UInt64(filled)))
            if n <= 0 { break }
            let scanFrom = filled          // the carry holds no newline, only scan fresh bytes
            filled += n

            var lineStart = 0
            var p = scanFrom
            while p < filled, let hit = memchr(buf + p, 0x0A, filled - p) {
                let nl = buf.distance(to: hit)
                if nl > lineStart {
                    body(UnsafeRawBufferPointer(start: buf + lineStart, count: nl - lineStart),
                         base + UInt64(lineStart))
                }
                lineStart = nl + 1
                p = lineStart
            }
            if lineStart > 0 {
                let rest = filled - lineStart
                if rest > 0 { memmove(buf, buf + lineStart, rest) }
                base += UInt64(lineStart)
                filled = rest
            }
        }
        return base
    }

    /// A literal to search for. Picks the two adjacent needle bytes that are rarest
    /// in JSON text so the SIMD scan in `contains` rarely stops on a false candidate.
    struct Needle {
        let bytes: [UInt8]
        let at: Int           // index of the rare pair within the needle
        init(_ s: StaticString) {
            bytes = Array(UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
            precondition(bytes.count >= 2)
            var best = 0, bestScore = Int.max
            for i in 0..<(bytes.count - 1) {
                let score = Needle.weight(bytes[i]) + Needle.weight(bytes[i + 1])
                if score < bestScore { bestScore = score; best = i }
            }
            at = best
        }
        /// Rough byte frequency in JSONL transcripts (higher = more common).
        private static func weight(_ b: UInt8) -> Int {
            switch b {
            case UInt8(ascii: "\""), UInt8(ascii: ":"), UInt8(ascii: ","), UInt8(ascii: "{"),
                 UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"): return 40
            case UInt8(ascii: "e"): return 26
            case UInt8(ascii: "t"): return 25
            case UInt8(ascii: "a"): return 24
            case UInt8(ascii: "o"), UInt8(ascii: "i"), UInt8(ascii: "n"): return 22
            case UInt8(ascii: "s"), UInt8(ascii: "r"): return 20
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return 18
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return 10
            case UInt8(ascii: "-"), UInt8(ascii: "_"): return 8
            default: return 12
            }
        }
    }

    /// True when `needle` occurs in `hay`. 16-byte SIMD scan on the needle's rarest
    /// adjacent byte pair, then a `memcmp` confirm; libc `memmem` was ~half of the
    /// replay's remaining time (it scans every byte of multi-MB tool-result lines
    /// several times). No allocation.
    static func contains(_ hay: UnsafeRawBufferPointer, _ needle: Needle) -> Bool {
        let m = needle.bytes.count
        let n = hay.count
        guard let h = hay.baseAddress, n >= m else { return false }
        return needle.bytes.withUnsafeBufferPointer { nb -> Bool in
            let lastStart = n - m                       // last legal needle start
            let n0 = SIMD16<UInt8>(repeating: nb[needle.at])
            let n1 = SIMD16<UInt8>(repeating: nb[needle.at + 1])
            var pos = 0                                  // candidate needle start for lane 0
            // A block at `pos` reads hay[pos+at ..< pos+at+17]; lanes whose start exceeds lastStart are ignored.
            while pos + needle.at + 17 <= n {
                let a = UnsafeRawPointer(h + pos + needle.at).loadUnaligned(as: SIMD16<UInt8>.self)
                let b = UnsafeRawPointer(h + pos + needle.at + 1).loadUnaligned(as: SIMD16<UInt8>.self)
                let hit = (a .== n0) .& (b .== n1)
                if any(hit) {
                    for lane in 0..<16 where hit[lane] {
                        let start = pos + lane
                        if start <= lastStart, memcmp(h + start, nb.baseAddress!, m) == 0 { return true }
                    }
                }
                pos += 16
            }
            // Tail shorter than one block: plain scan from `pos`.
            if pos > lastStart { return false }
            return memmem(h + pos, n - pos, nb.baseAddress!, m) != nil
        }
    }

    /// Wraps a callback line as `Data` without copying. Valid only inside the callback.
    @inline(__always)
    static func data(_ raw: UnsafeRawBufferPointer) -> Data {
        Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
             count: raw.count, deallocator: .none)
    }
}

/// Chronological bulk merge used by `UsageStore.ingest(batch:)`; equivalent to
/// inserting each event with `appendEvent` (ties land after existing events at the
/// same timestamp) but one pass instead of one array shift per event.
enum EventMerge {
    static func merge(_ existing: [UsageEvent], _ incoming: [UsageEvent]) -> [UsageEvent] {
        guard !incoming.isEmpty else { return existing }
        let sorted = incoming.sorted { $0.timestamp < $1.timestamp }
        guard let last = existing.last, last.timestamp > sorted[0].timestamp else {
            return existing + sorted
        }
        // First position where an existing event is strictly newer than the earliest
        // incoming one; everything before it is untouched.
        var low = 0, high = existing.count
        while low < high {
            let mid = (low + high) / 2
            if existing[mid].timestamp <= sorted[0].timestamp { low = mid + 1 } else { high = mid }
        }
        var merged = Array(existing[..<low])
        merged.reserveCapacity(existing.count + sorted.count)
        var i = low, j = 0
        while i < existing.count, j < sorted.count {
            if existing[i].timestamp <= sorted[j].timestamp { merged.append(existing[i]); i += 1 }
            else { merged.append(sorted[j]); j += 1 }
        }
        if i < existing.count { merged.append(contentsOf: existing[i...]) }
        if j < sorted.count { merged.append(contentsOf: sorted[j...]) }
        return merged
    }
}
