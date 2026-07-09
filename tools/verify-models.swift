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
        print("model checks passed")
    }

    private static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw CheckError.failed(name) }
    }

    enum CheckError: Error { case failed(String) }
}
