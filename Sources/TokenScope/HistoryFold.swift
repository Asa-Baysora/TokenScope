import Foundation

/// Pure window/fold/journal logic for `UsageStore`, kept free of SwiftUI, files
/// and clocks so `tools/verify-window.swift` can exercise it directly.
enum HistoryFold {
    /// Whole days kept live. Claude Code deletes transcripts by mtime at about 30
    /// days (cleanupPeriodDays), so the live window must end well before that:
    /// a day we still replay from disk must never have lost files yet.
    static let retentionDays = 28

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
    /// consistent with trim()'s `< cutoff` age-out.
    static func partitionJournal(_ records: [String: UsageEvent], cutoff: Date)
        -> (live: [String: UsageEvent], aged: [UsageEvent]) {
        var live: [String: UsageEvent] = [:]
        var aged: [UsageEvent] = []
        for (k, e) in records {
            if e.timestamp >= cutoff { live[k] = e } else { aged.append(e) }
        }
        return (live, aged.sorted { $0.timestamp < $1.timestamp })
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
    /// names a mid-window time, so it advances NEITHER watermark. Both paths drop
    /// the folded events' dedup keys so a later line with the same key cannot
    /// re-append the event. Returns (folded count, max-merged buckets).
    @discardableResult
    static func trim(_ w: inout Window, cutoff: Date, cap: Int = 60_000,
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
        if w.events.count > cap {
            let removed = Array(w.events.prefix(w.events.count - cap))
            w.events.removeFirst(w.events.count - cap)
            conflicts += fold(removed, into: &w.history, dayKey: dayKey)
            dropKeys(removed)
            folded += removed.count
        }
        return (folded, conflicts)
    }
}
