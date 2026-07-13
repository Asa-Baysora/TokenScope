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
              a.model == b.model,
              abs(a.timestamp.timeIntervalSince(b.timestamp)) < 4 else { return false }
        if let aStart = a.startedAt, let bStart = b.startedAt,
           abs(aStart.timeIntervalSince(bStart)) >= 4 { return false }
        if let aDuration = a.durationSeconds, let bDuration = b.durationSeconds,
           abs(aDuration - bDuration) >= 4 { return false }
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
