import Foundation

enum TokenProvider: String {
    case claude
    case ollama

    static func classify(model: String) -> TokenProvider {
        model.lowercased().hasPrefix("claude") ? .claude : .ollama
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .ollama: return "Ollama"
        }
    }
}

enum EventSource: String {
    case transcript // parsed from a Claude Code session JSONL
    case proxy      // observed by the local Ollama proxy
}

struct UsageEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let provider: TokenProvider
    let source: EventSource
    let model: String
    let sessionId: String?
    let projectName: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
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
    var calls = 0

    mutating func add(_ e: UsageEvent) {
        input += e.inputTokens
        output += e.outputTokens
        cacheRead += e.cacheReadTokens
        cacheCreate += e.cacheCreationTokens
        calls += 1
    }
}

struct SessionAgg: Identifiable {
    let id: String
    let title: String
    let project: String?
    let provider: TokenProvider
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
    var ollama = 0

    var id: Date { day }
    var total: Int { claude + ollama }
}

/// One calendar day's frozen totals, persisted once the day leaves the live
/// events window (Claude Code eventually deletes old transcripts, so history
/// must accumulate on our side to outlive them).
struct DayAgg: Codable, Equatable {
    var claudeIn = 0
    var claudeOut = 0
    var ollamaIn = 0
    var ollamaOut = 0
    var calls = 0

    var claude: Int { claudeIn + claudeOut }
    var ollama: Int { ollamaIn + ollamaOut }
    var total: Int { claude + ollama }

    mutating func add(_ e: UsageEvent) {
        if e.provider == .claude {
            claudeIn += e.inputTokens
            claudeOut += e.outputTokens
        } else {
            ollamaIn += e.inputTokens
            ollamaOut += e.outputTokens
        }
        calls += 1
    }

    mutating func merge(_ o: DayAgg) {
        claudeIn += o.claudeIn
        claudeOut += o.claudeOut
        ollamaIn += o.ollamaIn
        ollamaOut += o.ollamaOut
        calls += o.calls
    }
}
