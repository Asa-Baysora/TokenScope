import Foundation

enum LMStudioEventParser {
    static func parse(_ line: Data) -> (event: UsageEvent, key: String)? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let data = object["data"] as? [String: Any],
              data["type"] as? String == "llm.prediction.output",
              let stats = data["stats"] as? [String: Any] else { return nil }
        let prompt = int(stats["promptTokensCount"]) ?? 0
        let predicted = int(stats["predictedTokensCount"]) ?? 0
        guard prompt > 0 || predicted > 0 else { return nil }
        let model = (data["modelIdentifier"] as? String)
            ?? (data["modelPath"] as? String) ?? "LM Studio"
        let timestamp = timestamp(object["timestamp"]) ?? Date()
        let reasoning = int(stats["reasoningTokensCount"])
            ?? int(stats["reasoning_output_tokens"]) ?? 0
        let event = UsageEvent(
            timestamp: timestamp, provider: .lmStudio, source: .lmStudioLog,
            model: model, sessionId: "lmstudio:\(model)", projectName: nil,
            inputTokens: prompt, outputTokens: predicted,
            cacheReadTokens: 0, cacheCreationTokens: 0,
            reasoningTokens: reasoning, tokenAccuracy: .exact,
            operation: .unknown, status: .succeeded, executionLocation: .local,
            finishReason: stats["stopReason"] as? String,
            durationSeconds: firstDouble(stats, ["generationTimeSeconds", "generationTimeSec", "generation_time_seconds"]),
            loadDurationSeconds: firstDouble(stats, ["modelLoadTimeSeconds", "model_load_time_seconds"]),
            timeToFirstTokenSeconds: firstDouble(stats, ["timeToFirstTokenSeconds", "timeToFirstTokenSec", "time_to_first_token_seconds"]),
            tokensPerSecond: firstDouble(stats, ["tokensPerSecond", "tokens_per_second"]))
        let eventID = (data["predictionId"] as? String) ?? (data["id"] as? String)
        let key = eventID.map { "lmstudio:\($0)" }
            ?? "lmstudio:\(timestamp.timeIntervalSince1970):\(prompt):\(predicted):\(model)"
        return (event, key)
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func firstDouble(_ object: [String: Any], _ keys: [String]) -> Double? {
        for key in keys { if let value = double(object[key]) { return value } }
        return nil
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let number = double(value) {
            // Current CLI telemetry uses epoch milliseconds; accept seconds for
            // compatibility with older or alternate JSON emitters.
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }
}
