import Foundation

/// Pure window/fold/journal logic for `UsageStore`, kept free of SwiftUI, files
/// and clocks so `tools/verify-window.swift` can exercise it directly.
enum HistoryFold {
    /// Whole days kept live. Claude Code deletes transcripts by mtime at about 30
    /// days (cleanupPeriodDays), so the live window must end well before that:
    /// a day we still replay from disk must never have lost files yet.
    static let retentionDays = 28

    /// In-memory event cap. Overflow folds whole calendar days (oldest first), never
    /// slices of a day, so it only ever triggers on a truly extreme window.
    static let overflowCap = 150_000

    /// Whole-day cutoff: startOfDay(now) − retentionDays. Never a rolling timestamp.
    static func cutoff(now: Date, calendar: Calendar = .current, retentionDays: Int = HistoryFold.retentionDays) -> Date {
        calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(-Double(retentionDays) * 86400)
    }

    /// Folds events into per-day history. Per (day, provider): if history already
    /// holds that bucket (a replayed overflow fold, or a journal record that was
    /// already folded at runtime) the fold MERGES BY MAX PER FIELD instead of
    /// summing, so re-folding the same events is idempotent. Shadowed events are
    /// skipped. Returns one description per max-merged bucket, for logging.
    @discardableResult
    static func fold(_ events: [UsageEvent], into history: inout [String: DayAgg],
                     dayKey: (Date) -> String) -> [String] {
        var fresh: [String: [String: ProviderDayAgg]] = [:]   // day -> provider -> agg
        for e in events where !e.shadowed {
            var p = fresh[dayKey(e.timestamp), default: [:]][e.provider.rawValue] ?? ProviderDayAgg()
            p.input += e.inputTokens
            p.output += e.outputTokens
            p.cache += e.cacheReadTokens + e.cacheCreationTokens
            p.reasoning += e.reasoningTokens
            p.calls += 1
            fresh[dayKey(e.timestamp), default: [:]][e.provider.rawValue] = p
        }
        var conflicts: [String] = []
        for (day, providers) in fresh.sorted(by: { $0.key < $1.key }) {
            var d = history[day] ?? DayAgg()
            for (provider, add) in providers.sorted(by: { $0.key < $1.key }) {
                let old = d.providers[provider]
                var merged = add
                if let old {
                    merged = ProviderDayAgg(
                        input: max(old.input, add.input), output: max(old.output, add.output),
                        cache: max(old.cache, add.cache), reasoning: max(old.reasoning, add.reasoning),
                        calls: max(old.calls, add.calls))
                    conflicts.append("\(day)/\(provider)")
                }
                d.calls += merged.calls - (old?.calls ?? 0)
                d.providers[provider] = merged
            }
            history[day] = d
        }
        return conflicts
    }

    /// Splits journal records at the whole-day cutoff. `>= cutoff` is live,
    /// consistent with trim()'s `< cutoff` age-out. A record at or after the cutoff
    /// but BEFORE `foldedThrough` (the Claude watermark, which an overflow fold can
    /// push past the cutoff) belongs to a day that was already folded into history
    /// at runtime: it is dropped (`dropped`), not kept live and not folded again.
    static func partitionJournal(_ records: [String: UsageEvent], cutoff: Date,
                                 foldedThrough: Date = .distantPast)
        -> (live: [String: UsageEvent], aged: [UsageEvent], dropped: Int) {
        var live: [String: UsageEvent] = [:]
        var aged: [UsageEvent] = []
        var dropped = 0
        for (k, e) in records {
            if e.timestamp < cutoff { aged.append(e) }
            else if e.timestamp < foldedThrough { dropped += 1 }
            else { live[k] = e }
        }
        return (live, aged.sorted { $0.timestamp < $1.timestamp }, dropped)
    }

    /// Where a freshly parsed transcript event goes. `watermark` is the persisted
    /// history watermark (`backfillFrom` in the watchers). It is authoritative: an
    /// event below it is already inside history, even when the watermark sits ABOVE
    /// the live cutoff (an overflow fold advanced it), so it must not go live.
    enum Route: Equatable { case live, backfill, drop }

    static func route(_ timestamp: Date, cutoff: Date, backfilling: Bool,
                      backfillFrom: Date, watermark: Date) -> Route {
        if timestamp >= cutoff { return timestamp < watermark ? .drop : .live }
        if backfilling, timestamp >= backfillFrom { return .backfill }
        return .drop
    }

    struct Window {
        var events: [UsageEvent]
        var keyIDs: [String: UUID]
        var history: [String: DayAgg]
        var claudeThrough: Date
        var codexThrough: Date
    }

    /// Age-out + overflow trim. Whole-day age-out folds and advances the
    /// watermarks (Claude to the cutoff, Codex clamped to it). The overflow fold
    /// takes the oldest WHOLE calendar day(s) (every event of that day, so history
    /// and the live window never share a day and nothing is max-merged into a
    /// partial bucket) and advances the watermarks to the end of the last folded
    /// day (Codex only if a Codex event was folded, as for age-out: its watermark
    /// doubles as "never backfilled"). The newest event's day is never folded, so
    /// a single over-cap day just stays live. Both paths drop the folded events'
    /// dedup keys. Requires `w.events` sorted. Returns (folded count, max-merged
    /// buckets).
    @discardableResult
    static func trim(_ w: inout Window, cutoff: Date, cap: Int = HistoryFold.overflowCap,
                     calendar: Calendar = .current,
                     dayKey: (Date) -> String) -> (folded: Int, conflicts: [String]) {
        var folded = 0
        var conflicts: [String] = []
        func dropKeys(_ removed: [UsageEvent]) {
            let ids = Set(removed.map(\.id))
            w.keyIDs = w.keyIDs.filter { !ids.contains($0.value) }
        }
        if let first = w.events.first, first.timestamp < cutoff {
            let removed = w.events.filter { $0.timestamp < cutoff }
            w.events.removeAll { $0.timestamp < cutoff }
            conflicts += fold(removed, into: &w.history, dayKey: dayKey)
            dropKeys(removed)
            w.claudeThrough = max(w.claudeThrough, cutoff)
            w.codexThrough = CodexHistory.advancedCodexWatermark(
                current: w.codexThrough, through: cutoff, cutoff: cutoff,
                foldedCodex: removed.contains { !$0.shadowed && $0.provider == .codex })
            folded += removed.count
        }
        while w.events.count > cap, let first = w.events.first, let last = w.events.last {
            let dayStart = calendar.startOfDay(for: first.timestamp)
            guard calendar.startOfDay(for: last.timestamp) > dayStart,
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            var n = 0
            while n < w.events.count, w.events[n].timestamp < dayEnd { n += 1 }
            let removed = Array(w.events.prefix(n))
            w.events.removeFirst(n)
            conflicts += fold(removed, into: &w.history, dayKey: dayKey)
            dropKeys(removed)
            w.claudeThrough = max(w.claudeThrough, dayEnd)
            w.codexThrough = CodexHistory.advancedCodexWatermark(
                current: w.codexThrough, through: dayEnd, cutoff: dayEnd,
                foldedCodex: removed.contains { !$0.shadowed && $0.provider == .codex })
            folded += n
        }
        return (folded, conflicts)
    }
}
