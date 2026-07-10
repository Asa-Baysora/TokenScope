import Foundation

/// Watches the server→client byte stream of one proxied connection and extracts
/// token usage. Understands three response shapes, streaming or not:
///   - Ollama native (/api/chat, /api/generate): prompt_eval_count / eval_count
///   - Anthropic (/v1/messages): usage in message_start / message_delta, message_stop ends a call
///   - OpenAI (/v1/chat/completions): prompt_tokens / completion_tokens
/// Works line-by-line (NDJSON and SSE are both newline-framed); chunked-transfer
/// size markers appear as bare hex lines and are filtered out.
final class ResponseScanner {
    struct CallState {
        let id: UUID
        var requestPath: String?
        var promptFingerprint: String?
        var model = "ollama"
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreate = 0
        var approxOutput = 0   // streamed-chunk count, used until a real count arrives
        var sawUsage = false
        let startedAt = Date()

        var displayOutput: Int { output > 0 ? output : approxOutput }
    }

    private var carry = Data()
    private var state: CallState?
    private var requests: [OllamaRequestMetadata] = []
    private var lastEmit = Date.distantPast
    private let onUpdate: (CallState) -> Void
    private let onFinal: (CallState) -> Void

    init(onUpdate: @escaping (CallState) -> Void, onFinal: @escaping (CallState) -> Void) {
        self.onUpdate = onUpdate
        self.onFinal = onFinal
    }

    func observeRequest(_ request: OllamaRequestMetadata) {
        guard request.isInference else { return }
        requests.append(request)
    }

    func consume(_ data: Data) {
        var buf: Data
        if carry.isEmpty {
            buf = data
        } else {
            buf = carry
            buf.append(data)
            carry = Data()
        }
        var start = buf.startIndex
        while let nl = buf[start...].firstIndex(of: 0x0A) {
            processLine(buf[start..<nl])
            start = buf.index(after: nl)
        }
        if start < buf.endIndex {
            carry = Data(buf[start...])
            if carry.count > 4_000_000 { carry.removeAll() }
        }
    }

    func connectionClosed() {
        responseEnded()
    }

    func responseEnded() {
        if !carry.isEmpty {
            processLine(carry)
            carry = Data()
        }
        finalize()
    }

    // MARK: - Line handling

    private func processLine(_ raw: Data) {
        guard !raw.isEmpty else { return }
        var s = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("event:") { return }
        if s.hasPrefix("data:") {
            s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if s == "[DONE]" { finalize(); return }
        if isChunkSizeMarker(s) { return }
        guard s.hasPrefix("{") else { return }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else {
            regexFallback(s)
            return
        }
        handle(obj)
    }

    private func isChunkSizeMarker(_ s: String) -> Bool {
        s.count <= 8 && s.allSatisfy { $0.isHexDigit }
    }

    private func ensure() {
        if state == nil {
            let request = requests.isEmpty ? nil : requests.removeFirst()
            state = CallState(
                id: UUID(),
                requestPath: request?.path,
                promptFingerprint: request?.promptFingerprint,
                model: request?.model ?? "ollama")
        }
    }

    private func handle(_ obj: [String: Any]) {
        if let m = obj["model"] as? String {
            ensure()
            state?.model = m
        }

        if let type = obj["type"] as? String {
            switch type {
            case "message_start":
                if let msg = obj["message"] as? [String: Any] {
                    if let m = msg["model"] as? String { ensure(); state?.model = m }
                    if let u = msg["usage"] as? [String: Any] { apply(u) }
                }
                emitUpdate(force: true)
            case "content_block_delta":
                ensure()
                state?.approxOutput += 1
                emitUpdate()
            case "message_delta":
                if let u = obj["usage"] as? [String: Any] { apply(u) }
            case "message_stop":
                finalize()
            case "message":   // Anthropic non-streaming response
                if let u = obj["usage"] as? [String: Any] { apply(u) }
                finalize()
            default:
                break
            }
        } else if let u = obj["usage"] as? [String: Any] {
            apply(u)
        }

        if let objType = obj["object"] as? String {
            if objType == "chat.completion.chunk" {
                ensure()
                state?.approxOutput += 1
                emitUpdate()
            } else if objType == "chat.completion" {
                finalize()
            }
        }

        if let done = obj["done"] as? Bool {
            if done {
                ensure()
                if var st = state {
                    if let v = (obj["prompt_eval_count"] as? NSNumber)?.intValue {
                        st.input = max(st.input, v)
                        st.sawUsage = true
                    }
                    if let v = (obj["eval_count"] as? NSNumber)?.intValue {
                        st.output = max(st.output, v)
                        st.sawUsage = true
                    }
                    state = st
                }
                finalize()
            } else {
                ensure()
                state?.approxOutput += 1
                emitUpdate()
            }
        }
    }

    private func apply(_ u: [String: Any]) {
        ensure()
        guard var st = state else { return }
        func intVal(_ k: String) -> Int? { (u[k] as? NSNumber)?.intValue }
        if let v = intVal("input_tokens") { st.input = max(st.input, v); st.sawUsage = true }
        if let v = intVal("output_tokens") { st.output = max(st.output, v); st.sawUsage = true }
        if let v = intVal("cache_read_input_tokens") { st.cacheRead = max(st.cacheRead, v) }
        if let v = intVal("cache_creation_input_tokens") { st.cacheCreate = max(st.cacheCreate, v) }
        if let v = intVal("prompt_tokens") { st.input = max(st.input, v); st.sawUsage = true }
        if let v = intVal("completion_tokens") { st.output = max(st.output, v); st.sawUsage = true }
        state = st
        emitUpdate()
    }

    /// Last resort for usage-bearing lines that aren't standalone JSON
    /// (e.g. a chunk boundary split a JSON object mid-line).
    private static let patterns: [(String, NSRegularExpression)] = {
        let defs: [(String, String)] = [
            ("prompt_tokens", #""prompt_eval_count":\s*(\d+)"#),
            ("completion_tokens", #""eval_count":\s*(\d+)"#),
            ("input_tokens", #""input_tokens":\s*(\d+)"#),
            ("output_tokens", #""output_tokens":\s*(\d+)"#),
            ("prompt_tokens", #""prompt_tokens":\s*(\d+)"#),
            ("completion_tokens", #""completion_tokens":\s*(\d+)"#),
        ]
        return defs.compactMap { name, p in
            (try? NSRegularExpression(pattern: p)).map { (name, $0) }
        }
    }()

    private func regexFallback(_ s: String) {
        guard s.contains("tokens\":") || s.contains("eval_count\":") || s.contains("\"done\":") else { return }
        var u: [String: Any] = [:]
        let ns = s as NSString
        for (key, re) in Self.patterns {
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1,
               let v = Int(ns.substring(with: m.range(at: 1))) {
                u[key] = max(v, (u[key] as? Int) ?? 0)
            }
        }
        if !u.isEmpty { apply(u) }
        if s.contains("\"done\":true") || s.contains("\"type\":\"message_stop\"") { finalize() }
    }

    private func emitUpdate(force: Bool = false) {
        guard let st = state else { return }
        let now = Date()
        if force || now.timeIntervalSince(lastEmit) > 0.2 {
            lastEmit = now
            onUpdate(st)
        }
    }

    private func finalize() {
        guard let st = state else { return }
        state = nil
        onFinal(st)
    }
}
