import Foundation

/// Tails Claude Code session transcripts (~/.claude/projects/**/*.jsonl, plus any
/// `ExtraClaudeProjectDirs` roots for CLAUDE_CONFIG_DIR sessions) and turns
/// every assistant message's `usage` block into a UsageEvent. Covers native Claude
/// and Claude Code pointed at Ollama alike, with exact per-call token counts.
final class TranscriptWatcher {
    private let store: UsageStore
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let queue = DispatchQueue(label: "tokenscope.transcripts", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    private var parser = ClaudeTranscriptParser()

    private var cutoff = Date.distantPast        // events-window boundary (whole days)
    private var backfillFrom = Date.distantPast  // history already complete through here
    private var backfilling = false
    private var backfillBatch: [String: DayAgg] = [:]
    private var backfillBestByKey: [String: UsageEvent] = [:]

    init(store: UsageStore) { self.store = store }

    func start() {
        queue.async {
            self.bulkReplay = true
            self.bootstrap()
            self.scan()
            self.flushReplayBatch()
            self.bulkReplay = false
            if self.backfilling {
                for event in self.backfillBestByKey.values {
                    self.backfillBatch[UsageStore.dayKey(event.timestamp), default: DayAgg()].add(event)
                }
                self.store.mergeHistorical(self.backfillBatch)
                self.backfillBatch = [:]
                self.backfillBestByKey = [:]
                self.backfilling = false
            }
            self.store.replayFinished(coverThrough: self.cutoff)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3.0, repeating: 1.0, leeway: .milliseconds(300))  // coalescing; logic counts ticks, not exact seconds
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
        refreshRoots(seed: false)
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

    private var roots: [URL] = []
    private var knownRoots: Set<String> = []
    private var rootsSignature = ""

    private func enumerate(_ root: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where u.pathExtension == "jsonl" && !ClaudeProjectRoots.isIgnoredTranscript(u) { out.append(u) }
        return out
    }

    /// Re-resolves the roots (one defaults read + a few stats; called at bootstrap
    /// and on each full walk, so a root created later is picked up). A root that
    /// was not present at bootstrap has its existing files seeded to EOF: only new
    /// activity is counted until restart, so history is never replayed at runtime
    /// (that would double-count against proxy events). Logs the root set once per
    /// change.
    private func refreshRoots(seed: Bool) {
        let d = UserDefaults.standard.object(forKey: ClaudeProjectRoots.defaultsKey)
        let r = ClaudeProjectRoots.resolveDetailed(
            extra: ClaudeProjectRoots.entries(from: d), home: home)
        let existing = ClaudeProjectRoots.existing(extra: ClaudeProjectRoots.entries(from: d), home: home)
        let paths = Set(existing.map(\.path))
        if seed {
            for root in existing where !knownRoots.contains(root.path) {
                for u in enumerate(root) where offsets[u.path] == nil {
                    offsets[u.path] = UInt64(((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0)
                }
            }
        }
        knownRoots = paths
        roots = existing
        let sig = existing.map(\.path).joined(separator: "|") + "#" + r.rejected.joined(separator: "|")
        if sig != rootsSignature {
            rootsSignature = sig
            var msg = "claude transcript roots: " + existing.map(\.path).joined(separator: ", ")
            if !r.rejected.isEmpty { msg += " (rejected: \(r.rejected.joined(separator: ", ")))" }
            FileLog.log(msg)
        }
    }

    private func jsonlFiles() -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for root in roots {
            for u in enumerate(root) where seen.insert(u.path).inserted { out.append(u) }  // nested roots
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
        refreshRoots(seed: true)
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

    /// Per-file values computed once per read, not once per line.
    private final class FileContext {
        let url: URL
        let path: String
        let fileSession: String
        private var mtimeResolved = false
        private var mtimeValue: Date?
        init(_ url: URL) {
            self.url = url
            path = url.path
            fileSession = url.deletingPathExtension().lastPathComponent
        }
        /// Consulted lazily, only while a file has produced no timestamp yet.
        func mtime() -> Date? {
            if !mtimeResolved {
                mtimeResolved = true
                mtimeValue = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            return mtimeValue
        }
    }

    /// Chunked (2 MB) read from `offset`: each complete line is handed to `parse`
    /// straight out of the read buffer; a partial trailing line is carried across
    /// chunks and, at EOF, re-read next tick (the offset only advances past
    /// complete lines). One autorelease pool per file keeps Foundation temporaries
    /// from piling up across the whole replay.
    private func readNew(_ url: URL, from offset: UInt64) {
        autoreleasepool {
            let ctx = FileContext(url)
            let end = TranscriptIO.forEachLine(path: ctx.path, from: offset) { raw, _ in
                parse(raw, ctx)
            }
            offsets[ctx.path] = end
        }
    }

    // Cheap byte-level pre-filter so bulk replay doesn't JSON-decode every line;
    // assistant lines always contain this, anything else that does just gets decoded.
    // (SIMD marker scan over the raw read buffer — no Data wrapper is built unless a marker hits.)
    private static let assistantMarker = TranscriptIO.Needle("\"assistant\"")
    private static let aiTitleMarker = TranscriptIO.Needle("\"ai-title\"")
    private static let summaryMarker = TranscriptIO.Needle("\"type\":\"summary\"")
    private static let userMarker = TranscriptIO.Needle("\"type\":\"user\"")
    /// ai-title / summary records are a few hundred bytes; never scan a multi-MB
    /// tool-result line for them.
    private static let maxTitleLine = 16 * 1024

    private var fallbackNamed = Set<String>()   // sessions with a first-message name sent

    /// Non-assistant lines that name the session. Authoritative source is the
    /// `{"type":"ai-title","aiTitle":"…"}` line — the exact name Claude Code
    /// generates and shows in /resume. Older Claude Code wrote `"summary"`
    /// lines instead; both are honored. Sessions with neither fall back to the
    /// first real user message.
    private func handleMeta(_ raw: UnsafeRawBufferPointer, _ ctx: FileContext) {
        let fileSession = ctx.fileSession
        if raw.count <= Self.maxTitleLine && TranscriptIO.contains(raw, Self.aiTitleMarker) {
            let data = TranscriptIO.data(raw)
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               obj["type"] as? String == "ai-title",
               let title = (obj["aiTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                store.setSessionName(obj["sessionId"] as? String ?? fileSession, title)
            }
            return
        }
        if raw.count <= Self.maxTitleLine && TranscriptIO.contains(raw, Self.summaryMarker) {
            let data = TranscriptIO.data(raw)
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               obj["type"] as? String == "summary",
               let s = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                store.setSessionName(fileSession, s)
            }
            return
        }
        guard !fallbackNamed.contains(fileSession),
              TranscriptIO.contains(raw, Self.userMarker) else { return }
        let data = TranscriptIO.data(raw)
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

    private func parse(_ raw: UnsafeRawBufferPointer, _ ctx: FileContext) {
        guard TranscriptIO.contains(raw, Self.assistantMarker) else {
            handleMeta(raw, ctx)
            return
        }
        let observations = parser.parse(
            TranscriptIO.data(raw), fileKey: ctx.path, fileSession: ctx.fileSession,
            mtime: { ctx.mtime() })
        for obs in observations { route(obs.event, key: obs.dedupKey) }
    }

    /// Launch replay hands events to the main actor in batches (one main hop, one
    /// sort/merge, one publish per batch) instead of one `main.async` per line.
    /// Live tailing after the replay stays per-line.
    private static let replayBatchSize = 500
    private var bulkReplay = false
    private var replayBatch: [(event: UsageEvent, dedupKey: String)] = []

    private func flushReplayBatch() {
        guard !replayBatch.isEmpty else { return }
        let batch = replayBatch
        replayBatch = []
        replayBatch.reserveCapacity(Self.replayBatchSize)
        store.ingest(batch: batch)
    }

    private func route(_ event: UsageEvent, key: String) {
        let ts = event.timestamp
        // Streaming writes can repeat a message across lines. Keep the strongest
        // occurrence so a partial/zero rewrite cannot suppress finalized usage.
        if ts >= cutoff {
            if bulkReplay {
                replayBatch.append((event, key))
                if replayBatch.count >= Self.replayBatchSize { flushReplayBatch() }
            } else {
                store.addTranscriptEvent(event, dedupKey: key)
            }
        } else if backfilling, ts >= backfillFrom {
            if let existing = backfillBestByKey[key] {
                backfillBestByKey[key] = EventReconciler.preferred(existing, event)
            } else {
                backfillBestByKey[key] = event
            }
        }
    }
}
