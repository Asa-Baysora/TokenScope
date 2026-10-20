import Foundation

/// Pure rules for Codex accounting and daily-history integrity. Kept free of
/// UsageStore/AppKit so tools/verify-codex.swift can exercise them directly.
enum CodexHistory {
    /// Bump when a stored-history defect needs a one-time repair.
    /// 1 = legacy (Codex days could be doubled by fold()/backfill overlap).
    /// 2 = Codex stripped once and rebuilt from rollout files.
    static let historySchema = 2

    /// OpenAI semantics: `cached_input_tokens` is a SUBSET of `input_tokens`.
    /// TokenScope stores cache separately and adds it back for cache-inclusive
    /// totals, so fresh input = input - cached (never negative).
    static func freshInput(input: Int, cached: Int) -> Int { max(input - cached, 0) }

    /// Backfill guard for one provider's watermark. Active only while the
    /// watermark is older than the live-window cutoff.
    static func backfillPlan(watermark: Date, cutoff: Date, ancient: Date) -> (from: Date, active: Bool) {
        let from = max(watermark, ancient)
        return (from, from < cutoff)
    }

    /// fold() advances only the watermark of providers that actually left the
    /// window. The Codex watermark is clamped to the whole-day cutoff: the
    /// 60k-event overflow fold can name a mid-window time that must not skip
    /// days which still replay live.
    static func advancedCodexWatermark(current: Date, through: Date, cutoff: Date, foldedCodex: Bool) -> Date {
        guard foldedCodex else { return current }
        return max(current, min(through, cutoff))
    }

    /// Stable per-observation key. Independent of the file path so a rollout
    /// moving between sessions/ and archived_sessions/ cannot double-count.
    static func dedupKey(sessionId: String, timestamp: String, totalInput: Int, totalOutput: Int) -> String {
        "codex:\(sessionId):\(timestamp):\(totalInput)/\(totalOutput)"
    }

    /// Session id used in keys: the rollout file-name stem
    /// (rollout-<ts>-<uuid>), identical in sessions/ and archived_sessions/ and
    /// available even when tailing from EOF (no session_meta line seen).
    static func sessionKey(fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    struct Total: Equatable {
        var input: Int, cached: Int, output: Int, reasoning: Int
    }

    /// Skips a token_count whose cumulative total equals the previous one in the
    /// same stream (Codex re-emits identical records).
    struct DuplicateGate {
        private var last: [String: Total] = [:]
        mutating func shouldCount(stream: String, total: Total?) -> Bool {
            guard let total else { return true }
            defer { last[stream] = total }
            return last[stream] != total
        }
        mutating func reset() { last = [:] }
    }

    /// One-time repair of schema<2 history: drop every Codex provider entry and
    /// subtract its calls from the day total; the caller resets the Codex
    /// watermark so the backfill rebuilds from rollout files. Claude untouched.
    static func stripCodex(_ days: [String: DayAgg]) -> [String: DayAgg] {
        var out: [String: DayAgg] = [:]
        let key = UsageOrigin.codex.rawValue
        for (k, var day) in days {
            if let codex = day.providers[key] {
                day.providers[key] = nil
                day.calls = max(day.calls - codex.calls, 0)
            }
            if day.providers.isEmpty && day.calls == 0 { continue }
            out[k] = day
        }
        return out
    }
}
