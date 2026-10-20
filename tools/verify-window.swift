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

        try expect(StatsPeriod.allCases.allSatisfy { $0.days <= HistoryFold.retentionDays },
                   "no stats period reaches past the live events window")

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

        // 4. Overflow folds WHOLE calendar days (oldest first), never a slice of a day.
        let wm = Date(timeIntervalSince1970: 1_000)
        func dayStart(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: cutoff)! }
        var evs: [UsageEvent] = []
        var keys: [String: UUID] = [:]
        // day0: 2 claude + 1 codex, day1: 4 claude, day2: 3 claude  (10 total, sorted)
        let layout: [(Int, UsageOrigin)] = [(0, .claudeCode), (0, .codex), (0, .claudeCode),
                                            (1, .claudeCode), (1, .claudeCode), (1, .claudeCode), (1, .claudeCode),
                                            (2, .claudeCode), (2, .claudeCode), (2, .claudeCode)]
        for (i, (day, p)) in layout.enumerated() {
            let e = ev(dayStart(day).addingTimeInterval(3600 + Double(i) * 60), p)
            evs.append(e); keys["k\(i)"] = e.id
        }
        try expect(HistoryFold.overflowCap == 150_000, "overflow cap is 150k")
        var w = HistoryFold.Window(events: evs, keyIDs: keys, history: [:], claudeThrough: wm, codexThrough: wm)
        // cap 8: 10 events; trimming 2 would split day0 (3 events) — the whole day folds instead.
        var r = HistoryFold.trim(&w, cutoff: cutoff, cap: 8, calendar: cal, dayKey: key)
        try expect(r.folded == 3 && w.events.count == 7, "cap 8 folds the whole oldest day (3), not a 2-event slice")
        try expect(w.events.allSatisfy { $0.timestamp >= dayStart(1) }, "no event of the folded day stays live")
        try expect(w.keyIDs.keys.sorted() == ["k3", "k4", "k5", "k6", "k7", "k8", "k9"], "folded keys removed from dedup map")
        try expect(w.claudeThrough == dayStart(1) && w.codexThrough == dayStart(1),
                   "watermarks advance to the end of the folded day (codex folded too)")
        let d0 = w.history[key(dayStart(0))]!
        try expect(d0.calls == 3 && d0.providers[UsageOrigin.codex.rawValue]?.calls == 1, "day0 folded completely, once")
        try expect(r.conflicts.isEmpty, "whole-day fold never max-merges")
        // Restart: replaying the folded day's transcript lines must be dropped by the watermark,
        // even though the watermark sits ABOVE the live cutoff; the next day still goes live.
        try expect(HistoryFold.route(dayStart(0).addingTimeInterval(3600), cutoff: cutoff, backfilling: false,
                                     backfillFrom: w.claudeThrough, watermark: w.claudeThrough) == .drop,
                   "replayed folded-day event (>= cutoff, < watermark) is dropped")
        try expect(HistoryFold.route(dayStart(1).addingTimeInterval(60), cutoff: cutoff, backfilling: false,
                                     backfillFrom: w.claudeThrough, watermark: w.claudeThrough) == .live,
                   "first unfolded day goes live")
        // Fold again with a lower cap: folds day1 whole; Codex watermark stays (no codex folded).
        r = HistoryFold.trim(&w, cutoff: cutoff, cap: 5, calendar: cal, dayKey: key)
        try expect(r.folded == 4 && w.events.count == 3 && w.claudeThrough == dayStart(2) && w.codexThrough == dayStart(1),
                   "second overflow folds day1; codex watermark only moves when codex folded")
        // A single over-cap day is never folded (the newest day stays live).
        var w3 = HistoryFold.Window(events: Array(evs.suffix(3)), keyIDs: [:], history: [:], claudeThrough: wm, codexThrough: wm)
        r = HistoryFold.trim(&w3, cutoff: cutoff, cap: 1, calendar: cal, dayKey: key)
        try expect(r.folded == 0 && w3.events.count == 3 && w3.claudeThrough == wm, "newest day is never folded, even over cap")
        // Within cap: nothing happens.
        var w4 = HistoryFold.Window(events: evs, keyIDs: keys, history: [:], claudeThrough: wm, codexThrough: wm)
        r = HistoryFold.trim(&w4, cutoff: cutoff, calendar: cal, dayKey: key)
        try expect(r.folded == 0 && w4.claudeThrough == wm, "under the 150k cap nothing folds")

        // 4b. Routing: normal backfill gap, watermark above the cutoff, and drops.
        let ago40 = cutoff.addingTimeInterval(-86400 * 12)
        try expect(HistoryFold.route(ago40, cutoff: cutoff, backfilling: true, backfillFrom: ago40.addingTimeInterval(-60), watermark: ago40.addingTimeInterval(-60)) == .backfill,
                   "gap event goes to backfill")
        try expect(HistoryFold.route(ago40, cutoff: cutoff, backfilling: false, backfillFrom: cutoff, watermark: cutoff) == .drop,
                   "no backfill: pre-cutoff event dropped")
        try expect(HistoryFold.route(dayStart(1), cutoff: cutoff, backfilling: true, backfillFrom: ago40, watermark: ago40) == .live,
                   "in-window event with an old watermark goes live")
        let wmAbove = dayStart(2)   // watermark above the cutoff (post-overflow); backfilling is false then
        try expect(!(wmAbove < cutoff), "fixture: watermark above cutoff")
        try expect(HistoryFold.route(dayStart(1), cutoff: cutoff, backfilling: wmAbove < cutoff, backfillFrom: wmAbove, watermark: wmAbove) == .drop
                   && HistoryFold.route(wmAbove, cutoff: cutoff, backfilling: false, backfillFrom: wmAbove, watermark: wmAbove) == .live,
                   "watermark above cutoff: [cutoff, watermark) dropped, watermark.. live")

        // 4c. Journal partition honors the watermark: a record in a day already folded at runtime
        // (cutoff <= ts < watermark) is dropped, not kept live and not folded again.
        let inFoldedDay = ev(dayStart(1).addingTimeInterval(120))
        let afterFold = ev(dayStart(2).addingTimeInterval(120))
        let p4 = HistoryFold.partitionJournal(["f": inFoldedDay, "n": afterFold, "o": aged], cutoff: cutoff, foldedThrough: dayStart(2))
        try expect(p4.live.keys.sorted() == ["n"] && p4.aged.count == 1 && p4.dropped == 1,
                   "partition: live after watermark, folded-day record dropped, aged folds")

        // 5. Whole-day age-out advances watermarks to (not past) the cutoff and drops keys.
        let old = ev(cutoff.addingTimeInterval(-3600), .codex)
        var w2 = HistoryFold.Window(events: [old, ev(cutoff.addingTimeInterval(3600))], keyIDs: ["old": old.id], history: [:], claudeThrough: wm, codexThrough: wm)
        HistoryFold.trim(&w2, cutoff: cutoff, cap: 6, calendar: cal, dayKey: key)
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
