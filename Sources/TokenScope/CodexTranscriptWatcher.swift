import Foundation

/// Reads Codex's local rollout logs without retaining prompts, replies, tool
/// payloads, or any other session content. Codex appends token_count events to
/// ~/.codex/sessions/YYYY/MM/DD/*.jsonl; their last_token_usage field is the
/// per-turn usage record that belongs in TokenScope's local activity stream.
final class CodexTranscriptWatcher {
    private let store: UsageStore
    private let limits: OpenAILimitsManager
    // Live rollouts, plus rollouts Codex moves to archived_sessions/. Dedup keys
    // are path-independent so a move between the two never double-counts.
    private let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".codex/sessions", ".codex/archived_sessions"].map { home.appendingPathComponent($0) }
    }()
    private var duplicateGate = CodexHistory.DuplicateGate()
    private let queue = DispatchQueue(label: "tokenscope.codex-transcripts", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var monitorObserver: NSObjectProtocol?
    private var refreshObserver: NSObjectProtocol?
    private var offsets: [String: UInt64] = [:]
    private var activePaths: Set<String> = []
    private var sessionMetadata: [String: (id: String, project: String?)] = [:]
    // Codex records the model per turn in `turn_context`, not in the
    // `token_count` record that carries usage. Track the latest model seen per
    // file (turn_context precedes its token_counts in file order) so each event
    // carries its real model instead of a generic "Codex".
    private var latestModel: [String: String] = [:]
    private var lastTimestamp: [String: Date] = [:]   // per file, for timestamp carry-forward
    private var tick = 0
    private var backfillFrom = Date.distantPast
    private var backfilling = false
    private var backfillBatch: [String: DayAgg] = [:]
    private var backfillSeen = Set<String>()

    private static let fullScanEveryTicks = 10
    private static let hotWindow: TimeInterval = 180
    private static let tokenCountMarker = TranscriptIO.Needle("\"token_count\"")
    private static let sessionMetaMarker = TranscriptIO.Needle("\"session_meta\"")
    private static let turnContextMarker = TranscriptIO.Needle("\"turn_context\"")
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    init(store: UsageStore, limits: OpenAILimitsManager) {
        self.store = store
        self.limits = limits
    }

    func start() {
        // Local session token tracking is independent of the selected quota
        // source. Cookie-based limits cover the account, but cannot replace the
        // per-turn token_count records in ~/.codex/sessions.
        if CodexTrackingPolicy.tracksLocalSessionTokens(cookieLimitsSelected: !localQuotaEnabled) {
            startScanning()
        }
        monitorObserver = NotificationCenter.default.addObserver(
            forName: OpenAILimitsManager.monitoringChanged, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.monitoringChanged() }
        }
        refreshObserver = NotificationCenter.default.addObserver(
            forName: OpenAILimitsManager.refreshRequested, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                guard let self, self.localQuotaEnabled else { return }
                // A normal scan only tails new bytes. Refresh intentionally
                // replays the current window so the latest saved quota record
                // is re-observed even if Codex has been idle. Usage events are
                // keyed by session + timestamp + totals, so this cannot double-count them.
                self.offsets = [:]
                self.activePaths = []
                self.sessionMetadata = [:]
                self.latestModel = [:]
                self.lastTimestamp = [:]
                self.tick = 0
                self.bulk {
                    self.bootstrap()
                    self.fullScan()
                }
                self.finishBackfillIfNeeded()
                FileLog.log("Codex limits refreshed from local sessions")
            }
        }
    }

    private var localQuotaEnabled: Bool { limits.monitoringEnabled }

    private func startScanning() {
        guard timer == nil else { return }
        queue.async { [weak self] in
            self?.bulk {
                self?.bootstrap()
                self?.scan()
            }
            self?.finishBackfillIfNeeded()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 1, leeway: .milliseconds(300))  // coalescing; logic counts ticks, not exact seconds
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    private func monitoringChanged() {
        guard localQuotaEnabled else {
            FileLog.log("Codex local quota observation disabled; session token tracking remains active")
            return
        }
        // Replay the live window so the latest saved quota record is observed
        // immediately after switching back to local limits. Dedup keys are
        // path-independent, so local token events cannot be counted twice.
        offsets = [:]
        activePaths = []
        sessionMetadata = [:]
        latestModel = [:]
        lastTimestamp = [:]
        tick = 0
        bulk {
            bootstrap()
            scan()
        }
        finishBackfillIfNeeded()
        FileLog.log("Codex local quota observation resumed; session token tracking active")
    }

    /// Replays the live window and, once per persisted gap, folds up to a year
    /// of older local Codex logs into the same permanent day history Claude uses.
    /// Files older than the gap cannot contribute anything new and start at EOF.
    private func bootstrap() {
        let cutoff = store.eventsCutoff
        let ancient = Date().addingTimeInterval(-366 * 86400)
        let plan = CodexHistory.backfillPlan(
            watermark: store.codexWatermark(), cutoff: cutoff, ancient: ancient)
        backfillFrom = plan.from
        backfilling = plan.active
        duplicateGate.reset()
        backfillBatch = [:]
        backfillSeen = []
        var read = 0
        for url in jsonlFiles() {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if (values?.contentModificationDate ?? .distantPast) < backfillFrom {
                offsets[url.path] = UInt64(values?.fileSize ?? 0)
            } else {
                read += 1
            }
        }
        FileLog.log("Codex watcher started; reading \(read) files (events since \(UsageStore.dayKey(cutoff)), backfill from \(UsageStore.dayKey(backfillFrom)))")
    }

    private func finishBackfillIfNeeded() {
        guard backfilling else { return }
        store.mergeCodexHistorical(backfillBatch, coverThrough: store.eventsCutoff)
        backfillBatch = [:]
        backfillSeen = []
        backfilling = false
    }

    private func jsonlFiles() -> [URL] {
        var urls: [URL] = []
        for root in roots {
            guard let en = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" { urls.append(url) }
        }
        return urls
    }

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
        for url in jsonlFiles() {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = UInt64(values?.fileSize ?? 0)
            let offset = offsets[url.path] ?? 0
            if size > offset { readNew(url, from: offset) }
            else if size < offset { offsets[url.path] = size }
            if (values?.contentModificationDate ?? .distantPast) > hotCutoff { active.insert(url.path) }
        }
        activePaths = active
    }

    private func checkFile(_ url: URL) {
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(UInt64.init) ?? 0
        let offset = offsets[url.path] ?? 0
        if size > offset { readNew(url, from: offset) }
        else if size < offset { offsets[url.path] = size }
    }

    /// Per-file values computed once per read, not once per line.
    private final class FileContext {
        let path: String
        let fallbackSession: String   // file-name stem (used when session_meta was never seen)
        let sessionKey: String        // path-independent dedup stem
        let liveCutoff: Date          // one store.eventsCutoff per read, not per line
        private let url: URL
        private var mtimeResolved = false
        private var mtimeValue: Date?
        /// Consulted lazily, only for a line with no timestamp and no earlier one in the file.
        func mtime() -> Date {
            if !mtimeResolved {
                mtimeResolved = true
                mtimeValue = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            return mtimeValue ?? Date(timeIntervalSince1970: 0)
        }
        init(_ url: URL, liveCutoff: Date) {
            self.url = url
            path = url.path
            fallbackSession = url.deletingPathExtension().lastPathComponent
            sessionKey = CodexHistory.sessionKey(fileName: url.lastPathComponent)
            self.liveCutoff = liveCutoff
        }
    }

    /// Chunked (2 MB) read; lines are parsed straight out of the read buffer, a
    /// partial trailing record (Codex can leave one at EOF mid-turn) is carried
    /// across chunks and, at EOF, re-read next poll (offset only advances past
    /// complete lines). One autorelease pool per file.
    private func readNew(_ url: URL, from offset: UInt64) {
        autoreleasepool {
            let ctx = FileContext(url, liveCutoff: store.eventsCutoff)
            let end = TranscriptIO.forEachLine(path: ctx.path, from: offset) { raw, _ in
                parse(raw, ctx)
            }
            offsets[ctx.path] = end
        }
    }

    // Launch replay (and limits-refresh replays) batch their store hand-off; live
    // tailing stays per-line. See UsageStore.ingest(batch:).
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

    /// Runs `work` (a bootstrap + scan pass) with batched store hand-off, flushing at the end.
    private func bulk(_ work: () -> Void) {
        bulkReplay = true
        work()
        flushReplayBatch()
        bulkReplay = false
    }

    private struct Line: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
            let id: String?
            let cwd: String?
            let model: String?          // present on turn_context records
            let info: Info?
            let rate_limits: RateLimits?
        }
        struct Info: Decodable {
            let last_token_usage: TokenUsage?
            let total_token_usage: TokenUsage?
        }
        struct TokenUsage: Decodable {
            let input_tokens: Int?
            let cached_input_tokens: Int?
            let output_tokens: Int?
            let reasoning_output_tokens: Int?
        }
        struct RateLimits: Decodable {
            let primary: RateLimit?
            let secondary: RateLimit?
        }
        struct RateLimit: Decodable {
            let used_percent: Double?
            let window_minutes: Int?
            let resets_at: Double?
        }
    }

    private let decoder = JSONDecoder()

    private func parse(_ raw: UnsafeRawBufferPointer, _ ctx: FileContext) {
        let hasTokenCount = TranscriptIO.contains(raw, Self.tokenCountMarker)
        let hasSessionMeta = TranscriptIO.contains(raw, Self.sessionMetaMarker)
        let hasTurnContext = TranscriptIO.contains(raw, Self.turnContextMarker)
        guard hasTokenCount || hasSessionMeta || hasTurnContext,
              let line = try? decoder.decode(Line.self, from: TranscriptIO.data(raw)) else { return }
        let file = ctx
        if hasSessionMeta, line.type == "session_meta", let payload = line.payload,
           let id = payload.id {
            sessionMetadata[file.path] = (
                id: id,
                project: payload.cwd.map { URL(fileURLWithPath: $0).lastPathComponent })
            return
        }
        // turn_context names the model for the turn's subsequent token_count
        // records (which don't carry it). Remember it per file.
        if hasTurnContext, line.type == "turn_context",
           let model = line.payload?.model, !model.isEmpty {
            latestModel[file.path] = model
            return
        }
        guard line.type == "event_msg", line.payload?.type == "token_count" else { return }
        // Missing/unparseable timestamp: carry the previous line's forward, else the
        // file's mtime (same rule as the Claude parser) — never the wall clock.
        let parsedTimestamp = line.timestamp.flatMap {
            FastTimestamp.parse($0) ?? Self.isoFrac.date(from: $0) ?? Self.iso.date(from: $0)
        }
        if let parsedTimestamp { lastTimestamp[file.path] = parsedTimestamp }
        let timestamp = parsedTimestamp ?? lastTimestamp[file.path] ?? ctx.mtime()
        let liveCutoff = ctx.liveCutoff
        if let limits = line.payload?.rate_limits {
            self.limits.observe(
                primary: window(limits.primary), secondary: window(limits.secondary), at: timestamp)
        }
        guard let usage = line.payload?.info?.last_token_usage else { return }
        let total = line.payload?.info?.total_token_usage
        let signature = total.map {
            CodexHistory.Total(input: $0.input_tokens ?? 0, cached: $0.cached_input_tokens ?? 0,
                               output: $0.output_tokens ?? 0, reasoning: $0.reasoning_output_tokens ?? 0)
        }
        // Codex re-emits identical token_count records; count each total once.
        guard duplicateGate.shouldCount(stream: file.path, total: signature) else { return }
        let cached = usage.cached_input_tokens ?? 0
        // cached_input_tokens is a subset of input_tokens: store fresh input only,
        // so input + cacheRead equals the raw input exactly once.
        let input = CodexHistory.freshInput(input: usage.input_tokens ?? 0, cached: cached)
        let output = usage.output_tokens ?? 0
        guard input > 0 || output > 0 || cached > 0 else { return }
        let event = UsageEvent(
            timestamp: timestamp,
            provider: .codex,
            source: .codexTranscript,
            model: latestModel[file.path] ?? "Codex",
            sessionId: sessionMetadata[file.path]?.id ?? file.fallbackSession,
            projectName: sessionMetadata[file.path]?.project,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cached,
            cacheCreationTokens: 0,
            reasoningTokens: usage.reasoning_output_tokens ?? 0)
        // File-name stem, not session_meta: tailing from EOF never sees the meta
        // line, and a replay must produce the same key as a tail.
        let sid = file.sessionKey
        let key = CodexHistory.dedupKey(
            sessionId: sid, timestamp: line.timestamp ?? "",
            totalInput: signature?.input ?? usage.input_tokens ?? 0,
            totalOutput: signature?.output ?? output)
        // The persisted Codex watermark is authoritative (see HistoryFold.route): an
        // event below it is already in history even when it sits above the cutoff.
        switch HistoryFold.route(timestamp, cutoff: liveCutoff, backfilling: backfilling,
                                 backfillFrom: backfillFrom, watermark: backfillFrom) {
        case .live:
            if bulkReplay {
                replayBatch.append((event, key))
                if replayBatch.count >= Self.replayBatchSize { flushReplayBatch() }
            } else {
                store.addTranscriptEvent(event, dedupKey: key)
            }
        case .backfill:
            if backfillSeen.insert(key).inserted {
                backfillBatch[UsageStore.dayKey(timestamp), default: DayAgg()].add(event)
            }
        case .drop:
            break
        }
    }

    private func window(_ raw: Line.RateLimit?) -> ObservedWindow? {
        guard let raw, let percent = raw.used_percent else { return nil }
        return ObservedWindow(
            percent: percent,
            minutes: raw.window_minutes,
            resetsAt: raw.resets_at.map { Date(timeIntervalSince1970: $0) })
    }
}
