import Foundation

/// Framework-free checks that drive the REAL `UsageStore` against a scratch support
/// directory (`TOKENSCOPE_SUPPORT_DIR`, set before the store is first touched), with
/// "restarts" simulated by building a second store over the same files. Covers the
/// journal (shadow flags, aged-record twin matching), in-place replacement ordering,
/// and the history watermark. Run via scripts/verify-redesign.sh.
@main
struct StoreChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ msg: String) {
        if ok { print("PASS \(msg)") } else { print("FAIL \(msg)"); failures += 1 }
    }

    static let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ts-store-\(UUID().uuidString)")
    static let cal = Calendar.current
    static let journalURL = dir.appendingPathComponent("usage-events-v2.jsonl")
    static let historyURL = dir.appendingPathComponent("daily-history.json")

    // MARK: fixtures

    struct JournalRecord: Codable { let schema: Int; let key: String; let event: UsageEvent }
    struct HistoryFileMirror: Codable {
        var completeThrough: Double
        var codexCompleteThrough: Double?
        var schema: Int?
        var days: [String: DayAgg]
    }

    struct HistoryFileMirror2: Codable {
        var schema: Int?
        var rootCompleteThrough: [String: Double]?
    }

    static func wipe() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func writeJournal(_ records: [(String, UsageEvent)]) {
        var data = Data()
        for (k, e) in records {
            data.append(try! JSONEncoder().encode(JournalRecord(schema: 2, key: k, event: e)))
            data.append(0x0A)
        }
        try! data.write(to: journalURL)
    }

    static func writeHistory(claudeThrough: Date, codexThrough: Date? = nil, days: [String: DayAgg] = [:]) {
        let f = HistoryFileMirror(completeThrough: claudeThrough.timeIntervalSince1970,
                                  codexCompleteThrough: (codexThrough ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970,
                                  schema: CodexHistory.historySchema, days: days)
        try! JSONEncoder().encode(f).write(to: historyURL)
    }

    static func journalText() -> String { (try? String(contentsOf: journalURL, encoding: .utf8)) ?? "" }

    /// Runs the main queue so `DispatchQueue.main.async` store work lands.
    static func pump() { for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }

    static func restart(_ old: UsageStore?) -> UsageStore {
        pump(); old?.flushIO()
        let s = UsageStore()
        pump()
        return s
    }

    static func proxy(_ t: Date, out: Int = 150, input: Int = 0, model: String = "qwen") -> UsageEvent {
        UsageEvent(timestamp: t, provider: .ollama, source: .proxy, model: model, sessionId: "ollama-direct",
                   projectName: nil, inputTokens: input, outputTokens: out, cacheReadTokens: 0,
                   cacheCreationTokens: 0, reasoningTokens: 0, tokenAccuracy: .exact)
    }
    static func twin(_ t: Date, out: Int = 150, input: Int = 0, model: String = "qwen",
                     accuracy: MetricAccuracy = .exact) -> UsageEvent {
        UsageEvent(timestamp: t, provider: .ollama, source: .transcript, model: model, sessionId: "s",
                   projectName: nil, inputTokens: input, outputTokens: out, cacheReadTokens: 0,
                   cacheCreationTokens: 0, reasoningTokens: 0, tokenAccuracy: accuracy)
    }
    static func claude(_ t: Date, out: Int, accuracy: MetricAccuracy = .exact) -> UsageEvent {
        UsageEvent(timestamp: t, provider: .claudeCode, source: .transcript, model: "claude-x", sessionId: "s",
                   projectName: nil, inputTokens: 1, outputTokens: out, cacheReadTokens: 0,
                   cacheCreationTokens: 0, reasoningTokens: 0, tokenAccuracy: accuracy)
    }
    static func counted(_ s: UsageStore) -> Int {
        s.events.filter { !$0.shadowed }.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }
    static func dayAgg(of e: UsageEvent) -> DayAgg { var d = DayAgg(); d.add(e); return d }


    // MARK: per-root watcher fixtures

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
    /// Local noon of the day `offset` days from `base` (whole days), clear of DST/UTC edges.
    static func noon(_ base: Date, _ offset: Int) -> Date {
        cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: base))!)!
    }
    /// Writes finalized (exact) assistant lines: (id, timestamp, output tokens).
    static func writeTranscript(_ url: URL, _ lines: [(String, Date, Int)], mtime: Date) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for (id, ts, out) in lines {
            let usage: [String: Any] = ["input_tokens": 1, "output_tokens": out,
                                        "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]
            let msg: [String: Any] = ["id": id, "model": "claude-x", "content": [["type": "text", "text": "hi"]],
                                      "usage": usage, "stop_reason": "end_turn"]
            let o: [String: Any] = ["type": "assistant", "sessionId": "s-\(id)", "requestId": "req-\(id)",
                                    "cwd": "/tmp/p", "timestamp": iso(ts), "message": msg]
            data.append(try! JSONSerialization.data(withJSONObject: o)); data.append(0x0A)
        }
        try! data.write(to: url)
        try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }
    /// One simulated launch: fresh store over the same support dir + a watcher over `roots`.
    static func launch(roots: [(URL, ClaudeProjectRoots.Kind)]) -> (UsageStore, TranscriptWatcher) {
        let store = UsageStore()
        pump()
        let w = TranscriptWatcher(store: store, rootsProvider: {
            var kinds: [String: ClaudeProjectRoots.Kind] = [:]
            for (u, k) in roots { kinds[u.path] = k }
            return TranscriptWatcher.RootSet(existing: roots.map(\.0), kinds: kinds)
        })
        w.start()
        let deadline = Date().addingTimeInterval(15)
        while !store.replayComplete && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        pump(); store.flushIO()
        return (store, w)
    }

    // MARK: main

    static func main() {
        setenv(AppPaths.envKey, dir.path, 1)
        wipe()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let today = cal.startOfDay(for: now)
        let cutoff = HistoryFold.cutoff(now: now)

        // 0. TOKENSCOPE_SUPPORT_DIR
        check(AppPaths.supportDir.path == dir.path, "support dir comes from TOKENSCOPE_SUPPORT_DIR")
        check(AppPaths.logURL.deletingLastPathComponent().path == dir.path, "log moves next to the support dir")
        check(AppPaths.override(["TOKENSCOPE_SUPPORT_DIR": "~/ts-x"])?.path == NSHomeDirectory() + "/ts-x", "~ expands")
        check(AppPaths.override(["TOKENSCOPE_SUPPORT_DIR": "  "]) == nil && AppPaths.override([:]) == nil, "blank/unset = default")

        // 1a. A shadow decision made live survives a restart (journal tombstone).
        do {
            wipe()
            var store = UsageStore()
            let t = now.addingTimeInterval(-600)
            store.addLocalEvent(proxy(t), dedupKey: "proxy:A")
            store.addTranscriptEvent(twin(t.addingTimeInterval(5)), dedupKey: "msg:A")
            pump()
            check(store.events.count == 2 && counted(store) == 150, "live: proxy shadowed by its twin (150 counted)")
            store.flushIO()
            check(journalText().contains("shadowedKey"), "shadow flag appended to the journal")
            store = restart(store)
            check(store.events.count == 1 && store.events[0].shadowed, "restart: journaled proxy event is still shadowed")
            store.ingest(batch: [(twin(t.addingTimeInterval(5)), "msg:A")])
            pump()
            check(counted(store) == 150, "restart + twin replay still counts 150, not 300")
        }

        // 1a'. Shadowing found at replayFinished (twin replayed after restart) is persisted too.
        do {
            wipe()
            var store = UsageStore()
            let t = now.addingTimeInterval(-900)
            store.addLocalEvent(proxy(t), dedupKey: "proxy:B")
            pump()
            store = restart(store)
            store.ingest(batch: [(twin(t.addingTimeInterval(8)), "msg:B")])
            store.replayFinished(coverThrough: cutoff)
            pump()
            check(counted(store) == 150, "replayFinished shadows the proxy copy")
            store = restart(store)
            check(store.events.count == 1 && store.events[0].shadowed, "replayFinished decision survives the next restart")
        }

        // 1b. Aged proxy record + transcript twin across a restart folds to 150, not 300.
        do {
            wipe()
            let aged = cutoff.addingTimeInterval(-5 * 86400 + 3 * 3600)
            let agedKey = UsageStore.dayKey(aged)
            let p = proxy(aged, out: 50, input: 100)
            let unmatchedTime = cutoff.addingTimeInterval(-3 * 86400 + 3600)
            let unmatched = proxy(unmatchedTime, out: 40, input: 0, model: "direct")
            let desktopTime = cutoff.addingTimeInterval(-2 * 86400 + 3600)
            let dProxy = proxy(desktopTime, out: 70, input: 5, model: "m")
            var dDesktop = UsageEvent(timestamp: desktopTime.addingTimeInterval(1), startedAt: desktopTime.addingTimeInterval(-3),
                                      provider: .ollama, source: .ollamaDesktop, model: "m", sessionId: nil, projectName: nil,
                                      inputTokens: 5, outputTokens: 70, cacheReadTokens: 0, cacheCreationTokens: 0,
                                      reasoningTokens: 0, tokenAccuracy: .exact)
            dDesktop.shadowed = false
            let lm = UsageEvent(timestamp: cutoff.addingTimeInterval(-86400 + 7200), provider: .lmStudio, source: .lmStudioLog,
                                model: "lm", sessionId: nil, projectName: nil, inputTokens: 9, outputTokens: 1,
                                cacheReadTokens: 0, cacheCreationTokens: 0, reasoningTokens: 0)
            let liveEv = proxy(now.addingTimeInterval(-60), out: 11)
            writeJournal([("p", p), ("u", unmatched), ("dp", dProxy), ("dd", dDesktop), ("lm", lm), ("live", liveEv)])
            writeHistory(claudeThrough: cutoff.addingTimeInterval(-10 * 86400))
            let store = restart(nil)
            check(store.history[agedKey] == nil, "load does NOT fold the aged proxy record yet (held for twin matching)")
            check(store.history[UsageStore.dayKey(lm.timestamp)]?.lmStudio == 10, "aged LM Studio record folds at load")
            check(store.events.count == 1 && store.events[0].outputTokens == 11, "only the live record stays in the window")
            check(journalText().contains("\"key\":\"p\""), "journal is NOT compacted past held records")
            // The transcript backfill supplies the Claude-Code-via-Ollama twin (same tokens, a few s apart).
            let tw = twin(aged.addingTimeInterval(4), out: 50, input: 100)
            store.mergeHistorical([agedKey: dayAgg(of: tw)], ollamaTwins: [tw])
            store.replayFinished(coverThrough: cutoff)
            pump(); store.flushIO()
            check(store.history[agedKey]?.ollama == 150, "aged proxy + twin folds to 150, not 300 (got \(store.history[agedKey]?.ollama ?? -1))")
            check(store.history[UsageStore.dayKey(unmatchedTime)]?.ollama == 40, "aged proxy with no twin still folds (40)")
            check(store.history[UsageStore.dayKey(desktopTime)]?.ollama == 75, "aged desktop + proxy overlap folds once (75, got \(store.history[UsageStore.dayKey(desktopTime)]?.ollama ?? -1))")
            check(!journalText().contains("\"key\":\"p\"") && journalText().contains("\"key\":\"live\""),
                  "journal compacted to live records after the fold")
            let before = store.history
            let again = restart(store)
            check(again.history == before && again.events.count == 1, "second restart changes nothing (no refold)")
        }

        // 2. Watermark above the cutoff is authoritative on BOTH ingest paths and for the journal.
        do {
            wipe()
            let wm = today.addingTimeInterval(-3 * 86400)
            let inFolded = today.addingTimeInterval(-5 * 86400 + 600)
            let after = today.addingTimeInterval(-2 * 86400 + 600)
            writeHistory(claudeThrough: wm, codexThrough: wm)
            writeJournal([("old", proxy(inFolded, out: 7)), ("new", proxy(after, out: 8))])
            let store = restart(nil)
            check(store.events.count == 1 && store.events[0].outputTokens == 8, "journal record in an already-folded day is dropped at load")
            check(!journalText().contains("\"key\":\"old\""), "…and compacted out of the journal")
            store.addTranscriptEvent(claude(inFolded, out: 5), dedupKey: "c1")
            store.addTranscriptEvent(claude(after, out: 6), dedupKey: "c2")
            store.ingest(batch: [(claude(inFolded.addingTimeInterval(60), out: 5), "c3"), (claude(after.addingTimeInterval(60), out: 6), "c4")])
            let codexOld = UsageEvent(timestamp: inFolded, provider: .codex, source: .codexTranscript, model: "c", sessionId: "x",
                                      projectName: nil, inputTokens: 3, outputTokens: 3, cacheReadTokens: 0,
                                      cacheCreationTokens: 0, reasoningTokens: 0)
            store.addTranscriptEvent(codexOld, dedupKey: "cx")
            pump()
            let keys = store.events.map(\.outputTokens).sorted()
            check(keys == [6, 6, 8], "events below the watermark are dropped (single + batch + codex); got \(keys)")
            check(store.claudeWatermark() == wm && store.codexWatermark() == wm, "watermark accessors read the loaded value")
        }

        // 3. In-place replacement never unsorts `events` (single + batch paths), first-seen timestamp kept.
        do {
            wipe()
            let store = UsageStore()
            let t1 = today.addingTimeInterval(-30)       // yesterday 23:59:30 — an ESTIMATE
            let t0 = today.addingTimeInterval(5)         // an unrelated event just after midnight
            let t2 = today.addingTimeInterval(10)        // the exact line for the SAME message, after midnight
            store.addTranscriptEvent(claude(t1, out: 3, accuracy: .estimated), dedupKey: "m1:r1")
            store.addTranscriptEvent(claude(t0, out: 20), dedupKey: "other")
            store.addTranscriptEvent(claude(t2, out: 500), dedupKey: "m1:r1")
            pump()
            check(store.eventsAreSorted, "single path: events stay sorted after a later-stamped replacement")
            store.assertSorted()
            check(store.events.count == 2 && counted(store) == 522,
                  "single path: exact line replaced the estimate, nothing lost (counted \(counted(store)))")
            let kept = store.events.first { $0.outputTokens == 500 }
            check(kept?.timestamp == t1 && kept?.tokenAccuracy == .exact, "replacement keeps the FIRST-seen timestamp")
            check(store.totals(for: nil, in: .week).output == 520, "7-day total includes the replaced event (520)")
            store.addTranscriptEvent(claude(t2.addingTimeInterval(5), out: 4, accuracy: .estimated), dedupKey: "m1:r1")
            pump()
            check(store.events.count == 2 && store.events.contains { $0.outputTokens == 500 }, "a later weaker line cannot downgrade the replaced event")

            wipe()
            let b = UsageStore()
            b.ingest(batch: [(claude(t1, out: 3, accuracy: .estimated), "m1:r1"), (claude(t0, out: 20), "other")])
            pump()
            b.ingest(batch: [(claude(t2, out: 500), "m1:r1")])
            pump()
            check(b.eventsAreSorted && b.events.count == 2, "batch path: sorted after a later-stamped replacement")
            check(b.events.first { $0.outputTokens == 500 }?.timestamp == t1, "batch path keeps the first-seen timestamp")
            // repeats inside ONE batch fold the same way
            wipe()
            let c = UsageStore()
            c.ingest(batch: [(claude(t1, out: 3, accuracy: .estimated), "k"), (claude(t0, out: 20), "o"), (claude(t2, out: 500), "k")])
            pump()
            check(c.eventsAreSorted && c.events.count == 2 && c.events.first { $0.outputTokens == 500 }?.timestamp == t1,
                  "intra-batch repeat keeps first-seen timestamp")

            // Randomised stress over both paths.
            wipe()
            var rng = SystemRandomNumberGenerator()
            let r = UsageStore()
            let base = cutoff.addingTimeInterval(3600)
            for round in 0..<40 {
                var batch: [(event: UsageEvent, dedupKey: String)] = []
                for _ in 0..<Int.random(in: 1...25, using: &rng) {
                    let key = "k\(Int.random(in: 0..<60, using: &rng))"
                    let ts = base.addingTimeInterval(Double(Int.random(in: 0..<(20 * 86400), using: &rng)))
                    let out = Int.random(in: 1...400, using: &rng)
                    let acc: MetricAccuracy = Bool.random(using: &rng) ? .exact : .estimated
                    let ev = claude(ts, out: out, accuracy: acc)
                    batch.append((ev, key))
                    if round % 2 == 0 { r.addTranscriptEvent(ev, dedupKey: key) }
                }
                if round % 2 == 1 { r.ingest(batch: batch) }
                pump()
                if !r.eventsAreSorted { break }
            }
            check(r.eventsAreSorted, "randomised single+batch ingest/replace keeps events sorted")
            check(Set(r.events.map(\.id)).count == r.events.count, "no duplicate event ids after replacements")
        }


        // 4. Per-root history watermarks (schema 3): a root added on a later launch with files OLDER than
        //    root A's watermark backfills ADDITIVELY; a third launch changes nothing; an event below A's
        //    watermark arriving in A is dropped while the same-dated event in B is backfilled.
        do {
            wipe()
            let rootA = dir.appendingPathComponent("rootA/projects", isDirectory: true)
            let rootB = dir.appendingPathComponent("rootB/projects", isDirectory: true)
            let d20 = noon(cutoff, -20), d10 = noon(cutoff, -10), live = noon(today, -1)
            let k20 = UsageStore.dayKey(d20), k10 = UsageStore.dayKey(d10)
            // Legacy (schema 2) file: one shared Claude watermark at cutoff-15d.
            writeHistory(claudeThrough: noon(cutoff, -15))
            writeTranscript(rootA.appendingPathComponent("p/a.jsonl"),
                            [("a20", d20, 11), ("a10", d10, 100), ("alive", live, 7)], mtime: now)
            writeTranscript(rootB.appendingPathComponent("p/b.jsonl"),
                            [("b20", d20, 40), ("b10", d10, 25)], mtime: noon(cutoff, -17))
            writeTranscript(rootB.appendingPathComponent("p/b2.jsonl"), [("blive", live, 9)], mtime: now)
            func hist() -> HistoryFileMirror2 {
                try! JSONDecoder().decode(HistoryFileMirror2.self, from: Data(contentsOf: historyURL))
            }
            func claudeOut(_ s: UsageStore, _ k: String) -> Int? { s.history[k].map { $0.claudeOut } }

            // Launch 1: root A only. Upgrade seeds A with the shared watermark.
            let (s1, w1) = launch(roots: [(rootA, .primary)])
            check(claudeOut(s1, k10) == 100, "L1: A's day above its (seeded) watermark is backfilled (100)")
            check(s1.history[k20] == nil, "L1: A's event BELOW A's watermark is dropped (no \(k20) row)")
            check(s1.events.count == 1 && s1.events[0].outputTokens == 7, "L1: A's live event replayed")
            check(hist().schema == 3 && hist().rootCompleteThrough?[rootA.path] == cutoff.timeIntervalSince1970,
                  "L1: schema 3 + A's root watermark advanced to the cutoff")
            w1.stop()

            // Launch 2: B added; its files are older than A's watermark but B has no entry (starts at ancient).
            let (s2, w2) = launch(roots: [(rootA, .primary), (rootB, .cowork)])
            check(claudeOut(s2, k10) == 125, "L2: B's backfill is ADDITIVE onto A's day (100 + 25 = 125, got \(claudeOut(s2, k10) ?? -1))")
            check(claudeOut(s2, k20) == 40, "L2: same-dated event dropped in A is backfilled from B (40, got \(claudeOut(s2, k20) ?? -1))")
            check(s2.events.count == 2 && Set(s2.events.map(\.outputTokens)) == [7, 9], "L2: both roots' live events replayed, none duplicated")
            check(s2.rootHistoryCompleteThrough[rootB.path] == cutoff && s2.rootHistoryCompleteThrough[rootA.path] == cutoff,
                  "L2: both roots' watermarks at the cutoff")
            check(s2.historyCompleteThrough == cutoff, "L2: global watermark = min(root watermarks)")
            w2.stop()
            let bytes2 = try! Data(contentsOf: historyURL)
            let histBefore = s2.history

            // Launch 3: idempotent.
            let (s3, w3) = launch(roots: [(rootA, .primary), (rootB, .cowork)])
            check(s3.history == histBefore, "L3: history unchanged (no re-backfill)")
            check((try? Data(contentsOf: historyURL)) == bytes2, "L3: daily-history.json byte-identical")
            check(s3.events.count == 2, "L3: live window unchanged (2 events)")
            w3.stop()

            // A removed root keeps its watermark entry.
            let (s4, w4) = launch(roots: [(rootA, .primary)])
            check(s4.rootHistoryCompleteThrough[rootB.path] == cutoff && s4.history == histBefore, "L4: removed root keeps its entry, history unchanged")
            w4.stop()
            _ = (s1, s2, s3, s4)
        }

        // 5. Legacy upgrade never strands a schema-3 file without root entries, and Cowork is "never seen".
        do {
            wipe()
            let rootA = dir.appendingPathComponent("rootA/projects", isDirectory: true)
            let cow = dir.appendingPathComponent("cow", isDirectory: true)
            writeHistory(claudeThrough: noon(cutoff, -15))
            let store = UsageStore(); pump()
            check(store.resolveRootWatermarks(roots: [rootA.path, cow.path], seedLegacy: [rootA.path])[rootA.path] == noon(cutoff, -15),
                  "legacy: primary seeded with the shared watermark")
            check(store.resolveRootWatermarks(roots: [cow.path], seedLegacy: [])[cow.path] == nil, "legacy: Cowork root has no entry (starts at ancient)")
            // pure route() rule: per-root watermark decides
            let t = noon(cutoff, -12)
            check(HistoryFold.route(t, cutoff: cutoff, backfilling: true, backfillFrom: noon(cutoff, -15), watermark: noon(cutoff, -15)) == .backfill,
                  "route: event above the root's watermark backfills")
            check(HistoryFold.route(t, cutoff: cutoff, backfilling: true, backfillFrom: noon(cutoff, -10), watermark: noon(cutoff, -10)) == .drop,
                  "route: the same event below another root's watermark drops")
        }

        print(failures == 0 ? "store checks passed" : "store checks FAILED: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
