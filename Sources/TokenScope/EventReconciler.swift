import Foundation

/// Chooses the strongest observation when a durable source repeats the same
/// logical call (for example a zero-token streaming rewrite followed by final
/// usage). This is deliberately field-conservative: a later record must carry
/// stronger evidence, not merely arrive later.
enum EventReconciler {
    static func preferred(_ existing: UsageEvent, _ incoming: UsageEvent) -> UsageEvent {
        score(incoming) > score(existing) ? incoming : existing
    }

    /// Ollama.app normally bypasses TokenScope's proxy. If that changes (or a
    /// user explicitly routes it), the DB completion and proxy response describe
    /// the same call. Tight model/start/end/duration matching avoids counting it
    /// twice while preserving the proxy's stronger token evidence.
    static func desktopAndProxyOverlap(_ a: UsageEvent, _ b: UsageEvent) -> Bool {
        guard a.provider == .ollama, b.provider == .ollama,
              Set([a.source, b.source]) == Set([.ollamaDesktop, .proxy]),
              abs(a.timestamp.timeIntervalSince(b.timestamp)) < 4 else { return false }
        // The Desktop DB's model_name can be empty (unknown ≠ different) — let
        // only the DESKTOP side wildcard; a proxy event always names its model
        // from the request.
        let desktop = a.source == .ollamaDesktop ? a : b
        let proxy = a.source == .proxy ? a : b
        guard a.model == b.model || desktop.model.isEmpty else { return false }
        // Completion times (the <4s gate above) are the strong anchor — both
        // sides stamp within a second of stream end. Starts are NOT symmetric:
        // the app inserts the DB row only after prompt evaluation, so the row's
        // start lags the HTTP request start by an unbounded prompt-eval time
        // (measured 5s on a small chat; grows with context). Require containment
        // — the row must not START before the request did — instead of equal
        // starts, and drop the duration gate (implied by the two anchors).
        if let dStart = desktop.startedAt, let pStart = proxy.startedAt,
           dStart.timeIntervalSince(pStart) < -4 { return false }
        return true
    }

    private static func score(_ event: UsageEvent) -> (Int, Int, Int, Int) {
        let accuracy: Int
        switch event.tokenAccuracy {
        case .exact: accuracy = 3
        case .estimated: accuracy = 2
        case .unknown: accuracy = 1
        case .notApplicable: accuracy = 0
        }
        let terminal: Int
        switch event.status {
        case .succeeded, .failed, .cancelled: terminal = 2
        case .running: terminal = 0
        case .unknown: terminal = 1
        }
        let populatedMetrics = [event.durationSeconds, event.timeToFirstTokenSeconds,
                                event.tokensPerSecond, event.loadDurationSeconds]
            .compactMap { $0 }.count
        let tokenEvidence = event.inputTokens + event.outputTokens
            + event.cacheReadTokens + event.cacheCreationTokens
        return (accuracy, terminal, tokenEvidence, populatedMetrics)
    }
}
