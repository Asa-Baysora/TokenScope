import Foundation

/// Framework-free checks for the live window, fold and local-journal logic. Run via
/// scripts/verify-redesign.sh (Models + CodexHistory + HistoryFold + this file).
@main
struct WindowChecks {
    static var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }()
    static func key(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    static func ev(_ t: Date, _ p: UsageOrigin = .ollama, out: Int = 10, shadowed: Bool = false) -> UsageEvent {
        var e = UsageEvent(timestamp: t, provider: p, source: p == .codex ? .codexTranscript : .proxy,
                           model: "m", sessionId: nil, projectName: nil, inputTokens: 5, outputTokens: out,
                           cacheReadTokens: 2, cacheCreationTokens: 1, reasoningTokens: 0)
        e.shadowed = shadowed
        return e
    }

    static func main() throws {
        // 1. 28-day cutoff is whole-day, independent of time of day.
        try expect(HistoryFold.retentionDays == 28, "retention is 28")
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 42, second: 7))!
        let cutoff = HistoryFold.cutoff(now: now, calendar: cal)
        try expect(cutoff == cal.date(from: DateComponents(year: 2026, month: 9, day: 21))!, "cutoff = startOfDay - 28d")
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0, minute: 0, second: 1))!
        try expect(HistoryFold.cutoff(now: morning, calendar: cal) == cutoff, "cutoff does not roll with time of day")

        // 2. Aged-out journal record folds into history exactly once across two loads.
        let aged = ev(cutoff.addingTimeInterval(-86400 * 2 + 3600))
        let live = ev(cutoff.addingTimeInterval(3600))
        let journal = ["a": aged, "b": live]
        var history: [String: DayAgg] = [:]
        var split = HistoryFold.partitionJournal(journal, cutoff: cutoff)
        try expect(split.live.keys.sorted() == ["b"] && split.aged.count == 1, "partition aged vs live")
        let c1 = HistoryFold.fold(split.aged, into: &history, dayKey: key)
        let dk = key(aged.timestamp)
        try expect(c1.isEmpty && history[dk]?.ollama == 10 + 5 && history[dk]?.calls == 1, "first load folds once")
        // Second load: journal was compacted to live only, nothing to fold.
        split = HistoryFold.partitionJournal(split.live, cutoff: cutoff)
        try expect(split.aged.isEmpty, "compacted journal has nothing aged")
        // Even if the rewrite was lost and the aged record is seen again, no double add.
        let before = history
        let c2 = HistoryFold.fold([aged], into: &history, dayKey: key)
        try expect(history == before && c2 == ["\(dk)/ollama"], "re-fold of same record is idempotent (max)")
        // Boundary: exactly at cutoff is live (matches trim's < cutoff).
        try expect(HistoryFold.partitionJournal(["x": ev(cutoff)], cutoff: cutoff).live.count == 1, "cutoff instant is live")
        // Shadowed records never fold.
        var h2: [String: DayAgg] = [:]
        HistoryFold.fold([ev(aged.timestamp, shadowed: true)], into: &h2, dayKey: key)
        try expect(h2.isEmpty, "shadowed not folded")

        // 3. Same day/provider merge takes the max per field, other providers unaffected.
        var h3: [String: DayAgg] = [:]
        var existing = DayAgg()
        existing.providers[UsageOrigin.ollama.rawValue] = ProviderDayAgg(input: 100, output: 3, cache: 0, reasoning: 0, calls: 4)
        existing.providers[UsageOrigin.claudeCode.rawValue] = ProviderDayAgg(input: 7, output: 7, cache: 7, reasoning: 0, calls: 1)
        existing.calls = 5
        h3[dk] = existing
        let conf = HistoryFold.fold([ev(aged.timestamp, out: 50), ev(aged.timestamp, out: 50)], into: &h3, dayKey: key)
        let o = h3[dk]!.providers[UsageOrigin.ollama.rawValue]!
        try expect(conf == ["\(dk)/ollama"] && o.input == 100 && o.output == 100 && o.cache == 6 && o.calls == 4,
                   "max per field, not sum")
        try expect(h3[dk]!.providers[UsageOrigin.claudeCode.rawValue]!.input == 7 && h3[dk]!.calls == 5, "other provider and calls untouched")

        // 4. Overflow fold removes dedup keys and leaves both watermarks alone.
        var evs: [UsageEvent] = []
        var keys: [String: UUID] = [:]
        let base = cutoff.addingTimeInterval(3600)
        for i in 0..<10 {
            let e = ev(base.addingTimeInterval(Double(i) * 60), i < 3 ? .codex : .claudeCode)
            evs.append(e); keys["k\(i)"] = e.id
        }
        let wm = Date(timeIntervalSince1970: 1_000)
        var w = HistoryFold.Window(events: evs, keyIDs: keys, history: [:], claudeThrough: wm, codexThrough: wm)
        let r = HistoryFold.trim(&w, cutoff: cutoff, cap: 6, dayKey: key)
        try expect(r.folded == 4 && w.events.count == 6, "overflow folds oldest 4")
        try expect(w.keyIDs.keys.sorted() == ["k4", "k5", "k6", "k7", "k8", "k9"], "folded keys removed from dedup map")
        try expect(w.claudeThrough == wm && w.codexThrough == wm, "overflow leaves watermarks alone")
        try expect(!w.history.isEmpty, "overflow still folds data")

        // 5. Whole-day age-out advances watermarks to (not past) the cutoff and drops keys.
        let old = ev(cutoff.addingTimeInterval(-3600), .codex)
        var w2 = HistoryFold.Window(events: [old, ev(base)], keyIDs: ["old": old.id], history: [:], claudeThrough: wm, codexThrough: wm)
        HistoryFold.trim(&w2, cutoff: cutoff, cap: 6, dayKey: key)
        try expect(w2.claudeThrough == cutoff && w2.codexThrough == cutoff && w2.keyIDs.isEmpty && w2.events.count == 1,
                   "age-out advances watermarks to cutoff and drops keys")

        // 6. Shrink 31 -> 28: days between the old and new cutoff are NOT in history (watermark = old
        // cutoff), so the transcript backfill (watermark..cutoff) covers them once, and local journal
        // records in that gap fold via the journal path once.
        let oldCutoff = HistoryFold.cutoff(now: now, calendar: cal, retentionDays: 31)
        try expect(oldCutoff < cutoff && cutoff.timeIntervalSince(oldCutoff) >= 3 * 86400 - 3700, "31d cutoff precedes 28d cutoff")
        let gap = ev(oldCutoff.addingTimeInterval(86400 + 60))
        var h6: [String: DayAgg] = [:]
        let s6 = HistoryFold.partitionJournal(["g": gap], cutoff: cutoff)
        HistoryFold.fold(s6.aged, into: &h6, dayKey: key)
        try expect(s6.live.isEmpty && h6[key(gap.timestamp)]?.calls == 1, "gap-day journal record folds once on upgrade")

        print("window checks passed")
    }

    private static func expect(_ c: Bool, _ name: String) throws {
        guard c else { throw CheckError.failed(name) }
    }
    enum CheckError: Error { case failed(String) }
}
