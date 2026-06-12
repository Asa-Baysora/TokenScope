import Foundation
import Combine

final class UsageStore: ObservableObject {
    static let retentionDays = 31   // a hair more than the longest display window

    @Published private(set) var events: [UsageEvent] = []   // oldest → newest (sorted after replay)
    @Published private(set) var liveCalls: [LiveCall] = []
    @Published var proxyStatus = "proxy starting…"
    @Published var proxyHealthy = false
    @Published var loadedModels: [LoadedModel] = []
    @Published private(set) var history: [String: DayAgg] = [:]   // frozen days, keyed yyyy-MM-dd
    @Published private(set) var sessionNames: [String: String] = [:]   // sessionId → human title
    @Published private(set) var now = Date()

    /// All usage before this date is fully captured in `history`.
    private(set) var historyCompleteThrough = Date(timeIntervalSince1970: 0)

    let proxyPort: UInt16
    let upstreamPort: UInt16

    private var seenKeys = Set<String>()
    private var timer: Timer?
    private let ioQueue = DispatchQueue(label: "tokenscope.store-io", qos: .utility)

    private static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TokenScope")
    private static let proxyEventsURL = supportDir.appendingPathComponent("proxy-events.jsonl")
    private static let historyURL = supportDir.appendingPathComponent("daily-history.json")

    private struct HistoryFile: Codable {
        var completeThrough: Double
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

    init() {
        let d = UserDefaults.standard
        let p = d.integer(forKey: "ProxyPort")
        let u = d.integer(forKey: "OllamaPort")
        proxyPort = p > 0 ? UInt16(p) : 11435
        upstreamPort = u > 0 ? UInt16(u) : 11434
        loadPersistedProxyEvents()
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

    func addTranscriptEvent(_ e: UsageEvent, dedupKey: String) {
        DispatchQueue.main.async {
            guard !self.seenKeys.contains(dedupKey) else { return }
            self.seenKeys.insert(dedupKey)
            // If the proxy already observed this same call (Claude Code routed through it),
            // shadow the proxy copy so totals count it once.
            if e.provider == .ollama {
                for i in self.events.indices.reversed().prefix(60) {
                    let p = self.events[i]
                    if p.source == .proxy, !p.shadowed,
                       abs(p.timestamp.timeIntervalSince(e.timestamp)) < 90,
                       abs(p.outputTokens - e.outputTokens) <= 2 {
                        self.events[i].shadowed = true
                        break
                    }
                }
            }
            self.events.append(e)
            self.trim()
            // Intentionally not logged per-event: at thousands of events/replay this
            // dominated both the log size and the write overhead. Lifecycle summaries
            // (replay complete, proxy, limits, status) are logged instead.
        }
    }

    func upsertLiveCall(_ st: ResponseScanner.CallState) {
        DispatchQueue.main.async {
            let call = LiveCall(
                id: st.id,
                model: st.model,
                inputTokens: st.input + st.cacheRead,
                outputTokens: st.displayOutput,
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
            guard st.displayOutput > 0 else { return }   // pings, count_tokens, errors
            var e = UsageEvent(
                timestamp: Date(),
                provider: .ollama,
                source: .proxy,
                model: st.model,
                sessionId: "ollama-direct",
                projectName: nil,
                inputTokens: st.input,
                outputTokens: st.displayOutput,
                cacheReadTokens: st.cacheRead,
                cacheCreationTokens: st.cacheCreate)
            // Reverse of the shadowing above, in case the transcript line landed first.
            for t in self.events.suffix(60)
            where t.source == .transcript && t.provider == .ollama && !t.shadowed {
                if abs(t.timestamp.timeIntervalSinceNow) < 90, abs(t.outputTokens - e.outputTokens) <= 2 {
                    e.shadowed = true
                    break
                }
            }
            self.events.append(e)
            self.trim()
            self.persistProxyEvent(e)
            FileLog.log("proxy \(e.model) in=\(e.inputTokens) out=\(e.outputTokens) shadowed=\(e.shadowed)")
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

    /// Called once the transcript watcher has finished its initial replay: orders the
    /// bulk-loaded events, shadows persisted proxy events that match a transcript
    /// record of the same call (the live matching above only covers runtime arrivals),
    /// and records how far back history is now complete.
    func replayFinished(coverThrough: Date) {
        DispatchQueue.main.async {
            self.events.sort { $0.timestamp < $1.timestamp }
            var byOut: [Int: [Date]] = [:]
            for e in self.events where e.source == .transcript && e.provider == .ollama {
                byOut[e.outputTokens, default: []].append(e.timestamp)
            }
            var shadowed = 0
            for i in self.events.indices where self.events[i].source == .proxy && !self.events[i].shadowed {
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
            self.historyCompleteThrough = max(self.historyCompleteThrough, coverThrough)
            self.saveHistory()
            FileLog.log("replay complete: \(self.events.count) events in window, \(shadowed) proxy events shadowed, history through \(Self.dayKey(self.historyCompleteThrough))")
        }
    }

    private func pruneStaleLiveCalls() {
        let cutoff = Date().addingTimeInterval(-180)
        liveCalls.removeAll { $0.lastUpdate < cutoff }
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

    // MARK: - Persistence (proxy events only; transcripts replay from disk)

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              let f = try? JSONDecoder().decode(HistoryFile.self, from: data) else { return }
        history = f.days
        historyCompleteThrough = Date(timeIntervalSince1970: f.completeThrough)
        FileLog.log("loaded daily history: \(f.days.count) days, complete through \(Self.dayKey(historyCompleteThrough))")
    }

    private func saveHistory() {
        let f = HistoryFile(completeThrough: historyCompleteThrough.timeIntervalSince1970, days: history)
        guard let data = try? JSONEncoder().encode(f) else { return }
        ioQueue.async {
            try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            try? data.write(to: Self.historyURL)
        }
    }

    private func loadPersistedProxyEvents() {
        guard let data = try? Data(contentsOf: Self.proxyEventsURL), !data.isEmpty else { return }
        let cutoff = eventsCutoff
        let decoder = JSONDecoder()
        var loaded: [UsageEvent] = []
        var compacted = Data()
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<nl]
            start = nl < data.endIndex ? data.index(after: nl) : data.endIndex
            guard !line.isEmpty, let pe = try? decoder.decode(PersistedProxyEvent.self, from: line) else { continue }
            let ts = Date(timeIntervalSince1970: pe.ts)
            guard ts > cutoff else { continue }
            compacted.append(line)
            compacted.append(0x0A)
            loaded.append(UsageEvent(
                timestamp: ts,
                provider: .ollama,
                source: .proxy,
                model: pe.model,
                sessionId: "ollama-direct",
                projectName: nil,
                inputTokens: pe.input,
                outputTokens: pe.output,
                cacheReadTokens: pe.cacheR,
                cacheCreationTokens: pe.cacheC))
        }
        events = loaded
        ioQueue.async {
            try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            try? compacted.write(to: Self.proxyEventsURL)
        }
        FileLog.log("loaded \(loaded.count) persisted proxy events")
    }

    private func persistProxyEvent(_ e: UsageEvent) {
        let pe = PersistedProxyEvent(
            ts: e.timestamp.timeIntervalSince1970,
            model: e.model,
            input: e.inputTokens,
            output: e.outputTokens,
            cacheR: e.cacheReadTokens,
            cacheC: e.cacheCreationTokens)
        guard var line = try? JSONEncoder().encode(pe) else { return }
        line.append(0x0A)
        ioQueue.async {
            try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: Self.proxyEventsURL) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
                try? h.close()
            } else {
                try? line.write(to: Self.proxyEventsURL)
            }
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

    func totals(for provider: TokenProvider?, in period: StatsPeriod) -> Totals {
        var t = Totals()
        for e in events(in: period) where provider == nil || e.provider == provider {
            t.add(e)
        }
        return t
    }

    func modelTotals(for provider: TokenProvider, in period: StatsPeriod) -> [(model: String, totals: Totals)] {
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
            let key = e.sessionId ?? "unknown"
            var agg = by[key] ?? SessionAgg(
                id: key,
                title: sessionTitle(for: key, sample: e),
                project: e.source == .proxy ? nil : e.projectName,
                provider: e.provider)
            agg.totals.add(e)
            agg.lastActivity = max(agg.lastActivity, e.timestamp)
            agg.models.insert(e.model)
            by[key] = agg
        }
        return by.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    func dailyTotals(in period: StatsPeriod) -> [DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var by: [Date: DayStat] = [:]
        for e in events(in: period) {
            let day = cal.startOfDay(for: e.timestamp)
            var stat = by[day] ?? DayStat(day: day)
            let tokens = e.inputTokens + e.outputTokens
            if e.provider == .claude { stat.claude += tokens } else { stat.ollama += tokens }
            by[day] = stat
        }
        return (0..<period.days).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return by[day] ?? DayStat(day: day)
        }
    }

    /// Today's usage bucketed by hour (24 slots keyed by hour-start dates), so the
    /// Today chart has the same shape as the daily charts.
    func hourlyTotals() -> [DayStat] {
        let dayStart = Calendar.current.startOfDay(for: Date())
        var out = (0..<24).map { DayStat(day: dayStart.addingTimeInterval(Double($0) * 3600)) }
        for e in events(in: .today) {
            let h = Int(e.timestamp.timeIntervalSince(dayStart) / 3600)
            guard (0..<24).contains(h) else { continue }
            let tokens = e.inputTokens + e.outputTokens
            if e.provider == .claude { out[h].claude += tokens } else { out[h].ollama += tokens }
        }
        return out
    }

    /// Grid data for the activity heatmap: `weeks * 7` consecutive days, oldest
    /// first, aligned so the last column is the current (possibly partial) week.
    /// Per-day totals = frozen history + whatever is still in the live window.
    func heatmapDays(weeks: Int) -> [DayStat] {
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
            let tokens = e.inputTokens + e.outputTokens
            if e.provider == .claude { stat.claude += tokens } else { stat.ollama += tokens }
            window[k] = stat
        }

        var out: [DayStat] = []
        out.reserveCapacity(weeks * 7)
        for i in 0..<(weeks * 7) {
            let day = cal.date(byAdding: .day, value: i, to: gridStart) ?? gridStart
            let k = Self.dayKey(day)
            var stat = window[k] ?? DayStat(day: day)
            if let h = history[k] {
                stat.claude += h.claude
                stat.ollama += h.ollama
            }
            out.append(stat)
        }
        return out
    }

    private func sessionTitle(for key: String, sample e: UsageEvent) -> String {
        if e.source == .proxy { return "Ollama (direct)" }
        if let name = sessionNames[key] { return name }
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
