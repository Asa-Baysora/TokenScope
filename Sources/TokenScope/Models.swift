import Foundation

/// Product that produced a locally observed token event. This intentionally is
/// not inferred from a generic model name: Codex, Claude Code, and Ollama have
/// different local sources and usage semantics.
enum UsageOrigin: String, CaseIterable {
    case claudeCode
    case codex
    case ollama

    /// Claude Code can be configured to talk to Ollama. In that case its
    /// transcript is still the durable source, but the tokens belong to Ollama.
    static func classifyClaudeCode(model: String) -> UsageOrigin {
        model.lowercased().hasPrefix("claude") ? .claudeCode : .ollama
    }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .ollama: return "Ollama"
        }
    }
}

enum EventSource: String {
    case transcript // parsed from a Claude Code session JSONL
    case codexTranscript // parsed from a local Codex rollout JSONL
    case proxy      // observed by the local Ollama proxy
}

struct UsageEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let provider: UsageOrigin
    let source: EventSource
    let model: String
    let sessionId: String?
    let projectName: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    /// A subset of Codex's output tokens. Retained for detail, never added to
    /// the headline total a second time.
    let reasoningTokens: Int
    // A proxy observation that was also recorded by a Claude Code transcript;
    // kept for the call log but excluded from totals.
    var shadowed = false
}

struct LiveCall: Identifiable {
    let id: UUID
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var startedAt: Date
    var lastUpdate: Date
}

struct Totals {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreate = 0
    var reasoning = 0
    var calls = 0

    mutating func add(_ e: UsageEvent) {
        input += e.inputTokens
        output += e.outputTokens
        cacheRead += e.cacheReadTokens
        cacheCreate += e.cacheCreationTokens
        reasoning += e.reasoningTokens
        calls += 1
    }
}

struct SessionAgg: Identifiable {
    let id: String
    let title: String
    let project: String?
    let provider: UsageOrigin
    var totals = Totals()
    var lastActivity = Date.distantPast
    var models: Set<String> = []

    var isActive: Bool { Date().timeIntervalSince(lastActivity) < 15 * 60 }
}

struct LoadedModel: Equatable {
    let name: String
    let vramBytes: Int64
}

enum StatsPeriod: String, CaseIterable, Identifiable {
    case today, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 Days"
        case .month: return "30 Days"
        }
    }

    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }
}

struct DayStat: Identifiable {
    let day: Date
    var claude = 0
    var codex = 0
    var ollama = 0

    var id: Date { day }
    var total: Int { claude + codex + ollama }
}

/// One calendar day's frozen totals, persisted once the day leaves the live
/// events window (Claude Code eventually deletes old transcripts, so history
/// must accumulate on our side to outlive them).
struct DayAgg: Codable, Equatable {
    var claudeIn = 0
    var claudeOut = 0
    var codexIn = 0
    var codexOut = 0
    var ollamaIn = 0
    var ollamaOut = 0
    var calls = 0

    var claude: Int { claudeIn + claudeOut }
    var codex: Int { codexIn + codexOut }
    var ollama: Int { ollamaIn + ollamaOut }
    var total: Int { claude + codex + ollama }

    /// Older history files predate Codex. Decode absent Codex keys as zero so
    /// users keep their accumulated Claude/Ollama heatmap data after upgrade.
    enum CodingKeys: String, CodingKey {
        case claudeIn, claudeOut, codexIn, codexOut, ollamaIn, ollamaOut, calls
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeIn = try c.decodeIfPresent(Int.self, forKey: .claudeIn) ?? 0
        claudeOut = try c.decodeIfPresent(Int.self, forKey: .claudeOut) ?? 0
        codexIn = try c.decodeIfPresent(Int.self, forKey: .codexIn) ?? 0
        codexOut = try c.decodeIfPresent(Int.self, forKey: .codexOut) ?? 0
        ollamaIn = try c.decodeIfPresent(Int.self, forKey: .ollamaIn) ?? 0
        ollamaOut = try c.decodeIfPresent(Int.self, forKey: .ollamaOut) ?? 0
        calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
    }

    mutating func add(_ e: UsageEvent) {
        switch e.provider {
        case .claudeCode:
            claudeIn += e.inputTokens
            claudeOut += e.outputTokens
        case .codex:
            codexIn += e.inputTokens
            codexOut += e.outputTokens
        case .ollama:
            ollamaIn += e.inputTokens
            ollamaOut += e.outputTokens
        }
        calls += 1
    }

    mutating func merge(_ o: DayAgg) {
        claudeIn += o.claudeIn
        claudeOut += o.claudeOut
        codexIn += o.codexIn
        codexOut += o.codexOut
        ollamaIn += o.ollamaIn
        ollamaOut += o.ollamaOut
        calls += o.calls
    }
}
