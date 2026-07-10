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
        case .claudeCode: return "Claude"
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

/// The user-facing client that owns a local inference call. `provider` answers
/// who ran the model; `surface` answers where the conversation lives.
enum UsageSurface: String, Codable, CaseIterable {
    case claudeCode
    case codex
    case ollamaDesktop
    case ollamaDirect

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code · Ollama"
        case .codex: return "Codex · Ollama"
        case .ollamaDesktop: return "Ollama Desktop"
        case .ollamaDirect: return "Ollama Direct"
        }
    }
}

enum AttributionConfidence: String, Codable {
    case authoritative
    case linked
    case inferred
    case unassigned
}

struct UsageEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let provider: UsageOrigin
    let source: EventSource
    let model: String
    var sessionId: String?
    var projectName: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    /// A subset of Codex's output tokens. Retained for detail, never added to
    /// the headline total a second time.
    let reasoningTokens: Int
    /// Stable for a gateway-observed call. Transcript-only events do not have
    /// one because their durable source identity is their transcript dedup key.
    var callId: UUID? = nil
    var surface: UsageSurface? = nil
    var attributionConfidence: AttributionConfidence = .authoritative
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
    var surface: UsageSurface?
    var confidence: AttributionConfidence
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
    var claudeCache = 0
    var codexIn = 0
    var codexOut = 0
    var codexCache = 0
    var ollamaIn = 0
    var ollamaOut = 0
    var ollamaCache = 0
    var calls = 0

    var claude: Int { claudeIn + claudeOut }
    var codex: Int { codexIn + codexOut }
    var ollama: Int { ollamaIn + ollamaOut }
    var total: Int { claude + codex + ollama }

    // Cache-inclusive variants for long-range views (heatmap) so they can
    // honor the same "include cache" setting the bar chart uses. Days frozen
    // before cache tracking existed have *Cache == 0, so these equal the
    // fresh-only figures for them — old history degrades gracefully.
    var claudeWithCache: Int { claude + claudeCache }
    var codexWithCache: Int { codex + codexCache }
    var ollamaWithCache: Int { ollama + ollamaCache }

    /// Older history files predate Codex (and, later, cache fields). Decode
    /// absent keys as zero so users keep their accumulated heatmap data across
    /// upgrades — a missing cache field just means "no cache recorded that day".
    enum CodingKeys: String, CodingKey {
        case claudeIn, claudeOut, claudeCache
        case codexIn, codexOut, codexCache
        case ollamaIn, ollamaOut, ollamaCache
        case calls
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeIn = try c.decodeIfPresent(Int.self, forKey: .claudeIn) ?? 0
        claudeOut = try c.decodeIfPresent(Int.self, forKey: .claudeOut) ?? 0
        claudeCache = try c.decodeIfPresent(Int.self, forKey: .claudeCache) ?? 0
        codexIn = try c.decodeIfPresent(Int.self, forKey: .codexIn) ?? 0
        codexOut = try c.decodeIfPresent(Int.self, forKey: .codexOut) ?? 0
        codexCache = try c.decodeIfPresent(Int.self, forKey: .codexCache) ?? 0
        ollamaIn = try c.decodeIfPresent(Int.self, forKey: .ollamaIn) ?? 0
        ollamaOut = try c.decodeIfPresent(Int.self, forKey: .ollamaOut) ?? 0
        ollamaCache = try c.decodeIfPresent(Int.self, forKey: .ollamaCache) ?? 0
        calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
    }

    mutating func add(_ e: UsageEvent) {
        let cache = e.cacheReadTokens + e.cacheCreationTokens
        switch e.provider {
        case .claudeCode:
            claudeIn += e.inputTokens
            claudeOut += e.outputTokens
            claudeCache += cache
        case .codex:
            codexIn += e.inputTokens
            codexOut += e.outputTokens
            codexCache += cache
        case .ollama:
            ollamaIn += e.inputTokens
            ollamaOut += e.outputTokens
            ollamaCache += cache
        }
        calls += 1
    }

    mutating func merge(_ o: DayAgg) {
        claudeIn += o.claudeIn
        claudeOut += o.claudeOut
        claudeCache += o.claudeCache
        codexIn += o.codexIn
        codexOut += o.codexOut
        codexCache += o.codexCache
        ollamaIn += o.ollamaIn
        ollamaOut += o.ollamaOut
        ollamaCache += o.ollamaCache
        calls += o.calls
    }
}
