import Foundation

enum OllamaHTTPVerifier {
    static func run() -> Bool {
        var ok = true
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { ok = false; fputs("FAIL: \(message)\n", stderr) }
        }

        var requests: [OllamaRequestMetadata] = []
        let inspector = OllamaRequestInspector { requests.append($0) }
        let requestBody = #"{"model":"qwen3","messages":[{"role":"user","content":"first"},{"role":"assistant","content":"ok"},{"role":"user","content":"latest"}]}"#
        let request = "POST /api/chat?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(requestBody.utf8.count)\r\n\r\n\(requestBody)"
        let requestData = Data(request.utf8)
        inspector.consume(requestData.prefix(17))
        inspector.consume(requestData.dropFirst(17))
        check(requests.count == 1, "fragmented request framing")
        if let observed = requests.first {
            check(observed.path == "/api/chat", "request path")
            check(observed.model == "qwen3", "request model")
            check(observed.promptFingerprint == OllamaRequestInspector.fingerprintText("latest"), "last-user fingerprint")
        }

        let rewriter = OllamaRequestHeaderRewriter()
        let split = Data("GET /api/ps HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\n\r\n".utf8)
        check(rewriter.consume(split.prefix(23)).isEmpty, "header rewrite waits for complete headers")
        let rewritten = String(decoding: rewriter.consume(split.dropFirst(23)), as: UTF8.self)
        check(rewritten.contains("Accept-Encoding: identity"), "safe identity encoding rewrite")
        check(!rewritten.contains("Accept-Encoding: gzip"), "compressed response disabled")

        var fixedBody = Data()
        let fixed = OllamaResponseBodyDecoder { fixedBody.append($0) }
        let first = #"{"done":true,"eval_count":3}"#
        let second = #"{"done":true,"eval_count":7}"#
        fixed.consume(Data((
            "HTTP/1.1 200 OK\r\nContent-Length: \(first.utf8.count)\r\n\r\n\(first)" +
            "HTTP/1.1 200 OK\r\nContent-Length: \(second.utf8.count)\r\n\r\n\(second)"
        ).utf8))
        check(String(decoding: fixedBody, as: UTF8.self) == first + second, "content-length connection reuse")

        var reusedFinals: [ResponseScanner.CallState] = []
        let reusedScanner = ResponseScanner(onUpdate: { _ in }, onFinal: { reusedFinals.append($0) })
        reusedScanner.observeRequest(.init(path: "/api/chat", model: "one", promptFingerprint: nil))
        reusedScanner.observeRequest(.init(path: "/api/chat", model: "two", promptFingerprint: nil))
        let framed = OllamaResponseBodyDecoder(
            onBody: { reusedScanner.consume($0) },
            onResponseEnd: { reusedScanner.responseEnded() })
        let nativeOne = #"{"done":true,"prompt_eval_count":2,"eval_count":3}"#
        let nativeTwo = #"{"done":true,"prompt_eval_count":5,"eval_count":7}"#
        framed.consume(Data((
            "HTTP/1.1 200 OK\r\nContent-Length: \(nativeOne.utf8.count)\r\n\r\n\(nativeOne)" +
            "HTTP/1.1 200 OK\r\nContent-Length: \(nativeTwo.utf8.count)\r\n\r\n\(nativeTwo)"
        ).utf8))
        check(reusedFinals.count == 2, "scanner response boundaries on reused connection")
        check(reusedFinals.map(\.output) == [3, 7], "reused connection exact counts")

        var chunkBody = Data()
        let chunked = OllamaResponseBodyDecoder { chunkBody.append($0) }
        let one = #"{"done":false}"# + "\n"
        let two = #"{"done":true,"prompt_eval_count":4,"eval_count":2}"# + "\n"
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
            String(one.utf8.count, radix: 16) + "\r\n" + one + "\r\n" +
            String(two.utf8.count, radix: 16) + "\r\n" + two + "\r\n0\r\n\r\n"
        chunked.consume(Data(response.utf8))
        check(String(decoding: chunkBody, as: UTF8.self) == one + two, "chunked decoding")

        var final: ResponseScanner.CallState?
        let scanner = ResponseScanner(onUpdate: { _ in }, onFinal: { final = $0 })
        scanner.observeRequest(.init(path: "/api/chat", model: "gemma4", promptFingerprint: "hash"))
        scanner.consume(Data((#"{"model":"gemma4","done":true,"prompt_eval_count":12,"eval_count":9}"# + "\n").utf8))
        check(final?.input == 12 && final?.output == 9, "exact final usage")
        check(final?.model == "gemma4" && final?.promptFingerprint == "hash", "request metadata propagation")

        print(ok ? "Ollama HTTP verification passed" : "Ollama HTTP verification failed")
        return ok
    }
}
