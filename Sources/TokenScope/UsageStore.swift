import Foundation
import Combine

final class UsageStore: ObservableObject {
    static let retentionDays = 31   // a hair more than the longest display window

    @Published private(set) var events: [UsageEvent] = []   // oldest → newest (sorted after replay)
    @Published private(set) var liveCalls: [LiveCall] = []
    @Published var proxyStatus = "proxy starting…"
    @Published var proxyHealthy = false
    @Published var loadedModels: [LoadedModel] = []
    @Published private(set) var runtimeHealth: [UsageOrigin: RuntimeHealth] = [
        .ollama: RuntimeHealth(provider: .ollama, coverage: "routed clients"),
        .lmStudio: RuntimeHealth(provider: .lmStudio, coverage: "completed LLM generations"),
    ]
    @Published private(set) var history: [String: DayAgg] = [:]   // frozen days, keyed yyyy-MM-dd
    @Published private(set) var sessionNames: [String: String] = [:]   // sessionId → human title
    @Published private(set) var now = Date()

    /// All usage before this date is fully captured in `history`.
    private(set) var historyCompleteThrough = Date(timeIntervalSince1970: 0)
    /// Codex logs are independent from Claude Code transcripts, so their
    /// one-time historical replay needs its own persisted watermark.
    private(set) var codexHistoryCompleteThrough = Date(timeIntervalSince1970: 0)

    let proxyPort: UInt16
    let upstreamPort: UInt16

    private var eventIDByDedupKey: [String: UUID] = [:]
    private var timer: Timer?
    private let ioQueue = DispatchQueue(label: "tokenscope.store-io", qos: .utility)

    private static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TokenScope")
    private static let proxyEventsURL = supportDir.appendingPathComponent("proxy-events.jsonl")
    private static let localEventsURL = supportDir.appendingPathComponent("usage-events-v2.jsonl")
    private static let historyURL = supportDir.appendingPathComponent("daily-history.json")

    private struct HistoryFile: Codable {
        var completeThrough: Double
        var codexCompleteThrough: Double?
        var days: [String: DayAgg]
    }

    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayKey(_ d: Date) -> String { dayKeyFmt.string(from: d) }

    /// Events-window boundary, aligned to whole days so a day is either entirely
    /// live (in `events`) or entirely frozen (in `history`) — never split.
    var eventsCutoff: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: -Self.retentionDays, to: cal.startOfDay(for: Date()))
            ?? Date().addingTimeInterval(-Double(Self.retentionDays) * 86400)
    }

    /// Proxy observations have no on-disk source of truth (transcripts do), so they
    /// are persisted here to survive restarts within the retention window.
    private struct PersistedProxyEvent: Codable {
        let ts: Double
        let model: String
        let input: Int
        let output: Int
        let cacheR: Int
        let cacheC: Int
    }

    private struct PersistedLocalEvent: Codable {
        let schema: Int
        let key: String
        let event: UsageEvent
    }

    init() {
        let d = UserDefaults.standard
        let p = d.integer(forKey: "ProxyPort")
        let u = d.integer(forKey: "OllamaPort")
        proxyPort = p > 0 ? UInt16(p) : 11435
        upstreamPort = u > 0 ? UInt16(u) : 11434
        loadPersistedLocalEvents()
        loadHistory()
    }

    /// The clock timer only runs while calls are in flight — it drives the live
    /// `↓` counter and prunes stale calls. When idle there's nothing to animate,
    /// so we stop it entirely rather than waking the app (and recomputing the
    /// menu-bar label) every couple of seconds for nothing.
    private func startTickingIfNeeded() {
        guard timer == nil, !liveCalls.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
            self.pruneStaleLiveCalls()
            if self.liveCalls.isEmpty {
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    // MARK: - Ingest

    func updateRuntimeHealth(_ provider: UsageOrigin, _ update: @escaping (inout RuntimeHealth) -> Void) {
        DispatchQueue.main.async {
            var health = self.runtimeHealth[provider] ?? RuntimeHealth(provider: provider)
            update(&health)
            self.runtimeHealth[provider] = health
        }
    }

    func setLoadedModels(_ models: [LoadedModel], for provider: UsageOrigin) {
        DispatchQueue.main.async {
            let merged = self.loadedModels.filter { $0.provider != provider } + models
            if self.loadedModels != merged { self.loadedModels = merged }
        }
    }

    func addTranscriptEvent(_ e: UsageEvent, dedupKey: String) {
        ingest(e, dedupKey: dedupKey, persist: false)
    }

    /// Adds an event whose provider source cannot be replayed later (proxy and
    /// LM Studio log observations). These share one versioned journal.
    func addLocalEvent(_ e: UsageEvent, dedupKey: String) {
        ingest(e, dedupKey: dedupKey, persist: true)
    }

    private func ingest(_ incoming: UsageEvent, dedupKey: String, persist: Bool) {
        DispatchQueue.main.async {
            var event = incoming
            if let existingID = self.eventIDByDedupKey[dedupKey],
               let index = self.events.firstIndex(where: { $0.id == existingID }) {
                let existing = self.events[index]
                let preferred = EventReconciler.preferred(existing, incoming)
                guard preferred.id != existing.id else { return }
                event.shadowed = existing.shadowed
                self.events[index] = event
                self.eventIDByDedupKey[dedupKey] = event.id
            } else {
                self.appendEvent(event)
                self.eventIDByDedupKey[dedupKey] = event.id
            }
            self.reconcileDuplicates(around: event)
            self.trim()
            if persist { self.persistLocalEvent(event, key: dedupKey) }
            // Intentionally not logged per-event: at thousands of events/replay this
            // dominated both the log size and the write overhead. Lifecycle summaries
            // (replay complete, proxy, limits, status) are logged instead.
        }
    }

    private func reconcileDuplicates(around event: UsageEvent) {
        guard event.provider == .ollama else { return }
        if event.source == .proxy || event.source == .transcript {
            let counterpart: EventSource = event.source == .proxy ? .transcript : .proxy
            for i in events.indices.reversed().prefix(80) {
                let candidate = events[i]
                guard candidate.id != event.id, candidate.source == counterpart,
                      !candidate.shadowed,
                      abs(candidate.timestamp.timeIntervalSince(event.timestamp)) < 90,
                      abs(candidate.outputTokens - event.outputTokens) <= 2 else { continue }
                // Only the TRANSCRIPT side of the pair must carry exact usage (it
                // always does, by construction). The proxy side may be estimated
                // (stream ended without a usage record) or unknown (migrated from
                // the legacy journal) — its counts came from the same bytes, so the
                // ±2-token match is still meaningful. Requiring .exact on BOTH
                // sides left every non-exact proxy copy permanently double-counted.
                let transcript = event.source == .transcript ? event : candidate
                guard transcript.tokenAccuracy == .exact else { continue }
                if candidate.source == .proxy {
                    events[i].shadowed = true
                } else if let eventIndex = events.firstIndex(where: { $0.id == event.id }) {
                    events[eventIndex].shadowed = true
                }
                break
            }
        }

        guard event.source == .proxy || event.source == .ollamaDesktop else { return }
        for i in events.indices.reversed().prefix(80) {
            let candidate = events[i]
            guard candidate.id != event.id, !candidate.shadowed,
                  EventReconciler.desktopAndProxyOverlap(candidate, event) else { continue }
            if candidate.source == .ollamaDesktop {
                events[i].shadowed = true
            } else if let eventIndex = events.firstIndex(where: { $0.id == event.id }) {
                events[eventIndex].shadowed = true
            }
            break
        }
    }

    func upsertLiveCall(_ st: ResponseScanner.CallState) {
        DispatchQueue.main.async {
            let call = LiveCall(
                id: st.id,
                provider: .ollama,
                model: st.model,
                inputTokens: st.input + st.cacheRead,
                outputTokens: st.displayOutput,
                outputAccuracy: st.sawUsage ? .exact : (st.displayOutput > 0 ? .estimated : .unknown),
                operation: st.operation,
                startedAt: st.startedAt,
                lastUpdate: Date())
            if let i = self.liveCalls.firstIndex(where: { $0.id == st.id }) {
                self.liveCalls[i] = call
            } else {
                self.liveCalls.append(call)
            }
            self.startTickingIfNeeded()
        }
    }

    func finishLiveCall(_ st: ResponseScanner.CallState) {
        DispatchQueue.main.async {
            self.liveCalls.removeAll { $0.id == st.id }
            guard st.displayOutput > 0 || st.input > 0 || st.status == .failed else { return }
            let e = UsageEvent(
                timestamp: Date(),
                startedAt: st.startedAt,
                provider: .ollama,
                source: .proxy,
                model: st.model,
                sessionId: "ollama-direct",
                projectName: nil,
                inputTokens: st.input,
                outputTokens: st.displayOutput,
                cacheReadTokens: st.cacheRead,
                cacheCreationTokens: st.cacheCreate,
                reasoningTokens: st.reasoning,
                tokenAccuracy: st.sawUsage ? .exact : (st.displayOutput > 0 ? .estimated : .unknown),
                operation: st.operation,
                status: st.status,
                executionLocation: st.executionLocation,
                endpoint: st.endpoint,
                requestId: st.requestId,
                httpStatus: st.httpStatus,
                finishReason: st.finishReason,
                errorCategory: st.errorCategory,
                durationSeconds: st.durationSeconds,
                loadDurationSeconds: st.loadDurationSeconds,
                promptEvalDurationSeconds: st.promptEvalDurationSeconds,
                evalDurationSeconds: st.evalDurationSeconds,
                timeToFirstTokenSeconds: st.timeToFirstTokenSeconds,
                tokensPerSecond: st.tokensPerSecond)
            self.ingest(e, dedupKey: "proxy:\(st.id.uuidString)", persist: true)
            FileLog.log("proxy \(e.model) in=\(e.inputTokens) out=\(e.outputTokens) accuracy=\(e.tokenAccuracy.rawValue)")
        }
    }

    /// Session titles from transcripts: Claude Code summary lines are
    /// authoritative and overwrite; a first-user-message fallback only fills gaps.
    func setSessionName(_ id: String, _ name: String, fallback: Bool = false) {
        DispatchQueue.main.async {
            if fallback {
                if self.sessionNames[id] == nil { self.sessionNames[id] = name }
            } else if self.sessionNames[id] != name {
                self.sessionNames[id] = name
            }
        }
    }

    /// Backfilled day totals from transcripts older than the events window,
    /// produced by the watcher's one-time-per-gap historical scan.
    func mergeHistorical(_ batch: [String: DayAgg]) {
        guard !batch.isEmpty else { return }
        DispatchQueue.main.async {
            for (k, v) in batch {
                var d = self.history[k] ?? DayAgg()
                d.merge(v)
                self.history[k] = d
            }
            FileLog.log("backfilled \(batch.count) days into history")
        }
    }

    /// Codex uses its own watermark because the source log lives outside the
    /// Claude transcript tree. Both sources still merge into one day aggregate.
    func mergeCodexHistorical(_ batch: [String: DayAgg], coverThrough: Date) {
        DispatchQueue.main.async {
            for (key, value) in batch {
                var day = self.history[key] ?? DayAgg()
                day.merge(value)
                self.history[key] = day
            }
            self.codexHistoryCompleteThrough = max(self.codexHistoryCompleteThrough, coverThrough)
            self.saveHistory()
            FileLog.log("Codex history backfill: \(batch.count) days through \(Self.dayKey(coverThrough))")
        }
    }

    /// Called once the transcript watcher has finished its initial replay: orders the
    /// bulk-loaded events, shadows persisted proxy events that match a transcript
    /// record of the same call (the live matching above only covers runtime arrivals),
    /// and records how far back history is now complete.
    func replayFinished(coverThrough: Date) {
        DispatchQueue.main.async {
            self.events.sort { $0.timestamp < $1.timestamp }
            var byOut: [Int: [Date]] = [:]
            for e in self.events where e.source == .transcript && e.provider == .ollama
                && e.tokenAccuracy == .exact {
                byOut[e.outputTokens, default: []].append(e.timestamp)
            }
            var shadowed = 0
            // Proxy-side accuracy is deliberately NOT gated here: estimated and
            // legacy-migrated (.unknown) proxy events are exactly the copies that
            // need shadowing against their exact transcript twins. The transcript
            // index above already requires .exact on the authoritative side.
            for i in self.events.indices where self.events[i].source == .proxy
                && !self.events[i].shadowed {
                let e = self.events[i]
                search: for delta in -2...2 {
                    if let dates = byOut[e.outputTokens + delta],
                       dates.contains(where: { abs($0.timeIntervalSince(e.timestamp)) < 120 }) {
                        self.events[i].shadowed = true
                        shadowed += 1
                        break search
                    }
                }
            }
            for i in self.events.indices where self.events[i].source == .ollamaDesktop
                && !self.events[i].shadowed {
                let desktop = self.events[i]
                if self.events.contains(where: {
                    $0.source == .proxy && !$0.shadowed
                        && EventReconciler.desktopAndProxyOverlap(desktop, $0)
                }) {
                    self.events[i].shadowed = true
                    shadowed += 1
                }
            }
            self.historyCompleteThrough = max(self.historyCompleteThrough, coverThrough)
            self.saveHistory()
            FileLog.log("replay complete: \(self.events.count) events in window, \(shadowed) proxy events shadowed, history through \(Self.dayKey(self.historyCompleteThrough))")
        }
    }

    private func pruneStaleLiveCalls() {
        let cutoff = Date().addingTimeInterval(-180)
        liveCalls.removeAll { $0.lastUpdate < cutoff }
    }

    /// Claude and Codex replay independently at launch. Keep the shared event
    /// window chronological even if their directory enumerations interleave;
    /// trim(), recent calls, and time-based reconciliation all rely on it.
    private func appendEvent(_ event: UsageEvent) {
        guard let last = events.last, last.timestamp > event.timestamp else {
            events.append(event)
            return
        }
        var low = 0
        var high = events.count
        while low < high {
            let mid = (low + high) / 2
            if events[mid].timestamp <= event.timestamp { low = mid + 1 } else { high = mid }
        }
        events.insert(event, at: low)
    }

    private func trim() {
        let cutoff = eventsCutoff
        if let first = events.first, first.timestamp < cutoff {
            let removed = events.filter { $0.timestamp < cutoff }
            events.removeAll { $0.timestamp < cutoff }
            fold(removed, through: cutoff)
        }
        if events.count > 60_000 {
            let removed = Array(events.prefix(events.count - 60_000))
            events.removeFirst(events.count - 60_000)
            fold(removed, through: removed.last?.timestamp ?? cutoff)
        }
    }

    /// Events leaving the live window are folded into the persistent daily history
    /// so the heatmap keeps them after the raw events (and transcripts) are gone.
    private func fold(_ removed: [UsageEvent], through: Date) {
        guard !removed.isEmpty else { return }
        for e in removed where !e.shadowed {
            let k = Self.dayKey(e.timestamp)
            var d = history[k] ?? DayAgg()
            d.add(e)
            history[k] = d
        }
        historyCompleteThrough = max(historyCompleteThrough, through)
        saveHistory()
        FileLog.log("folded \(removed.count) aged-out events into daily history")
    }

    // MARK: - Persistence (non-replayable local events; transcripts replay from disk)

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              let f = try? JSONDecoder().decode(HistoryFile.self, from: data) else { return }
        history = f.days
        historyCompleteThrough = Date(timeIntervalSince1970: f.completeThrough)
        codexHistoryCompleteThrough = f.codexCompleteThrough.map(Date.init(timeIntervalSince1970:))
            ?? Date(timeIntervalSince1970: 0)
        FileLog.log("loaded daily history: \(f.days.count) days, Claude through \(Self.dayKey(historyCompleteThrough)), Codex through \(Self.dayKey(codexHistoryCompleteThrough))")
    }

    private func saveHistory() {
        let f = HistoryFile(
            completeThrough: historyCompleteThrough.timeIntervalSince1970,
            codexCompleteThrough: codexHistoryCompleteThrough.timeIntervalSince1970,
            days: history)
        guard let data = try? JSONEncoder().encode(f) else { return }
        ioQueue.async {
            try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            try? data.write(to: Self.historyURL)
        }
    }

    private func loadPersistedLocalEvents() {
        if let data = try? Data(contentsOf: Self.localEventsURL), !data.isEmpty {
            loadV2Events(data)
            return
        }
        migrateLegacyProxyEvents()
    }

    private func loadV2Events(_ data: Data) {
        let cutoff = eventsCutoff
        let decoder = JSONDecoder()
        var bestByKey: [String: UsageEvent] = [:]
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<nl]
            start = nl < data.endIndex ? data.index(after: nl) : data.endIndex
            guard !line.isEmpty,
                  let record = try? decoder.decode(PersistedLocalEvent.self, from: line),
                  record.schema == 2, record.event.timestamp > cutoff else { continue }
            if let existing = bestByKey[record.key] {
                bestByKey[record.key] = EventReconciler.preferred(existing, record.event)
            } else {
                bestByKey[record.key] = record.event
            }
        }
        events = bestByKey.values.sorted { $0.timestamp < $1.timestamp }
        eventIDByDedupKey = Dictionary(uniqueKeysWithValues: bestByKey.map { ($0.key, $0.value.id) })
        rewriteLocalEventJournal(bestByKey)
        FileLog.log("loaded \(events.count) persisted local inference events")
    }

    private func migrateLegacyProxyEvents() {
        guard let data = try? Data(contentsOf: Self.proxyEventsURL), !data.isEmpty else { return }
        let cutoff = eventsCutoff
        let decoder = JSONDecoder()
        var migrated: [String: UsageEvent] = [:]
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<nl]
            start = nl < data.endIndex ? data.index(after: nl) : data.endIndex
            guard !line.isEmpty, let pe = try? decoder.decode(PersistedProxyEvent.self, from: line) else { continue }
            let timestamp = Date(timeIntervalSince1970: pe.ts)
            guard timestamp > cutoff else { continue }
            let event = UsageEvent(
                timestamp: timestamp, provider: .ollama, source: .proxy,
                model: pe.model, sessionId: "ollama-direct", projectName: nil,
                inputTokens: pe.input, outputTokens: pe.output,
                cacheReadTokens: pe.cacheR, cacheCreationTokens: pe.cacheC,
                reasoningTokens: 0, tokenAccuracy: .unknown,
                operation: .unknown, status: .succeeded,
                executionLocation: .unknown)
            let key = "legacy-proxy:\(pe.ts):\(pe.model):\(pe.input):\(pe.output)"
            migrated[key] = event
        }
        events = migrated.values.sorted { $0.timestamp < $1.timestamp }
        eventIDByDedupKey = Dictionary(uniqueKeysWithValues: migrated.map { ($0.key, $0.value.id) })
        rewriteLocalEventJournal(migrated)
        FileLog.log("migrated \(migrated.count) legacy proxy events to schema v2")
    }

    private func persistLocalEvent(_ event: UsageEvent, key: String) {
        let record = PersistedLocalEvent(schema: 2, key: key, event: event)
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(0x0A)
        ioQueue.async {
            try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: Self.localEventsURL) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
                try? h.close()
            } else {
                try? line.write(to: Self.localEventsURL)
            }
        }
    }

    private func rewriteLocalEventJournal(_ records: [String: UsageEvent]) {
        let encoder = JSONEncoder()
        var compacted = Data()
        for (key, event) in records.sorted(by: { $0.value.timestamp < $1.value.timestamp }) {
            guard var line = try? encoder.encode(PersistedLocalEvent(schema: 2, key: key, event: event)) else { continue }
            line.append(0x0A)
            compacted.append(line)
        }
        ioQueue.async {
            try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            try? compacted.write(to: Self.localEventsURL, options: .atomic)
        }
    }

    // MARK: - Aggregates

    func events(in period: StatsPeriod) -> [UsageEvent] {
        let cal = Calendar.current
        if period == .today {
            return events.filter { cal.isDateInToday($0.timestamp) && !$0.shadowed }
        }
        let start = cal.date(byAdding: .day, value: -(period.days - 1), to: cal.startOfDay(for: Date())) ?? Date()
        return events.filter { $0.timestamp >= start && !$0.shadowed }
    }

    func totals(for provider: UsageOrigin?, in period: StatsPeriod) -> Totals {
        var t = Totals()
        for e in events(in: period) where provider == nil || e.provider == provider {
            t.add(e)
        }
        return t
    }

    func modelTotals(for provider: UsageOrigin, in period: StatsPeriod) -> [(model: String, totals: Totals)] {
        var by: [String: Totals] = [:]
        for e in events(in: period) where e.provider == provider {
            by[e.model, default: Totals()].add(e)
        }
        return by
            .sorted { ($0.value.input + $0.value.output) > ($1.value.input + $1.value.output) }
            .map { (model: $0.key, totals: $0.value) }
    }

    func sessions(in period: StatsPeriod) -> [SessionAgg] {
        var by: [String: SessionAgg] = [:]
        for e in events(in: period) {
            let sessionID = e.sessionId ?? "activity"
            let key = "\(e.provider.rawValue):\(sessionID)"
            var agg = by[key] ?? SessionAgg(
                id: key,
                title: sessionTitle(for: sessionID, sample: e),
                project: e.source == .proxy ? nil : e.projectName,
                provider: e.provider)
            agg.totals.add(e)
            agg.lastActivity = max(agg.lastActivity, e.timestamp)
            agg.models.insert(e.model)
            by[key] = agg
        }
        return by.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Chart tokens for one event. Cache reads/writes are context actually
    /// processed per call (and usually dwarf fresh input), so the chart counts
    /// them by default; the Settings toggle drops them for a billing-ish view.
    private func chartTokens(_ e: UsageEvent, includeCache: Bool) -> Int {
        e.inputTokens + e.outputTokens
            + (includeCache ? e.cacheReadTokens + e.cacheCreationTokens : 0)
    }

    func dailyTotals(in period: StatsPeriod, includeCache: Bool) -> [DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var by: [Date: DayStat] = [:]
        for e in events(in: period) {
            let day = cal.startOfDay(for: e.timestamp)
            var stat = by[day] ?? DayStat(day: day)
            let tokens = chartTokens(e, includeCache: includeCache)
            switch e.provider {
            case .claudeCode: stat.claude += tokens
            case .codex: stat.codex += tokens
            case .ollama: stat.ollama += tokens
            case .lmStudio: stat.lmStudio += tokens
            }
            by[day] = stat
        }
        return (0..<period.days).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return by[day] ?? DayStat(day: day)
        }
    }

    /// Today's usage bucketed by hour (24 slots keyed by hour-start dates), so the
    /// Today chart has the same shape as the daily charts.
    func hourlyTotals(includeCache: Bool) -> [DayStat] {
        let dayStart = Calendar.current.startOfDay(for: Date())
        var out = (0..<24).map { DayStat(day: dayStart.addingTimeInterval(Double($0) * 3600)) }
        for e in events(in: .today) {
            let h = Int(e.timestamp.timeIntervalSince(dayStart) / 3600)
            guard (0..<24).contains(h) else { continue }
            let tokens = chartTokens(e, includeCache: includeCache)
            switch e.provider {
            case .claudeCode: out[h].claude += tokens
            case .codex: out[h].codex += tokens
            case .ollama: out[h].ollama += tokens
            case .lmStudio: out[h].lmStudio += tokens
            }
        }
        return out
    }

    /// Grid data for the activity heatmap: `weeks * 7` consecutive days, oldest
    /// first, aligned so the last column is the current (possibly partial) week.
    /// Per-day totals = frozen history + whatever is still in the live window.
    func heatmapDays(weeks: Int, includeCache: Bool) -> [DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start,
              let gridStart = cal.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeekStart)
        else { return [] }

        var window: [String: DayStat] = [:]
        for e in events where !e.shadowed {
            let day = cal.startOfDay(for: e.timestamp)
            let k = Self.dayKey(day)
            var stat = window[k] ?? DayStat(day: day)
            let tokens = chartTokens(e, includeCache: includeCache)
            switch e.provider {
            case .claudeCode: stat.claude += tokens
            case .codex: stat.codex += tokens
            case .ollama: stat.ollama += tokens
            case .lmStudio: stat.lmStudio += tokens
            }
            window[k] = stat
        }

        var out: [DayStat] = []
        out.reserveCapacity(weeks * 7)
        for i in 0..<(weeks * 7) {
            let day = cal.date(byAdding: .day, value: i, to: gridStart) ?? gridStart
            let k = Self.dayKey(day)
            var stat = window[k] ?? DayStat(day: day)
            if let h = history[k] {
                stat.claude += includeCache ? h.claudeWithCache : h.claude
                stat.codex += includeCache ? h.codexWithCache : h.codex
                stat.ollama += includeCache ? h.ollamaWithCache : h.ollama
                stat.lmStudio += includeCache ? h.lmStudioWithCache : h.lmStudio
            }
            out.append(stat)
        }
        return out
    }

    private func sessionTitle(for key: String, sample e: UsageEvent) -> String {
        if e.source == .proxy { return "Ollama (direct)" }
        if e.source == .ollamaDesktop { return "Ollama Desktop" }
        if let name = sessionNames[key] { return name }
        if e.provider == .lmStudio { return "LM Studio · \(e.model)" }
        if e.provider == .codex {
            return e.projectName.map { "Codex · \($0)" } ?? "Codex session \(String(key.prefix(8)))"
        }
        return "Session \(String(key.prefix(8)))"
    }

    var menuTitle: String {
        if let live = liveCalls.last, now.timeIntervalSince(live.lastUpdate) < 8 {
            return "↓\(Fmt.compact(live.outputTokens))"
        }
        let t = totals(for: nil, in: .today)
        return Fmt.compact(t.input + t.output)
    }
}
