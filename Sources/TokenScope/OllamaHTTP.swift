import Foundation
import CryptoKit

struct OllamaRequestMetadata: Equatable {
    let path: String
    let model: String?
    let promptFingerprint: String?

    var isInference: Bool {
        path == "/api/chat" || path == "/api/generate" ||
        path == "/v1/chat/completions" || path == "/v1/responses" ||
        path == "/v1/messages"
    }
}

/// Rewrites only complete HTTP header blocks, so a network packet split can
/// never turn a partial header into malformed traffic. Bodies remain byte-for-
/// byte identical.
final class OllamaRequestHeaderRewriter {
    private enum Mode { case headers, fixed(Int), passthrough }
    private var mode: Mode = .headers
    private var buffer = Data()

    func consume(_ data: Data) -> Data {
        buffer.append(data)
        var output = Data()
        while !buffer.isEmpty {
            switch mode {
            case .headers:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return output }
                var header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                let hasEncoding = lines.contains { $0.lowercased().hasPrefix("accept-encoding:") }
                if hasEncoding {
                    header = lines.map { line in
                        line.lowercased().hasPrefix("accept-encoding:") ? "Accept-Encoding: identity" : line
                    }.joined(separator: "\r\n")
                } else {
                    header += "\r\nAccept-Encoding: identity"
                }
                output.append(Data((header + "\r\n\r\n").utf8))
                buffer.removeSubrange(..<end.upperBound)
                let length = lines.compactMap { line -> Int? in
                    let p = line.split(separator: ":", maxSplits: 1)
                    guard p.count == 2, p[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                    return Int(p[1].trimmingCharacters(in: .whitespaces))
                }.first
                let chunked = lines.contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
                mode = length.map(Mode.fixed) ?? (chunked ? .passthrough : .fixed(0))
            case .fixed(let remaining):
                if remaining == 0 { mode = .headers; continue }
                let count = min(remaining, buffer.count)
                output.append(buffer.prefix(count))
                buffer.removeFirst(count)
                mode = count == remaining ? .headers : .fixed(remaining - count)
            case .passthrough:
                output.append(buffer)
                buffer.removeAll()
            }
        }
        return output
    }
}

/// Incrementally frames HTTP/1 requests. It never persists request bodies. A
/// SHA-256 of the last user prompt is retained only long enough to associate an
/// Ollama Desktop database row with the corresponding gateway call.
final class OllamaRequestInspector {
    private var buffer = Data()
    private let onRequest: (OllamaRequestMetadata) -> Void

    init(onRequest: @escaping (OllamaRequestMetadata) -> Void) {
        self.onRequest = onRequest
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while parseOne() {}
        if buffer.count > 16_000_000 { buffer.removeAll() }
    }

    private func parseOne() -> Bool {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return false }
        let requestParts = first.split(separator: " ")
        guard requestParts.count >= 2 else { buffer.removeAll(); return false }
        let path = String(requestParts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        var contentLength = 0
        for line in lines.dropFirst() {
            let p = line.split(separator: ":", maxSplits: 1)
            if p.count == 2, p[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(p[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count >= bodyStart + contentLength else { return false }
        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let model = json?["model"] as? String
        onRequest(.init(path: path, model: model, promptFingerprint: Self.fingerprint(json)))
        buffer.removeSubrange(..<(bodyStart + contentLength))
        return !buffer.isEmpty
    }

    static func fingerprintText(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(_ json: [String: Any]?) -> String? {
        guard let json else { return nil }
        if let prompt = json["prompt"] as? String { return fingerprintText(prompt) }
        guard let messages = json["messages"] as? [[String: Any]] else { return nil }
        for message in messages.reversed() where message["role"] as? String == "user" {
            if let content = message["content"] as? String { return fingerprintText(content) }
            if let blocks = message["content"] as? [[String: Any]] {
                let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { return fingerprintText(text) }
            }
        }
        return nil
    }
}

/// Removes HTTP response headers and transfer framing before bytes reach the
/// JSON/SSE scanner. Handles fragmented headers, Content-Length, and chunked
/// streaming responses while preserving connection reuse.
final class OllamaResponseBodyDecoder {
    private enum BodyMode { case headers, fixed(Int), chunkSize, chunk(Int), untilClose }
    private var buffer = Data()
    private var mode: BodyMode = .headers
    private let onBody: (Data) -> Void
    private let onResponseEnd: () -> Void

    init(onBody: @escaping (Data) -> Void, onResponseEnd: @escaping () -> Void = {}) {
        self.onBody = onBody
        self.onResponseEnd = onResponseEnd
    }

    func consume(_ data: Data) {
        buffer.append(data)
        drain()
    }

    func connectionClosed() {
        if case .untilClose = mode, !buffer.isEmpty { onBody(buffer) }
        onResponseEnd()
        buffer.removeAll()
        mode = .headers
    }

    private func drain() {
        while true {
            switch mode {
            case .headers:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<end.upperBound)
                let fields = header.components(separatedBy: "\r\n").dropFirst()
                let chunked = fields.contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
                let length = fields.compactMap { line -> Int? in
                    let p = line.split(separator: ":", maxSplits: 1)
                    guard p.count == 2, p[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                    return Int(p[1].trimmingCharacters(in: .whitespaces))
                }.first
                mode = chunked ? .chunkSize : length.map(BodyMode.fixed) ?? .untilClose
            case .fixed(let remaining):
                guard !buffer.isEmpty else { return }
                let count = min(remaining, buffer.count)
                onBody(Data(buffer.prefix(count)))
                buffer.removeFirst(count)
                if count == remaining {
                    onResponseEnd()
                    mode = .headers
                } else {
                    mode = .fixed(remaining - count)
                }
            case .chunkSize:
                guard let end = buffer.range(of: Data("\r\n".utf8)) else { return }
                let raw = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).split(separator: ";", maxSplits: 1)[0]
                guard let size = Int(raw.trimmingCharacters(in: .whitespaces), radix: 16) else { buffer.removeAll(); return }
                buffer.removeSubrange(..<end.upperBound)
                if size == 0 {
                    if let trailers = buffer.range(of: Data("\r\n\r\n".utf8)) { buffer.removeSubrange(..<trailers.upperBound) }
                    else if buffer.starts(with: Data("\r\n".utf8)) { buffer.removeFirst(2) }
                    onResponseEnd()
                    mode = .headers
                } else { mode = .chunk(size) }
            case .chunk(let count):
                guard buffer.count >= count + 2 else { return }
                onBody(Data(buffer.prefix(count)))
                buffer.removeFirst(count + 2)
                mode = .chunkSize
            case .untilClose:
                guard !buffer.isEmpty else { return }
                onBody(buffer)
                buffer.removeAll()
                return
            }
        }
    }
}
