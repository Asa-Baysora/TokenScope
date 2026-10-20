import Foundation
import Combine

final class UsageStore: ObservableObject {
    static let retentionDays = HistoryFold.retentionDays   // 28 whole days; see HistoryFold

    // oldest → newest (kept sorted by ingest/merge; `events(in:)` binary-searches it).
    // Every mutation (ingest, shadowing, trim, fold, replay sort) funnels through here,
    // so the didSet is the single invalidation point for the today-totals cache.
    @Published private(set) var events: [UsageEvent] = [] {
        didSet { todayCache = nil }
    }
    /// menu-bar "tokens today" (input + output), valid for one calendar day and
    /// until `events` next mutates. Not published: it is derived state.
    private var todayCache: (dayStart: Date, tokens: Int)?
    private var midnightTimer: Timer?
    @Published private(set) var liveCalls: [LiveCall] = []
    @Published var proxyStatus = "proxy starting…"
    @Published var proxyHealthy = false
    @Published var loadedModels: [LoadedModel] = []
    // Published only on significant change (see RuntimeHealth.significantlyDiffers).
    // The volatile lastSuccess/lastEvent heartbeats live in `runtimeHealthPulse`
    // and are overlaid by the computed `runtimeHealth` at read time — publishing
    // them re-rendered the scene (and the menu-bar bitmap) on every 10s poll.
    @Published private var runtimeHealthState: [UsageOrigin: RuntimeHealth] = [
        .ollama: RuntimeHealth(provider: .ollama, coverage: "routed clients"),
        .lmStudio: RuntimeHealth(provider: .lmStudio, coverage: "completed LLM generations"),
    ]
    private var runtimeHealthPulse: [UsageOrigin: (lastSuccess: Date?, lastEvent: Date?)] = [:]

    var runtimeHealth: [UsageOrigin: RuntimeHealth] {
        runtimeHealthState.mapValues { health in
            var merged = health
            if let pulse = runtimeHealthPulse[health.provider] {
                merged.lastSuccess = pulse.lastSuccess ?? merged.lastSuccess
                merged.lastEvent = pulse.lastEvent ?? merged.lastEvent
            }
            return merged
        }
    }
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
    /// event id → journal key, for the persisted local events (proxy / Desktop / LM
    /// Studio) currently in `events`. Lets a shadow decision be written back.
    private var journalKeyByID: [UUID: String] = [:]
    /// Journaled proxy / Ollama Desktop records that aged out while the app was
    /// closed. Held (not folded) until the transcript backfill can supply their
    /// Claude-Code-via-Ollama twins; see `foldPendingAged`.
    private var pendingAged: [(key: String, event: UsageEvent)] = []
    private var dayChangedObserver: NSObjectProtocol?
    private var timer: Timer?
    private let ioQueue = DispatchQueue(label: "tokenscope.store-io", qos: .utility)

    /// `TOKENSCOPE_SUPPORT_DIR` redirects this (and the log); see `AppPaths`.
    private static let supportDir = AppPaths.supportDir
    private static let proxyEventsURL = supportDir.appendingPathComponent("proxy-events.jsonl")
    private static let localEventsURL = supportDir.appendingPathComponent("usage-events-v2.jsonl")
    private static let historyURL = supportDir.appendingPathComponent("daily-history.json")

    private struct HistoryFile: Codable {
        var completeThrough: Double
        var codexCompleteThrough: Double?
        var schema: Int?
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
    var eventsCutoff: Date { HistoryFold.cutoff(now: Date()) }

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

    /// Tombstone appended when reconcile shadows a journaled event: the event
    /// record itself was written unshadowed, and rewriting the append-only journal
    /// per decision is wasteful. The loader applies these by key; compaction folds
    /// the flag into the rewritten event record.
    private struct PersistedShadowFlag: Codable {
        let schema: Int
        let shadowedKey: String
    }

    init() {
        let d = UserDefaults.standard
        let p = d.integer(forKey: "ProxyPort")
        let u = d.integer(forKey: "OllamaPort")
        proxyPort = p > 0 ? UInt16(p) : 11435
        upstreamPort = u > 0 ? UInt16(u) : 11434
        // History first: aged-out journal records fold into it during the journal load.
        loadHistory()
        loadPersistedLocalEvents()
        scheduleMidnightRollover()
        // The one-shot timer below can be skipped by sleep or a clock/timezone
        // change; the system's day-change notification covers those.
        dayChangedObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.dayRolledOver() }
    }

    deinit {
        if let o = dayChangedObserver { NotificationCenter.default.removeObserver(o) }
        midnightTimer?.invalidate()
    }

    private func dayRolledOver() {
        todayCache = nil
        now = Date()
        scheduleMidnightRollover()
    }

    /// One-shot timer at the next local midnight: drops the today cache and bumps
    /// `now` so the menu-bar total resets to the new day even when nothing else
    /// publishes overnight (the clock timer only runs while calls are live).
    private func scheduleMidnightRollover() {
        midnightTimer?.invalidate()
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) else { return }
        let t = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            self?.dayRolledOver()
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        midnightTimer = t
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
            // Base on the merged view so update closures see current heartbeats.
            var health = self.runtimeHealth[provider] ?? RuntimeHealth(provider: provider)
            update(&health)
            // Heartbeats always land in the (non-published) pulse map…
            self.runtimeHealthPulse[provider] = (health.lastSuccess, health.lastEvent)
            // …but the published state only changes when something the UI keys
            // its structure/colors off actually differs.
            let previous = self.runtimeHealthState[provider] ?? RuntimeHealth(provider: provider)
            if previous.significantlyDiffers(from: health) {
                self.runtimeHealthState[provider] = health
            }
        }
    }

    func setLoadedModels(_ models: [LoadedModel], for provider: UsageOrigin) {
        DispatchQueue.main.async {
            let merged = self.loadedModels.filter { $0.provider != provider } + models
            // displayEquals ignores expiresAt — Ollama's keep-alive countdown
            // changes every poll and would republish (and re-render) every 10s.
            let unchanged = merged.count == self.loadedModels.count
                && zip(merged, self.loadedModels).allSatisfy { $0.displayEquals($1) }
            if !unchanged { self.loadedModels = merged }
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

    /// Bulk transcript ingest for launch replay (non-persisted, replayable sources
    /// only). Same dedup semantics as the per-event path: keys already in the store
    /// go through `EventReconciler.preferred(existing, incoming)` (replace in place,
    /// keep the `shadowed` flag, ties keep the existing record), and repeats inside
    /// the batch fold the same way. New events are then merged in chronological
    /// order with ONE sort/merge and ONE `events` publish per batch, and the window
    /// is trimmed once. The per-event live double-count matcher
    /// (`reconcileDuplicates`) is deliberately not run here: replay always ends with
    /// `replayFinished`, whose full pass shadows every proxy/desktop event that has
    /// a transcript twin. Live (post-replay) arrivals keep using `addTranscriptEvent`.
    func ingest(batch: [(event: UsageEvent, dedupKey: String)]) {
        guard !batch.isEmpty else { return }
        DispatchQueue.main.async {
            // 1. Fold repeats within the batch (first-seen order preserved).
            // 0. The history watermark is authoritative: an event below it is already
            //    inside history (a replay of a folded day), so it never goes live.
            var slot: [String: Int] = [:]
            var unique: [(event: UsageEvent, dedupKey: String)] = []
            unique.reserveCapacity(batch.count)
            for item in batch where !self.isFolded(item.event) {
                if let i = slot[item.dedupKey] {
                    // First-seen timestamp is kept (see EventReconciler.replacement).
                    unique[i].event = EventReconciler.replacement(existing: unique[i].event, incoming: item.event)
                        ?? unique[i].event
                } else {
                    slot[item.dedupKey] = unique.count
                    unique.append(item)
                }
            }
            // 2. Keys already in the store: in-place replace when incoming is stronger.
            var fresh: [UsageEvent] = []
            fresh.reserveCapacity(unique.count)
            var indexByID: [UUID: Int]?
            for item in unique {
                guard let existingID = self.eventIDByDedupKey[item.dedupKey] else {
                    fresh.append(item.event)
                    self.eventIDByDedupKey[item.dedupKey] = item.event.id
                    continue
                }
                if indexByID == nil {
                    var m: [UUID: Int] = [:]
                    m.reserveCapacity(self.events.count)
                    for (i, e) in self.events.enumerated() { m[e.id] = i }
                    indexByID = m
                }
                guard let index = indexByID?[existingID] else {
                    // Key map points at an event that is gone (folded); treat as new.
                    fresh.append(item.event)
                    self.eventIDByDedupKey[item.dedupKey] = item.event.id
                    continue
                }
                let existing = self.events[index]
                // Same slot, same (first-seen) timestamp: `events` stays sorted.
                guard let event = EventReconciler.replacement(existing: existing, incoming: item.event) else { continue }
                self.events[index] = event
                self.eventIDByDedupKey[item.dedupKey] = event.id
            }
            // 3. One chronological merge of the new events.
            self.mergeChronologically(fresh)
            self.trim()
            #if DEBUG
            self.assertSorted()
            #endif
        }
    }

    private func mergeChronologically(_ incoming: [UsageEvent]) {
        guard !incoming.isEmpty else { return }
        events = EventMerge.merge(events, incoming)
    }

    private func ingest(_ incoming: UsageEvent, dedupKey: String, persist: Bool) {
        DispatchQueue.main.async {
            guard !self.isFolded(incoming) else { return }
            var event = incoming
            if let existingID = self.eventIDByDedupKey[dedupKey],
               let index = self.events.firstIndex(where: { $0.id == existingID }) {
                let existing = self.events[index]
                // Keeps the first-seen timestamp and the shadowed flag, so the slot
                // stays in sorted position (see EventReconciler.replacement).
                guard let replaced = EventReconciler.replacement(existing: existing, incoming: incoming) else { return }
                event = replaced
                self.events[index] = event
                self.eventIDByDedupKey[dedupKey] = event.id
                self.journalKeyByID[existing.id] = nil
            } else {
                self.appendEvent(event)
                self.eventIDByDedupKey[dedupKey] = event.id
            }
            if persist { self.journalKeyByID[event.id] = dedupKey }
            self.reconcileDuplicates(around: event)
            self.trim()
            if persist { self.persistLocalEvent(event, key: dedupKey) }
            #if DEBUG
            self.assertSorted()
            #endif
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
                    markShadowed(at: i)
                } else if let eventIndex = events.firstIndex(where: { $0.id == event.id }) {
                    markShadowed(at: eventIndex)
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
                markShadowed(at: i)
            } else if let eventIndex = events.firstIndex(where: { $0.id == event.id }) {
                markShadowed(at: eventIndex)
            }
            break
        }
    }

    /// Shadows `events[i]` and, for a journaled event, persists the decision (the
    /// journal record was written unshadowed; without this a restart resurrects it).
    private func markShadowed(at i: Int) {
        guard !events[i].shadowed else { return }
        events[i].shadowed = true
        if let key = journalKeyByID[events[i].id] { persistShadowFlag(key) }
    }

    /// True when the event's day is already inside frozen history. The watermark is
    /// authoritative: transcript sources only (local proxy/Desktop/LM Studio events
    /// have no watermark and are never replayed).
    private func isFolded(_ e: UsageEvent) -> Bool {
        switch e.source {
        case .transcript: return e.timestamp < historyCompleteThrough
        case .codexTranscript: return e.timestamp < codexHistoryCompleteThrough
        case .proxy, .ollamaDesktop, .lmStudioLog: return false
        }
    }

    /// `events` must stay sorted ascending by timestamp: `EventRange`,
    /// `EventMerge`, trim and the today cache all binary-search or prefix-scan it.
    var eventsAreSorted: Bool {
        zip(events, events.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
    }

    /// Debug helper (also used by tools/verify-store.swift): traps if the window is unsorted.
    func assertSorted(_ context: @autoclosure () -> String = "") {
        assert(eventsAreSorted, "UsageStore.events is not sorted by timestamp \(context())")
    }

    /// Blocks until queued persistence writes (journal, history) have hit disk.
    func flushIO() { ioQueue.sync {} }

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
    /// `ollamaTwins` are the exact Claude-Code-via-Ollama transcript events inside
    /// that backfill: they are what journaled proxy records that aged out while the
    /// app was closed must be shadowed against BEFORE those records fold (order
    /// matters: the fold max-merges into an existing bucket, the backfill sums).
    func mergeHistorical(_ batch: [String: DayAgg], ollamaTwins: [UsageEvent] = []) {
        guard !batch.isEmpty else { return }
        DispatchQueue.main.async {
            self.foldPendingAged(twins: ollamaTwins)
            for (k, v) in batch {
                var d = self.history[k] ?? DayAgg()
                d.merge(v)
                self.history[k] = d
            }
            FileLog.log("backfilled \(batch.count) days into history")
        }
    }

    /// Thread-safe read of the Codex watermark. Writers update it on main, so
    /// reading through main (FIFO) orders a bootstrap after any earlier merge
    /// and prevents a replay from re-running a backfill that just finished.
    func claudeWatermark() -> Date {
        Thread.isMainThread ? historyCompleteThrough
            : DispatchQueue.main.sync { historyCompleteThrough }
    }

    func codexWatermark() -> Date {
        Thread.isMainThread ? codexHistoryCompleteThrough
            : DispatchQueue.main.sync { codexHistoryCompleteThrough }
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
            var evs = self.events
            evs.sort { $0.timestamp < $1.timestamp }
            // Proxy-side accuracy is deliberately NOT gated (see shadowProxyTwins):
            // estimated and legacy-migrated (.unknown) proxy events are exactly the
            // copies that need shadowing against their exact transcript twins.
            var changed = EventReconciler.shadowProxyTwins(
                in: &evs, index: EventReconciler.TranscriptTwinIndex(evs))
            changed += EventReconciler.shadowDesktopOverlaps(in: &evs)
            self.events = evs
            for i in changed {
                if let key = self.journalKeyByID[evs[i].id] { self.persistShadowFlag(key) }
            }
            let shadowed = changed.count
            // Aged journal records the backfill did not take (no backfill ran).
            self.foldPendingAged(twins: [])
            self.historyCompleteThrough = max(self.historyCompleteThrough, coverThrough)
            self.saveHistory()
            FileLog.log("replay complete: \(self.events.count) events in window, \(shadowed) proxy events shadowed, history through \(Self.dayKey(self.historyCompleteThrough))")
            #if DEBUG
            self.assertSorted()
            #endif
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
        var w = HistoryFold.Window(
            events: events, keyIDs: eventIDByDedupKey, history: history,
            claudeThrough: historyCompleteThrough, codexThrough: codexHistoryCompleteThrough)
        let before = events.count
        guard before > HistoryFold.overflowCap
                || (events.first.map { $0.timestamp < eventsCutoff } ?? false) else { return }
        let r = HistoryFold.trim(&w, cutoff: eventsCutoff, dayKey: Self.dayKey)
        guard r.folded > 0 else { return }
        events = w.events
        eventIDByDedupKey = w.keyIDs
        history = w.history
        historyCompleteThrough = w.claudeThrough
        codexHistoryCompleteThrough = w.codexThrough
        saveHistory()
        logMaxMerges(r.conflicts)
        FileLog.log("folded \(r.folded) aged-out events into daily history")
    }

    private func logMaxMerges(_ conflicts: [String]) {
        guard !conflicts.isEmpty else { return }
        FileLog.log("fold: history already had \(conflicts.count) day/provider bucket(s) (\(conflicts.prefix(6).joined(separator: ", "))); merged by max, not summed")
    }

    // MARK: - Persistence (non-replayable local events; transcripts replay from disk)

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              let f = try? JSONDecoder().decode(HistoryFile.self, from: data) else { return }
        history = f.days
        historyCompleteThrough = Date(timeIntervalSince1970: f.completeThrough)
        codexHistoryCompleteThrough = f.codexCompleteThrough.map(Date.init(timeIntervalSince1970:))
            ?? Date(timeIntervalSince1970: 0)
        // One-time repair: pre-v2 history could hold doubled Codex days (fold()
        // never advanced the Codex watermark, so the next backfill re-added them).
        // Strip Codex and reset only its watermark; the backfill rebuilds it.
        if (f.schema ?? 1) < CodexHistory.historySchema {
            history = CodexHistory.stripCodex(f.days)
            codexHistoryCompleteThrough = Date(timeIntervalSince1970: 0)
            FileLog.log("history schema \(f.schema ?? 1) -> \(CodexHistory.historySchema): stripped Codex days, rebuilding from rollout files")
            saveHistory()
        }
        FileLog.log("loaded daily history: \(f.days.count) days, Claude through \(Self.dayKey(historyCompleteThrough)), Codex through \(Self.dayKey(codexHistoryCompleteThrough))")
    }

    private func saveHistory() {
        let f = HistoryFile(
            completeThrough: historyCompleteThrough.timeIntervalSince1970,
            codexCompleteThrough: codexHistoryCompleteThrough.timeIntervalSince1970,
            schema: CodexHistory.historySchema,
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
        let decoder = JSONDecoder()
        var bestByKey: [String: UsageEvent] = [:]
        var shadowKeys = Set<String>()
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<nl]
            start = nl < data.endIndex ? data.index(after: nl) : data.endIndex
            guard !line.isEmpty else { continue }
            if let record = try? decoder.decode(PersistedLocalEvent.self, from: line) {
                guard record.schema == 2 else { continue }
                if record.event.shadowed { shadowKeys.insert(record.key) }
                if let existing = bestByKey[record.key] {
                    bestByKey[record.key] = EventReconciler.preferred(existing, record.event)
                } else {
                    bestByKey[record.key] = record.event
                }
            } else if let flag = try? decoder.decode(PersistedShadowFlag.self, from: line),
                      flag.schema == 2 {
                shadowKeys.insert(flag.shadowedKey)
            }
        }
        // A shadow decision is sticky for the key, whichever record won `preferred`.
        for key in shadowKeys { bestByKey[key]?.shadowed = true }
        installJournal(bestByKey)
        FileLog.log("loaded \(events.count) persisted local inference events (\(pendingAged.count) aged proxy/Desktop records held for twin matching)")
    }

    private func migrateLegacyProxyEvents() {
        guard let data = try? Data(contentsOf: Self.proxyEventsURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        var migrated: [String: UsageEvent] = [:]
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<nl]
            start = nl < data.endIndex ? data.index(after: nl) : data.endIndex
            guard !line.isEmpty, let pe = try? decoder.decode(PersistedProxyEvent.self, from: line) else { continue }
            let timestamp = Date(timeIntervalSince1970: pe.ts)
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
        installJournal(migrated)
        FileLog.log("migrated \(migrated.count) legacy proxy events to schema v2")
    }

    /// Turns loaded journal records into the live window.
    ///
    /// - `>= cutoff` and not below the Claude watermark: live.
    /// - At/after the cutoff but below the watermark (an overflow fold advanced it):
    ///   that day is already in history; dropped, compacted away.
    /// - Below the cutoff (aged out while closed): LM Studio records fold now.
    ///   Proxy / Ollama Desktop records are HELD in `pendingAged` until
    ///   `mergeHistorical`/`replayFinished`, because their Claude-Code-via-Ollama
    ///   twins only appear in the transcript backfill that runs after this load;
    ///   folding them first double-counts every twinned call. The journal is not
    ///   compacted past held records, so quitting before they fold loses nothing.
    private func installJournal(_ records: [String: UsageEvent]) {
        let split = HistoryFold.partitionJournal(
            records, cutoff: eventsCutoff, foldedThrough: historyCompleteThrough)
        let keyByID = Dictionary(records.map { ($0.value.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        func isHeld(_ e: UsageEvent) -> Bool { e.source == .proxy || e.source == .ollamaDesktop }
        let foldNow = split.aged.filter { !isHeld($0) }
        if !foldNow.isEmpty {
            let conflicts = HistoryFold.fold(foldNow, into: &history, dayKey: Self.dayKey)
            saveHistory()
            logMaxMerges(conflicts)
            FileLog.log("folded \(foldNow.count) journaled local events that aged out while closed into daily history")
        }
        pendingAged = split.aged.filter(isHeld).compactMap { e in keyByID[e.id].map { (key: $0, event: e) } }
        if split.dropped > 0 {
            FileLog.log("dropped \(split.dropped) journaled local events already folded into history (day(s) below the watermark)")
        }
        events = split.live.values.sorted { $0.timestamp < $1.timestamp }
        eventIDByDedupKey = Dictionary(uniqueKeysWithValues: split.live.map { ($0.key, $0.value.id) })
        journalKeyByID = Dictionary(split.live.map { ($0.value.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        var keep = split.live
        for held in pendingAged { keep[held.key] = held.event }
        rewriteLocalEventJournal(keep)
    }

    /// Shadows the held aged proxy/Desktop records against the backfilled transcript
    /// twins (same ±2 token / 120 s rule as the live path) and against each other
    /// (`desktopAndProxyOverlap`), folds the survivors into history, then compacts
    /// the journal to the live records. Runs on main, once.
    private func foldPendingAged(twins: [UsageEvent]) {
        guard !pendingAged.isEmpty else { return }
        var evs = pendingAged.map(\.event)
        pendingAged = []
        let shadowed = EventReconciler.shadowProxyTwins(
            in: &evs, index: EventReconciler.TranscriptTwinIndex(twins)).count
            + EventReconciler.shadowDesktopOverlaps(in: &evs).count
        let conflicts = HistoryFold.fold(evs, into: &history, dayKey: Self.dayKey)
        saveHistory()
        logMaxMerges(conflicts)
        FileLog.log("folded \(evs.count - shadowed) aged proxy/Desktop journal events into daily history (\(shadowed) shadowed as duplicates of transcript/proxy records)")
        compactJournal()
    }

    /// Rewrites the journal with only the persisted events still in the window
    /// (shadow flags folded into the records). Queued after the history save on the
    /// same serial IO queue.
    private func compactJournal() {
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var records: [String: UsageEvent] = [:]
        for (id, key) in journalKeyByID { if let e = byID[id] { records[key] = e } }
        journalKeyByID = Dictionary(records.map { ($0.value.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        rewriteLocalEventJournal(records)
    }

    private func persistShadowFlag(_ key: String) {
        guard var line = try? JSONEncoder().encode(PersistedShadowFlag(schema: 2, shadowedKey: key)) else { return }
        line.append(0x0A)
        appendJournalLine(line)
    }

    private func persistLocalEvent(_ event: UsageEvent, key: String) {
        let record = PersistedLocalEvent(schema: 2, key: key, event: event)
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(0x0A)
        appendJournalLine(line)
    }

    private func appendJournalLine(_ line: Data) {
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

    /// Non-shadowed events in the period. `events` is sorted by timestamp, so the
    /// window start (and, for today, the day end) is found by binary search and only
    /// that slice is filtered — not all ~18k events.
    func events(in period: StatsPeriod) -> [UsageEvent] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let start = period == .today
            ? dayStart
            : (cal.date(byAdding: .day, value: -(period.days - 1), to: dayStart) ?? dayStart)
        let lo = EventRange.firstIndex(in: events, timestamp: { $0.timestamp }, atOrAfter: start)
        var hi = events.count
        if period == .today, let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) {
            hi = EventRange.firstIndex(in: events, timestamp: { $0.timestamp }, atOrAfter: dayEnd)
        }
        guard lo < hi else { return [] }
        return events[lo..<hi].filter { !$0.shadowed }
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
            stat.cached[e.provider, default: 0] += e.cacheReadTokens + e.cacheCreationTokens
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
            out[h].cached[e.provider, default: 0] += e.cacheReadTokens + e.cacheCreationTokens
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
            stat.cached[e.provider, default: 0] += e.cacheReadTokens + e.cacheCreationTokens
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
                stat.cached[.claudeCode, default: 0] += h.claudeWithCache - h.claude
                stat.cached[.codex, default: 0] += h.codexWithCache - h.codex
                stat.cached[.ollama, default: 0] += h.ollamaWithCache - h.ollama
                stat.cached[.lmStudio, default: 0] += h.lmStudioWithCache - h.lmStudio
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
        return Fmt.compact(todayTokens)
    }

    /// Today's input + output, cached per (calendar day, events mutation).
    private var todayTokens: Int {
        let dayStart = Calendar.current.startOfDay(for: Date())
        if let c = todayCache, c.dayStart == dayStart { return c.tokens }
        var t = Totals()
        for e in events(in: .today) { t.add(e) }
        let tokens = t.input + t.output
        todayCache = (dayStart, tokens)
        return tokens
    }
}
