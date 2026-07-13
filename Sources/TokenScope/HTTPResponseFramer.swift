import Foundation

/// Streaming HTTP/1.1 response-body decoder. It removes transport framing but
/// never interprets or retains body content beyond the bytes needed for the
/// current header/chunk boundary.
final class HTTPResponseFramer {
    private enum Mode {
        case headers
        case fixedBody(Int)
        case chunkSize
        case chunkBody(Int)
        case chunkEnding
        case trailers
        case untilClose
    }

    private var mode: Mode = .headers
    private var buffer = Data()
    private let onStatus: (Int) -> Void
    private let onBody: (Data) -> Void
    private let onResponseEnd: (Bool) -> Void
    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let maxHeaderBytes = 128 << 10

    init(onStatus: @escaping (Int) -> Void,
         onBody: @escaping (Data) -> Void,
         onResponseEnd: @escaping (Bool) -> Void) {
        self.onStatus = onStatus
        self.onBody = onBody
        self.onResponseEnd = onResponseEnd
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        parseAvailable()
    }

    func connectionClosed() {
        if case .untilClose = mode, !buffer.isEmpty {
            onBody(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        if case .headers = mode {
            // No response is in progress.
        } else {
            let complete: Bool
            if case .untilClose = mode { complete = true } else { complete = false }
            onResponseEnd(complete)
        }
        mode = .headers
        buffer.removeAll(keepingCapacity: true)
    }

    private func parseAvailable() {
        while true {
            switch mode {
            case .headers:
                guard let end = buffer.range(of: Self.headerEnd) else {
                    if buffer.count > Self.maxHeaderBytes { buffer.removeAll(keepingCapacity: true) }
                    return
                }
                let block = Data(buffer[..<end.lowerBound])
                buffer.removeSubrange(..<end.upperBound)
                guard let header = String(data: block, encoding: .utf8) else { continue }
                let parsed = Self.parseHeaders(header)
                guard let status = parsed.status else { continue }
                // Interim responses do not consume the queued request.
                if (100..<200).contains(status) { continue }
                onStatus(status)
                if status == 204 || status == 304 {
                    onResponseEnd(true)
                } else if parsed.chunked {
                    mode = .chunkSize
                } else if let length = parsed.contentLength {
                    if length == 0 { onResponseEnd(true) } else { mode = .fixedBody(length) }
                } else {
                    mode = .untilClose
                }

            case .fixedBody(let remaining):
                guard !buffer.isEmpty else { return }
                let count = min(remaining, buffer.count)
                onBody(Data(buffer.prefix(count)))
                buffer.removeFirst(count)
                if count == remaining {
                    mode = .headers
                    onResponseEnd(true)
                } else {
                    mode = .fixedBody(remaining - count)
                }

            case .chunkSize:
                guard let end = buffer.range(of: Self.crlf) else { return }
                let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<end.upperBound)
                let token = line.split(separator: ";", maxSplits: 1).first ?? ""
                guard let size = Int(token.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    mode = .untilClose
                    continue
                }
                mode = size == 0 ? .trailers : .chunkBody(size)

            case .chunkBody(let remaining):
                guard !buffer.isEmpty else { return }
                let count = min(remaining, buffer.count)
                onBody(Data(buffer.prefix(count)))
                buffer.removeFirst(count)
                mode = count == remaining ? .chunkEnding : .chunkBody(remaining - count)

            case .chunkEnding:
                guard buffer.count >= 2 else { return }
                guard buffer.prefix(2) == Self.crlf else { mode = .untilClose; continue }
                buffer.removeFirst(2)
                mode = .chunkSize

            case .trailers:
                guard let end = buffer.range(of: Self.crlf) else { return }
                let empty = end.lowerBound == buffer.startIndex
                buffer.removeSubrange(..<end.upperBound)
                if empty {
                    mode = .headers
                    onResponseEnd(true)
                }

            case .untilClose:
                guard !buffer.isEmpty else { return }
                onBody(buffer)
                buffer.removeAll(keepingCapacity: true)
                return
            }
        }
    }

    private static func parseHeaders(_ raw: String) -> (status: Int?, contentLength: Int?, chunked: Bool) {
        let lines = raw.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        var length: Int?
        var chunked = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { length = Int(value) }
            if name == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
        }
        return (status, length, chunked)
    }
}
