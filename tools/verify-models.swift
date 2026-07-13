import Foundation

/// Framework-free regression checks for the pure data model. Run with:
/// swiftc Sources/TokenScope/Models.swift tools/verify-models.swift -o /tmp/tokenscope-model-checks && /tmp/tokenscope-model-checks
@main
struct ModelChecks {
    static func main() throws {
        let legacy = Data("""
        {"claudeIn":11,"claudeOut":7,"ollamaIn":5,"ollamaOut":3,"calls":2}
        """.utf8)
        let day = try JSONDecoder().decode(DayAgg.self, from: legacy)
        try expect(day.claude == 18 && day.ollama == 8 && day.codex == 0 && day.total == 26,
                   "legacy DayAgg migration")

        let event = UsageEvent(
            timestamp: Date(), provider: .codex, source: .codexTranscript,
            model: "Codex", sessionId: "session", projectName: nil,
            inputTokens: 120, outputTokens: 30, cacheReadTokens: 80,
            cacheCreationTokens: 0, reasoningTokens: 12)
        var totals = Totals()
        totals.add(event)
        var codexDay = DayAgg()
        codexDay.add(event)
        try expect(totals.input == 120 && totals.output == 30 && totals.cacheRead == 80 && totals.reasoning == 12,
                   "Codex totals retain cache/reasoning detail")
        try expect(codexDay.codex == 150 && codexDay.total == 150,
                   "Codex headline total excludes cache/reasoning subsets")

        let encoded = try JSONEncoder().encode(codexDay)
        let roundTrip = try JSONDecoder().decode(DayAgg.self, from: encoded)
        try expect(roundTrip == codexDay && roundTrip.providers[UsageOrigin.codex.rawValue]?.reasoning == 12,
                   "provider-keyed DayAgg round trip")

        let operational = UsageEvent(
            timestamp: Date(timeIntervalSince1970: 20), startedAt: Date(timeIntervalSince1970: 19),
            provider: .ollama, source: .proxy, model: "qwen", sessionId: nil,
            projectName: nil, inputTokens: 8, outputTokens: 5, cacheReadTokens: 0,
            cacheCreationTokens: 0, reasoningTokens: 1, tokenAccuracy: .estimated,
            operation: .responses, status: .failed, executionLocation: .cloud,
            endpoint: "/v1/responses", requestId: "resp_1", httpStatus: 502,
            finishReason: "error", errorCategory: "bad_gateway", durationSeconds: 1.2)
        let decoded = try JSONDecoder().decode(UsageEvent.self, from: JSONEncoder().encode(operational))
        try expect(decoded == operational, "operational UsageEvent round trip")

        let partial = UsageEvent(
            timestamp: Date(timeIntervalSince1970: 30), provider: .ollama,
            source: .transcript, model: "qwen", sessionId: "s", projectName: nil,
            inputTokens: 100, outputTokens: 0, cacheReadTokens: 0,
            cacheCreationTokens: 0, reasoningTokens: 0)
        let final = UsageEvent(
            timestamp: Date(timeIntervalSince1970: 31), provider: .ollama,
            source: .transcript, model: "qwen", sessionId: "s", projectName: nil,
            inputTokens: 100, outputTokens: 200, cacheReadTokens: 0,
            cacheCreationTokens: 0, reasoningTokens: 0)
        try expect(EventReconciler.preferred(partial, final).outputTokens == 200,
                   "final transcript rewrite replaces partial usage")
        try expect(EventReconciler.preferred(final, partial).outputTokens == 200,
                   "partial replay cannot replace final usage")

        try expect(CodexTrackingPolicy.tracksLocalSessionTokens(cookieLimitsSelected: true)
                   && CodexTrackingPolicy.tracksLocalSessionTokens(cookieLimitsSelected: false),
                   "Codex local tokens remain active with cookie or local limits")

        let desktopObservation = OllamaDesktopObservation(
            rowID: 42, chatID: "chat-1", model: "gemma4:12b-mlx",
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 108))
        let desktopEvent = desktopObservation.event
        try expect(desktopEvent.source == .ollamaDesktop && desktopEvent.tokenAccuracy == .unknown
                   && desktopEvent.inputTokens == 0 && desktopEvent.outputTokens == 0
                   && desktopEvent.durationSeconds == 8 && desktopEvent.model == "gemma4:12b-mlx",
                   "Ollama Desktop metadata never invents token counts")
        let proxyCounterpart = UsageEvent(
            timestamp: Date(timeIntervalSince1970: 108.5),
            startedAt: Date(timeIntervalSince1970: 100.5), provider: .ollama,
            source: .proxy, model: "gemma4:12b-mlx", sessionId: nil, projectName: nil,
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
            cacheCreationTokens: 0, reasoningTokens: 0, durationSeconds: 8)
        try expect(EventReconciler.desktopAndProxyOverlap(desktopEvent, proxyCounterpart),
                   "matching Ollama Desktop and proxy observations reconcile")

        let performanceEvents = [
            UsageEvent(timestamp: Date(), provider: .ollama, source: .proxy, model: "qwen",
                       sessionId: nil, projectName: nil, inputTokens: 1, outputTokens: 2,
                       cacheReadTokens: 0, cacheCreationTokens: 0, reasoningTokens: 0,
                       tokenAccuracy: .estimated, durationSeconds: 4, timeToFirstTokenSeconds: 0.2,
                       tokensPerSecond: 10),
            UsageEvent(timestamp: Date(), provider: .ollama, source: .proxy, model: "qwen",
                       sessionId: nil, projectName: nil, inputTokens: 1, outputTokens: 2,
                       cacheReadTokens: 0, cacheCreationTokens: 0, reasoningTokens: 0,
                       status: .failed, durationSeconds: 2, timeToFirstTokenSeconds: 0.4,
                       tokensPerSecond: 30),
            UsageEvent(timestamp: Date(), provider: .lmStudio, source: .lmStudioLog, model: "gemma",
                       sessionId: nil, projectName: nil, inputTokens: 3, outputTokens: 4,
                       cacheReadTokens: 0, cacheCreationTokens: 0, reasoningTokens: 0,
                       tokensPerSecond: 50),
        ]
        let summaries = PerformanceAggregator.summarize(performanceEvents)
        let ollama = summaries.first { $0.provider == .ollama }
        try expect(ollama?.calls == 2 && ollama?.succeeded == 1 && ollama?.failed == 1 &&
                   ollama?.estimated == 1 && ollama?.unknownTokens == 0 && ollama?.medianTokensPerSecond == 20 &&
                   close(ollama?.medianTimeToFirstTokenSeconds, 0.3) && ollama?.medianDurationSeconds == 3,
                   "provider-neutral performance aggregation")
        try expect(summaries.first { $0.provider == .lmStudio }?.medianTokensPerSecond == 50,
                   "LM Studio uses the shared performance aggregation")
        try expect(PerformanceAggregator.median([]) == nil && PerformanceAggregator.median([1, 3, 2]) == 2,
                   "median boundaries")
        print("model checks passed")
    }

    private static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw CheckError.failed(name) }
    }

    private static func close(_ value: Double?, _ expected: Double, tolerance: Double = 0.000_001) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    enum CheckError: Error { case failed(String) }
}
