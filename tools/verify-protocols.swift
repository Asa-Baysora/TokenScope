import Foundation

@main
struct ProtocolChecks {
    static func main() throws {
        try requestMetadataAcrossArbitraryReads()
        try chunkedRequestMetadata()
        try identityRewriteAcrossArbitraryReads()
        try nativeOllamaFinalUsageAndPerformance()
        try responsesAPIUsage()
        try embeddingAndErrorCalls()
        try truncatedResponseIsCancelled()
        print("protocol checks passed")
    }

    private static func requestMetadataAcrossArbitraryReads() throws {
        var captured: [HTTPRequestMetadata] = []
        let scanner = HTTPRequestScanner { captured.append($0) }
        let body = Data(#"{"model":"qwen3:8b","stream":true,"prompt":"discard me"}"#.utf8)
        let head = Data("POST /api/generate?x=1 HTTP/1.1\r\nContent-Length: \(body.count)\r\nX-Request-ID: req-1\r\n\r\n".utf8)
        var request = head
        request.append(body)
        scanner.consume(request.prefix(11))
        scanner.consume(request.dropFirst(11).prefix(17))
        scanner.consume(request.dropFirst(28))
        try expect(captured.count == 1, "request emitted exactly once")
        try expect(captured[0].path == "/api/generate" && captured[0].operation == .generate,
                   "native generate endpoint classified")
        try expect(captured[0].model == "qwen3:8b" && captured[0].stream && captured[0].requestId == "req-1",
                   "request routing metadata captured")
    }

    private static func chunkedRequestMetadata() throws {
        var captured: [HTTPRequestMetadata] = []
        let scanner = HTTPRequestScanner { captured.append($0) }
        let body = Data(#"{"model":"gpt-oss:120b-cloud","stream":false}"#.utf8)
        let encoded = "\(String(body.count, radix: 16))\r\n\(String(decoding: body, as: UTF8.self))\r\n0\r\nX-Trace: complete\r\n\r\n"
        let next = "GET /api/version HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let request = Data(("POST /v1/responses HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + encoded + next).utf8)
        scanner.consume(request)
        try expect(captured.count == 2 && captured[0].operation == .responses
                   && captured[1].path == "/api/version",
                   "chunked request trailers and keep-alive framed")
        try expect(captured[0].executionLocation == .cloud, "cloud model classified")
    }

    private static func identityRewriteAcrossArbitraryReads() throws {
        let rewriter = HTTPIdentityEncodingRewriter()
        let body = #"{"prompt":"Accept-Encoding: preserve inside body"}"#
        let first = "POST /api/generate HTTP/1.1\r\nAccept-Encoding: gzip, br\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let second = "GET /api/version HTTP/1.1\r\nAccept-Encoding: deflate\r\n\r\n"
        let bytes = Data((first + second).utf8)
        var rewritten = Data()
        for offset in stride(from: 0, to: bytes.count, by: 7) {
            rewritten.append(rewriter.consume(Data(bytes[offset..<min(offset + 7, bytes.count)])))
        }
        let tail = rewriter.flush()
        rewritten.append(tail)
        let text = String(decoding: rewritten, as: UTF8.self)
        try expect(text.components(separatedBy: "Accept-Encoding: identity").count - 1 == 2,
                   "split and keep-alive request headers rewritten")
        try expect(text.contains(body), "request body forwarded byte-for-byte")
    }

    private static func nativeOllamaFinalUsageAndPerformance() throws {
        var final: ResponseScanner.CallState?
        let scanner = ResponseScanner(onUpdate: { _ in }, onFinal: { final = $0 })
        scanner.enqueueRequest(.init(method: "POST", path: "/api/chat", model: "gemma3",
                                     stream: true, operation: .chat, requestId: nil,
                                     executionLocation: .local))
        let body = Data("""
        {"model":"gemma3","done":false,"message":{"content":"x"}}
        {"model":"gemma3","done":true,"done_reason":"stop","prompt_eval_count":11,"eval_count":18,"total_duration":174560334,"load_duration":101397084,"prompt_eval_duration":13074791,"eval_duration":52479709}
        """.utf8)
        let response = chunkedResponse(body, chunkSize: 13)
        for offset in stride(from: 0, to: response.count, by: 9) {
            scanner.consume(Data(response[offset..<min(offset + 9, response.count)]))
        }
        scanner.connectionClosed()
        try expect(final?.input == 11 && final?.output == 18 && final?.sawUsage == true,
                   "native final usage exact")
        try expect(final?.operation == .chat && final?.finishReason == "stop" && final?.status == .succeeded,
                   "native lifecycle attributed")
        try expect((final?.tokensPerSecond ?? 0) > 300, "native throughput derived")
    }

    private static func responsesAPIUsage() throws {
        var final: ResponseScanner.CallState?
        let scanner = ResponseScanner(onUpdate: { _ in }, onFinal: { final = $0 })
        scanner.enqueueRequest(.init(method: "POST", path: "/v1/responses", model: "qwen3",
                                     stream: true, operation: .responses, requestId: "client-1",
                                     executionLocation: .local))
        let body = Data("""
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"hello"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","model":"qwen3","usage":{"input_tokens":7,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":2}}}}
        """.utf8)
        scanner.consume(chunkedResponse(body, chunkSize: 17))
        scanner.connectionClosed()
        try expect(final?.requestId == "resp_1" && final?.input == 7 && final?.output == 4,
                   "Responses API final usage parsed")
        try expect(final?.reasoning == 2 && final?.operation == .responses,
                   "Responses reasoning and operation parsed")
    }

    private static func embeddingAndErrorCalls() throws {
        var finals: [ResponseScanner.CallState] = []
        let scanner = ResponseScanner(onUpdate: { _ in }, onFinal: { finals.append($0) })
        scanner.enqueueRequest(.init(method: "POST", path: "/api/embed", model: "embeddinggemma",
                                     stream: false, operation: .embedding, requestId: nil,
                                     executionLocation: .local))
        let embedding = Data("{\"model\":\"embeddinggemma\",\"embeddings\":[[0.1]],\"prompt_eval_count\":8,\"total_duration\":10}".utf8)
        scanner.consume(fixedResponse(embedding, status: "200 OK"))
        scanner.enqueueRequest(.init(method: "POST", path: "/api/chat", model: "missing",
                                     stream: false, operation: .chat, requestId: nil,
                                     executionLocation: .local))
        let error = Data("{\"error\":\"sensitive provider message\"}".utf8)
        // Same keep-alive connection: Content-Length must end the first call
        // before this response consumes the second queued request.
        scanner.consume(fixedResponse(error, status: "404 Not Found"))
        try expect(finals.count == 2 && finals[0].input == 8 && finals[0].operation == .embedding,
                   "embedding input usage retained")
        try expect(finals[1].status == .failed && finals[1].httpStatus == 404
                   && finals[1].errorCategory == "http_404", "HTTP error categorized")
    }

    private static func truncatedResponseIsCancelled() throws {
        var final: ResponseScanner.CallState?
        let scanner = ResponseScanner(onUpdate: { _ in }, onFinal: { final = $0 })
        scanner.enqueueRequest(.init(method: "POST", path: "/api/generate", model: "qwen",
                                     stream: true, operation: .generate, requestId: nil,
                                     executionLocation: .local))
        let body = Data("{\"model\":\"qwen\",\"done\":false}\n".utf8)
        var response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count + 10)\r\n\r\n".utf8)
        response.append(body)
        scanner.consume(response)
        scanner.connectionClosed()
        try expect(final?.status == .cancelled, "truncated fixed-length response is cancelled")
    }

    private static func fixedResponse(_ body: Data, status: String) -> Data {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    private static func chunkedResponse(_ body: Data, chunkSize: Int) -> Data {
        var out = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        var offset = 0
        while offset < body.count {
            let count = min(chunkSize, body.count - offset)
            out.append(Data("\(String(count, radix: 16))\r\n".utf8))
            out.append(body[offset..<(offset + count)])
            out.append(Data("\r\n".utf8))
            offset += count
        }
        out.append(Data("0\r\n\r\n".utf8))
        return out
    }

    private static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw CheckError.failed(name) }
    }

    enum CheckError: Error { case failed(String) }
}
