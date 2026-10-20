import Foundation

/// Framework-free Codex accuracy checks. Run with:
/// swiftc Sources/TokenScope/Models.swift Sources/TokenScope/CodexHistory.swift tools/verify-codex.swift -o /tmp/tokenscope-codex-checks && /tmp/tokenscope-codex-checks
@main
struct CodexChecks {
    static func expect(_ ok: Bool, _ msg: String) {
        if !ok { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); exit(1) }
    }

    static func event(_ p: UsageOrigin, input: Int, output: Int, cache: Int = 0) -> UsageEvent {
        UsageEvent(timestamp: Date(), provider: p, source: p == .codex ? .codexTranscript : .transcript,
                   model: "m", sessionId: "s", projectName: nil, inputTokens: input,
                   outputTokens: output, cacheReadTokens: cache, cacheCreationTokens: 0, reasoningTokens: 0)
    }

    static func main() {
        let day = 86400.0
        let ancient = Date(timeIntervalSince1970: 0)
        let cutoff = Date(timeIntervalSince1970: 1_000 * day)

        // Watermark advance on fold (clamped to the whole-day cutoff).
        let w0 = Date(timeIntervalSince1970: 900 * day)
        let adv = CodexHistory.advancedCodexWatermark(current: w0, through: cutoff, cutoff: cutoff, foldedCodex: true)
        expect(adv == cutoff, "fold advances the Codex watermark to the cutoff")
        let mid = Date(timeIntervalSince1970: 1_010 * day)
        expect(CodexHistory.advancedCodexWatermark(current: w0, through: mid, cutoff: cutoff, foldedCodex: true) == cutoff,
               "overflow fold cannot push the Codex watermark past the whole-day cutoff")
        expect(CodexHistory.advancedCodexWatermark(current: w0, through: cutoff, cutoff: cutoff, foldedCodex: false) == w0,
               "a fold with no Codex events leaves the Codex watermark alone")
        expect(CodexHistory.advancedCodexWatermark(current: cutoff, through: w0, cutoff: cutoff, foldedCodex: true) == cutoff,
               "watermark never moves backwards")

        // Per-provider backfill guard: after fold the next launch must not backfill.
        expect(!CodexHistory.backfillPlan(watermark: adv, cutoff: cutoff, ancient: ancient).active,
               "no Codex backfill once the watermark reached the cutoff")
        let stale = CodexHistory.backfillPlan(watermark: w0, cutoff: cutoff, ancient: ancient)
        expect(stale.active && stale.from == w0, "stale Codex watermark backfills from itself")
        // Guard is a pure function of ONE provider's watermark: a Claude watermark
        // at the cutoff must not suppress an older Codex gap.
        let claudeWM = cutoff
        expect(!CodexHistory.backfillPlan(watermark: claudeWM, cutoff: cutoff, ancient: ancient).active
               && CodexHistory.backfillPlan(watermark: w0, cutoff: cutoff, ancient: ancient).active,
               "backfill guard is per provider")

        // Input excludes cached (cached is a subset of input).
        expect(CodexHistory.freshInput(input: 19_750, cached: 10_496) == 9_254, "fresh input = input - cached")
        expect(CodexHistory.freshInput(input: 100, cached: 150) == 0, "fresh input clamps at zero")
        var agg = DayAgg()
        agg.add(event(.codex, input: CodexHistory.freshInput(input: 19_750, cached: 10_496), output: 210, cache: 10_496))
        expect(agg.codexWithCache == 19_750 + 210, "cache-inclusive total equals raw input + output, counted once")

        // Duplicate token_count skip.
        var gate = CodexHistory.DuplicateGate()
        let t1 = CodexHistory.Total(input: 10, cached: 4, output: 2, reasoning: 1)
        let t2 = CodexHistory.Total(input: 30, cached: 8, output: 5, reasoning: 2)
        expect(gate.shouldCount(stream: "a", total: t1), "first record counts")
        expect(!gate.shouldCount(stream: "a", total: t1), "identical consecutive total is skipped")
        expect(gate.shouldCount(stream: "a", total: t2), "changed total counts")
        expect(gate.shouldCount(stream: "a", total: t1), "non-consecutive repeat is not a duplicate")
        expect(gate.shouldCount(stream: "b", total: t1), "streams are independent")
        expect(gate.shouldCount(stream: "a", total: nil), "records without a total are never skipped")
        gate.reset()
        expect(gate.shouldCount(stream: "a", total: t1), "reset clears the gate for replays")

        // sessions/ -> archived_sessions/ move yields identical keys.
        let name = "rollout-2026-07-09T14-32-30-019f4894-f7c2-7a71-9598-d3318a821429.jsonl"
        let live = URL(fileURLWithPath: "/h/.codex/sessions/2026/07/09/\(name)")
        let archived = URL(fileURLWithPath: "/h/.codex/archived_sessions/\(name)")
        func key(_ u: URL) -> String {
            CodexHistory.dedupKey(sessionId: CodexHistory.sessionKey(fileName: u.lastPathComponent),
                                  timestamp: "2026-07-09T20:32:38.098Z", totalInput: 19_750, totalOutput: 210)
        }
        expect(key(live) == key(archived), "move between roots keeps the dedup key")
        expect(key(live) != CodexHistory.dedupKey(sessionId: CodexHistory.sessionKey(fileName: live.lastPathComponent),
               timestamp: "2026-07-09T20:32:42.260Z", totalInput: 39_922, totalOutput: 382),
               "different observations get different keys")

        // One-time repair strips Codex only; Claude and its calls are untouched.
        var doubled = DayAgg()
        doubled.add(event(.claudeCode, input: 5, output: 5))
        doubled.add(event(.codex, input: 100, output: 10)); doubled.add(event(.codex, input: 100, output: 10))
        var codexOnly = DayAgg()
        codexOnly.add(event(.codex, input: 1, output: 1))
        let fixed = CodexHistory.stripCodex(["2026-06-01": doubled, "2026-06-02": codexOnly])
        expect(fixed["2026-06-01"]?.codex == 0 && fixed["2026-06-01"]?.claude == 10
               && fixed["2026-06-01"]?.calls == 1, "repair removes Codex, keeps Claude and recomputes calls")
        expect(fixed["2026-06-02"] == nil, "repair drops days left empty")
        expect(CodexHistory.historySchema >= 2, "history schema marker bumped")

        print("codex checks passed")
    }
}
