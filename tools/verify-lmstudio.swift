import Foundation

@main
struct LMStudioChecks {
    static func main() throws {
        let fixture = Data(#"{"timestamp":"2026-07-13T20:00:00Z","data":{"type":"llm.prediction.output","predictionId":"pred-1","modelIdentifier":"qwen","output":"must not be retained","stats":{"promptTokensCount":"12","predictedTokensCount":7,"reasoningTokensCount":2,"tokensPerSecond":33.5,"timeToFirstTokenSec":0.4,"generationTimeSeconds":1.2,"stopReason":"eos"}}}"#.utf8)
        guard let parsed = LMStudioEventParser.parse(fixture) else { throw CheckError.failed("output parsed") }
        try expect(parsed.event.inputTokens == 12 && parsed.event.outputTokens == 7,
                   "exact token counts")
        try expect(parsed.event.reasoningTokens == 2 && parsed.event.tokensPerSecond == 33.5,
                   "reasoning and performance stats")
        try expect(parsed.event.timeToFirstTokenSeconds == 0.4 && parsed.event.finishReason == "eos",
                   "lifecycle stats")
        try expect(parsed.event.model == "qwen" && parsed.event.tokenAccuracy == .exact,
                   "model and accuracy")
        try expect(parsed.key == "lmstudio:pred-1" && parsed.event.timestamp.timeIntervalSince1970 == 1_783_972_800,
                   "stable prediction id and ISO timestamp")
        let persisted = String(decoding: try JSONEncoder().encode(parsed.event), as: UTF8.self)
        try expect(!persisted.contains("must not be retained"), "output content cannot cross persistence boundary")

        let input = Data(#"{"timestamp":10000,"data":{"type":"llm.prediction.input","modelIdentifier":"qwen","input":"secret"}}"#.utf8)
        try expect(LMStudioEventParser.parse(input) == nil, "input content ignored")
        let missingStats = Data(#"{"timestamp":10000,"data":{"type":"llm.prediction.output","modelIdentifier":"qwen","output":"secret"}}"#.utf8)
        try expect(LMStudioEventParser.parse(missingStats) == nil, "content without stats ignored")
        print("LM Studio checks passed")
    }

    private static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw CheckError.failed(name) }
    }
    enum CheckError: Error { case failed(String) }
}
