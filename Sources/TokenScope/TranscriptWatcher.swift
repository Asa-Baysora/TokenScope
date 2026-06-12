import Foundation

/// Tails Claude Code session transcripts (~/.claude/projects/**/*.jsonl) and turns
/// every assistant message's `usage` block into a UsageEvent. Covers native Claude
/// and Claude Code pointed at Ollama alike, with exact per-call token counts.
final class TranscriptWatcher {
    private let store: UsageStore
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")
    private let queue = DispatchQueue(label: "tokenscope.transcripts", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    private let decoder = JSONDecoder()

    private var cutoff = Date.distantPast        // events-window boundary (whole days)
    private var backfillFrom = Date.distantPast  // history already complete through here
    private var backfilling = false
    private var backfillBatch: [String: DayAgg] = [:]
    private var backfillSeen = Set<String>()

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(store: UsageStore) { self.store = store }

    func start() {
        queue.async {
            self.bootstrap()
            self.scan()
            if self.backfilling {
                self.store.mergeHistorical(self.backfillBatch)
                self.backfillBatch = [:]
                self.backfillSeen = []
                self.backfilling = false
            }
            self.store.replayFinished(coverThrough: self.cutoff)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.cutoff = self.store.eventsCutoff
            self.scan()
        }
        t.resume()
        timer = t
    }

    /// Lines newer than the events cutoff replay into the live window; older lines
    /// not yet covered by the persisted daily history get aggregated into it
    /// (backfill). Files whose mtime predates the covered range hold nothing new —
    /// mtime is the file's newest event — and start at EOF.
    private func bootstrap() {
        cutoff = store.eventsCutoff
        let ancient = Date().addingTimeInterval(-366 * 86400)
        backfillFrom = max(store.historyCompleteThrough, ancient)
        backfilling = backfillFrom < cutoff
        var read = 0
        for u in jsonlFiles() {
            let vals = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = vals?.contentModificationDate ?? .distantPast
            if mtime < backfillFrom {
                offsets[u.path] = UInt64(vals?.fileSize ?? 0)
            } else {
                read += 1
            }
        }
        FileLog.log("transcript watcher started; reading \(read) files (events since \(UsageStore.dayKey(cutoff)), backfill from \(UsageStore.dayKey(backfillFrom)))")
    }

    private func jsonlFiles() -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where u.pathExtension == "jsonl" {
            out.append(u)
        }
        return out
    }

    // Cadence: a full directory walk + stat of all files is expensive (hundreds of
    // files). Almost always only the current session file is being written, so we
    // stat just the "hot" files (modified recently) every tick, and do a full walk
    // only every Nth tick to discover new files. Cuts idle work from O(all files)
    // per second to ~O(1).
    private var tick = 0
    private var activePaths: Set<String> = []
    private static let fullScanEveryTicks = 10        // full walk every ~10s
    private static let hotWindow: TimeInterval = 180  // "active" = written in last 3 min

    private func scan() {
        if tick % Self.fullScanEveryTicks == 0 {
            fullScan()
        } else {
            for path in activePaths { checkFile(URL(fileURLWithPath: path)) }
        }
        tick += 1
    }

    private func fullScan() {
        let hotCutoff = Date().addingTimeInterval(-Self.hotWindow)
        var active: Set<String> = []
        for u in jsonlFiles() {
            let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = UInt64(vals?.fileSize ?? 0)
            let off = offsets[u.path] ?? 0
            if size > off { readNew(u, from: off) }
            else if size < off { offsets[u.path] = size }
            if (vals?.contentModificationDate ?? .distantPast) > hotCutoff { active.insert(u.path) }
        }
        activePaths = active
    }

    private func checkFile(_ url: URL) {
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(UInt64.init) ?? 0
        let off = offsets[url.path] ?? 0
        if size > off { readNew(url, from: off) }
        else if size < off { offsets[url.path] = size }
    }

    private func readNew(_ url: URL, from offset: UInt64) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: offset)) != nil,
              let data = try? fh.readToEnd(), !data.isEmpty else { return }

        var consumed = 0
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: 0x0A) {
            let line = data[start..<nl]
            consumed = nl - data.startIndex + 1
            start = nl + 1
            if !line.isEmpty { parse(Data(line), file: url) }
        }
        // Only advance past complete lines; a partially written tail is re-read next tick.
        offsets[url.path] = offset + UInt64(consumed)
    }

    private struct Line: Decodable {
        let type: String?
        let sessionId: String?
        let timestamp: String?
        let cwd: String?
        let requestId: String?
        let message: Msg?

        struct Msg: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation_input_tokens: Int?
        }
    }

    // Cheap byte-level pre-filter so bulk replay doesn't JSON-decode every line;
    // assistant lines always contain this, anything else that does just gets decoded.
    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let aiTitleMarker = Data("\"ai-title\"".utf8)
    private static let summaryMarker = Data("\"type\":\"summary\"".utf8)
    private static let userMarker = Data("\"type\":\"user\"".utf8)

    private var fallbackNamed = Set<String>()   // sessions with a first-message name sent

    /// Non-assistant lines that name the session. Authoritative source is the
    /// `{"type":"ai-title","aiTitle":"…"}` line — the exact name Claude Code
    /// generates and shows in /resume. Older Claude Code wrote `"summary"`
    /// lines instead; both are honored. Sessions with neither fall back to the
    /// first real user message.
    private func handleMeta(_ data: Data, file: URL) {
        let fileSession = file.deletingPathExtension().lastPathComponent
        if data.range(of: Self.aiTitleMarker) != nil {
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               obj["type"] as? String == "ai-title",
               let title = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                store.setSessionName(obj["sessionId"] as? String ?? fileSession, title)
            }
            return
        }
        if data.range(of: Self.summaryMarker) != nil {
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               obj["type"] as? String == "summary",
               let s = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                store.setSessionName(fileSession, s)
            }
            return
        }
        guard !fallbackNamed.contains(fileSession), data.range(of: Self.userMarker) != nil else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "user",
              obj["isMeta"] as? Bool != true,
              let msg = obj["message"] as? [String: Any] else { return }
        var text: String?
        if let s = msg["content"] as? String {
            text = s
        } else if let blocks = msg["content"] as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "text" {
                text = block["text"] as? String
                break
            }
        }
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:") else { return }
        t = t.replacingOccurrences(of: "\n", with: " ")
        if t.count > 60 { t = String(t.prefix(60)) + "…" }
        fallbackNamed.insert(fileSession)
        store.setSessionName(obj["sessionId"] as? String ?? fileSession, t, fallback: true)
    }

    private func parse(_ data: Data, file: URL) {
        guard data.range(of: Self.assistantMarker) != nil else {
            handleMeta(data, file: file)
            return
        }
        guard let line = try? decoder.decode(Line.self, from: data),
              line.type == "assistant",
              let msg = line.message,
              let usage = msg.usage,
              let model = msg.model, model != "<synthetic>" else { return }

        let ts = line.timestamp.flatMap { Self.isoFrac.date(from: $0) ?? Self.iso.date(from: $0) } ?? Date()
        let event = UsageEvent(
            timestamp: ts,
            provider: TokenProvider.classify(model: model),
            source: .transcript,
            model: model,
            sessionId: line.sessionId ?? file.deletingPathExtension().lastPathComponent,
            projectName: line.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            inputTokens: usage.input_tokens ?? 0,
            outputTokens: usage.output_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0,
            cacheCreationTokens: usage.cache_creation_input_tokens ?? 0)

        // Streaming writes can repeat a message across lines; first occurrence wins.
        let key = "\(msg.id ?? UUID().uuidString):\(line.requestId ?? "")"
        if ts >= cutoff {
            store.addTranscriptEvent(event, dedupKey: key)
        } else if backfilling, ts >= backfillFrom, backfillSeen.insert(key).inserted {
            backfillBatch[UsageStore.dayKey(ts), default: DayAgg()].add(event)
        }
    }
}
