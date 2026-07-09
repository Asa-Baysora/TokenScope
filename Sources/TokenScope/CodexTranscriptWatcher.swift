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
    private var offsets: [String: UInt64] = [:]
    private var activePaths: Set<String> = []
    private var sessionMetadata: [String: (id: String, project: String?)] = [:]
    private var tick = 0

    private static let fullScanEveryTicks = 10
    private static let hotWindow: TimeInterval = 180
    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let sessionMetaMarker = Data("\"session_meta\"".utf8)
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
        queue.async { [weak self] in
            self?.bootstrap()
            self?.scan()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 1)
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        self.timer = timer
        monitorObserver = NotificationCenter.default.addObserver(
            forName: OpenAILimitsManager.monitoringChanged, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.monitoringChanged() }
        }
    }

    private var enabled: Bool { limits.monitoringEnabled }

    private func monitoringChanged() {
        guard enabled else {
            FileLog.log("Codex transcript watcher paused")
            return
        }
        offsets = [:]
        activePaths = []
        tick = 0
        bootstrap()
        scan()
        FileLog.log("Codex transcript watcher resumed")
    }

    /// A file whose newest modification predates the live window cannot contain
    /// an event TokenScope needs. Skip it at EOF rather than replaying years of
    /// local history. Events that later age out are folded into DayAgg normally.
    private func bootstrap() {
        let cutoff = store.eventsCutoff
        var read = 0
        for url in jsonlFiles() {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if (values?.contentModificationDate ?? .distantPast) < cutoff {
                offsets[url.path] = UInt64(values?.fileSize ?? 0)
            } else {
                read += 1
            }
        }
        FileLog.log("Codex watcher started; reading \(read) files since \(UsageStore.dayKey(cutoff))")
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
        guard hasTokenCount || hasSessionMeta,
              let line = try? JSONDecoder().decode(Line.self, from: data) else { return }
        if hasSessionMeta, line.type == "session_meta", let payload = line.payload,
           let id = payload.id {
            sessionMetadata[file.path] = (
                id: id,
                project: payload.cwd.map { URL(fileURLWithPath: $0).lastPathComponent })
            return
        }
        guard line.type == "event_msg", line.payload?.type == "token_count" else { return }
        let timestamp = line.timestamp.flatMap { Self.isoFrac.date(from: $0) ?? Self.iso.date(from: $0) } ?? Date()
        guard timestamp >= store.eventsCutoff else { return }
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
            model: "Codex",
            sessionId: sessionMetadata[file.path]?.id ?? file.deletingPathExtension().lastPathComponent,
            projectName: sessionMetadata[file.path]?.project,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: usage.cached_input_tokens ?? 0,
            cacheCreationTokens: 0,
            reasoningTokens: usage.reasoning_output_tokens ?? 0)
        store.addTranscriptEvent(event, dedupKey: "codex:\(file.path):\(offset)")
    }

    private func window(_ raw: Line.RateLimit?) -> ObservedWindow? {
        guard let raw, let percent = raw.used_percent else { return nil }
        return ObservedWindow(
            percent: percent,
            minutes: raw.window_minutes,
            resetsAt: raw.resets_at.map { Date(timeIntervalSince1970: $0) })
    }
}
