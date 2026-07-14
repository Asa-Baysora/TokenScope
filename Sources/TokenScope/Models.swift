import Foundation

/// Product that produced a locally observed token event. This intentionally is
/// not inferred from a generic model name: Codex, Claude Code, and Ollama have
/// different local sources and usage semantics.
enum UsageOrigin: String, CaseIterable, Codable {
    case claudeCode
    case codex
    case ollama
    case lmStudio

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
        case .lmStudio: return "LM Studio"
        }
    }
}

enum EventSource: String, Codable {
    case transcript // parsed from a Claude Code session JSONL
    case codexTranscript // parsed from a local Codex rollout JSONL
    case proxy      // observed by the local Ollama proxy
    case ollamaDesktop // metadata-only completion observed in Ollama.app's local DB
    case lmStudioLog // observed via `lms log stream --source model`
}

enum MetricAccuracy: String, Codable, CaseIterable {
    case exact
    case estimated
    case unknown
    case notApplicable
}

enum InferenceOperation: String, Codable, CaseIterable {
    case chat
    case generate
    case completion
    case responses
    case embedding
    case image
    case unknown
}

enum CallStatus: String, Codable, CaseIterable {
    case running
    case succeeded
    case failed
    case cancelled
    case unknown
}

enum ExecutionLocation: String, Codable, CaseIterable {
    case local
    case cloud
    case remote
    case unknown
}

enum CodexTrackingPolicy {
    /// Cookie telemetry contains account quota windows, not per-turn token use.
    /// Local Codex session tokens therefore remain enabled for either limits source.
    static func tracksLocalSessionTokens(cookieLimitsSelected: Bool) -> Bool { true }
}

/// Canonical local-inference call. Collectors may know only a subset of the
/// operational fields; unknown is always preferable to inventing attribution.
struct UsageEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let startedAt: Date?
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
    let tokenAccuracy: MetricAccuracy
    let operation: InferenceOperation
    let status: CallStatus
    let executionLocation: ExecutionLocation
    let endpoint: String?
    let requestId: String?
    let httpStatus: Int?
    let finishReason: String?
    /// Sanitized category only. Never persist provider error bodies, which may
    /// echo request content.
    let errorCategory: String?
    let durationSeconds: Double?
    let loadDurationSeconds: Double?
    let promptEvalDurationSeconds: Double?
    let evalDurationSeconds: Double?
    let timeToFirstTokenSeconds: Double?
    let tokensPerSecond: Double?
    // A proxy observation that was also recorded by a Claude Code transcript;
    // kept for the call log but excluded from totals.
    var shadowed = false

    init(
        id: UUID = UUID(),
        timestamp: Date,
        startedAt: Date? = nil,
        provider: UsageOrigin,
        source: EventSource,
        model: String,
        sessionId: String?,
        projectName: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        reasoningTokens: Int,
        tokenAccuracy: MetricAccuracy = .exact,
        operation: InferenceOperation = .unknown,
        status: CallStatus = .succeeded,
        executionLocation: ExecutionLocation = .unknown,
        endpoint: String? = nil,
        requestId: String? = nil,
        httpStatus: Int? = nil,
        finishReason: String? = nil,
        errorCategory: String? = nil,
        durationSeconds: Double? = nil,
        loadDurationSeconds: Double? = nil,
        promptEvalDurationSeconds: Double? = nil,
        evalDurationSeconds: Double? = nil,
        timeToFirstTokenSeconds: Double? = nil,
        tokensPerSecond: Double? = nil,
        shadowed: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.startedAt = startedAt
        self.provider = provider
        self.source = source
        self.model = model
        self.sessionId = sessionId
        self.projectName = projectName
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.tokenAccuracy = tokenAccuracy
        self.operation = operation
        self.status = status
        self.executionLocation = executionLocation
        self.endpoint = endpoint
        self.requestId = requestId
        self.httpStatus = httpStatus
        self.finishReason = finishReason
        self.errorCategory = errorCategory
        self.durationSeconds = durationSeconds
        self.loadDurationSeconds = loadDurationSeconds
        self.promptEvalDurationSeconds = promptEvalDurationSeconds
        self.evalDurationSeconds = evalDurationSeconds
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.tokensPerSecond = tokensPerSecond
        self.shadowed = shadowed
    }
}

/// Metadata Ollama.app persists for a completed assistant message. TokenScope
/// intentionally never selects the message content or thinking columns: the
/// desktop database does not store Ollama's prompt_eval_count/eval_count, so
/// model/timing/call activity are the strongest privacy-preserving facts here.
struct OllamaDesktopObservation: Equatable {
    let rowID: Int64
    let chatID: String
    let model: String
    let startedAt: Date
    let completedAt: Date

    var dedupKey: String { "ollama-desktop:\(chatID):\(rowID)" }

    var event: UsageEvent {
        UsageEvent(
            timestamp: completedAt,
            startedAt: startedAt,
            provider: .ollama,
            source: .ollamaDesktop,
            model: model.isEmpty ? "Ollama Desktop" : model,
            sessionId: "ollama-app:\(chatID)",
            projectName: nil,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: 0,
            tokenAccuracy: .unknown,
            operation: .chat,
            status: .succeeded,
            executionLocation: .unknown,
            endpoint: "/api/chat",
            durationSeconds: max(0, completedAt.timeIntervalSince(startedAt)))
    }
}

struct LiveCall: Identifiable {
    let id: UUID
    var provider: UsageOrigin
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var outputAccuracy: MetricAccuracy
    var operation: InferenceOperation
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
    /// Calls observed with no token data at all (e.g. Ollama Desktop metadata,
    /// which never persists runtime counts). Kept separate so the UI can say
    /// "tokens unavailable" instead of fabricating a "↑ 0 ↓ 0".
    var unmetered = 0

    mutating func add(_ e: UsageEvent) {
        input += e.inputTokens
        output += e.outputTokens
        cacheRead += e.cacheReadTokens
        cacheCreate += e.cacheCreationTokens
        reasoning += e.reasoningTokens
        calls += 1
        if e.tokenAccuracy == .unknown && e.inputTokens == 0 && e.outputTokens == 0 {
            unmetered += 1
        }
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

enum LoadedModelKind: String, Codable {
    case llm
    case embedding
    case unknown
}

struct LoadedModel: Equatable, Identifiable {
    var id: String { "\(provider.rawValue):\(instanceId ?? name)" }

    /// Publish-gating equality: everything EXCEPT `expiresAt`, whose keep-alive
    /// countdown moves on every /api/ps poll while a model is resident and is
    /// displayed nowhere — comparing it defeated the equality gate and forced a
    /// scene re-render every 10s. Revisit if the UI ever shows expiry.
    func displayEquals(_ other: LoadedModel) -> Bool {
        provider == other.provider && name == other.name
            && instanceId == other.instanceId && kind == other.kind
            && sizeBytes == other.sizeBytes && vramBytes == other.vramBytes
            && contextLength == other.contextLength && family == other.family
            && parameterSize == other.parameterSize && quantization == other.quantization
            && format == other.format && parallelCapacity == other.parallelCapacity
            && queuedRequests == other.queuedRequests && isGenerating == other.isGenerating
    }
    let provider: UsageOrigin
    let name: String
    let instanceId: String?
    let kind: LoadedModelKind
    let sizeBytes: Int64
    let vramBytes: Int64
    let contextLength: Int?
    let expiresAt: Date?
    let family: String?
    let parameterSize: String?
    let quantization: String?
    let format: String?
    let parallelCapacity: Int?
    let queuedRequests: Int?
    let isGenerating: Bool?

    init(
        provider: UsageOrigin = .ollama,
        name: String,
        instanceId: String? = nil,
        kind: LoadedModelKind = .unknown,
        sizeBytes: Int64 = 0,
        vramBytes: Int64 = 0,
        contextLength: Int? = nil,
        expiresAt: Date? = nil,
        family: String? = nil,
        parameterSize: String? = nil,
        quantization: String? = nil,
        format: String? = nil,
        parallelCapacity: Int? = nil,
        queuedRequests: Int? = nil,
        isGenerating: Bool? = nil
    ) {
        self.provider = provider
        self.name = name
        self.instanceId = instanceId
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.vramBytes = vramBytes
        self.contextLength = contextLength
        self.expiresAt = expiresAt
        self.family = family
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.format = format
        self.parallelCapacity = parallelCapacity
        self.queuedRequests = queuedRequests
        self.isGenerating = isGenerating
    }
}

enum RuntimeConnectionState: String, Codable {
    case unavailable
    case installed
    case connecting
    case connected
    case degraded
}

struct RuntimeHealth: Equatable {
    var provider: UsageOrigin
    var state: RuntimeConnectionState = .unavailable
    var version: String?
    var serverRunning = false
    var collectorRunning = false
    var coverage: String = "unavailable"
    var lastSuccess: Date?
    var lastEvent: Date?
    var lastError: String?

    /// True when a change is worth publishing to SwiftUI. `lastSuccess` and
    /// `lastEvent` are heartbeat timestamps that move on every successful poll
    /// (10s/30s); publishing them re-rendered the whole scene — including the
    /// ImageRenderer menu-bar bitmap — around the clock (~0.2% → ~2% idle CPU).
    /// UsageStore keeps them in a non-published side map and overlays them at
    /// read time, so excluding them here loses nothing the UI shows.
    func significantlyDiffers(from other: RuntimeHealth) -> Bool {
        provider != other.provider
            || state != other.state
            || version != other.version
            || serverRunning != other.serverRunning
            || collectorRunning != other.collectorRunning
            || coverage != other.coverage
            || lastError != other.lastError
    }
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
    var providers: [UsageOrigin: Int] = [:]

    var claude: Int {
        get { providers[.claudeCode, default: 0] }
        set { providers[.claudeCode] = newValue }
    }
    var codex: Int {
        get { providers[.codex, default: 0] }
        set { providers[.codex] = newValue }
    }
    var ollama: Int {
        get { providers[.ollama, default: 0] }
        set { providers[.ollama] = newValue }
    }
    var lmStudio: Int {
        get { providers[.lmStudio, default: 0] }
        set { providers[.lmStudio] = newValue }
    }

    var id: Date { day }
    var total: Int { providers.values.reduce(0, +) }
}

/// One calendar day's frozen totals, persisted once the day leaves the live
/// events window (Claude Code eventually deletes old transcripts, so history
/// must accumulate on our side to outlive them).
struct ProviderDayAgg: Codable, Equatable {
    var input = 0
    var output = 0
    var cache = 0
    var reasoning = 0
    var calls = 0

    var tokens: Int { input + output }
    var tokensWithCache: Int { tokens + cache }

    mutating func merge(_ other: ProviderDayAgg) {
        input += other.input
        output += other.output
        cache += other.cache
        reasoning += other.reasoning
        calls += other.calls
    }
}

struct DayAgg: Codable, Equatable {
    var providers: [String: ProviderDayAgg] = [:]
    var calls = 0

    private func provider(_ origin: UsageOrigin) -> ProviderDayAgg {
        providers[origin.rawValue] ?? ProviderDayAgg()
    }

    var claudeIn: Int { provider(.claudeCode).input }
    var claudeOut: Int { provider(.claudeCode).output }
    var claudeCache: Int { provider(.claudeCode).cache }
    var codexIn: Int { provider(.codex).input }
    var codexOut: Int { provider(.codex).output }
    var codexCache: Int { provider(.codex).cache }
    var ollamaIn: Int { provider(.ollama).input }
    var ollamaOut: Int { provider(.ollama).output }
    var ollamaCache: Int { provider(.ollama).cache }
    var lmStudioIn: Int { provider(.lmStudio).input }
    var lmStudioOut: Int { provider(.lmStudio).output }
    var lmStudioCache: Int { provider(.lmStudio).cache }

    var claude: Int { provider(.claudeCode).tokens }
    var codex: Int { provider(.codex).tokens }
    var ollama: Int { provider(.ollama).tokens }
    var lmStudio: Int { provider(.lmStudio).tokens }
    var total: Int { providers.values.reduce(0) { $0 + $1.tokens } }

    // Cache-inclusive variants for long-range views (heatmap) so they can
    // honor the same "include cache" setting the bar chart uses. Days frozen
    // before cache tracking existed have *Cache == 0, so these equal the
    // fresh-only figures for them — old history degrades gracefully.
    var claudeWithCache: Int { provider(.claudeCode).tokensWithCache }
    var codexWithCache: Int { provider(.codex).tokensWithCache }
    var ollamaWithCache: Int { provider(.ollama).tokensWithCache }
    var lmStudioWithCache: Int { provider(.lmStudio).tokensWithCache }

    /// Older history files predate Codex (and, later, cache fields). Decode
    /// absent keys as zero so users keep their accumulated heatmap data across
    /// upgrades — a missing cache field just means "no cache recorded that day".
    enum CodingKeys: String, CodingKey {
        case providers
        case claudeIn, claudeOut, claudeCache
        case codexIn, codexOut, codexCache
        case ollamaIn, ollamaOut, ollamaCache
        case lmStudioIn, lmStudioOut, lmStudioCache
        case calls
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
        if let keyed = try c.decodeIfPresent([String: ProviderDayAgg].self, forKey: .providers) {
            providers = keyed
            return
        }
        func legacy(_ origin: UsageOrigin, _ input: CodingKeys, _ output: CodingKeys, _ cache: CodingKeys) {
            let p = ProviderDayAgg(
                input: (try? c.decodeIfPresent(Int.self, forKey: input)) ?? 0,
                output: (try? c.decodeIfPresent(Int.self, forKey: output)) ?? 0,
                cache: (try? c.decodeIfPresent(Int.self, forKey: cache)) ?? 0,
                reasoning: 0,
                calls: 0)
            if p.input > 0 || p.output > 0 || p.cache > 0 { providers[origin.rawValue] = p }
        }
        legacy(.claudeCode, .claudeIn, .claudeOut, .claudeCache)
        legacy(.codex, .codexIn, .codexOut, .codexCache)
        legacy(.ollama, .ollamaIn, .ollamaOut, .ollamaCache)
        legacy(.lmStudio, .lmStudioIn, .lmStudioOut, .lmStudioCache)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(providers, forKey: .providers)
        try c.encode(calls, forKey: .calls)
    }

    mutating func add(_ e: UsageEvent) {
        var p = providers[e.provider.rawValue] ?? ProviderDayAgg()
        p.input += e.inputTokens
        p.output += e.outputTokens
        p.cache += e.cacheReadTokens + e.cacheCreationTokens
        p.reasoning += e.reasoningTokens
        p.calls += 1
        providers[e.provider.rawValue] = p
        calls += 1
    }

    mutating func merge(_ o: DayAgg) {
        for (key, value) in o.providers {
            var p = providers[key] ?? ProviderDayAgg()
            p.merge(value)
            providers[key] = p
        }
        calls += o.calls
    }
}
