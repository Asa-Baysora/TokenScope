import Foundation

/// Observes the server-to-client side of one proxied HTTP connection. Request
/// metadata is supplied by HTTPRequestScanner, so response usage is attributed
/// to an endpoint/operation instead of guessed from response fragments alone.
final class ResponseScanner {
    struct CallState {
        let id = UUID()
        var model: String
        var input = 0
        var output = 0
        var reasoning = 0
        var cacheRead = 0
        var cacheCreate = 0
        var approxOutput = 0
        var sawUsage = false
        let startedAt: Date
        var operation: InferenceOperation
        var endpoint: String?
        var requestId: String?
        var executionLocation: ExecutionLocation
        var httpStatus: Int?
        var finishReason: String?
        var errorCategory: String?
        var status: CallStatus = .running
        var durationSeconds: Double?
        var loadDurationSeconds: Double?
        var promptEvalDurationSeconds: Double?
        var evalDurationSeconds: Double?
        var timeToFirstTokenSeconds: Double?
        var tokensPerSecond: Double?

        init(request: HTTPRequestMetadata?) {
            startedAt = request?.observedAt ?? Date()
            model = request?.model ?? "ollama"
            operation = request?.operation ?? .unknown
            endpoint = request?.path
            requestId = request?.requestId
            executionLocation = request?.executionLocation ?? .unknown
        }

        var displayOutput: Int { output > 0 ? output : approxOutput }
    }

    private var carry = Data()
    private lazy var responseFramer = HTTPResponseFramer(
        onStatus: { [weak self] in self?.processStatus($0) },
        onBody: { [weak self] in self?.consumeBody($0) },
        onResponseEnd: { [weak self] complete in self?.responseEnded(complete: complete) })
    private var state: CallState?
    private var pendingRequests: [HTTPRequestMetadata] = []
    private var lastEmit = Date.distantPast
    private let onUpdate: (CallState) -> Void
    private let onFinal: (CallState) -> Void

    init(onUpdate: @escaping (CallState) -> Void, onFinal: @escaping (CallState) -> Void) {
        self.onUpdate = onUpdate
        self.onFinal = onFinal
    }

    func enqueueRequest(_ request: HTTPRequestMetadata) {
        pendingRequests.append(request)
    }

    func consume(_ data: Data) {
        responseFramer.consume(data)
    }

    private func consumeBody(_ data: Data) {
        var buf = carry
        buf.append(data)
        carry.removeAll(keepingCapacity: true)
        var start = buf.startIndex
        while start < buf.endIndex, let nl = buf[start...].firstIndex(of: 0x0A) {
            processLine(buf[start..<nl])
            start = buf.index(after: nl)
        }
        if start < buf.endIndex {
            carry = Data(buf[start...])
            if carry.count > 4_000_000 { carry.removeAll(keepingCapacity: true) }
        }
    }

    func connectionClosed() {
        responseFramer.connectionClosed()
    }

    private func responseEnded(complete: Bool) {
        if !carry.isEmpty {
            processLine(carry)
            carry.removeAll(keepingCapacity: true)
        }
        if !complete, state?.status == .running { state?.status = .cancelled }
        finalize(success: nil)
    }

    private func processStatus(_ code: Int) {
        ensure()
        state?.httpStatus = code
        if code >= 400 {
            state?.status = .failed
            state?.errorCategory = "http_\(code)"
        }
    }

    private func processLine(_ raw: Data) {
        guard !raw.isEmpty else { return }
        var line = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("event:") { return }
        if line.hasPrefix("data:") {
            line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if line == "[DONE]" { finalize(success: true); return }
        if isChunkSizeMarker(line) { return }
        guard line.hasPrefix("{") else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            regexFallback(line)
            return
        }
        handle(object)
    }

    private func isChunkSizeMarker(_ line: String) -> Bool {
        line.count <= 8 && line.allSatisfy { $0.isHexDigit }
    }

    private func ensure() {
        guard state == nil else { return }
        let request = pendingRequests.isEmpty ? nil : pendingRequests.removeFirst()
        state = CallState(request: request)
    }

    private func handle(_ object: [String: Any]) {
        ensure()
        if let model = object["model"] as? String { state?.model = model }
        if let id = object["id"] as? String, state?.requestId == nil { state?.requestId = id }

        if object["error"] != nil {
            let category = state?.httpStatus.map { "http_\($0)" } ?? "provider_error"
            state?.status = .failed
            state?.errorCategory = category
            finalize(success: false)
            return
        }

        if let type = object["type"] as? String {
            switch type {
            case "message_start":
                if let message = object["message"] as? [String: Any] {
                    if let model = message["model"] as? String { state?.model = model }
                    if let id = message["id"] as? String { state?.requestId = id }
                    if let usage = message["usage"] as? [String: Any] { apply(usage) }
                }
                emitUpdate(force: true)
            case "content_block_delta", "response.output_text.delta", "response.reasoning_text.delta":
                markFirstToken()
                state?.approxOutput += 1
                emitUpdate()
            case "message_delta":
                if let usage = object["usage"] as? [String: Any] { apply(usage) }
                if let delta = object["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    state?.finishReason = reason
                }
            case "message_stop":
                finalize(success: true)
            case "message":
                if let usage = object["usage"] as? [String: Any] { apply(usage) }
                state?.finishReason = object["stop_reason"] as? String
                finalize(success: true)
            case "response.created", "response.in_progress":
                if let response = object["response"] as? [String: Any] { applyResponse(response) }
                emitUpdate(force: true)
            case "response.completed":
                if let response = object["response"] as? [String: Any] { applyResponse(response) }
                finalize(success: true)
            case "response.failed", "error":
                if let response = object["response"] as? [String: Any] { applyResponse(response) }
                state?.status = .failed
                state?.errorCategory = "provider_error"
                finalize(success: false)
            default:
                break
            }
        }

        if let usage = object["usage"] as? [String: Any] { apply(usage) }

        if let objectType = object["object"] as? String {
            switch objectType {
            case "chat.completion.chunk", "text_completion":
                markFirstToken()
                state?.approxOutput += 1
                captureFinishReason(object)
                emitUpdate()
            case "chat.completion":
                captureFinishReason(object)
                finalize(success: true)
            case "list" where state?.operation == .embedding:
                finalize(success: true)
            case "response":
                applyResponse(object)
                if object["status"] as? String == "completed" { finalize(success: true) }
            default:
                break
            }
        }

        if object["embeddings"] != nil, state?.operation == .embedding {
            applyNativeMetrics(object)
            finalize(success: true)
            return
        }

        if let done = object["done"] as? Bool {
            if done {
                applyNativeMetrics(object)
                state?.finishReason = object["done_reason"] as? String
                finalize(success: true)
            } else {
                markFirstToken()
                state?.approxOutput += 1
                emitUpdate()
            }
        }
    }

    private func applyResponse(_ response: [String: Any]) {
        if let model = response["model"] as? String { state?.model = model }
        if let id = response["id"] as? String { state?.requestId = id }
        if let usage = response["usage"] as? [String: Any] { apply(usage) }
        if let reason = response["incomplete_details"] as? [String: Any],
           let value = reason["reason"] as? String { state?.finishReason = value }
    }

    private func apply(_ usage: [String: Any]) {
        ensure()
        guard var current = state else { return }
        func int(_ key: String) -> Int? { (usage[key] as? NSNumber)?.intValue }
        if let value = int("input_tokens") { current.input = max(current.input, value); current.sawUsage = true }
        if let value = int("output_tokens") { current.output = max(current.output, value); current.sawUsage = true }
        if let value = int("total_output_tokens") { current.output = max(current.output, value); current.sawUsage = true }
        if let value = int("reasoning_output_tokens") { current.reasoning = max(current.reasoning, value) }
        if let value = int("cache_read_input_tokens") { current.cacheRead = max(current.cacheRead, value) }
        if let value = int("cache_creation_input_tokens") { current.cacheCreate = max(current.cacheCreate, value) }
        if let value = int("prompt_tokens") { current.input = max(current.input, value); current.sawUsage = true }
        if let value = int("completion_tokens") { current.output = max(current.output, value); current.sawUsage = true }
        if let details = usage["input_tokens_details"] as? [String: Any],
           let value = (details["cached_tokens"] as? NSNumber)?.intValue {
            current.cacheRead = max(current.cacheRead, value)
        }
        if let details = usage["output_tokens_details"] as? [String: Any],
           let value = (details["reasoning_tokens"] as? NSNumber)?.intValue {
            current.reasoning = max(current.reasoning, value)
        }
        state = current
        emitUpdate()
    }

    private func applyNativeMetrics(_ object: [String: Any]) {
        guard var current = state else { return }
        if let value = (object["prompt_eval_count"] as? NSNumber)?.intValue {
            current.input = max(current.input, value); current.sawUsage = true
        }
        if let value = (object["eval_count"] as? NSNumber)?.intValue {
            current.output = max(current.output, value); current.sawUsage = true
        }
        func seconds(_ key: String) -> Double? {
            (object[key] as? NSNumber).map { $0.doubleValue / 1_000_000_000 }
        }
        current.durationSeconds = seconds("total_duration")
        current.loadDurationSeconds = seconds("load_duration")
        current.promptEvalDurationSeconds = seconds("prompt_eval_duration")
        current.evalDurationSeconds = seconds("eval_duration")
        if let duration = current.evalDurationSeconds, duration > 0, current.output > 0 {
            current.tokensPerSecond = Double(current.output) / duration
        }
        state = current
    }

    private func captureFinishReason(_ object: [String: Any]) {
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first, let reason = first["finish_reason"] as? String else { return }
        state?.finishReason = reason
    }

    private static let patterns: [(String, NSRegularExpression)] = {
        let definitions: [(String, String)] = [
            ("prompt_tokens", #""prompt_eval_count":\s*(\d+)"#),
            ("completion_tokens", #""eval_count":\s*(\d+)"#),
            ("input_tokens", #""input_tokens":\s*(\d+)"#),
            ("output_tokens", #""output_tokens":\s*(\d+)"#),
            ("prompt_tokens", #""prompt_tokens":\s*(\d+)"#),
            ("completion_tokens", #""completion_tokens":\s*(\d+)"#),
        ]
        return definitions.compactMap { key, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (key, $0) }
        }
    }()

    private func regexFallback(_ line: String) {
        guard line.contains("tokens\":") || line.contains("eval_count\":") || line.contains("\"done\":") else { return }
        var usage: [String: Any] = [:]
        let string = line as NSString
        for (key, expression) in Self.patterns {
            if let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: string.length)),
               match.numberOfRanges > 1, let value = Int(string.substring(with: match.range(at: 1))) {
                usage[key] = max(value, (usage[key] as? Int) ?? 0)
            }
        }
        if !usage.isEmpty { apply(usage) }
        if line.contains("\"done\":true") || line.contains("\"type\":\"message_stop\"") {
            finalize(success: true)
        }
    }

    private func emitUpdate(force: Bool = false) {
        guard let current = state else { return }
        let now = Date()
        if force || now.timeIntervalSince(lastEmit) > 0.2 {
            lastEmit = now
            onUpdate(current)
        }
    }

    private func markFirstToken() {
        guard state?.timeToFirstTokenSeconds == nil, let startedAt = state?.startedAt else { return }
        state?.timeToFirstTokenSeconds = max(0, Date().timeIntervalSince(startedAt))
    }

    private func finalize(success: Bool?) {
        guard var final = state else { return }
        if final.durationSeconds == nil {
            final.durationSeconds = max(0, Date().timeIntervalSince(final.startedAt))
        }
        if final.status == .running {
            if success == true || (success == nil && final.sawUsage) {
                final.status = .succeeded
            } else if success == false {
                final.status = .failed
            } else {
                final.status = .cancelled
            }
        }
        state = nil
        onFinal(final)
    }
}
