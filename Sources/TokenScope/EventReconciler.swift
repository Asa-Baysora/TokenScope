import Foundation

/// Chooses the strongest observation when a durable source repeats the same
/// logical call (for example a zero-token streaming rewrite followed by final
/// usage). This is deliberately field-conservative: a later record must carry
/// stronger evidence, not merely arrive later.
enum EventReconciler {
    static func preferred(_ existing: UsageEvent, _ incoming: UsageEvent) -> UsageEvent {
        score(incoming) > score(existing) ? incoming : existing
    }

    /// In-place dedup replacement. Returns the event to store at the existing slot,
    /// or nil when `existing` stays. The winner is the stronger observation, but it
    /// KEEPS THE EXISTING (first-seen) TIMESTAMP and `shadowed` flag. Why first-seen:
    /// the first line of a message is when the call started (the ground-truth
    /// script also uses first-seen), it is stable however many later lines or
    /// duplicate files rewrite the message, and it can never move the event out of
    /// its sorted position or across a day boundary after the day was counted.
    /// (Real Cowork corpus: 201 resumed-session copies, max 24 s apart, none
    /// across a local day.)
    static func replacement(existing: UsageEvent, incoming: UsageEvent) -> UsageEvent? {
        guard preferred(existing, incoming).id != existing.id else { return nil }
        var e = incoming
        e.timestamp = existing.timestamp
        e.shadowed = existing.shadowed
        return e
    }

    /// Same-call match between a proxy observation and its exact Claude-Code-via-
    /// Ollama transcript twin: output within ±2 tokens and 120 s (replay/startup rule;
    /// the live per-event matcher uses a 90 s window on the same output rule).
    static let twinTokenSlack = 2
    static let twinSeconds: TimeInterval = 120

    /// Index of exact Ollama transcript events by output tokens, for twin lookups.
    struct TranscriptTwinIndex {
        private var byOut: [Int: [Date]] = [:]
        var isEmpty: Bool { byOut.isEmpty }

        init<S: Sequence>(_ events: S) where S.Element == UsageEvent {
            for e in events where e.source == .transcript && e.provider == .ollama
                && e.tokenAccuracy == .exact {
                byOut[e.outputTokens, default: []].append(e.timestamp)
            }
        }

        func hasTwin(for proxy: UsageEvent) -> Bool {
            for delta in -EventReconciler.twinTokenSlack...EventReconciler.twinTokenSlack {
                if let dates = byOut[proxy.outputTokens + delta],
                   dates.contains(where: { abs($0.timeIntervalSince(proxy.timestamp)) < EventReconciler.twinSeconds }) {
                    return true
                }
            }
            return false
        }
    }

    /// Shadows every unshadowed proxy event that has a transcript twin. Proxy-side
    /// accuracy is deliberately NOT gated: estimated and legacy (.unknown) proxy
    /// copies are exactly what needs shadowing; the index already requires .exact on
    /// the authoritative transcript side. Returns the indices newly shadowed.
    @discardableResult
    static func shadowProxyTwins(in events: inout [UsageEvent], index: TranscriptTwinIndex) -> [Int] {
        guard !index.isEmpty else { return [] }
        var changed: [Int] = []
        for i in events.indices where events[i].source == .proxy && !events[i].shadowed
            && index.hasTwin(for: events[i]) {
            events[i].shadowed = true
            changed.append(i)
        }
        return changed
    }

    /// Shadows each unshadowed Ollama Desktop event that overlaps an unshadowed proxy
    /// event (`desktopAndProxyOverlap`). Returns the indices newly shadowed.
    @discardableResult
    static func shadowDesktopOverlaps(in events: inout [UsageEvent]) -> [Int] {
        let proxies = events.filter { $0.source == .proxy && !$0.shadowed }
        guard !proxies.isEmpty else { return [] }
        var changed: [Int] = []
        for i in events.indices where events[i].source == .ollamaDesktop && !events[i].shadowed {
            let desktop = events[i]
            if proxies.contains(where: { desktopAndProxyOverlap(desktop, $0) }) {
                events[i].shadowed = true
                changed.append(i)
            }
        }
        return changed
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
