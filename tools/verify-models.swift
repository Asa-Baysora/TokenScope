import Foundation

/// Framework-free regression checks for the pure data model. Run with:
/// swiftc Sources/TokenScope/Models.swift Sources/TokenScope/LimitRailPresentation.swift tools/verify-models.swift -o /tmp/tokenscope-model-checks && /tmp/tokenscope-model-checks
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

        let modelSummaries = PerformanceAggregator.summarizeByModel(performanceEvents)
        let qwen = modelSummaries.first { $0.model == "qwen" }
        try expect(qwen?.calls == 2 && qwen?.failed == 1 && qwen?.medianTokensPerSecond == 20
                   && close(qwen?.medianTimeToFirstTokenSeconds, 0.3),
                   "per-model performance aggregation")

        let rail = [
            LimitRailReading(id: "claude-secondary", provider: .claude, period: .secondary,
                             label: "Claude 7d", utilization: 85, resetsAt: nil),
            LimitRailReading(id: "codex-primary", provider: .codex, period: .primary,
                             label: "Codex 5h", utilization: 60, resetsAt: nil),
            LimitRailReading(id: "claude-primary", provider: .claude, period: .primary,
                             label: "Claude 5h", utilization: 85.1, resetsAt: nil),
        ]
        try expect(LimitRailPresentation.ordered(rail).map(\.id) ==
                   ["codex-primary", "claude-primary", "claude-secondary"],
                   "limit rail collapses missing windows while retaining canonical order")
        let withoutCodexPrimary = LimitRailPresentation.ordered(rail.filter { $0.id != "codex-primary" })
        let withoutClaudeSecondary = LimitRailPresentation.ordered(rail.filter { $0.id != "claude-secondary" })
        try expect(withoutCodexPrimary.map(\.id) == ["claude-primary", "claude-secondary"]
                   && withoutClaudeSecondary.map(\.id) == ["codex-primary", "claude-primary"],
                   "any unavailable Codex or Claude window closes its rail gap")
        try expect(LimitRailPresentation.nearestID(in: rail) == "claude-primary",
                   "nearest limit is computed from available windows")
        try expect(LimitRailPresentation.nearestID(in: []) == nil,
                   "empty limit rail has no fabricated nearest window")
        try expect(LimitSeverity(utilization: 59.9) == .healthy
                   && LimitSeverity(utilization: 60) == .warning
                   && LimitSeverity(utilization: 85) == .warning
                   && LimitSeverity(utilization: 85.1) == .danger,
                   "limit severity boundaries")

        // Totals.unmetered: metadata-only calls (unknown accuracy, zero tokens —
        // Ollama Desktop) are counted separately so the UI can say "tokens
        // unavailable" instead of fabricating "↑ 0 ↓ 0". A zero-token call with
        // EXACT accuracy is a genuine zero, not unmetered.
        var unmeteredTotals = Totals()
        unmeteredTotals.add(UsageEvent(
            timestamp: Date(), provider: .ollama, source: .ollamaDesktop, model: "gemma",
            sessionId: nil, projectName: nil, inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, reasoningTokens: 0,
            tokenAccuracy: .unknown))
        unmeteredTotals.add(UsageEvent(
            timestamp: Date(), provider: .ollama, source: .proxy, model: "gemma",
            sessionId: nil, projectName: nil, inputTokens: 10, outputTokens: 5,
            cacheReadTokens: 0, cacheCreationTokens: 0, reasoningTokens: 0,
            tokenAccuracy: .exact))
        unmeteredTotals.add(UsageEvent(
            timestamp: Date(), provider: .ollama, source: .proxy, model: "gemma",
            sessionId: nil, projectName: nil, inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheCreationTokens: 0, reasoningTokens: 0,
            tokenAccuracy: .exact))
        try expect(unmeteredTotals.calls == 3 && unmeteredTotals.unmetered == 1
                   && unmeteredTotals.input == 10 && unmeteredTotals.output == 5,
                   "Totals.unmetered counts only unknown-accuracy zero-token calls")

        // desktopAndProxyOverlap: the Desktop DB's model_name can be '' (unknown,
        // not different) — an empty DESKTOP model must still shadow against a
        // named proxy twin when the timing gates hold; different named models
        // must never shadow.
        let overlapNow = Date()
        func ollamaEvent(source: EventSource, model: String, startLag: TimeInterval = 0) -> UsageEvent {
            UsageEvent(
                timestamp: overlapNow, startedAt: overlapNow.addingTimeInterval(-30 + startLag),
                provider: .ollama, source: source, model: model,
                sessionId: nil, projectName: nil, inputTokens: source == .proxy ? 10 : 0,
                outputTokens: source == .proxy ? 5 : 0, cacheReadTokens: 0,
                cacheCreationTokens: 0, reasoningTokens: 0,
                tokenAccuracy: source == .proxy ? .exact : .unknown)
        }
        try expect(EventReconciler.desktopAndProxyOverlap(
                       ollamaEvent(source: .ollamaDesktop, model: ""),
                       ollamaEvent(source: .proxy, model: "gemma")),
                   "empty desktop model wildcards against a named proxy twin")
        try expect(!EventReconciler.desktopAndProxyOverlap(
                       ollamaEvent(source: .ollamaDesktop, model: "llama"),
                       ollamaEvent(source: .proxy, model: "gemma")),
                   "different named models never shadow")
        // The DB row starts AFTER the HTTP request (prompt-eval lag, unbounded):
        // a desktop start 12s late must still shadow; a desktop start 12s BEFORE
        // the request is a different call and must not.
        try expect(EventReconciler.desktopAndProxyOverlap(
                       ollamaEvent(source: .ollamaDesktop, model: "gemma", startLag: 12),
                       ollamaEvent(source: .proxy, model: "gemma")),
                   "prompt-eval start lag still shadows (containment, not equality)")
        try expect(!EventReconciler.desktopAndProxyOverlap(
                       ollamaEvent(source: .ollamaDesktop, model: "gemma", startLag: -12),
                       ollamaEvent(source: .proxy, model: "gemma")),
                   "desktop row starting before the request never shadows")

        // Publish gating: heartbeat timestamps must not count as significant;
        // every field the UI keys structure/colors off must.
        var healthA = RuntimeHealth(provider: .ollama)
        var healthB = healthA
        healthB.lastSuccess = Date()
        healthB.lastEvent = Date()
        try expect(!healthA.significantlyDiffers(from: healthB),
                   "lastSuccess/lastEvent alone are not significant")
        healthB.state = .connected
        try expect(healthA.significantlyDiffers(from: healthB), "state change is significant")
        healthB = healthA; healthB.serverRunning = true
        try expect(healthA.significantlyDiffers(from: healthB), "serverRunning change is significant")
        healthB = healthA; healthB.lastError = "boom"
        try expect(healthA.significantlyDiffers(from: healthB), "lastError change is significant")
        healthB = healthA; healthB.version = "0.3.30"
        try expect(healthA.significantlyDiffers(from: healthB), "version change is significant")
        healthA.lastSuccess = Date(timeIntervalSince1970: 1)

        // LoadedModel.displayEquals ignores only the expiresAt countdown.
        let modelA = LoadedModel(provider: .ollama, name: "gemma", sizeBytes: 7,
                                 expiresAt: Date(timeIntervalSince1970: 100))
        let modelB = LoadedModel(provider: .ollama, name: "gemma", sizeBytes: 7,
                                 expiresAt: Date(timeIntervalSince1970: 200))
        let modelC = LoadedModel(provider: .ollama, name: "gemma", sizeBytes: 8,
                                 expiresAt: Date(timeIntervalSince1970: 100))
        try expect(modelA.displayEquals(modelB), "expiresAt drift alone is not a display change")
        try expect(!modelA.displayEquals(modelC), "any other field change is a display change")

        // ProcessReaper.candidates: only launchd-adopted (ppid 1) processes whose
        // argv matches the exact lms log stream invocation are reap candidates.
        let psFixture = """
        101     1 /Users/x/.lmstudio/bin/lms log stream --source model --filter output --stats --json
        150     1 /Users/x/.lmstudio/bin/lms log stream --source model --stats --json
        202   555 /Users/x/.lmstudio/bin/lms log stream --source model --filter output --stats --json
        303     1 /Users/x/.lmstudio/bin/lms log stream
        404     1 /usr/bin/tail -f something
        """
        let reapable = ProcessReaper.candidates(
            psOutput: psFixture, argvContains: ProcessReaper.lmsLogStreamArgv)
        try expect(reapable == [101, 150],
                   "reaper matches orphaned (ppid 1) streams across argv versions, nothing else")

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
