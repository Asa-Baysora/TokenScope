import Foundation

/// Pure (store-free) parser for Claude Code transcript assistant lines, so the
/// accuracy rules can be regression-tested without the app. `TranscriptWatcher`
/// owns one instance and feeds it every line.
///
/// Rules (see docs/REFERENCE.md §6.1):
/// - A message with a `stop_reason` carries final usage → `.exact`.
/// - A message that never gets one (it ends in `tool_use`) keeps the
///   `message_start` snapshot (output_tokens ~1–10) on every line. Claude Code
///   writes ONE content block per line, so content size is accumulated per
///   `message.id:requestId` across lines and the event is
///   `max(observed, ceil(chars / charsPerToken))`, marked `.estimated`.
///   `EventReconciler` ranks `.exact` above `.estimated`, so a later finalized
///   line replaces the estimate and an estimate can never downgrade it.
/// - `usage.iterations[]` entries whose type != "message" (advisor calls) are a
///   SEPARATE model's tokens excluded from the top-level usage → one extra event
///   each, dedup key `<key>:iter<i>`.
/// - A line without `timestamp` inherits the previous timestamp seen in the same
///   file, else the file's mtime — never the wall clock.
struct ClaudeTranscriptParser {
    /// The single place the estimate ratio lives (measured ≈4 chars/token on
    /// finalized messages across the corpus).
    static let charsPerToken = 4
    static let advisorModelSuffix = " (advisor)"
    static let advisorFinishReason = "advisor_message"

    struct Observation {
        let event: UsageEvent
        let dedupKey: String
    }

    private struct Acc {
        var chars = 0
        var seen = Set<Int>()
    }
    private var acc: [String: Acc] = [:]
    private var lastTimestamp: [String: Date] = [:]   // per file

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func estimateTokens(chars: Int) -> Int {
        (chars + charsPerToken - 1) / charsPerToken
    }

    /// `fileKey` identifies the file for timestamp carry-forward; `mtime` is
    /// consulted lazily, only when no earlier timestamp exists.
    mutating func parse(_ data: Data, fileKey: String, fileSession: String,
                        mtime: () -> Date?) -> [Observation] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, model != "<synthetic>" else { return [] }

        var ts: Date
        if let s = obj["timestamp"] as? String,
           let d = Self.isoFrac.date(from: s) ?? Self.iso.date(from: s) {
            ts = d
            lastTimestamp[fileKey] = d
        } else if let prev = lastTimestamp[fileKey] {
            ts = prev
        } else {
            ts = mtime() ?? Date(timeIntervalSince1970: 0)
        }

        let msgId = msg["id"] as? String
        let reqId = obj["requestId"] as? String ?? ""
        let key = "\(msgId ?? UUID().uuidString):\(reqId)"
        let session = obj["sessionId"] as? String ?? fileSession
        let project = (obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let provider = UsageOrigin.classifyClaudeCode(model: model)

        func int(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }

        var output = int(usage, "output_tokens")
        var accuracy = MetricAccuracy.exact
        let finalized = (msg["stop_reason"] as? String).map { !$0.isEmpty } ?? false
        if finalized {
            acc[key] = nil
        } else if provider == .claudeCode, msgId != nil {
            // Ollama-routed Claude Code is left exact: the proxy shadowing match
            // requires an exact transcript twin and Ollama reports real counts.
            var a = acc[key] ?? Acc()
            if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks {
                    let (h, n) = Self.measure(b)
                    if a.seen.insert(h).inserted { a.chars += n }
                }
            }
            if acc.count > 50_000 { acc.removeAll(keepingCapacity: true) }  // bound memory
            acc[key] = a
            output = max(output, Self.estimateTokens(chars: a.chars))
            accuracy = .estimated
        }

        var out = [Observation(
            event: UsageEvent(
                timestamp: ts, provider: provider, source: .transcript, model: model,
                sessionId: session, projectName: project,
                inputTokens: int(usage, "input_tokens"), outputTokens: output,
                cacheReadTokens: int(usage, "cache_read_input_tokens"),
                cacheCreationTokens: int(usage, "cache_creation_input_tokens"),
                reasoningTokens: 0, tokenAccuracy: accuracy),
            dedupKey: key)]

        if let its = usage["iterations"] as? [[String: Any]] {
            for (i, it) in its.enumerated() where (it["type"] as? String ?? "message") != "message" {
                guard let m = it["model"] as? String, m != "<synthetic>" else { continue }
                let ev = UsageEvent(
                    timestamp: ts, provider: UsageOrigin.classifyClaudeCode(model: m),
                    source: .transcript, model: m + Self.advisorModelSuffix,
                    sessionId: session, projectName: project,
                    inputTokens: int(it, "input_tokens"), outputTokens: int(it, "output_tokens"),
                    cacheReadTokens: int(it, "cache_read_input_tokens"),
                    cacheCreationTokens: int(it, "cache_creation_input_tokens"),
                    reasoningTokens: 0, tokenAccuracy: .exact,
                    finishReason: Self.advisorFinishReason)
                out.append(Observation(event: ev, dedupKey: "\(key):iter\(i)"))
            }
        }
        return out
    }

    /// (identity hash, character count) of one content block: text, thinking text,
    /// or JSON-serialized tool input.
    private static func measure(_ b: [String: Any]) -> (Int, Int) {
        let type = b["type"] as? String ?? ""
        if let t = b["text"] as? String {
            return ("\(type)|\(t)".hashValue, t.unicodeScalars.count)
        }
        if let t = b["thinking"] as? String {
            return ("\(type)|\(t)".hashValue, t.unicodeScalars.count)
        }
        if let input = b["input"], JSONSerialization.isValidJSONObject(input),
           let d = try? JSONSerialization.data(withJSONObject: input, options: [.withoutEscapingSlashes]) {
            let id = b["id"] as? String
            let h = id.map { "\(type)|\($0)".hashValue } ?? d.hashValue
            return (h, d.count)
        }
        return ("\(type)|\(b["id"] as? String ?? "")".hashValue, 0)
    }
}
