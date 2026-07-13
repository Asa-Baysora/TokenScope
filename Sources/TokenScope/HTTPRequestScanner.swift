import Foundation

struct HTTPRequestMetadata: Equatable {
    let method: String
    let path: String
    let model: String?
    let stream: Bool
    let operation: InferenceOperation
    let requestId: String?
    let executionLocation: ExecutionLocation
    let observedAt: Date

    init(method: String, path: String, model: String?, stream: Bool,
         operation: InferenceOperation, requestId: String?,
         executionLocation: ExecutionLocation, observedAt: Date = Date()) {
        self.method = method
        self.path = path
        self.model = model
        self.stream = stream
        self.operation = operation
        self.requestId = requestId
        self.executionLocation = executionLocation
        self.observedAt = observedAt
    }
}

/// Passive HTTP/1.1 request framer for the transparent Ollama relay. It reads
/// only routing metadata and selected JSON scalars, then immediately discards
/// the request body. Prompt/message/tool content is never retained or emitted.
final class HTTPRequestScanner {
    private var buffer = Data()
    private let onRequest: (HTTPRequestMetadata) -> Void
    private static let maxBufferedRequest = 8 << 20

    init(onRequest: @escaping (HTTPRequestMetadata) -> Void) {
        self.onRequest = onRequest
    }

    func consume(_ data: Data) {
        buffer.append(data)
        parseAvailable()
        if buffer.count > Self.maxBufferedRequest { buffer.removeAll(keepingCapacity: true) }
    }

    private func parseAvailable() {
        let separator = Data("\r\n\r\n".utf8)
        while let headerRange = buffer.range(of: separator) {
            let headerData = buffer[..<headerRange.lowerBound]
            guard let header = String(data: headerData, encoding: .utf8) else {
                buffer.removeSubrange(..<headerRange.upperBound)
                continue
            }
            let headers = Self.parseHeaders(header)
            let bodyStart = headerRange.upperBound
            let body: Data
            let consumed: Int
            if headers.chunked {
                guard let decoded = Self.decodeChunked(buffer, from: bodyStart) else { return }
                body = decoded.body
                consumed = decoded.consumed
            } else {
                let length = headers.contentLength ?? 0
                guard buffer.count - bodyStart >= length else { return }
                body = Data(buffer[bodyStart..<(bodyStart + length)])
                consumed = bodyStart + length
            }
            emit(header: headers, body: body)
            buffer.removeSubrange(..<consumed)
        }
    }

    private func emit(header: ParsedHeaders, body: Data) {
        var model: String?
        var stream = false
        if !body.isEmpty,
           let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            model = object["model"] as? String
            stream = object["stream"] as? Bool ?? false
        }
        let location: ExecutionLocation
        if let lower = model?.lowercased(), lower.contains(":cloud") || lower.hasSuffix("-cloud") {
            location = .cloud
        } else {
            location = .local
        }
        onRequest(HTTPRequestMetadata(
            method: header.method,
            path: header.path,
            model: model,
            stream: stream,
            operation: Self.operation(for: header.path),
            requestId: header.requestId,
            executionLocation: location))
    }

    private struct ParsedHeaders {
        let method: String
        let path: String
        let contentLength: Int?
        let chunked: Bool
        let requestId: String?
    }

    private static func parseHeaders(_ raw: String) -> ParsedHeaders {
        let lines = raw.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        let method = request.first.map(String.init) ?? "?"
        let rawPath = request.count > 1 ? String(request[1]) : "/"
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        var length: Int?
        var chunked = false
        var requestId: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { length = Int(value) }
            if name == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
            if name == "x-request-id" || name == "request-id" { requestId = value }
        }
        return ParsedHeaders(method: method, path: path, contentLength: length,
                             chunked: chunked, requestId: requestId)
    }

    private static func operation(for path: String) -> InferenceOperation {
        switch path {
        case "/api/chat", "/v1/chat/completions", "/v1/messages": return .chat
        case "/api/generate": return .generate
        case "/v1/completions": return .completion
        case "/v1/responses": return .responses
        case "/api/embed", "/api/embeddings", "/v1/embeddings": return .embedding
        case "/v1/images/generations": return .image
        default: return .unknown
        }
    }

    private static func decodeChunked(_ data: Data, from start: Int) -> (body: Data, consumed: Int)? {
        var cursor = start
        var body = Data()
        let crlf = Data("\r\n".utf8)
        while true {
            guard cursor < data.count,
                  let sizeRange = data[cursor...].range(of: crlf),
                  let sizeText = String(data: data[cursor..<sizeRange.lowerBound], encoding: .utf8),
                  let size = Int(sizeText.split(separator: ";", maxSplits: 1)[0], radix: 16) else { return nil }
            cursor = sizeRange.upperBound
            if size == 0 {
                guard data.count - cursor >= 2 else { return nil }
                if data[cursor...].starts(with: crlf) {
                    return (body, cursor + 2) // empty trailer section
                }
                let trailerEnd = Data("\r\n\r\n".utf8)
                guard let end = data[cursor...].range(of: trailerEnd) else { return nil }
                return (body, end.upperBound)
            }
            guard data.count - cursor >= size + 2 else { return nil }
            body.append(data[cursor..<(cursor + size)])
            cursor += size
            guard data[cursor..<(cursor + 2)] == crlf else { return nil }
            cursor += 2
            if body.count > maxBufferedRequest { return nil }
        }
    }
}
