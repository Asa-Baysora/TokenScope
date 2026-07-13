import Foundation

/// Streaming request-header rewriter used by the transparent proxy. It buffers
/// only HTTP framing boundaries, forwards body bytes unchanged, and therefore
/// still works when `Accept-Encoding` is split across arbitrary TCP reads.
final class HTTPIdentityEncodingRewriter {
    private enum Mode {
        case headers
        case fixedBody(Int)
        case chunkSize
        case chunkBody(Int)
        case chunkEnding
        case trailers
        case opaque
    }

    private var mode: Mode = .headers
    private var buffer = Data()
    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let maxHeaderBytes = 128 << 10

    func consume(_ data: Data) -> Data {
        buffer.append(data)
        var output = Data()
        parseAvailable(into: &output)
        return output
    }

    func flush() -> Data {
        // Relay lifetime ends immediately after this flush, so avoiding a
        // needless mutation also preserves Data's potentially sliced indices.
        buffer
    }

    private func parseAvailable(into output: inout Data) {
        while true {
            switch mode {
            case .headers:
                guard let end = buffer.range(of: Self.headerEnd) else {
                    if buffer.count > Self.maxHeaderBytes {
                        output.append(buffer)
                        buffer.removeAll(keepingCapacity: true)
                        mode = .opaque
                    }
                    return
                }
                let original = Data(buffer[..<end.upperBound])
                buffer.removeSubrange(..<end.upperBound)
                guard let raw = String(data: original, encoding: .utf8) else {
                    output.append(original)
                    continue
                }
                let parsed = Self.rewrite(raw)
                output.append(Data(parsed.header.utf8))
                if parsed.chunked { mode = .chunkSize }
                else if let length = parsed.contentLength, length > 0 { mode = .fixedBody(length) }
                else { mode = .headers }

            case .fixedBody(let remaining):
                guard !buffer.isEmpty else { return }
                let count = min(remaining, buffer.count)
                output.append(buffer.prefix(count))
                buffer.removeFirst(count)
                mode = count == remaining ? .headers : .fixedBody(remaining - count)

            case .chunkSize:
                guard let end = buffer.range(of: Self.crlf) else { return }
                let lineData = Data(buffer[..<end.upperBound])
                let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                output.append(lineData)
                buffer.removeSubrange(..<end.upperBound)
                let token = line.split(separator: ";", maxSplits: 1).first ?? ""
                guard let size = Int(token.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    mode = .opaque
                    continue
                }
                mode = size == 0 ? .trailers : .chunkBody(size)

            case .chunkBody(let remaining):
                guard !buffer.isEmpty else { return }
                let count = min(remaining, buffer.count)
                output.append(buffer.prefix(count))
                buffer.removeFirst(count)
                mode = count == remaining ? .chunkEnding : .chunkBody(remaining - count)

            case .chunkEnding:
                guard buffer.count >= 2 else { return }
                output.append(buffer.prefix(2))
                if buffer.prefix(2) != Self.crlf { mode = .opaque }
                else { mode = .chunkSize }
                buffer.removeFirst(2)

            case .trailers:
                guard let end = buffer.range(of: Self.crlf) else { return }
                let empty = end.lowerBound == buffer.startIndex
                output.append(buffer[..<end.upperBound])
                buffer.removeSubrange(..<end.upperBound)
                if empty { mode = .headers }

            case .opaque:
                output.append(buffer)
                buffer.removeAll(keepingCapacity: true)
                return
            }
        }
    }

    private static func rewrite(_ raw: String) -> (header: String, contentLength: Int?, chunked: Bool) {
        var lines = raw.components(separatedBy: "\r\n")
        var length: Int?
        var chunked = false
        for index in lines.indices.dropFirst() {
            guard let colon = lines[index].firstIndex(of: ":") else { continue }
            let name = lines[index][..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = lines[index][lines[index].index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "accept-encoding" { lines[index] = "Accept-Encoding: identity" }
            if name == "content-length" { length = Int(value) }
            if name == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
        }
        return (lines.joined(separator: "\r\n"), length, chunked)
    }
}
