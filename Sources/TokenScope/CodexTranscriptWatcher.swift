import Foundation

/// Reads Codex's local rollout logs without retaining prompts, replies, tool
/// payloads, or any other session content. Codex appends token_count events to
/// ~/.codex/sessions/YYYY/MM/DD/*.jsonl; their last_token_usage field is the
/// per-turn usage record that belongs in TokenScope's local activity stream.
final class CodexTranscriptWatcher {
    private let store: UsageStore
    private let limits: OpenAILimitsManager
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
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
    private var tick = 0
    private var backfillFrom = Date.distantPast
    private var backfilling = false
    private var backfillBatch: [String: DayAgg] = [:]
    private var backfillSeen = Set<String>()

    private static let fullScanEveryTicks = 10
    private static let hotWindow: TimeInterval = 180
    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let sessionMetaMarker = Data("\"session_meta\"".utf8)
    private static let turnContextMarker = Data("\"turn_context\"".utf8)
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
        // Only run the file-scanning loop when local is the selected Codex source;
        // otherwise register the observers and stay idle (no timer firing at all).
        if enabled { startScanning() }
        monitorObserver = NotificationCenter.default.addObserver(
            forName: OpenAILimitsManager.monitoringChanged, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.monitoringChanged() }
        }
        refreshObserver = NotificationCenter.default.addObserver(
            forName: OpenAILimitsManager.refreshRequested, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                guard let self, self.enabled else { return }
                // A normal scan only tails new bytes. Refresh intentionally
                // replays the current window so the latest saved quota record
                // is re-observed even if Codex has been idle. Usage events are
                // keyed by file byte offset, so this cannot double-count them.
                self.offsets = [:]
                self.activePaths = []
                self.sessionMetadata = [:]
                self.latestModel = [:]
                self.tick = 0
                self.bootstrap()
                self.fullScan()
                self.finishBackfillIfNeeded()
                FileLog.log("Codex limits refreshed from local sessions")
            }
        }
    }

    private var enabled: Bool { limits.monitoringEnabled }

    private func startScanning() {
        guard timer == nil else { return }
        queue.async { [weak self] in
            self?.bootstrap()
            self?.scan()
            self?.finishBackfillIfNeeded()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 1)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    private func stopScanning() {
        timer?.cancel()
        timer = nil
    }

    private func monitoringChanged() {
        guard enabled else {
            stopScanning()
            FileLog.log("Codex transcript watcher stopped (not the selected source)")
            return
        }
        if timer == nil {
            startScanning()
        } else {
            offsets = [:]
            activePaths = []
            tick = 0
            bootstrap()
            scan()
            finishBackfillIfNeeded()
        }
        FileLog.log("Codex transcript watcher resumed")
    }

    /// Replays the live window and, once per persisted gap, folds up to a year
    /// of older local Codex logs into the same permanent day history Claude uses.
    /// Files older than the gap cannot contribute anything new and start at EOF.
    private func bootstrap() {
        let cutoff = store.eventsCutoff
        let ancient = Date().addingTimeInterval(-366 * 86400)
        backfillFrom = max(store.codexHistoryCompleteThrough, ancient)
        backfilling = backfillFrom < cutoff
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
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl" { urls.append(url) }
        return urls
    }

    private func scan() {
        guard enabled else { return }
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

    private func readNew(_ url: URL, from offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }

        var consumed = 0
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            let line = data[start..<newline]
            let lineOffset = offset + UInt64(start - data.startIndex)
            consumed = newline - data.startIndex + 1
            start = newline + 1
            if !line.isEmpty { parse(Data(line), file: url, offset: lineOffset) }
        }
        // Like Claude Code, Codex can leave a partial JSON record at EOF while
        // streaming a turn. Leave it to be retried on the next poll.
        offsets[url.path] = offset + UInt64(consumed)
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

    private func parse(_ data: Data, file: URL, offset: UInt64) {
        let hasTokenCount = data.range(of: Self.tokenCountMarker) != nil
        let hasSessionMeta = data.range(of: Self.sessionMetaMarker) != nil
        let hasTurnContext = data.range(of: Self.turnContextMarker) != nil
        guard hasTokenCount || hasSessionMeta || hasTurnContext,
              let line = try? JSONDecoder().decode(Line.self, from: data) else { return }
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
        let timestamp = line.timestamp.flatMap { Self.isoFrac.date(from: $0) ?? Self.iso.date(from: $0) } ?? Date()
        let liveCutoff = store.eventsCutoff
        if let limits = line.payload?.rate_limits {
            self.limits.observe(
                primary: window(limits.primary), secondary: window(limits.secondary), at: timestamp)
        }
        guard let usage = line.payload?.info?.last_token_usage else { return }
        let input = usage.input_tokens ?? 0
        let output = usage.output_tokens ?? 0
        guard input > 0 || output > 0 else { return }
        let event = UsageEvent(
            timestamp: timestamp,
            provider: .codex,
            source: .codexTranscript,
            model: latestModel[file.path] ?? "Codex",
            sessionId: sessionMetadata[file.path]?.id ?? file.deletingPathExtension().lastPathComponent,
            projectName: sessionMetadata[file.path]?.project,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: usage.cached_input_tokens ?? 0,
            cacheCreationTokens: 0,
            reasoningTokens: usage.reasoning_output_tokens ?? 0)
        let key = "codex:\(file.path):\(offset)"
        if timestamp >= liveCutoff {
            store.addTranscriptEvent(event, dedupKey: key)
        } else if backfilling, timestamp >= backfillFrom, backfillSeen.insert(key).inserted {
            backfillBatch[UsageStore.dayKey(timestamp), default: DayAgg()].add(event)
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
